-- The canvas. Each script has one, made by gen.canvas(w, h) and held here,
-- out of the script's reach. Draws and post passes are recorded in script
-- order and the CLI renders the canvas after the script finishes.

local M = {}

local current = nil

-- Prelude files share a source prefix, so the first stack level outside
-- it is the script line that made the call.
local preludeSource = debug.getinfo(1, "S").source:gsub("canvas%.lua$", "")

local function scriptLevel()
    local level = 3
    while true do
        local info = debug.getinfo(level, "S")
        if not info then return 1 end
        if info.source:sub(1, #preludeSource) ~= preludeSource then return level - 1 end
        level = level + 1
    end
end

-- The canvas, or an error at the script's line naming what needed it.
function M.need(what)
    if current == nil then
        error(what .. " needs the canvas. Call gen.canvas(w, h) first", scriptLevel())
    end
    return current
end

-- The canvas, or nil before gen.canvas. The CLI renders what this returns.
function M.current()
    return current
end

-- Raise an error at the script's line when a call passes a canvas
-- first. A variable set by `local c = gen.canvas(w, h)` holds nil, since
-- gen.canvas returns nothing, so a nil first argument followed by more
-- arguments counts.
function M.rejectCanvasArg(what, first, second, usage)
    local stale = (first == nil and second ~= nil)
        or (type(first) == "table" and rawget(first, "elements") ~= nil and rawget(first, "width") ~= nil)
    if stale then
        error(string.format("%s takes no canvas argument. The script has one canvas, made by gen.canvas(w, h). Call %s",
            what, usage), scriptLevel())
    end
end

-- Create the script's canvas, w by h. A script has one canvas, so a
-- second call is an error. Returns nothing.
function M.canvas(w, h)
    if current ~= nil then
        error("gen.canvas: the script already has a canvas. There is one canvas per script", 2)
    end
    if type(w) ~= "number" or type(h) ~= "number" or not (w > 0 and h > 0) then
        error("gen.canvas: width and height must be positive numbers", 2)
    end
    current = {width = w, height = h, bg = nil, elements = {}, layers = {}, passes = 0}
end

-- The canvas width and height.
function M.size()
    local c = M.need("gen.size")
    return c.width, c.height
end

-- Set the background color.
function M.background(color, extra)
    M.rejectCanvasArg("gen.background", color, extra, "gen.background(color)")
    M.need("gen.background").bg = color
end

-- Append a draw for prelude code that has already checked its arguments.
function M.add(shape, style)
    table.insert(M.need("gen.draw").elements, {shape = shape, style = style or {}})
end

-- Append a post pass with checked options.
function M.addPass(name, opts)
    local c = M.need("gen.post." .. name)
    table.insert(c.elements, {pass = name, opts = opts, shape = {type = "pass"}, style = {}})
    c.passes = c.passes + 1
end

-- Draw a shape with the given style.
-- Style keys: fill, stroke (color or gradient), strokeWidth, opacity,
-- fillOpacity, strokeOpacity, strokeLinecap, strokeLinejoin,
-- strokeDasharray (list of numbers), strokeDashoffset, blendMode, colorMap.
function M.draw(shape, style)
    M.rejectCanvasArg("gen.draw", shape, style, "gen.draw(shape, style)")
    M.add(shape, style)
end

-- Create a style table (passthrough convenience, same keys as draw).
function M.style(opts)
    return opts
end

-- Start a named layer. Later draws go to it until the next gen.layer.
function M.layer(name, extra)
    M.rejectCanvasArg("gen.layer", name, extra, "gen.layer(name)")
    local c = M.need("gen.layer")
    local l = {name = name, elements = {}}
    table.insert(c.layers, l)
    c.elements = l.elements
end

return M
