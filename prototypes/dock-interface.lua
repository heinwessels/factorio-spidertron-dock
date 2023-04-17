local interface = util.copy(data.raw["constant-combinator"]["constant-combinator"])
interface.name = "sd-spidertron-dock-interface"
interface.item_slot_count = 1
interface.allow_copy_paste = false
interface.icon = "__spidertron-dock__/graphics/spidertron-dock-interface/spidertron-dock-interface-icon.png"
interface.icon_size = 64
interface.icon_mipmaps = 0
interface.minable.result = "sd-spidertron-dock-interface"
interface.radius_visualisation_specification = {
    offset = {0, 1},
    distance = 0.5,
    sprite = {
        filename = "__core__/graphics/arrows/gui-arrow-circle.png",
        height = 50,
        width = 50
    }
}

interface.sprites = { }
for x, direction in pairs{"north", "east", "south", "west"} do
    interface.sprites[direction] = {layers = {
        {
            filename = "__spidertron-dock__/graphics/spidertron-dock-interface/hr-spidertron-dock-interface.png",
            frame_count = 1,
            height = 102,
            priority = "high",
            scale = 0.5,
            shift = { 0, 0.15625 },
            width = 114,
            x = (x-1) * 114,
            y = 0
        },
        {
            draw_as_shadow = true,
            filename = "__base__/graphics/entity/combinator/hr-constant-combinator-shadow.png",
            frame_count = 1,
            height = 66,
            priority = "high",
            scale = 0.5,
            shift = { 0.265625, 0.171875 },
            width = 98,
            x = (x-1) * 98,
            y = 0
        }
    }}
end


local interface_item = {
    type = "item",
    name = "sd-spidertron-dock-interface",
    icon = interface.icon,
    icon_size = interface.icon_size,
    stack_size = 20,
    subgroup = "transport",
    order = "b[personal-transport]-c[spidertron]-d[spidertron-dock-interface]",
    place_result = "sd-spidertron-dock-interface"
}

local interface_recipe = {
    type = "recipe",
    name = "sd-spidertron-dock-interface",
    icon = interface.icon,
    icon_size = interface.icon_size,
    enabled = false,
    ingredients = {
        {"copper-cable", 5},
        {"electronic-circuit", 10},
    },
    energy_required = 5,
    result = "sd-spidertron-dock-interface"
}

data:extend{interface, interface_item, interface_recipe}