#!/usr/bin/env python3
"""
Luanti-Ollama-NPC Brain Controller
Orchestrates the NPC decision loop: Read State -> Query Ollama -> Execute Action
"""

import json
import os
import sys
import time
import logging
import tempfile
import shutil
from pathlib import Path
from typing import Optional, Dict, Any
import urllib.request
import urllib.error

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler('npc_brain.log')
    ]
)
logger = logging.getLogger(__name__)


class Config:
    """Configuration manager for NPC brain."""
    
    def __init__(self, config_path: str = "config.json"):
        self.config_path = Path(config_path)
        self.data = self._load_config()
    
    def _load_config(self) -> Dict[str, Any]:
        """Load configuration from JSON file."""
        if not self.config_path.exists():
            logger.warning(f"Config file not found: {self.config_path}, using defaults")
            return self._default_config()
        
        try:
            with open(self.config_path, 'r') as f:
                data = json.load(f)
            logger.info(f"Loaded config from {self.config_path}")
            return data
        except json.JSONDecodeError as e:
            logger.error(f"Invalid JSON in config file: {e}")
            return self._default_config()
        except Exception as e:
            logger.error(f"Error loading config: {e}")
            return self._default_config()
    
    def _default_config(self) -> Dict[str, Any]:
        """Return default configuration."""
        return {
            "ollama": {
                "host": "http://127.0.0.1:11434",
                "model": "llama3.2",
                "timeout": 30,
                "temperature": 0.7
            },
            "npc": {
                "name": "AutoBot",
                "spawn_pos": {"x": 0, "y": 50, "z": 0},
                "personality_prompt": "You are a helpful and curious NPC exploring a voxel world.",
                "update_interval": 2.0
            },
            "paths": {
                "commands_file": "commands.json",
                "state_file": "state.json"
            },
            "behavior": {
                "move_radius": 5,
                "dig_depth_limit": -10,
                "build_schematic_max_size": 10
            }
        }
    
    @property
    def ollama_host(self) -> str:
        return self.data.get("ollama", {}).get("host", "http://127.0.0.1:11434")
    
    @property
    def model(self) -> str:
        return self.data.get("ollama", {}).get("model", "llama3.2")
    
    @property
    def timeout(self) -> int:
        return self.data.get("ollama", {}).get("timeout", 30)
    
    @property
    def temperature(self) -> float:
        return self.data.get("ollama", {}).get("temperature", 0.7)
    
    @property
    def npc_name(self) -> str:
        return self.data.get("npc", {}).get("name", "AutoBot")
    
    @property
    def personality_prompt(self) -> str:
        return self.data.get("npc", {}).get("personality_prompt", "")
    
    @property
    def update_interval(self) -> float:
        return self.data.get("npc", {}).get("update_interval", 2.0)
    
    @property
    def commands_file(self) -> Path:
        path_str = self.data.get("paths", {}).get("commands_file", "commands.json")
        return Path(path_str)
    
    @property
    def state_file(self) -> Path:
        path_str = self.data.get("paths", {}).get("state_file", "state.json")
        return Path(path_str)


class AtomicFileWriter:
    """Handle atomic file writes to prevent race conditions."""
    
    @staticmethod
    def write(filepath: Path, content: str) -> bool:
        """Write content atomically using temp file + rename."""
        try:
            # Create temp file in same directory for atomic rename
            fd, temp_path = tempfile.mkstemp(
                suffix='.tmp',
                prefix='npc_cmd_',
                dir=filepath.parent
            )
            try:
                with os.fdopen(fd, 'w') as f:
                    f.write(content)
                
                # Atomic rename
                shutil.move(temp_path, filepath)
                logger.debug(f"Atomic write successful: {filepath}")
                return True
            except Exception as e:
                logger.error(f"Error during atomic write: {e}")
                # Clean up temp file on failure
                if os.path.exists(temp_path):
                    os.unlink(temp_path)
                return False
        except Exception as e:
            logger.error(f"Failed to create temp file: {e}")
            return False


def read_json_file(filepath: Path) -> Optional[Dict[str, Any]]:
    """Safely read and parse a JSON file."""
    if not filepath.exists():
        logger.debug(f"File not found: {filepath}")
        return None
    
    try:
        with open(filepath, 'r') as f:
            data = json.load(f)
        return data
    except json.JSONDecodeError as e:
        logger.error(f"JSON parse error in {filepath}: {e}")
        return None
    except Exception as e:
        logger.error(f"Error reading {filepath}: {e}")
        return None


def get_state(state_file: Path) -> Optional[Dict[str, Any]]:
    """Read and parse the current state from state.json."""
    return read_json_file(state_file)


def send_command(commands_file: Path, action: str, params: Dict[str, Any], 
                 npc_name: str, command_id: int) -> bool:
    """Write command to commands.json atomically."""
    command = {
        "id": command_id,
        "npc_name": npc_name,
        "action": action,
        "params": params,
        "timestamp": time.time()
    }
    
    content = json.dumps(command, indent=2)
    return AtomicFileWriter.write(commands_file, content)


def load_prompt_template(template_path: str = "prompt_template.txt") -> str:
    """Load the prompt template from file."""
    path = Path(template_path)
    if not path.exists():
        logger.warning(f"Prompt template not found: {path}, using default")
        return DEFAULT_PROMPT_TEMPLATE
    
    try:
        with open(path, 'r') as f:
            return f.read()
    except Exception as e:
        logger.error(f"Error loading prompt template: {e}")
        return DEFAULT_PROMPT_TEMPLATE


DEFAULT_PROMPT_TEMPLATE = """You are an autonomous NPC in a Luanti (Minetest) voxel world.
{personality}

CURRENT STATE:
- Position: {pos}
- Yaw (rotation): {yaw} radians
- Health: {hp}/10
- Nearby blocks (within 5 blocks): {nearby_blocks}

AVAILABLE ACTIONS:
1. "move" - Move in a direction
   Params: {{"direction": "forward|backward|left|right|up|down", "distance": 1}}
   OR: {{"x": number, "y": number, "z": number}} for direct position

2. "turn" - Rotate the NPC
   Params: {{"angle": 90, "direction": "left|right"}}

3. "dig" - Dig a block
   Params: {{"offset": {{"x": 0, "y": -1, "z": 0}}}}

4. "place" - Place a block
   Params: {{"node": "default:dirt", "offset": {{"x": 0, "y": -1, "z": 0}}}}

5. "build_schematic" - Build a structure
   Params: {{"schematic": [{{"pos": {{"x": 0, "y": 0, "z": 0}}, "name": "default:stone"}}]}}

RESPONSE FORMAT:
You MUST respond with ONLY valid JSON in this exact format:
{{
    "action": "<action_type>",
    "params": {{...}},
    "reason": "<brief explanation of why you chose this action>"
}}

IMPORTANT:
- Return ONLY the JSON object, no other text
- Ensure all quotes and brackets are properly closed
- Choose actions that make sense given your current state
- Be cautious of solid blocks when moving
- If you see interesting blocks nearby, consider interacting with them

Your response:"""


def query_ollama(state: Dict[str, Any], personality: str, config: Config, 
                 prompt_template: str) -> Optional[Dict[str, Any]]:
    """Query Ollama API and parse the response."""
    
    # Format state information
    pos = state.get("pos", {})
    pos_str = f"({pos.get('x', 0)}, {pos.get('y', 0)}, {pos.get('z', 0)})"
    yaw = state.get("yaw", 0)
    hp = state.get("hp", 10)
    
    # Format nearby blocks
    nearby_blocks = state.get("nearby_blocks", [])
    if nearby_blocks:
        blocks_summary = []
        for block in nearby_blocks[:10]:  # Limit to first 10
            block_pos = block.get("pos", {})
            blocks_summary.append(
                f"{block.get('name', 'unknown')} at ({block_pos.get('x', 0)}, {block_pos.get('y', 0)}, {block_pos.get('z', 0)})"
            )
        nearby_str = "; ".join(blocks_summary)
        if len(nearby_blocks) > 10:
            nearby_str += f" ... and {len(nearby_blocks) - 10} more"
    else:
        nearby_str = "No blocks nearby (empty space)"
    
    # Build prompt
    prompt = prompt_template.format(
        personality=personality,
        pos=pos_str,
        yaw=yaw,
        hp=hp,
        nearby_blocks=nearby_str
    )
    
    # Prepare API request
    api_url = f"{config.ollama_host}/api/generate"
    payload = {
        "model": config.model,
        "prompt": prompt,
        "stream": False,
        "options": {
            "temperature": config.temperature,
            "num_predict": 256
        }
    }
    
    logger.debug(f"Querying Ollama at {api_url} with model {config.model}")
    
    try:
        # Create request
        data = json.dumps(payload).encode('utf-8')
        req = urllib.request.Request(
            api_url,
            data=data,
            headers={'Content-Type': 'application/json'},
            method='POST'
        )
        
        # Send request
        with urllib.request.urlopen(req, timeout=config.timeout) as response:
            result = json.loads(response.read().decode('utf-8'))
            
        # Extract response text
        llm_response = result.get("response", "")
        logger.debug(f"LLM raw response: {llm_response[:200]}...")
        
        # Parse JSON from response
        return parse_llm_json(llm_response)
        
    except urllib.error.URLError as e:
        logger.error(f"Network error querying Ollama: {e}")
        return None
    except urllib.error.HTTPError as e:
        logger.error(f"HTTP error from Ollama: {e.code} - {e.reason}")
        return None
    except json.JSONDecodeError as e:
        logger.error(f"Failed to parse Ollama response JSON: {e}")
        return None
    except Exception as e:
        logger.error(f"Unexpected error querying Ollama: {e}")
        return None


def parse_llm_json(response: str) -> Optional[Dict[str, Any]]:
    """Extract and parse JSON from LLM response."""
    response = response.strip()
    
    # Try to find JSON object in response
    start_idx = response.find('{')
    end_idx = response.rfind('}') + 1
    
    if start_idx == -1 or end_idx <= start_idx:
        logger.error("No JSON object found in LLM response")
        return None
    
    json_str = response[start_idx:end_idx]
    
    try:
        parsed = json.loads(json_str)
        
        # Validate required fields
        if not isinstance(parsed, dict):
            logger.error("Parsed response is not a JSON object")
            return None
        
        if "action" not in parsed:
            logger.error("Missing 'action' field in response")
            return None
        
        if "params" not in parsed:
            parsed["params"] = {}
        
        if "reason" not in parsed:
            parsed["reason"] = "No reason provided"
        
        return parsed
        
    except json.JSONDecodeError as e:
        logger.error(f"Failed to parse JSON from LLM: {e}")
        logger.debug(f"Attempted to parse: {json_str}")
        return None


def main():
    """Main execution loop."""
    logger.info("=" * 50)
    logger.info("Luanti-Ollama-NPC Brain Controller Starting")
    logger.info("=" * 50)
    
    # Load configuration
    config = Config()
    logger.info(f"NPC Name: {config.npc_name}")
    logger.info(f"Ollama Host: {config.ollama_host}")
    logger.info(f"Model: {config.model}")
    logger.info(f"Update Interval: {config.update_interval}s")
    
    # Load prompt template
    prompt_template = load_prompt_template()
    
    # Initialize command counter for unique IDs
    command_id = 0
    
    # Main loop
    iteration = 0
    while True:
        iteration += 1
        logger.debug(f"\n--- Iteration {iteration} ---")
        
        try:
            # Step 1: Get current state
            state = get_state(config.state_file)
            
            if state is None:
                logger.warning("No state available yet, waiting...")
                time.sleep(config.update_interval)
                continue
            
            logger.info(f"Current state - Pos: {state.get('pos')}, HP: {state.get('hp')}")
            
            # Step 2: Query Ollama for decision
            decision = query_ollama(state, config.personality_prompt, config, prompt_template)
            
            if decision is None:
                logger.warning("Failed to get valid decision from LLM, skipping action")
                time.sleep(config.update_interval)
                continue
            
            action = decision.get("action")
            params = decision.get("params", {})
            reason = decision.get("reason", "No reason provided")
            
            logger.info(f"Decision: {action} - {reason}")
            
            # Step 3: Send command to Lua mod
            command_id += 1
            success = send_command(
                config.commands_file,
                action,
                params,
                config.npc_name,
                command_id
            )
            
            if success:
                logger.info(f"Command {command_id} sent successfully")
            else:
                logger.error("Failed to send command")
            
            # Step 4: Wait for next iteration
            time.sleep(config.update_interval)
            
        except KeyboardInterrupt:
            logger.info("Interrupted by user, shutting down...")
            break
        except Exception as e:
            logger.exception(f"Unexpected error in main loop: {e}")
            time.sleep(config.update_interval)
    
    logger.info("NPC Brain Controller stopped")


if __name__ == "__main__":
    main()
