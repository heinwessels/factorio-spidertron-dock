for _, dock_data in pairs(storage.docks) do
    local render_objects = { }
    for _, object_id in pairs(dock_data.docked_sprites) do
        rendering.get_object_by_id(object_id --[[@as uint64]])
    end
    dock_data.docked_sprites = render_objects
end