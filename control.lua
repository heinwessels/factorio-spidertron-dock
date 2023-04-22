local util = require("__core__/lualib/util")
local spidertron_lib = require("lib.spidertron_lib")
local lib = require("lib.lib")

local consts = {
    occupied_signal = {type = "virtual", name="signal-O"},
    recall_signal = {type = "virtual", name="signal-R"},
    undock_signal = {type = "virtual", name="signal-U"},
    dock_circuit_hysteresis = 120, -- In ticks
}

-- Convenience method for when SE is active
local se_active = script.active_mods["space-exploration"] ~= nil

-- We add a hack here because we accidentally created a bunch of 
-- global functions, and I don't want to move it all into the 
-- right order and lose a bunch of history, so we'll just
-- put some of them in a lovely table.
local funcs = { }

local function name_is_dock(name)
    return not (string.match(name, "ss[-]spidertron[-]dock") == nil)
end

local function name_is_docked_spider(name)
    return not (string.match(name, "ss[-]docked[-]") == nil)
end

local function create_dock_data(dock_entity)
    return {
        occupied = false,

        -- Remember the normal type of the spider docked here
        -- Note: This value might not be cleaned when the spider undocked
        spider_name = nil,

        -- Keep a reference to the docked spider
        -- Only used when in `active` mode
        docked_spider = nil,

        -- Keep track of sprites drawed so we
        -- can pop them out later.
        docked_sprites = {},

        -- Keeps a serialised version of the spider
        -- Only used when in `passive` mode
        serialised_spider = nil,

        -- Can be nil when something goes wrong
        dock_entity = dock_entity,

        -- Keep this in here so that it's easy to
        -- find this entry in global
        unit_number = dock_entity.unit_number,

        -- 'active' or `passive`. 
        -- Dictates if an actual spider is placed
        -- while docking, or only a sprite.
        mode = string.find(dock_entity.name, "passive") and "passive" or "active",
        
        -- Keep track of the spider that was docked last so that
        -- we can summon it
        last_docked_spider = nil,

        -- This is so that we can always find where this dock
        -- is, even if the type and unit number change during migration.
        position = dock_entity.position,

        -- Map of interfaces referenced by their unit numbers, linked to
        -- the interface entity. A dock can have multiple interfaces.
        interfaces = { },

        -- Store the next tick that this dock is allowed to do circuit any operation
        -- This is to prevent a rapid dock/undock cycle when both signals are applied
        circuit_hysteresis = nil,
    }
end

local function create_spider_data(spider_entity)
    return {
        -- A spider will only attempt to dock
        -- if it's armed for that dock in
        -- particular upon reaching it at
        -- the end of the waypoint.
        -- It's attempted to be set when the
        -- player uses the spidertron remote.
        armed_for = nil, -- Dock entity

        -- Can be nil when something goes wrong
        spider_entity = spider_entity,

        -- Keep this in here so that it's easy to
        -- find this entry in global
        unit_number = spider_entity.unit_number,

        -- Store a reference to the last dock this
        -- spider docked to. It's so that you can 
        -- click "return to dock" on a spider.
        -- This system will be dum, so if the dock
        -- is no longer valid then it will do nothing.
        -- If the dock is occupied then it will still return
        -- but simply fail to dock
        last_used_dock = nil,
        
        -- This field will only be true if this spider is
        -- the docked variant. It contains the actual
        -- spider name that is docked.
        original_spider_name = nil,

        -- This will be populated by the dock recalling this spider
        -- when done through circuit or GUI. It's so that the command
        -- isn't actively given.
        recall_target = nil
    }
end

local function create_interface_data(interface)
    return {
        -- Keep this in here so that it's easy to
        -- find this entry in global
        unit_number = interface.unit_number,

        -- This is so that we can always find where this interface
        -- is, even if the type and unit number change during migration.
        position = interface.position,

        -- The dock entity this interface is connected to
        dock = nil,

        -- Cache this constant combinator's control behaviour
        -- for quick setting of signals.
        control_behaviour = interface.get_control_behavior(),

        -- Cache of the circuit network. The validity of this
        -- cached data needs to be verified before it's used
        circuit_network = { red = nil, green = nil }
    }
end

local function get_dock_data_from_entity(dock)
    if not name_is_dock(dock.name) then return end
    local dock_data = global.docks[dock.unit_number]
    if not dock_data then
        global.docks[dock.unit_number] = create_dock_data(dock)
        dock_data = global.docks[dock.unit_number]
    end
    return dock_data
end

local function get_spider_data_from_unit_number(spider_unit_number)
    return global.spiders[spider_unit_number]
end

local function get_spider_data_from_entity(spider)
    if not spider.type == "spider-vehicle" then return end
    local spider_data = global.spiders[spider.unit_number]
    if not spider_data then
        global.spiders[spider.unit_number] = create_spider_data(spider)
        spider_data = global.spiders[spider.unit_number]
    end
    return spider_data
end

-- An function to call when an dock action
-- was not allowed. It will play the "no-no"
-- sound and create some flying text
local function dock_error(dock, text)
    dock.surface.play_sound{
        path="ss-no-no", 
        position=dock.position
    }
    dock.surface.create_entity{
        name = "flying-text",
        position = dock.position,
        text = text,
        color = {r=1,g=1,b=1,a=1},
    }
end

-- Based on the tool provided by Wube, but that tool
-- does not function during runtime, so I need to redo it
local function collision_masks_collide(mask_1, mask_2)

    local clear_flags = function(map)
        for k, flag in pairs ({
            "consider-tile-transitions",
            "not-colliding-with-itself",
            "colliding-with-tiles-only"
          }) do
            map[flag] = nil
        end
    end

    clear_flags(mask_1)
    clear_flags(mask_2)
  
    for layer, _ in pairs (mask_2) do
      if mask_1[layer] then
        return true
      end
    end
    return false
end

-- Sometimes a dock will not support a specific
-- spider type. Currently this only happens
-- when a normal spider tries to dock to a dock
-- that's placed on a spaceship tile. This is required
-- because if your spaceship is small enough the spider
-- can reach the dock without stepping on restricted
-- spaceship tiles
-- Will return the text to display if there is no support
local function dock_does_not_support_spider(dock, spider)

    -- Hacky implementation where spider can be
    -- either the entity or the name of the entity.
    -- So unpack it so we know how to handle it
    local spider_name = nil
    if type(spider) ~= "string" then
        -- It's the entity
        spider_name = spider.name
    else
        -- We just got a spider name. Lame!
        spider_name = spider
        spider = nil
    end
    
    -- Is this spider type supported in the first place?
    if not global.spider_whitelist[spider_name] then
        return {"sd-spidertron-dock.spider-not-supported"}
    end

    -- Can the spider dock on this tile? This is to prevent terrestrial spiders
    -- being able to dock to a spaceship they can't walk on because the body
    -- can still reach the dock. We do this by checking if the first leg collides
    -- with a tile underneath the dock
    if game.active_mods["space-exploration"]
            and not settings.startup["space-spidertron-allow-other-spiders-in-space"].value then
        -- Only do it if we care about it though

        local tile_collision_mask = dock.surface.get_tile(dock.position).prototype.collision_mask
        local leg_collision_mask = nil
        if spider then
            leg_collision_mask = util.table.deepcopy(
                spider.get_spider_legs()[1].prototype.collision_mask)
        else
            -- We don't have a valid spider to get the leg-name from. 
            -- So lets create a temporary one
            -- TODO This is so ugly, we need a better way!
            local temporary_spider = dock.surface.create_entity{
                name=spider_name, 
                position=dock.position,
                create_build_effect_smoke=false,
                raise_built=false,
            }
            leg_collision_mask = util.table.deepcopy(
                temporary_spider.get_spider_legs()[1].prototype.collision_mask)
            temporary_spider.destroy() -- Destroy it after looking at it's leg!
        end

        -- If the leg would collide with the tile then it's not supported
        if collision_masks_collide(tile_collision_mask, leg_collision_mask) then
            return {"sd-spidertron-dock.spider-not-supported-on-tile"}
        end
    end
end

local function draw_docked_spider(dock, spider_name, color)
    local dock_data = get_dock_data_from_entity(dock)
    dock_data.docked_sprites = dock_data.docked_sprites or {}

    -- Offset to place sprite at correct location
    -- This assumes we're not drawing the bottom
    local offset = {0, -0.35}
    local render_layer = "object"
    
    -- Draw shadows
    table.insert(dock_data.docked_sprites, 
        rendering.draw_sprite{
            sprite = "ss-docked-"..spider_name.."-shadow", 
            target = dock, 
            surface = dock.surface,
            target_offset = offset,
            render_layer = render_layer,
        }
    )

    -- First draw main layer
    table.insert(dock_data.docked_sprites, 
        rendering.draw_sprite{
            sprite = "ss-docked-"..spider_name.."-main", 
            target = dock, 
            surface = dock.surface,
            target_offset = offset,
            render_layer = render_layer,
        }
    )

    -- Then draw tinted layer
    table.insert(dock_data.docked_sprites, 
        rendering.draw_sprite{
            sprite = "ss-docked-"..spider_name.."-tint", 
            target = dock, 
            surface = dock.surface,
            tint = color,
            target_offset = offset,
            render_layer = render_layer,
        }
    )

    -- Finally draw the light animation
    table.insert(dock_data.docked_sprites, 
        rendering.draw_animation{
            animation = "ss-docked-light", 
            target = dock, 
            surface = dock.surface,
            target_offset = offset,
            render_layer = render_layer,
            animation_offset = math.random(15) -- Not sure how to start at frame 0
        }
    )
end

-- Destroys sprites from a dock and also removes
-- their entries in it's data
local function pop_dock_sprites(dock_data)
    for _, sprite in pairs(dock_data.docked_sprites) do
        rendering.destroy(sprite)
    end
    dock_data.docked_sprites = {}
end

-- A regular spider turns into a serialised version ready
-- for docking. This will remove the spider entity and is
-- the first step of the actual docking procedure
local function dock_from_spider_to_serialised(dock, spider)
    local dock_data = get_dock_data_from_entity(dock)
    dock_data.spider_name = spider.name
    local serialised_spider = spidertron_lib.serialise_spidertron(spider)    
    spider.destroy{raise_destroy=true}  -- This will clean the spider data in the destroy event
    dock_data.occupied = true
    return serialised_spider
end

-- A serialised spider turns back into the regular spider
-- This is the last step of the actual undocking procedure
local function dock_from_serialised_to_spider(dock, serialised_spider)
    local dock_data = get_dock_data_from_entity(dock)
    local spider = dock.surface.create_entity{
        name = dock_data.spider_name,
        position = dock.position,
        force = dock.force,
        create_build_effect_smoke = false,
        raise_built = true,                 -- Regular spider it is
    }
    spidertron_lib.deserialise_spidertron(spider, serialised_spider)
    spider.torso_orientation = 0.58 -- orientation of sprite
    local spider_data = get_spider_data_from_entity(spider)
    spider_data.last_used_dock = dock
    dock_data.occupied = false
    return spider
end

-- Dock a spider passively to a dock. This means that
-- spider-sprites are drawn and the serialization info 
-- is stored in the dock
local function dock_from_serialised_to_passive(dock, serialised_spider)
    local dock_data = get_dock_data_from_entity(dock)
    dock_data.serialised_spider = serialised_spider
    draw_docked_spider(dock, dock_data.spider_name, serialised_spider.color)
end

-- Returns the serialised version of a passively docked spider
-- this will also pop the sprites
local function dock_from_passive_to_serialised(dock)
    local dock_data = get_dock_data_from_entity(dock)
    pop_dock_sprites(dock_data)
    local serialised_spider = dock_data.serialised_spider
    dock_data.serialised_spider = nil
    return serialised_spider
end

-- Dock a spider actively to a dock. This means a docked-version
-- of the spider is placed on the dock
local function dock_from_serialised_to_active(dock, serialised_spider)
    local dock_data = get_dock_data_from_entity(dock)
    local docked_spider = dock.surface.create_entity{
        name = "ss-docked-"..dock_data.spider_name,
        position = {
            dock.position.x,
            dock.position.y + 0.004 -- To draw spidertron over dock entity
        },
        force = dock.force,
        create_build_effect_smoke = false,
        raise_built = false, -- Because it's not a real spider
    }
    docked_spider.destructible = false -- Only dock can be attacked
    spidertron_lib.deserialise_spidertron(docked_spider, serialised_spider)
    docked_spider.torso_orientation = 0.58 -- Looks nice
    local docked_spider_data = get_spider_data_from_entity(docked_spider)
    docked_spider_data.original_spider_name = serialised_spider.name
    docked_spider_data.armed_for = dock
    dock_data.docked_spider = docked_spider
end

-- Retreives the serialised version of an actively docked spider
-- this will remove the docked spider version
local function dock_from_active_to_serialised(dock)
    local dock_data = get_dock_data_from_entity(dock)
    local docked_spider = dock_data.docked_spider
    if not docked_spider or not docked_spider.valid then return end
    local serialised_spider = spidertron_lib.serialise_spidertron(docked_spider)
    global.spiders[docked_spider.unit_number] = nil -- Because no destroy event will be called
    docked_spider.destroy{raise_destroy=false}      -- False because it's not a real spider
    dock_data.docked_spider = nil
    return serialised_spider
end

-- This function accepts a map of {interface_unit_number, interface} to update
-- It's assumes that all the interfaces are connected to the same dock
local function update_circuit_output_for_interfaces(interfaces)

    -- Now loop through all the interfaces and update them
    for interface_unit_number, interface in pairs(interfaces) do
        local interface_data = global.interfaces[interface_unit_number]
        interface_data.control_behaviour.enabled = true
        
        -- Find the dock data, if there are any. We will still
        -- clean interfaces not connected to anything. Doing it 
        -- this way means that if we give this function bad input
        -- it will give bad output, but that's fine, we never write any bugs.
        local dock_data = nil
        if not dock_data and interface_data.dock then
            dock_data = get_dock_data_from_entity(interface_data.dock)
        end

        -- Now set the signals if there is dock_data, or clear it otherwise
        if dock_data and dock_data.occupied then
            for interface_unit_number, interface in pairs(dock_data.interfaces) do
                if interface.valid then
                    interface_data = global.interfaces[interface_unit_number]
                    interface_data.control_behaviour.set_signal(1, {signal=consts.occupied_signal, count=1})
                end
            end
        else
            interface_data.control_behaviour.set_signal(1,  nil)
        end
    end
end

script.on_event(defines.events.on_gui_closed, function(event)
    local entity = event.entity
    if entity and entity.valid and entity.name == "sd-spidertron-dock-interface" then
        update_circuit_output_for_interfaces({[entity.unit_number]=entity})
    end
end)

-- This will dock a spider, and not
-- do any checks.
local function dock_spider(dock, spider)
    local dock_data = get_dock_data_from_entity(dock)

    -- Some smoke and mirrors
    dock.create_build_effect_smoke()
    dock.surface.play_sound{path="ss-spidertron-dock-1", position=dock.position}
    dock.surface.play_sound{path="ss-spidertron-dock-2", position=dock.position}
    
    -- Docking procedure
    local serialised_spider = dock_from_spider_to_serialised(dock, spider)
    if dock_data.mode == "passive" then
        dock_from_serialised_to_passive(dock, serialised_spider)
    else
        dock_from_serialised_to_active(dock, serialised_spider)
    end

    update_circuit_output_for_interfaces(dock_data.interfaces)
end

-- This will undock a spider, and not
-- do any checks.
local function undock_spider(dock)
    local dock_data = get_dock_data_from_entity(dock)

    -- Some smoke and mirrors
    dock.create_build_effect_smoke()
    dock.surface.play_sound{path="ss-spidertron-undock-1", position=dock.position}
    dock.surface.play_sound{path="ss-spidertron-undock-2", position=dock.position}

    -- Undocking procedure
    local serialised_spider = nil
    if dock_data.mode == "passive" then
        serialised_spider = dock_from_passive_to_serialised(dock)
    else
        serialised_spider = dock_from_active_to_serialised(dock)
    end
    local spider = dock_from_serialised_to_spider(dock, serialised_spider)

    update_circuit_output_for_interfaces(dock_data.interfaces)

    return spider
end

-- This function will attempt the dock
-- of a spider.
function attempt_dock(spider)
    local spider_data = get_spider_data_from_entity(spider)
    if not spider_data.armed_for then return end

    -- Find the dock this spider armed for in the region
    -- We check the area because spidertrons are innacurate
    -- and will not always stop on top of the dock
    local dock = nil    
    for _, potential_dock in pairs(spider.surface.find_entities_filtered{
        name = {"ss-spidertron-dock-active", "ss-spidertron-dock-passive"},
        position = spider.position,
        radius = 3,
        force = spider.force
    }) do
        if spider_data.armed_for == potential_dock then
            dock = potential_dock
            break
        end
    end
    if not dock then return end

    -- Check if dock is occupied
    local dock_data = get_dock_data_from_entity(dock)
    if dock_data.occupied then return end

    -- Check if this spider is allowed to dock here
    local error_msg = dock_does_not_support_spider(dock, spider)
    if error_msg then
        dock_error(dock, error_msg)
        return
    end

    -- Dock the spider!
    dock_spider(dock, spider)
    spider_data.recall_target = nil

    -- Update GUI's for all players
    for _, player in pairs(game.players) do
        funcs.update_spider_gui_for_player(player)
        funcs.update_dock_gui_for_player(player, dock)
    end
end

local function attempt_undock(dock_data, player, force)
    if not dock_data.occupied then return end
    local dock = dock_data.dock_entity
    if not dock then error("dock_data had no associated entity") end
    if player and (player.force ~= dock.force) then return end

    -- Some sanity check. If this happens, then something bad happens.
    -- Just quitly sweep it under the rug
    if not dock.valid then 
        -- Delete the entry, because it's likely this
        -- dock was deleted
        global.docks[dock_data.unit_number] = nil
        return
    end

    -- When the dock is mined then we will force the
    -- spider to be created so that the player doesn't lose it,
    -- whereas normally we would do some collision checks.
    -- Which might place the spider in an odd position, but oh well
    if force ~= true then

        -- Check if this spider is allowed to dock here
        local error_msg = dock_does_not_support_spider(dock, dock_data.spider_name)
        if error_msg then
            dock_error(dock, error_msg)
            return
        end

        -- We do no collision checks. We prevent normal spiders
        -- from undocking on spaceships by checking the tile
        -- and spider combination. And there *should* always be space
        -- for the legs next to the dock and whatever is next to it
    end

    -- Undock the spider!
    local spider = undock_spider(dock)

    -- close the gui since player likely just wanted to undock the spider
    if player then
        player.opened = nil
    end

    -- Destroy GUI for all players
    for _, player in pairs(game.players) do
        funcs.update_spider_gui_for_player(player, spider)
        funcs.update_dock_gui_for_player(player, dock)
    end

    dock_data.last_docked_spider = spider

    return true
end

script.on_event(defines.events.on_spider_command_completed, 
    function (event)
        if #event.vehicle.autopilot_destinations == 0 then
            -- Spidertron reached end of waypoints. See if it's above a dock.
            -- Attempt a dock!
            attempt_dock(event.vehicle)
        end
    end
)

script.on_event(defines.events.on_player_used_spider_remote,
    function (event)
        local spider = event.vehicle
        if spider and spider.valid then
            local spider_data = get_spider_data_from_entity(spider)
            spider_data.recall_target = nil -- Remotes always overwrite recall commands

            -- First check if this is a docked spider. If it is, then
            -- will attempt an undock.
            if name_is_docked_spider(spider.name) then
                local dock = spider_data.armed_for
                if not dock or not dock.valid then return end
                local dock_data = get_dock_data_from_entity(dock)
                local player = game.get_player(event.player_index)
                if not attempt_undock(dock_data, player) and spider.valid then
                    -- This was not a successfull undock event. Prevent
                    -- the remote from moving the still-docked spider!
                    spider.follow_target = nil
                    spider.autopilot_destination = nil
                end
                return
            end
            
            -- Now we know the current spider is not a docked version. Check if the player
            -- is directing a spider to a dock to dock the spider
            local dock = spider.surface.find_entity("ss-spidertron-dock-active", event.position)
            if not dock then
                dock = spider.surface.find_entity("ss-spidertron-dock-passive", event.position)
            end
            if dock then
                -- This waypoint was placed on a valid dock!
                -- Arm the dock so that spider is allowed to dock there
                local dock_data = get_dock_data_from_entity(dock)
                if dock.force ~= spider.force then return end
                if dock_data.occupied then return end
                spider_data.armed_for = dock
            else
                -- The player directed the spider somewhere else
                -- that's not a dock command. So remove any pending
                -- dock arms
                spider_data.armed_for = nil
            end
        end
    end
)

local function dock_connect_to_interface(dock, interface)
    -- Do the connection
    local dock_data = global.docks[dock.unit_number]
    local interface_unit_number = interface.unit_number
    dock_data.interfaces[interface_unit_number] = interface
    global.interfaces[interface_unit_number].dock = dock
    
    -- Ensure the circuit connection is outputting the correct value
    update_circuit_output_for_interfaces({[interface_unit_number] = interface})
end

local function dock_disconnect_from_interface(dock, interface)
    -- Do the connection
    local dock_data = global.docks[dock.unit_number]
    local interface_unit_number = interface.unit_number
    dock_data.interfaces[interface_unit_number] = nil
    global.interfaces[interface_unit_number].dock = nil
    
    -- Ensure the circuit connection is outputting the correct value
    update_circuit_output_for_interfaces({[interface_unit_number] = interface})
end

local function interface_get_connected_dock(interface)
    -- Gets the connected dock by looking at the location
    -- and not the interface's data. This is heavily based
    -- on Klonan's Transport Drones, thanks!

    -- Map between interface direction to the offset where we
    -- expect the dock entity.
    local circuit_offset_map = {
        [0] = {0, 1},
        [2] = {-1, 0},
        [4] = {0, -1},
        [6] = {1, 0},
    }
    local search_offset = circuit_offset_map[interface.direction]
    if not search_offset then error("Unexpected interface direction") end
    local search_position = interface.position
    search_position.x = search_position.x + search_offset[1]
    search_position.y = search_position.y + search_offset[2]

    for _, found_entity in pairs(interface.surface.find_entities_filtered{
        position = search_position, force = interface.force,
        name = {"ss-spidertron-dock-active", "ss-spidertron-dock-passive"}
    }) do
        return found_entity
    end
end

local function interface_built(interface)
    -- HACK: It might be that this interface is already initialized, 
    -- and if it is then we assume it's initialized correctly. This
    -- should only happen with SE spaceship launches
    if se_active and global.interfaces[unit_number] then return end

    -- Create the data in global
    local unit_number = interface.unit_number
    global.interfaces[unit_number] = create_interface_data(interface)
    local interface_data = global.interfaces[unit_number]

    -- Change some properties to make this entity easier to handle
    interface.rotatable = false
    
    -- Determine if it has connected dock
    local dock = interface_get_connected_dock(interface)
    if dock then        
        dock.create_build_effect_smoke()    -- Cool connect effect
        -- TODO Make connection sound
        
        dock_connect_to_interface(dock, interface)
    end
end

local function dock_built(dock)
    local dock_data = get_dock_data_from_entity(dock)

    -- Look for interfaces around this dock, and attempt to connect any of them
    for _, interface in pairs (dock.surface.find_entities_filtered{
        name = "sd-spidertron-dock-interface", 
        radius = dock.get_radius() + 1, 
        position = dock.position
    }) do
        if dock == interface_get_connected_dock(interface) then
            -- This interface is pointing towards this dock
            -- Setup the corresponding connections
            if not global.interfaces[interface.unit_number] and se_active then
                -- HACK: For when SE spaceship cloning occurs. This
                -- function might be called before the interface
                -- data is created. Therefore, swop it to the interface
                -- is built. This will find the dock and do the connection anyway.
                interface_built(interface)
            else
                -- The happy flow of this function
                dock_connect_to_interface(dock, interface)
                interface.create_build_effect_smoke()
                -- TODO Make connection sound
            end
        end
    end
end

local function on_built(event)
    -- If a dock interface is built we need to set it up
    local entity = event.created_entity or event.entity
    if not entity or not entity.valid then return end
    local name = entity.name

    if name == "sd-spidertron-dock-interface" then
        interface_built(entity)
        return
    end

    if name_is_dock(name) then
        dock_built(entity)
        return
    end
end

script.on_event(defines.events.on_robot_built_entity, on_built)
script.on_event(defines.events.on_built_entity, on_built)
script.on_event(defines.events.script_raised_built, on_built)
script.on_event(defines.events.script_raised_revive, on_built)

local function on_deconstructed(event)
    -- When the dock is destroyed then attempt undock the spider
    local entity = event.entity
    local player = event.player_index and game.get_player(event.player_index) or nil
    if entity and entity.valid then
        if name_is_dock(entity.name) then
            attempt_undock(get_dock_data_from_entity(entity), player, true)
            for _, interface in pairs(global.docks[entity.unit_number].interfaces) do
                if interface.valid then
                    interface.create_build_effect_smoke()
                    global.interfaces[interface.unit_number].dock = nil
                end
            end
            global.docks[entity.unit_number] = nil
        elseif entity.name == "sd-spidertron-dock-interface" then
            local interface_data = global.interfaces[entity.unit_number]
            if not interface_data or not interface_data.dock then return end
            if interface_data.dock.valid then
                interface_data.dock.create_build_effect_smoke()
                local dock_data = get_dock_data_from_entity(interface_data.dock)
                dock_data.interfaces[entity.unit_number] = nil
            end
            global.interfaces[entity.unit_number] = nil
        elseif entity.type == "spider-vehicle" then
            if name_is_docked_spider(entity.name) then
                local spider_data = get_spider_data_from_entity(entity)
                local dock = spider_data.armed_for
                if not dock or not dock.valid then return end
                local dock_data = get_dock_data_from_entity(dock)
                attempt_undock(dock_data, player, true)
            else
                global.spiders[entity.unit_number] = nil
            end
        end
    end
end

script.on_event(defines.events.on_player_mined_entity, on_deconstructed)
script.on_event(defines.events.on_robot_mined_entity, on_deconstructed)
script.on_event(defines.events.on_entity_died, on_deconstructed)
script.on_event(defines.events.script_raised_destroy, on_deconstructed)

-- This will toggle the dock between active and passive mode.
-- This will change the actual dock entity below so that
-- it's easy to copy-paste with settings. And have better tooltips
script.on_event("ss-spidertron-dock-toggle", function(event)
    local player = game.get_player(event.player_index)
    if not player then return end
    local dock = player.selected
    if not dock or not dock.valid then return end
    if dock.force ~= player.force then return end
    if not name_is_dock(dock.name) then return end
    
    -- By this point we know that this is a dock the player can toggle
    -- We need to be careful with the data
    local dock_data = get_dock_data_from_entity(dock)

    -- Toggle the mode
    local new_mode = dock_data.mode == "active" and "passive" or "active"

    -- Create the new entity
    local new_dock = dock.surface.create_entity{
        name = "ss-spidertron-dock-"..new_mode,
        position = dock.position,
        force = dock.force,
        create_build_effect_smoke = false,
        raise_built = true,
        player = player,
    } -- Will set the mode correctly
    new_dock.health = dock.health
    new_dock.energy = dock.energy

    -- Transfer the data
    local key_blacklist = {
        ["mode"]=true,
        ["dock_entity"]=true,
        ["unit_number"]=true,
        ["dock_unit_number"]=true}
    local new_dock_data = get_dock_data_from_entity(new_dock)
    for key, value in pairs(dock_data) do
        if not key_blacklist[key] then
            new_dock_data[key] = value
        end
    end

    -- Process the docking procedure
    if new_dock_data.occupied then        
        if new_dock_data.mode == "active" then
            -- Dock was passive, so now we need to create a spider entity
            local serialised_spider = dock_from_passive_to_serialised(new_dock)
            dock_from_serialised_to_active(new_dock, serialised_spider)
        else
            -- Dock was active, so now we remove a spider entity
            local serialised_spider = dock_from_active_to_serialised(new_dock)
            dock_from_serialised_to_passive(new_dock, serialised_spider)
        end
        
        -- Play nice sound if dock is occupied
        dock.surface.play_sound{
            path="ss-spidertron-dock-mode-"..new_dock_data.mode, 
            position=new_dock.position
        }
    end

    dock.surface.create_entity{
        name = "flying-text",
        position = dock.position,
        text = {"sd-spidertron-dock.mode-to-"..new_dock_data.mode},
        color = {r=1,g=1,b=1,a=1},
    }

    -- Remove the old dock data first otherwise the deconstrcut handler
    -- will think the dock is still occupied
    global.docks[dock_data.unit_number] = nil
    dock.destroy{raise_destroy=true}
end)

-- We can move docks with picker dollies, regardless
-- of if it contains a spider or not. We do not allow
-- moving the spiders though 
local function picker_dollies_move_event(event)
    local entity = event.moved_entity
    if name_is_dock(entity.name) then
        local dock = entity
        local dock_data = get_dock_data_from_entity(dock)
        -- Handle the docked spider entity
        if dock.name == "ss-spidertron-dock-active" then
            if dock_data.occupied then
                dock_data.docked_spider.teleport({
                    dock.position.x,
                    dock.position.y + 0.01 -- To draw spidertron over dock entity
                }, dock.surface)
            end
            -- When it's a passive dock we don't need to shift
            -- the sprites because they are attached to the dock
        end

        -- Handle the possibility of new interface connections
        local something_changed = false
        -- First we loop over all current interfaces and ensure they are all still connected
        for interface_unit_number, interface in pairs(dock_data.interfaces) do
            if interface_get_connected_dock(interface) ~= dock then
                -- This connection no longer exists
                something_changed = true
                interface.create_build_effect_smoke()
                dock_disconnect_from_interface(dock, interface)
            end
        end
        
        -- Look for interfaces around this dock, and attempt to connect any of them
        for _, interface in pairs (dock.surface.find_entities_filtered{
            name = "sd-spidertron-dock-interface", 
            radius = dock.get_radius() + 1, 
            position = dock.position
        }) do
            -- Check if this interface is connected to the dock, but ignore it
            -- if it the connection already existed
            if not dock_data.interfaces[interface.unit_number] and
                    interface_get_connected_dock(interface) == dock then
                something_changed = true
                dock_connect_to_interface(dock, interface)
                interface.create_build_effect_smoke()
            end
        end

        if something_changed then
            -- Just a little trick to only create dock smoke once
            dock.create_build_effect_smoke()
        end
    elseif entity.name == "sd-spidertron-dock-interface" then
        local interface = entity
        local interface_data = global.interfaces[interface.unit_number]
        local previous_dock = interface_data.dock
        local new_dock = interface_get_connected_dock(interface)

        -- Only need to update anything in this case when the connection
        -- is not the same anymore. Then we disconnect from the previous dock
        -- and connect to the new one
        if previous_dock ~= new_dock then
            interface.create_build_effect_smoke()
            if previous_dock and previous_dock.valid then
                previous_dock.create_build_effect_smoke()
                dock_disconnect_from_interface(previous_dock, interface)
            end
            if new_dock then
                new_dock.create_build_effect_smoke()
                dock_connect_to_interface(new_dock, interface)
            end
        end
    end
end

-- This function is called in SE when the spaceship changes surfaces.
-- Technically it can be called in other scenario's too, but we won't
-- care about that until someone complains, because nobody else uses clone.
-- 
-- This event will only be called by SE on the docks and interfaces, not on
-- the docked-spider-entity, because spiders are teleported. So we also assume
-- that the teleportion is always successful, and we won't double check.
-- The new dock entity will be created as usual, and the spider data will
-- be moved to the new entities.
script.on_event(defines.events.on_entity_cloned, function(event)
    local source = event.source
    local destination = event.destination
    local name = destination.name
    if not source or not source.valid then return end
    if not destination or not destination.valid then return end    

    if name_is_dock(name) then
        local source_dock_data = get_dock_data_from_entity(source)
        local destination_dock_data = get_dock_data_from_entity(destination)
        
        -- Move data from source dock to new dock
        local keys_to_copy = { -- Which keys to copy from source dock data
            "occupied",
            "spider_name",
            "docked_spider",
            "serialised_spider",    -- Will be non-nil when passively docked
            "last_docked_spider",
            "circuit_hysteresis",
        }
        for _, key in pairs(keys_to_copy) do
            destination_dock_data[key] = util.table.deepcopy(source_dock_data[key])
        end
        source_dock_data.occupied = false        
        source_dock_data.spider_name = nil
        source_dock_data.docked_spider = nil
        source_dock_data.serialised_spider = nil
        source_dock_data.last_docked_spider = nil
        
        if destination_dock_data.occupied and destination_dock_data.mode == "passive" then
            -- pop the sprites from the source and add to destination
            pop_dock_sprites(source_dock_data)
            draw_docked_spider(
                destination,
                destination_dock_data.spider_name,
                destination_dock_data.serialised_spider.color
            )
        end

        -- Do this last, because it will handle the interface connection
        dock_built(destination) -- Will auto-connect to interfaces if available

        -- The old dock entity will be removed by a destroy event by SE
    elseif name == "sd-spidertron-dock-interface" then
        interface_built(destination) -- Will auto-connect to dock if available
    end
end)

local function dock_recall_last_spider(dock)
    -- We will only recall the spider to the dock if it's
    -- not already on it's way to this dock
    local dock_data = get_dock_data_from_entity(dock)
    local spider = dock_data.last_docked_spider
    if not spider or not spider.valid then
        dock_data.last_docked_spider = nil
        return
    end 
    local spider_data = get_spider_data_from_entity(spider)
    if spider_data.recall_target == dock then return end
    if spider and spider.valid and spider.surface == dock.surface then
        -- TODO Clear all current waypoints?
        spider.add_autopilot_destination(dock.position)
        spider_data.armed_for = dock
        spider_data.recall_target = dock
    end
end

local wire_colours = {red = defines.wire_type.red, green = defines.wire_type.green}
local function update_dock_circuits(dock_data, dock_unit_number)
    if not next(dock_data.interfaces) then return end
    local tick = game.tick
    if dock_data.circuit_hysteresis and tick < dock_data.circuit_hysteresis then return end
    
    local recall_requested = false
    local undock_requested = false

    for interface_unit_number, interface in pairs(dock_data.interfaces) do
        local interface_data = global.interfaces[interface_unit_number]
        for wire_colour, wire_colour_define in pairs(wire_colours) do
            local network = interface_data.circuit_network[wire_colour]
            
            -- This code checks if there is a circuit connection cached. If there are, then
            -- ensure it's still valid (connected), and if not then get the new state. Or
            -- if there's nothing cached then we will also check if there is something connected
            -- now. This is faster than calling get_circuit_network everytime we need to update
            if not network or not network.valid then
                interface_data.circuit_network[wire_colour] = interface.get_circuit_network(wire_colour_define)
                network = interface_data.circuit_network[wire_colour]
            end

            -- network will contain a valid circuit network or be nil
            if network then
                -- Only see if there is a dock signal if dock is currently occupied
                if dock_data.occupied and network.get_signal(consts.undock_signal) > 0 then
                    attempt_undock(dock_data)
                    dock_data.circuit_hysteresis = tick + consts.dock_circuit_hysteresis
                
                    -- Only check if there is a recal signal if there is a spider to recal
                elseif dock_data.last_docked_spider 
                        and dock_data.last_docked_spider.valid 
                        and network.get_signal(consts.recall_signal) > 0 then
                    local dock = dock_data.dock_entity
                    if not dock or not dock.valid then return end
                    dock_recall_last_spider(dock)
                    dock_data.circuit_hysteresis = tick + consts.dock_circuit_hysteresis
                end
            end
        end
    end
end

script.on_nth_tick(10, function (event)
    -- Iterate over docks to see if there are any interfaces we
    -- should respond to. We do this per dock, and not per interface,
    -- so that the interfaces always act as a group, if multiple are
    -- connected to a dock
    global._iterate_docks = lib.table.for_n_of(
        global.docks, 
        global._iterate_docks, 
        3,      -- Amount of docks to service per tick
        update_dock_circuits
    )
end)

function funcs.update_spider_gui_for_player(player, spider)
    
    -- Destroy whatever is there currently for
    -- any player. That's so that the player doesn't
    -- look at an outdated GUI
    for _, child in pairs(player.gui.relative.children) do
        if child.name == "ss-docked-spider" then
            -- We destroy all GUIs, not only for this unit-number,
            -- because otherwise they will open for other entities
            child.destroy() 
        end
    end
    
    -- All spiders have their GUIs destroyed for this player
    -- Now redraw it if we're looking at a docked spider
    
    if not spider then return end
    local spider_data = get_spider_data_from_entity(spider)
    if not name_is_docked_spider(spider.name) then return end

    -- Decide if we should rebuild. We will only build
    -- if the player is currently looking at this docked spider
    if player.opened 
            and (player.opened == spider) 
            and spider_data.armed_for
            and spider_data.armed_for.valid then
        -- Build a new gui!

        -- Build starting frame
        local anchor = {
            gui=defines.relative_gui_type.spider_vehicle_gui, 
            position=defines.relative_gui_position.top
        }
        local invisible_frame = player.gui.relative.add{
            name="ss-docked-spider", 
            type="frame", 
            style="ss_invisible_frame",
            anchor=anchor,

            tags = {spider_unit_number = spider.unit_number}
        }

        -- Add button
        invisible_frame.add{
            type = "button",
            name = "spidertron-undock-button",
            caption = {"sd-spidertron-dock.undock"},
            style = "ss_undock_button",
        }
    end
end

function funcs.update_dock_gui_for_player(player, dock)
    
    -- Destroy whatever is there currently for
    -- any player. That's so that the player doesn't
    -- look at an outdated GUI
    for _, child in pairs(player.gui.relative.children) do
        if child.name == "ss-spidertron-dock" then
            -- We destroy all GUIs, not only for this unit-number,
            -- because otherwise they will open for other entities
            child.destroy() 
        end
    end
    
    -- All docks have their GUIs destroyed for this player
    -- If this dock is not occupied then we don't need
    -- to redraw anything
    local dock_data = get_dock_data_from_entity(dock)
    if not dock_data then return end -- Other accumulator type
    if not dock_data.occupied then return end

    -- Decide if we should rebuild. We will only build
    -- if the player is currently looking at this dock
    if player.opened and (player.opened == dock) then
        -- Build a new gui!

        -- Build starting frame
        local anchor = {
            gui=defines.relative_gui_type.accumulator_gui, 
            position=defines.relative_gui_position.top
        }
        local invisible_frame = player.gui.relative.add{
            name="ss-spidertron-dock", 
            type="frame", 
            style="ss_invisible_frame",
            anchor=anchor,

            tags = {dock_unit_number = dock.unit_number}
        }

        -- Add button
        invisible_frame.add{
            type = "button",
            name = "spidertron-undock-button",
            caption = {"sd-spidertron-dock.undock"},
            style = "ss_undock_button",
        }
    end
end

script.on_event(defines.events.on_gui_opened, function(event)
    local entity = event.entity
    if not entity then return end
    if event.gui_type == defines.gui_type.entity then
        -- Need to check all versions of specific entity
        -- type. Otherwise it will draw it for those too.
        if entity.type == "spider-vehicle" then
            funcs.update_spider_gui_for_player(
                game.get_player(event.player_index),
                event.entity
            )
        elseif entity.type == "accumulator" then
            funcs.update_dock_gui_for_player(
                game.get_player(event.player_index),
                event.entity
            )
        end
    end
end)

-- This event is called from both the dock gui and the
-- spidertron gui
script.on_event(defines.events.on_gui_click, function(event)
    local element = event.element
    local player = game.get_player(event.player_index)
    if element.name == "spidertron-undock-button" then
        local parent = element.parent 
        local dock_data = nil        
        if parent.name == "ss-spidertron-dock" then
            dock_data = global.docks[parent.tags.dock_unit_number]
        elseif parent.name == "ss-docked-spider" then
            local spider_data = get_spider_data_from_unit_number(
                element.parent.tags.spider_unit_number)
            if not spider_data then return end
            if not spider_data.armed_for.valid then return end
            dock_data = get_dock_data_from_entity(spider_data.armed_for)
        end
        if not dock_data then return end
        attempt_undock(dock_data, player)
    end
end)

-- All this code does it to show dock/interface connection where hovering
-- the mouse over either entity, similar to how beacons/machines. It's not
-- really required, but I think it will look cool.
script.on_event(defines.events.on_selected_entity_changed , function(event)
    local player = game.get_player(event.player_index)
    local player_data = global.players[event.player_index]

    -- Urgh, I don't want handle all players leaving or joining or whatever.
    -- I'll just hack it in here for now.
    if not player_data then
        global.players[event.player_index] = { }
        player_data = global.players[event.player_index]
    end
    
    -- Always destroy all current selection boxes, if any, to keep logic simple.
    -- We will have to do it most of the time anyway
    if player_data.selection_boxes then -- We create it dynamically
        for _, box in pairs(player_data.selection_boxes) do box.destroy() end
    end
    player_data.selection_boxes = { }
    
    -- Draw new custom selection if we need to 
    local entity = player.selected
    if not entity or not entity.valid then return end
    if name_is_dock(entity.name) then
        local dock_data = get_dock_data_from_entity(entity)
        local surface = entity.surface
        for interface_unit_number, interface in pairs(dock_data.interfaces) do
            table.insert(player_data.selection_boxes, surface.create_entity{
                name = "highlight-box",
                position = interface.position,
                source = interface,
                box_type = "electricity", -- For the light blue box
                render_player_index = event.player_index,
            })
        end
    elseif entity.name == "sd-spidertron-dock-interface" then        
        local interface_data = global.interfaces[entity.unit_number]
        if interface_data.dock then
            local dock = interface_data.dock
            table.insert(player_data.selection_boxes, entity.surface.create_entity{
                name = "highlight-box",
                position = dock.position,
                source = dock,
                box_type = "electricity", -- For the light blue box
                render_player_index = event.player_index,
            })
        end
    end
end)

-- It might be that some docks had their docked
-- spidey removed because mods changed. Clean them up
local function sanitize_docks()
    local marked_for_deletion = {}
    for unit_number, dock_data in pairs(global.docks) do
        local dock = dock_data.dock_entity
        if dock and dock.valid then
            if dock_data.occupied then
                if dock_data.mode == "active" then
                    if dock_data.docked_spider and not dock_data.docked_spider.valid then
                        -- This spider entity is no longer supported for docking. In this
                        -- case the data will be lost
                        table.insert(marked_for_deletion, unit_number)
                    end
                elseif dock_data.mode == "passive" then
                    if not global.spider_whitelist[dock_data.spider_name] then
                        -- This spider is no longer supported. We can undock the spider though
                        -- because we still have the serialized information
                        attempt_undock(dock_data, nil, true)
                        table.insert(marked_for_deletion, unit_number)
                    end
                end
            end
        else
            -- TODO There is some unhandled edge cases here, but
            -- I'll fix them later. This will only occur if a script
            -- destroys a dock without an event, which should not happen.
            table.insert(marked_for_deletion, unit_number)
        end
    end

    -- Clean up docks I marked for deletion
    for _, unit_number in pairs(marked_for_deletion) do
        global.docks[unit_number] = nil
    end
end

local function build_spider_whitelist()
    local whitelist = {}
    local spiders = game.get_filtered_entity_prototypes({{filter="type", type="spider-vehicle"}})
    for _, spider in pairs(spiders) do
        local original_spider_name = string.match(spider.name, "ss[-]docked[-](.*)")
        if original_spider_name and spiders[original_spider_name] then
            whitelist[original_spider_name] = true
        end
    end
    return whitelist
end

local function picker_dollies_blacklist_docked_spiders()
    if remote.interfaces["PickerDollies"] and remote.interfaces["PickerDollies"]["add_blacklist_name"] then
        local spiders = game.get_filtered_entity_prototypes({{filter="type", type="spider-vehicle"}})
        for _, spider in pairs(spiders) do
            if name_is_docked_spider(spider.name) then
                remote.call("PickerDollies", "add_blacklist_name",  spider.name)
            end
        end
    end
end

if script.active_mods["SpidertronEnhancements"] then
    -- This event fires when Spidertron Enhancements is used
    -- and a waypoint-with-pathfinding is created. This mod
    -- has a check ignore docked spidertrons, but we still
    -- want to send a message.
    script.on_event("spidertron-enhancements-use-alt-spidertron-remote", function(event)
        local player = game.get_player(event.player_index)
        if not player then return end
        local cursor_item = player.cursor_stack
        if cursor_item and cursor_item.valid_for_read and (cursor_item.type == "spidertron-remote" and cursor_item.name ~= "sp-spidertron-patrol-remote") then
            local spider = cursor_item.connected_entity
            if spider and string.match(spider.name, "ss[-]docked[-]") then            
                -- Prevent the auto pilot in case, but shouldn't be required
                spider.follow_target = nil
                spider.autopilot_destination = nil

                -- Let the player know
                spider.surface.play_sound{path="ss-no-no", position=spider.position}
                spider.surface.create_entity{
                    name = "flying-text",
                    position = spider.position,
                    text = {"sd-spidertron-dock.cannot-command"},
                    color = {r=1,g=1,b=1,a=1},
                }
            end
        end
    end
    )
end

script.on_init(function()
    global.docks = {}
    global.spiders = {}
    global.spider_whitelist = build_spider_whitelist()
    global.interfaces = {}
    global.players = {}
    picker_dollies_blacklist_docked_spiders()
    
    -- Add support for picker dollies
    if remote.interfaces["PickerDollies"] 
    and remote.interfaces["PickerDollies"]["dolly_moved_entity_id"] then
        script.on_event(remote.call("PickerDollies", "dolly_moved_entity_id"), picker_dollies_move_event)
    end
end)

script.on_load(function()
    -- Add support for picker dollies
    if remote.interfaces["PickerDollies"] 
        and remote.interfaces["PickerDollies"]["dolly_moved_entity_id"] then
        script.on_event(remote.call("PickerDollies", "dolly_moved_entity_id"), picker_dollies_move_event)
    end
end)

script.on_configuration_changed(function (event)
    global.docks = global.docks or {}
    global.spiders = global.spiders or {}
    global.spider_whitelist = build_spider_whitelist()
    global.interfaces = global.interfaces or {}
    global.players = global.players or {}
    
    picker_dollies_blacklist_docked_spiders()
    sanitize_docks()

    -- Fix technologies
    local technology_unlocks_spidertron = false
    for index, force in pairs(game.forces) do
        for _, technology in pairs(force.technologies) do		
            if technology.effects then			
                for _, effect in pairs(technology.effects) do
                    if effect.type == "unlock-recipe" then					
                        if effect.recipe == "spidertron" then
                            technology_unlocks_spidertron = true
                        end
                    end
                end
                if technology_unlocks_spidertron then
                    force.recipes["ss-spidertron-dock"].enabled = technology.researched
                    force.recipes["sd-spidertron-dock-interface"].enabled = technology.researched
                    break
                end
            end
        end
    end
end)
