# Luanti-Ollama-NPC

A complete, modular software suite that enables autonomous NPCs in Luanti (Minetest) worlds, controlled by a local Ollama Large Language Model (LLM). This system allows NPCs to perceive their environment, make decisions based on personality prompts, and execute actions like moving, digging, building, and interacting with the world.

## 🌟 Features

- **Autonomous Decision Making**: NPCs use a local LLM (via Ollama) to decide actions based on current state and personality.
- **Modular Architecture**: Clean separation between Lua mod (in-game) and Python controller (external brain).
- **Robust IPC**: Atomic file-based communication prevents race conditions between Lua and Python.
- **Configurable Behavior**: All parameters (model, update interval, personality, spawn position) defined in `config.json`.
- **Physics-Aware**: Collision detection ensures moves fail gracefully if targeting solid blocks.
- **Extensible Action System**: Supports `move`, `turn`, `dig`, `place`, and `build_schematic` out of the box.
- **Error Resilience**: Graceful handling of missing files, malformed JSON, and network timeouts.
- **Visible Entity**: NPCs use the standard `character.b3d` mesh with nametags for easy identification.

## 🏗️ Architecture Overview

```
┌─────────────────┐      JSON Files      ┌─────────────────┐
│   Luanti World  │ ◄──────────────────► │  Python Brain   │
│                 │  (commands.json)     │                 │
│  ┌───────────┐  │  (state.json)        │  ┌───────────┐  │
│  │ Lua Mod   │  │ ◄──────────────────► │  │ Ollama    │  │
│  │ (Entity)  │  │                      │  │ Controller│  │
│  └───────────┘  │                      │  └───────────┘  │
└─────────────────┘                      └─────────────────┘
       ▲                                        ▲
       │                                        │
       │                                        │
       ▼                                        ▼
  Game Physics                            HTTP API
  Collision Detection                     (localhost:11434)
```

### Components

1. **Lua Mod (`llm_npc_core`)**
   - Runs inside the Luanti game engine.
   - Renders the NPC entity with mesh, texture, and nametag.
   - Handles physics, collision detection, and world interactions.
   - Reads commands from `commands.json` and writes state to `state.json`.
   - Executes actions: move, turn, dig, place, build_schematic.

2. **Python Controller (`npc_brain.py`)**
   - Runs externally as a separate process.
   - Orchestrates the decision loop: Read State → Query Ollama → Parse Decision → Send Command.
   - Constructs prompts with current state and personality instructions.
   - Handles HTTP communication with the Ollama API.
   - Logs all activities and errors for debugging.

3. **Configuration (`config.json`)**
   - Central configuration for Ollama host, model, NPC personality, and behavior parameters.
   - Allows customization without code changes.

4. **Prompt Template (`prompt_template.txt`)**
   - Flexible template for instructing the LLM.
   - Includes placeholders for dynamic state injection.
   - Enforces strict JSON output schema.

## 📋 Prerequisites

- **Luanti/Minetest** (version 5.8+ recommended)
- **Ollama** installed and running locally
  - Install from: https://ollama.ai
  - Pull a model: `ollama pull llama3.2` (or your preferred model)
- **Python 3.8+** with the following packages:
  ```bash
  pip install requests
  ```
- **Required Mods**: `default`, `player_api` (usually included in most games)

## 🚀 Installation

### Step 1: Install the Lua Mod

1. Copy the `llm_npc_core` folder to your Luanti world's `mods` directory:
   ```bash
   cp -r llm_npc_core ~/.minetest/worlds/<your_world>/mods/
   # OR for Luanti
   cp -r llm_npc_core ~/.luanti/worlds/<your_world>/mods/
   ```

2. Enable the mod in your world's `world.mt` file:
   ```
   load_mod_llm_npc_core = true
   ```

3. Alternatively, enable it via the in-game Mods menu.

### Step 2: Configure the System

1. Place `config.json` in your world directory or the mod folder:
   ```bash
   cp config.json ~/.minetest/worlds/<your_world>/
   ```

2. Edit `config.json` to customize:
   - Ollama host and model name
   - NPC spawn position
   - Personality prompt
   - Update interval and behavior limits

### Step 3: Start Ollama

Ensure Ollama is running and your chosen model is available:

```bash
# Start Ollama server (if not already running)
ollama serve

# In another terminal, verify the model is downloaded
ollama list

# If needed, pull a model
ollama pull llama3.2
```

### Step 4: Run the Python Controller

Navigate to the project directory and start the brain:

```bash
cd /path/to/Luanti-Ollama-NPC
python3 npc_brain.py
```

You should see log output indicating successful connection and state reading.

### Step 5: Spawn the NPC in-Game

1. Join your Luanti world.
2. Use the chat command to spawn the NPC:
   ```
   /spawn_npc AutoBot
   ```
3. The NPC will appear at the configured spawn position.
4. The Python controller will immediately begin sending commands.

## ⚙️ Configuration

### config.json Structure

```json
{
  "ollama": {
    "host": "http://localhost:11434",
    "model": "llama3.2",
    "timeout": 30,
    "temperature": 0.7
  },
  "npc": {
    "name": "AutoBot",
    "spawn_pos": {
      "x": 0,
      "y": 10,
      "z": 0
    },
    "personality_prompt": "You are a curious explorer...",
    "update_interval": 2.0
  },
  "paths": {
    "commands_file": "commands.json",
    "state_file": "state.json"
  },
  "behavior": {
    "move_radius": 5,
    "dig_depth_limit": 3,
    "schematic_max_size": 10
  }
}
```

### Configuration Fields

| Field | Description | Default |
|-------|-------------|---------|
| `ollama.host` | Ollama API endpoint URL | `http://localhost:11434` |
| `ollama.model` | Model name to use for inference | `llama3.2` |
| `ollama.timeout` | HTTP request timeout in seconds | `30` |
| `ollama.temperature` | LLM creativity (0.0-1.0) | `0.7` |
| `npc.name` | Default NPC name | `AutoBot` |
| `npc.spawn_pos` | Initial spawn coordinates | `{x:0, y:10, z:0}` |
| `npc.personality_prompt` | Instructions for LLM behavior | *(see config.json)* |
| `npc.update_interval` | Seconds between action cycles | `2.0` |
| `paths.commands_file` | Path to commands IPC file | `commands.json` |
| `paths.state_file` | Path to state IPC file | `state.json` |
| `behavior.move_radius` | Max blocks to move per action | `5` |
| `behavior.dig_depth_limit` | Max depth for digging | `3` |
| `behavior.schematic_max_size` | Max schematic dimensions | `10` |

## 🎮 Usage

### Chat Commands

- `/spawn_npc <name>` - Spawn an NPC with the given name at the configured position.
- `/despawn_npc <name>` - Remove an NPC from the world.

### Action Types

The LLM can issue the following actions:

| Action | Description | Parameters |
|--------|-------------|------------|
| `move` | Move in a direction | `direction` (north/south/east/west/up/down), `distance` |
| `turn` | Rotate the NPC | `yaw` (angle in radians) or `direction` (left/right) |
| `dig` | Remove a node | `direction` (relative to NPC), `count` |
| `place` | Place a node | `direction`, `node_name` |
| `build_schematic` | Build a structure | `schematic` (2D/3D array of node names) |

### Example LLM Response

The LLM must return valid JSON:

```json
{
  "action": "move",
  "params": {
    "direction": "north",
    "distance": 3
  },
  "reason": "I see open space to the north and want to explore."
}
```

## 🔍 Monitoring & Debugging

### Logs

- **Python Controller**: Logs are written to `npc_brain.log` and printed to console.
- **Lua Mod**: Check `debug.txt` in your Luanti world directory or use in-game console.

### State Inspection

The current NPC state is written to `state.json`:

```json
{
  "name": "AutoBot",
  "pos": {"x": 0, "y": 10, "z": 0},
  "yaw": 0.0,
  "hp": 20,
  "inventory": [],
  "nearby_blocks": [
    {"pos": {"x": 1, "y": 10, "z": 0}, "name": "default:stone"},
    ...
  ],
  "timestamp": 1699999999.123
}
```

### Common Issues

| Issue | Solution |
|-------|----------|
| NPC doesn't move | Check `commands.json` permissions; ensure atomic writes work |
| Ollama timeout | Increase `ollama.timeout` in config; verify model is loaded |
| Malformed JSON from LLM | Adjust temperature; refine prompt template |
| NPC falls through ground | Verify `spawn_pos.y` is above ground; check physics mod |
| No state updates | Ensure Lua mod is enabled; check `world.mt` |

## 🛠️ Extending the System

### Adding New Actions

1. **Lua Side** (`init.lua`):
   - Add a new handler in `execute_action()`:
     ```lua
     elseif action_type == "say" then
         local msg = params.message or "Hello!"
         minetest.chat_send_all(npc_name .. ": " .. msg)
     end
     ```

2. **Prompt Template** (`prompt_template.txt`):
   - Document the new action in the schema section.

3. **Python Side** (optional):
   - Add validation logic if needed.

### Customizing Personalities

Create different personality prompts for various NPC behaviors:

```json
"personality_prompt": "You are a cautious builder who prefers to construct shelters before exploring. Always prioritize safety and resource gathering."
```

### Multi-NPC Support

The system supports multiple NPCs:

1. Spawn additional NPCs with `/spawn_npc NPC2`
2. Each NPC has independent state/command files (extend the system to use named files like `state_NPC2.json`)

## 📁 Project Structure

```
Luanti-Ollama-NPC/
├── mod.conf                  # Luanti mod metadata
├── config.json               # Central configuration
├── npc_brain.py              # Python controller
├── prompt_template.txt       # LLM prompt template
├── llm_npc_core/
│   ├── init.lua              # Main Lua mod code
│   └── (future extensions)
├── README.md                 # This file
└── npc_brain.log             # Generated log file (gitignored)
```

## 🔒 Security Considerations

- **Local Only**: This system is designed for local Ollama instances. Do not expose Ollama to the internet without authentication.
- **File Permissions**: Ensure the Luanti process and Python script have read/write access to the IPC files.
- **Sandboxing**: The Lua mod only executes predefined actions; arbitrary code execution is not possible.

## 🤝 Contributing

Contributions are welcome! Areas for improvement:

- [ ] Add inventory management actions
- [ ] Implement pathfinding for complex navigation
- [ ] Support multiplayer coordination between NPCs
- [ ] Add visual indicators for NPC decision states
- [ ] Create a web dashboard for monitoring multiple NPCs

## 📄 License

This project is provided under the MIT License. See LICENSE file for details.

## 🙏 Acknowledgments

- Luanti/Minetest community for the excellent game engine
- Ollama team for making local LLM inference accessible
- Contributors to the `character.b3d` model and textures

---

**Happy Building!** 🎮🤖

For questions or issues, please check the logs first, then consult the configuration options before reporting bugs.
