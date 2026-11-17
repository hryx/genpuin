local M = {}

-- Create a new canvas with the given width and height.
function M.canvas(w, h)
    return {width = w, height = h, bg = nil, elements = {}, layers = {}}
end

-- Set the background color of the canvas.
function M.background(c, color)
    c.bg = color
    return c
end

-- Draw a shape onto the canvas with the given style.
-- Style keys: fill, stroke (color or gradient), strokeWidth, opacity,
-- fillOpacity, strokeOpacity, strokeLinecap, strokeLinejoin,
-- strokeDasharray (list of numbers), strokeDashoffset, blendMode, colorMap.
function M.draw(c, shape, style)
    table.insert(c.elements, {shape = shape, style = style or {}})
    return c
end

-- Create a style table (passthrough convenience, same keys as draw).
function M.style(opts)
    return opts
end

-- Create a named layer; subsequent draws go to this layer.
function M.layer(c, name)
    local l = {name = name, elements = {}}
    table.insert(c.layers, l)
    -- redirect draws to this layer until next layer call
    c.elements = l.elements
    return c
end

return M
