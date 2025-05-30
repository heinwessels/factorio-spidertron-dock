local item_sounds = require("__base__.prototypes.item_sounds")
local sounds = require("__base__.prototypes.entity.sounds")
local util = require("__core__/lualib/util")

local dock_active = {
    -- Type radar so that we have an animation to work with
    type = "accumulator",
    name = "ss-spidertron-dock-active",
    factoriopedia_alternative = "ss-spidertron-dock",
    localised_name = {"entity-name.ss-spidertron-dock"},
    icon = "__spidertron-dock__/graphics/spidertron-dock/dock-icon.png",
    placeable_by = {item="ss-spidertron-dock", count=1},
    minable = {mining_time = 0.1, result = "ss-spidertron-dock"},
    icon_size = 64, icon_mipmaps = 4,
    flags = {"placeable-player", "player-creation"},
    max_health = 250,
    corpse = "medium-remnants",
    dying_explosion = "medium-explosion",
    collision_box = {{-0.7, -0.7}, {0.7, 0.7}},
    selection_box = {{-1, -1}, {1, 1}},
    charge_cooldown = 30,
    discharge_cooldown = 60,
    energy_per_nearby_scan = "1J",
    energy_source = {
      type = "electric",
      buffer_capacity = "1J",
      usage_priority = "tertiary",
      input_flow_limit = "1W",
      output_flow_limit = "1W",
      render_no_network_icon = false,
      render_no_power_icon = false,
    },
    chargable_graphics = {
      picture =
      {
        layers =
        {
          {
            filename = "__spidertron-dock__/graphics/spidertron-dock/hr-dock.png",
            priority = "low",
            width = 113,
            height = 120,
            direction_count = 1,
            shift = util.by_pixel(0, -4),
            scale = 0.6,
          },
          {
              filename = "__spidertron-dock__/graphics/spidertron-dock/dock-shadow.png",
              priority = "low",
              width = 126,
              height = 80,
              direction_count = 1,
              shift = util.by_pixel(20, 6),
              scale = 0.6,
              draw_as_shadow = true,
          },
        }
      },
    },
    vehicle_impact_sound = sounds.generic_impact,
    working_sound =
    {
      sound =
      {
        {
          filename = "__base__/sound/accumulator-working.ogg",
          volume = 0.8
        }
      },
      --persistent = true,
      max_sounds_per_type = 3,
      audible_distance_modifier = 0.5,
      fade_in_ticks = 4,
      fade_out_ticks = 20
    },
    radius_minimap_visualisation_color = { r = 0.059, g = 0.092, b = 0.235, a = 0.275 },
    rotation_speed = 0.01,
    water_reflection =
    {
      pictures =
      {
        filename = "__base__/graphics/entity/radar/radar-reflection.png",
        priority = "extra-high",
        width = 28,
        height = 32,
        shift = util.by_pixel(5, -15),
        variation_count = 1,
        scale = 5
      },
      rotate = false,
      orientation_to_variation = false
    }
}

local dock_item = {
    type = "item",
    name = "ss-spidertron-dock",
    icon = "__spidertron-dock__/graphics/spidertron-dock/dock-icon.png",
    icon_size = 64, icon_mipmaps = 4,
    subgroup = "transport",
    order = "b[personal-transport]-c[spidertron]-d[spidertron-dock]",
    inventory_move_sound = item_sounds.mechanical_inventory_move,
    pick_sound = item_sounds.mechanical_inventory_move,
    drop_sound = item_sounds.mechanical_inventory_move,
    place_result = "ss-spidertron-dock-active",
    stack_size = 20
}

local dock_recipe = {
    type = "recipe",
    name = "ss-spidertron-dock",
    enabled = false,
    energy_required = 10,
    ingredients = {
        {type = "item", name = "steel-plate", amount = 20},
        {type = "item", name = "low-density-structure", amount = 10},
        {type = "item", name = "engine-unit", amount = 10},
    },
    results = {{type = "item", name = "ss-spidertron-dock", amount = 1}},
}

local dock_passive = util.table.deepcopy(dock_active)
dock_passive.name = "ss-spidertron-dock-passive"
dock_passive.factoriopedia_alternative = "ss-spidertron-dock"

local dock_hidden = util.table.deepcopy(dock_active)
dock_hidden.name = "ss-spidertron-dock"
dock_hidden.hidden = true -- This is a little hacky, but it works

data:extend{dock_active, dock_passive, dock_hidden, dock_item, dock_recipe}


-- Create descriptions
dock_active = data.raw.accumulator["ss-spidertron-dock-active"]
dock_passive = data.raw.accumulator["ss-spidertron-dock-passive"]

for i, dock in pairs({dock_active, dock_passive, dock_hidden}) do
  dock.localised_description = {""}
  if mods["space-exploration"] then
    table.insert(dock.localised_description, {"sd-spidertron-dock.description-se"})
  else
    table.insert(dock.localised_description, {"sd-spidertron-dock.description"})
  end
  table.insert(dock.localised_description, {"sd-spidertron-dock.description-mode-"..(i==1 and "active" or "passive")})
  table.insert(dock.localised_description, {"sd-spidertron-dock.description-use"})

  dock.factoriopedia_description = {"",
    {"sd-spidertron-dock.description"..( mods["space-exploration"] and "-se" or "")},
    {"sd-spidertron-dock.factoriopedia-description"},
    {"sd-spidertron-dock.supported"},
  }
end
