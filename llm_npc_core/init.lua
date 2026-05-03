-- Luanti-Ollama-NPC Core Mod
-- init.lua - Main Lua module for autonomous NPC control via Ollama LLM

local mod_name = "llm_npc_core"
local mod_path = minetest.get_modpath(mod_name)

-- Configuration defaults (can be overridden by config.json if loaded)
local CONFIG = {
    commands_file = "commands.json",
    state_file = "state.json",
    update_interval = 1.0,
}

-- Load configuration: first from mod path (default), then override from worldpath if available
local function load_config()
    -- First, try to load default config from mod path
    local mod_config_path = mod_path .. "/config.json"
    local file = io.open(mod_config_path, "r")
    if file then
        local content = file:read("*all")
        file:close()
        local success, data = pcall(minetest.parse_json, content)
        if success and data then
            if data.paths then
                if data.paths.commands_file then
                    CONFIG.commands_file = data.paths.commands_file
                end
                if data.paths.state_file then
                    CONFIG.state_file = data.paths.state_file
                end
            end
            if data.npc and data.npc.update_interval then
                CONFIG.update_interval = data.npc.update_interval
            end
            minetest.log("action", "[LLM_NPC] Loaded default config from " .. mod_config_path)
        end
    end

    -- Then, try to override with world-specific config from worldpath
    local world_config_path = minetest.get_worldpath() .. "/config.json"
    file = io.open(world_config_path, "r")
    if file then
        local content = file:read("*all")
        file:close()
        local success, data = pcall(minetest.parse_json, content)
        if success and data then
            if data.paths then
                if data.paths.commands_file then
                    CONFIG.commands_file = data.paths.commands_file
                end
                if data.paths.state_file then
                    CONFIG.state_file = data.paths.state_file
                end
            end
            if data.npc and data.npc.update_interval then
                CONFIG.update_interval = data.npc.update_interval
            end
            minetest.log("action", "[LLM_NPC] Overridden config from " .. world_config_path)
        end
    end
end

-- Resolve file paths relative to worldpath
local function get_commands_path()
    return minetest.get_worldpath() .. "/" .. CONFIG.commands_file
end

local function get_state_path()
    return minetest.get_worldpath() .. "/" .. CONFIG.state_file
end

-- Atomic file write: write to temp file then rename
local function atomic_write(filepath, content)
    local temp_path = filepath .. ".tmp." .. os.time()
    local file = io.open(temp_path, "w")
    if not file then
        minetest.log("error", "[LLM_NPC] Failed to open temp file: " .. temp_path)
        return false
    end
    local success, err = file:write(content)
    file:close()
    if not success then
        minetest.log("error", "[LLM_NPC] Failed to write to temp file: " .. err)
        os.remove(temp_path)
        return false
    end
    -- Atomic rename
    local rename_success = os.rename(temp_path, filepath)
    if not rename_success then
        minetest.log("error", "[LLM_NPC] Failed to rename temp file to: " .. filepath)
        os.remove(temp_path)
        return false
    end
    return true
end

-- Safe JSON read with error handling
local function read_json_file(filepath)
    local file = io.open(filepath, "r")
    if not file then
        return nil, "File not found: " .. filepath
    end
    local content = file:read("*all")
    file:close()
    local success, data = pcall(minetest.parse_json, content)
    if not success then
        return nil, "JSON parse error: " .. tostring(data)
    end
    return data, nil
end

-- Get nearby blocks information
local function get_nearby_blocks(pos, radius)
    local blocks = {}
    local count = 0
    for x = -radius, radius do
        for y = -radius, radius do
            for z = -radius, radius do
                local check_pos = vector.add(pos, {x = x, y = y, z = z})
                local node = minetest.get_node(check_pos)
                if node and node.name ~= "air" then
                    count = count + 1
                    blocks[count] = {
                        pos = check_pos,
                        name = node.name,
                        param1 = node.param1 or 0,
                        param2 = node.param2 or 0
                    }
                    if count >= 50 then -- Limit to prevent huge state
                        break
                    end
                end
            end
            if count >= 50 then break end
        end
        if count >= 50 then break end
    end
    return blocks
end

-- Check if a position is solid (collision detection)
local function is_position_solid(pos)
    local node = minetest.get_node(pos)
    if not node or node.name == "air" then
        return false
    end
    local def = minetest.registered_nodes[node.name]
    if def and def.walkable then
        return true
    end
    return node.name ~= "air"
end

-- Entity definition
local npc_entities = {}

minetest.register_entity("llm_npc_core:npc", {
    initial_properties = {
        hp_max = 10,
        physical = true,
        collide_with_objects = true,
        collisionbox = {-0.3, 0, -0.3, 0.3, 1.7, 0.3},
        selectionbox = {-0.3, 0, -0.3, 0.3, 1.7, 0.3},
        visual = "mesh",
        mesh = "character.b3d",
        textures = {"character.png"},
        makes_footstep_sound = true,
        automatic_rotate = false,
        stepheight = 0.6,
    },
    
    on_activate = function(self, staticdata)
        self.object:set_armor_groups({fleshy = 100})
        self.hp = self.object:get_hp()
        
        -- Store entity reference
        local obj_id = self.object:get_id()
        npc_entities[obj_id] = self
        
        -- Set nametag from staticdata or default
        local name = staticdata and staticdata ~= "" and staticdata or "NPC"
        self.object:set_nametag_attributes({
            text = name,
            bgcolor = {a = 200, r = 0, g = 100, b = 200},
        })
        
        minetest.log("action", "[LLM_NPC] NPC activated: " .. name)
    end,
    
    on_punch = function(self, puncher, time_from_last_punch, tool_capabilities, dir, damage)
        self.hp = self.hp - (damage or 1)
        self.object:set_hp(self.hp)
        if self.hp <= 0 then
            minetest.log("action", "[LLM_NPC] NPC died: " .. (self.object:get_nametag_attributes() or {}).text)
            self.object:remove()
            npc_entities[self.object:get_id()] = nil
        end
    end,
    
    on_step = function(self, dtime)
        -- Basic physics handled by engine
        -- Update internal state
        self.hp = self.object:get_hp()
    end,
    
    get_staticdata = function(self)
        -- Return nametag as staticdata
        local attrs = self.object:get_nametag_attributes()
        return attrs and attrs.text or "NPC"
    end,
})

-- Spawn NPC function
function spawn_npc(name, pos)
    if not pos then
        pos = {x = 0, y = 50, z = 0}
    end
    
    -- Find ground level if y is high
    if pos.y > 10 then
        local ground_pos = minetest.find_node_closest(pos, 10, "group:soil")
        if ground_pos then
            pos = vector.add(ground_pos, {x = 0, y = 1, z = 0})
        end
    end
    
    local obj = minetest.add_entity(pos, "llm_npc_core:npc", name or "NPC")
    if obj then
        minetest.log("action", "[LLM_NPC] Spawned NPC '" .. (name or "NPC") .. "' at " .. minetest.pos_to_string(pos))
        return obj
    else
        minetest.log("error", "[LLM_NPC] Failed to spawn NPC at " .. minetest.pos_to_string(pos))
        return nil
    end
end

-- Execute action on NPC
function execute_action(npc_name, action_type, params)
    params = params or {}
    
    -- Find NPC by nametag using stored entity references first
    local npc_obj = nil
    local npc_data = nil
    
    -- Try using stored npc_entities table first
    for obj_id, entity in pairs(npc_entities) do
        if entity and entity.object then
            local attrs = entity.object:get_nametag_attributes()
            if attrs and attrs.text == npc_name then
                npc_obj = entity.object
                npc_data = entity
                break
            end
        end
    end
    
    -- Fallback: iterate all objects if not found in npc_entities
    if not npc_obj and minetest.get_objects_in_area then
        local all_objects = minetest.get_objects_in_area(
            vector.new(-32000, -32000, -32000),
            vector.new(32000, 32000, 32000)
        )
        for _, obj in ipairs(all_objects) do
            if obj and obj:get_luaentity() then
                local attrs = obj:get_nametag_attributes()
                if attrs and attrs.text == npc_name then
                    npc_obj = obj
                    npc_data = obj:get_luaentity()
                    break
                end
            end
        end
    end
    
    if not npc_obj then
        minetest.log("warning", "[LLM_NPC] NPC not found: " .. npc_name)
        return false, "NPC not found"
    end
    
    local pos = npc_obj:get_pos()
    local yaw = npc_obj:get_yaw()
    
    if action_type == "move" then
        local direction = params.direction or "forward"
        local distance = params.distance or 1
        
        local move_offset = {x = 0, y = 0, z = 0}
        if direction == "forward" then
            move_offset.x = math.sin(yaw) * distance
            move_offset.z = -math.cos(yaw) * distance
        elseif direction == "backward" then
            move_offset.x = -math.sin(yaw) * distance
            move_offset.z = math.cos(yaw) * distance
        elseif direction == "left" then
            move_offset.x = -math.cos(yaw) * distance
            move_offset.z = -math.sin(yaw) * distance
        elseif direction == "right" then
            move_offset.x = math.cos(yaw) * distance
            move_offset.z = math.sin(yaw) * distance
        elseif direction == "up" then
            move_offset.y = distance
        elseif direction == "down" then
            move_offset.y = -distance
        elseif params.x and params.y and params.z then
            -- Direct position move
            local target_pos = {x = params.x, y = params.y, z = params.z}
            local check_pos = vector.add(target_pos, {x = 0, y = 0.5, z = 0})
            if is_position_solid(check_pos) then
                minetest.log("action", "[LLM_NPC] Move blocked: target position is solid")
                return false, "Position blocked"
            end
            npc_obj:set_pos(target_pos)
            return true, "Moved to position"
        end
        
        local new_pos = vector.add(pos, move_offset)
        -- Check collision
        local check_pos = vector.add(new_pos, {x = 0, y = 0.5, z = 0})
        if is_position_solid(check_pos) then
            minetest.log("action", "[LLM_NPC] Move blocked: " .. direction)
            return false, "Path blocked"
        end
        
        npc_obj:set_pos(new_pos)
        minetest.log("action", "[LLM_NPC] Moved " .. direction .. " to " .. minetest.pos_to_string(new_pos))
        return true, "Moved successfully"
        
    elseif action_type == "turn" then
        local angle = params.angle or 90
        local direction = params.direction or "right"
        local rad = angle * math.pi / 180
        if direction == "left" then
            rad = -rad
        end
        npc_obj:set_yaw(yaw + rad)
        minetest.log("action", "[LLM_NPC] Turned " .. direction .. " by " .. angle .. " degrees")
        return true, "Turned successfully"
        
    elseif action_type == "dig" then
        local offset = params.offset or {x = 0, y = -1, z = 0}
        local target_pos = vector.add(pos, offset)
        local node = minetest.get_node(target_pos)
        if node and node.name ~= "air" then
            minetest.dig_node(target_pos)
            minetest.log("action", "[LLM_NPC] Dug node at " .. minetest.pos_to_string(target_pos))
            return true, "Dug successfully"
        end
        return false, "Nothing to dig"
        
    elseif action_type == "place" then
        local offset = params.offset or {x = 0, y = -1, z = 0}
        local target_pos = vector.add(pos, offset)
        local node_name = params.node or "default:dirt"
        local node_def = minetest.registered_nodes[node_name]
        if not node_def then
            return false, "Unknown node: " .. node_name
        end
        -- Check if position is empty
        local current_node = minetest.get_node(target_pos)
        if current_node and current_node.name == "air" then
            minetest.set_node(target_pos, {name = node_name})
            minetest.log("action", "[LLM_NPC] Placed " .. node_name .. " at " .. minetest.pos_to_string(target_pos))
            return true, "Placed successfully"
        end
        return false, "Position not empty"
        
    elseif action_type == "build_schematic" then
        -- Simplified schematic building
        local schematic = params.schematic
        if not schematic then
            return false, "No schematic provided"
        end
        local base_pos = params.base_pos or vector.add(pos, {x = 0, y = 0, z = 0})
        local placed_count = 0
        for _, block in ipairs(schematic) do
            local place_pos = vector.add(base_pos, block.pos)
            local current_node = minetest.get_node(place_pos)
            if current_node and current_node.name == "air" then
                minetest.set_node(place_pos, {name = block.name})
                placed_count = placed_count + 1
            end
        end
        minetest.log("action", "[LLM_NPC] Built schematic: " .. placed_count .. " blocks placed")
        return true, "Built " .. placed_count .. " blocks"
        
    else
        minetest.log("warning", "[LLM_NPC] Unknown action type: " .. action_type)
        return false, "Unknown action"
    end
end

-- Globalstep loop for IPC
local last_update = 0
local command_processed_id = nil

minetest.register_globalstep(function(dtime)
    last_update = last_update + dtime
    if last_update < CONFIG.update_interval then
        return
    end
    last_update = 0
    
    -- Read commands
    local commands_path = get_commands_path()
    local commands_data, err = read_json_file(commands_path)
    
    if commands_data and commands_data.action then
        -- Check if this is a new command (different id)
        if commands_data.id ~= command_processed_id then
            local npc_name = commands_data.npc_name or "NPC"
            local action_type = commands_data.action
            local params = commands_data.params or {}
            
            minetest.log("action", "[LLM_NPC] Executing command: " .. action_type .. " for " .. npc_name)
            local success, result = execute_action(npc_name, action_type, params)
            
            -- Mark as processed
            command_processed_id = commands_data.id
            
            -- Clear the command file after processing
            atomic_write(commands_path, "{}")
        end
    end
    
    -- Write state for all NPCs using stored entity references
    for obj_id, entity in pairs(npc_entities) do
        if entity and entity.object then
            local obj = entity.object
            -- Check if object still exists (not removed)
            if obj:get_pos() then
                local attrs = obj:get_nametag_attributes()
                local npc_name = attrs and attrs.text or "NPC"
                local pos = obj:get_pos()
                local yaw = obj:get_yaw()
                local hp = obj:get_hp()
                
                local state = {
                    npc_name = npc_name,
                    pos = {x = math.floor(pos.x * 100) / 100, y = math.floor(pos.y * 100) / 100, z = math.floor(pos.z * 100) / 100},
                    yaw = math.floor(yaw * 100) / 100,
                    hp = hp,
                    timestamp = os.time(),
                    nearby_blocks = get_nearby_blocks(pos, 5),
                    inventory = {}, -- Placeholder for future inventory system
                }
                
                local state_path = get_state_path()
                local json_str = minetest.write_json(state)
                if json_str then
                    atomic_write(state_path, json_str)
                else
                    minetest.log("error", "[LLM_NPC] Failed to serialize state")
                end
            else
                -- Object was removed, clean up from table
                npc_entities[obj_id] = nil
            end
        end
    end
end)

-- Register chat command to spawn NPC
minetest.register_chatcommand("spawn_npc", {
    params = "<name>",
    description = "Spawn an LLM-controlled NPC",
    func = function(name, param)
        local npc_name = param ~= "" and param or "AutoBot"
        local player = minetest.get_player_by_name(name)
        local pos
        if player then
            pos = vector.add(player:get_pos(), {x = 0, y = 1, z = 1})
        else
            pos = {x = 0, y = 50, z = 0}
        end
        spawn_npc(npc_name, pos)
        return true, "Spawned NPC: " .. npc_name
    end,
})

-- Initialize
load_config()
minetest.log("action", "[LLM_NPC] Module loaded. Commands file: " .. get_commands_path() .. ", State file: " .. get_state_path())
