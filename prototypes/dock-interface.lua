local interface = util.copy(data.raw["constant-combinator"]["constant-combinator"])
interface.name = "sd-spidertron-dock-interface"
interface.item_slot_count = 1
interface.allow_copy_paste = false
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