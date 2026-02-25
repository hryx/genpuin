local M = {}

function M.canvas(w, h)
    return {width = w, height = h, bg = nil, elements = {}, layers = {}}
end

function M.background(c, color)
    c.bg = color
    return c
end

function M.draw(c, shape, style)
    table.insert(c.elements, {shape = shape, style = style or {}})
    return c
end

function M.style(opts)
    return opts
end

function M.layer(c, name)
    local l = {name = name, elements = {}}
    table.insert(c.layers, l)
    -- redirect draws to this layer until next layer call
    c.elements = l.elements
    return c
end

return M
