-- When a spidertron is docked the spider will
-- be replaced by a different spider-vehicle entity
-- which is a copy of the original one. This is changed
-- from the sprite system because an entity will have
-- functioning inventory, and logistics.

-- Notes:
--      Will still draw sprite, because spider will always be drawn on top
--          and we want the tall entities below the dock to draw over the
--          docked spider
--      To stop bouncing set entity to active==false
--          Manually charge all equipment then through dock
--          Except automatic-targetting weapons, deplete them of energy
--              Docked spiders shall not be used as defense.
--          Still allows logistic requests to be furfilled

local util = require("__core__/lualib/util")

local registry = require("registry")

-- An unmovable leg that will be used for all
-- docked spidertrons
data:extend{{
    type = "spider-leg",
    name = "ss-dead-leg",
    hidden = true,
    collision_box = nil,
    collision_mask = { layers = { }},
    selection_box = {{-0, -0}, {0, 0}},
    icon = "__base__/graphics/icons/spidertron.png",
    target_position_randomisation_distance = 0.25,
    minimal_step_size = 1,
    stretch_force_scalar = 1,
    knee_height = 1,
    knee_distance_factor = 0.4,
    initial_movement_speed = 1,
    movement_acceleration = 1,
    max_health = 10000,
    base_position_selection_distance = 1,
    movement_based_position_selection_distance = 1,
    selectable_in_game = false,
    alert_when_damaged = false,
}}


-- The sprites will be used when the spider is
-- docked passively.
function attempt_build_sprite(spider)
    local main_layers = {}
    local shadow_layers = {}
    local tint_layers = {}

    -- Try to build the sprite. We will only care about
    --  Base: The stationary frame at the bottom
    --      Here will will remove any potential layers with the
    --      word "flame" in the file name. Flames will burn the dock
    --  Animation: The part that turns
    --  Shadow: It's shadow
    --      Only here will we not expect layers
    --      What if it is though? FAIL!

    -- Using these sprites we will build our own three sprites
    -- that we layer during runtime. This will be:
    --      Main: The body, essentially a single rotation of the animation
    --      Tint: Only the tinted layers to give the docked spider the correct colours
    --      Shadow: Yup...

    if not spider.graphics_set then return end
    if not spider.graphics_set.base_animation then return end
    if not spider.graphics_set.animation then return end
    if not spider.graphics_set.shadow_animation then return end

    local torso_bottom_layers = util.copy(spider.graphics_set.base_animation.layers)
    local torso_body_layers = util.copy(spider.graphics_set.animation.layers)
    local torso_body_shadow = util.copy(spider.graphics_set.shadow_animation)

    if not torso_bottom_layers or not torso_body_layers or not torso_body_shadow then return end

    -- AAI Programmable Vehicles compatability:
    -- We don't display the AI version of the spider. Such spiders usually
    -- end with "-rocket-1" or something. This is a silly check, but should
    -- be good enough for now.
    if string.match(spider.name, "-[0-9]+$") then return end

    -- Sanitize and add the bottom layers
    for index, layer in pairs(torso_bottom_layers) do
        -- Actually, we don't want to draw the bottom.
        -- The spider sits much more snugly if we don't
        -- draw the bottom. Changing this requires 
        -- changing where the sprite is drawn
        break

        -- Only use non-flame layers
        -- Only looking at the bottom because that's likely where they will exist
        if not layer.filename:find("flame") then
            if layer.apply_runtime_tint then
                table.insert(tint_layers, layer)
            else
                table.insert(main_layers, layer)
            end
        end
    end

    -- Sanitize the and add the body layer. 
    for index, layer in pairs(torso_body_layers) do

        -- Rudemental sanity check to see if this is a
        -- normal-ish spidertron
        if layer.direction_count ~= 64 then return end

        -- The body layer contains animations for all rotations,
        -- So change {x,y} to a nice looking one
        -- TODO This can be smarter
        layer.x = layer.width * 4
        layer.y = layer.height * 4

        if layer.apply_runtime_tint then
            table.insert(tint_layers, layer)
        else
        table.insert(main_layers, layer)
        end
    end

    -- Sanitize the and add the shadow layers
    -- NB: We're not building the "bottom" shadows,
    -- because the bottom is not currently drawn
    for index, layer in pairs({torso_body_shadow}) do

        -- Rudemental sanity check to see if this is a
        -- normal-ish spidertron
        if layer.direction_count ~= 64 then return end

        -- The body layer contains animations for all rotations,
        -- So change {x,y} to a nice looking one
        -- TODO This can be smarter
        layer.x = layer.width * 4
        layer.y = layer.height * 4

        table.insert(shadow_layers, layer)
    end

    if not next(shadow_layers) or not next(main_layers) or not next(tint_layers) then return end

    -- Add the sprites
    data:extend{
        {
            type = "sprite",
            name = "ss-docked-"..spider.name.."-shadow",
            layers = shadow_layers,
            flags = {"shadow"},
            draw_as_shadow = true,
        },
        {
            type = "sprite",
            name = "ss-docked-"..spider.name.."-main",
            layers = main_layers,
        },
        {
            type = "sprite",
            name = "ss-docked-"..spider.name.."-tint",
            layers = tint_layers,
        },
    }

    return true
end


-- This function will dictate if a spider is
-- dockable or not. If we can build a docked-spider
-- for it to show during docking, then it's
-- dockable. If we find anything that we don't
-- expect, then we abort the spider, and it won't
-- be dockable. It will be checked during runtime
-- if this dummy entity exist, which dictates if
-- a spider type is dockable
function attempt_docked_spider(spider)

    -- Some basic checks
    if spider.hidden then return end
    if spider.selectable_in_game == false then return end
    if not spider.graphics_set then return end
    if not spider.graphics_set.base_animation then return end
    if not spider.graphics_set.animation then return end
    if not spider.graphics_set.shadow_animation then return end

    if not attempt_build_sprite(spider) then return end

    -- Good enough to start the construction attempt
    local docked_spider = util.copy(spider)
    docked_spider.name = "ss-docked-"..spider.name
    docked_spider.localised_name = {"sd-spidertron-dock.docked-spider", {"entity-name."..spider.name}}
    docked_spider.localised_description = {"sd-spidertron-dock.docked-spider-description"}
    docked_spider.factoriopedia_alternative = spider.name

    if mods["aai-programmable-vehicles"] then
        -- Ensure that the docked variants won't be programmable.
        -- It has a weird way to prevent it from being generated.
        docked_spider.order = docked_spider.order or ""
        docked_spider.order = docked_spider.order.."[no-aai]"
    end

    docked_spider.minable = {result = nil, mining_time = 1}
    docked_spider.torso_bob_speed = 0
    docked_spider.allow_passengers = false
    docked_spider.height = 0.35 -- To place spider on top of dock
    docked_spider.selection_box = {{-1, -1}, {1, 0.5}}
    docked_spider.collision_box = nil
    docked_spider.minimap_representation = nil
    docked_spider.selected_minimap_representation = nil
    docked_spider.allow_remote_driving = false

    -- Replace the leg with the invisible dead one
    docked_spider.spider_engine = {
        legs = {{
            leg = "ss-dead-leg",
            mount_position = {0, 0},
            ground_position = {0, 0},
            walking_group = 1,
            leg_hit_the_ground_trigger = nil
        }}
    }

    -- Remove base layers TODO Replace with light layer
    docked_spider.graphics_set.base_animation = {layers={
        -- Will also remove flames
        {
            filename = "__spidertron-dock__/graphics/spidertron-dock/dock-light.png",
            blend_mode = "additive",
            direction_count = 1,
            draw_as_glow = true,    -- Draws a sprite and a light
            width = 19,
            height = 19,
            shift = { -0.42, 0.5 },
            scale = 0.4,
            tint = {r=0.173, g=0.824, b=0.251, a=1},
            run_mode = "forward-then-backward",
            frame_count = 16,
            line_length = 8,
            -- 3 second loop, meaning 16 frames per 180 ticks
            animation_speed = 0.088, -- frames per tick
        }
    }}
    docked_spider.graphics_set.shadow_base_animation = util.empty_sprite(1)
    -- Change render layer so it's not on top of everything
    docked_spider.graphics_set.render_layer = "object"

    return docked_spider
end

local function safely_insert_description(descriptions, addition)
    if (#descriptions + 1) < 20 then -- +1 for the empty "" at the start
        if (#descriptions + 1) < 19 then
            table.insert(descriptions, addition)
        else
            table.insert(descriptions, {"sd-spidertron-dock.etc"})
        end
    end
end

-- Loop through all spider vehicles
local found_at_least_one = false
local docked_spiders = {}   -- Cannot insert in the loop, otherwise infinite loop
local dock_active_description = data.raw.accumulator["ss-spidertron-dock-active"].factoriopedia_description
local dock_passive_description = data.raw.accumulator["ss-spidertron-dock-passive"].factoriopedia_description
for _, spider in pairs(data.raw["spider-vehicle"]) do
    if not registry.is_blacklisted(spider) then
        local docked_spider = attempt_docked_spider(spider)
        if docked_spider then
            table.insert(docked_spiders, docked_spider)
            found_at_least_one = true

            for _, description in pairs({dock_active_description, dock_passive_description}) do
                safely_insert_description(description, {
                    "",
                    "\n[img=entity/"..spider.name.."]",
                    {"entity-name."..spider.name},
                })
            end
        end
    end
end
if not found_at_least_one then
    error("Could not find any spiders that can dock")
end
for _, docked_spider in pairs(docked_spiders) do data:extend{docked_spider} end



-- Create the docking light. This will be used when
-- the spider is docked in passive mode
data:extend{
    {
        -- We declare it as an animation because that can
        -- animate and have act as a light as well
        type = "animation",
        name = "ss-docked-light",
        layers = {
            {
                filename = "__spidertron-dock__/graphics/spidertron-dock/dock-light.png",
                blend_mode = "additive",
                draw_as_glow = true,    -- Draws a sprite and a light
                width = 19,
                height = 19,
                shift = { -0.42, 0.5 },
                scale = 0.4,
                tint = {r=87/255, g=174/255, b=255/255, a=1},
                run_mode = "forward-then-backward",
                frame_count = 16,
                line_length = 8,
                -- 3 second loop, meaning 16 frames per 180 ticks
                animation_speed = 0.088, -- frames per tick
            }
        }
    }
}
