-- test-canvas.lua: one canvas per script, made by gen.canvas and rendered
-- after the script, whatever it returns.

local T = require("test.testkit")

local check = T.check

local function errorOf(fn)
    local ok, err = pcall(fn)
    if ok then return nil end
    return err
end

local function write(path, text)
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
end

print("Before gen.canvas")

local err = errorOf(function() gen.draw(gen.circle({5, 5}, 2), {fill = {1, 1, 1}}) end)
check("draw before canvas raises", err ~= nil)
check("the error says to call gen.canvas first",
    err and err:find("gen.draw needs the canvas. Call gen.canvas(w, h) first", 1, true), err)
check("the error names the script line", err and err:find("test%-canvas%.lua:22:"), err)
err = errorOf(function() return gen.size() end)
check("size before canvas raises", err and err:find("gen.size needs the canvas", 1, true), err)
local pen = gen.pen()
err = errorOf(function() pen:moveTo({0, 0}):forward(3):stroke() end)
check("a pen stroke before canvas names the script line",
    err and err:find("test%-canvas%.lua:30: gen%.draw needs the canvas") ~= nil, err)
err = errorOf(function() gen.post.invert() end)
check("a post pass before canvas raises", err and err:find("gen.post.invert needs the canvas", 1, true), err)

print("\nOne canvas")

check("gen.canvas returns nothing", select("#", gen.canvas(30, 20)) == 0)
local w, h = gen.size()
check("gen.size returns width and height", w == 30 and h == 20, string.format("%s %s", w, h))
err = errorOf(function() gen.canvas(10, 10) end)
check("a second gen.canvas raises", err and err:find("already has a canvas", 1, true), err)
check("the second canvas error names the script line", err and err:find("test%-canvas%.lua:41:"), err)
w, h = gen.size()
check("the second call left the canvas alone", w == 30 and h == 20)

print("\nOld canvas arguments")

local c = nil
err = errorOf(function() gen.draw(c, gen.circle({5, 5}, 2), {fill = {1, 1, 1}}) end)
check("draw with a canvas first raises", err and err:find("gen.draw takes no canvas argument", 1, true), err)
check("the error shows the new call", err and err:find("gen.draw(shape, style)", 1, true), err)
err = errorOf(function() gen.background(c, {1, 1, 1}) end)
check("background with a canvas first raises", err and err:find("gen.background takes no canvas argument", 1, true), err)
err = errorOf(function() gen.exportPng(c, "out/test/never.png") end)
check("exportPng with a canvas first raises", err and err:find("gen.exportPng takes no canvas argument", 1, true), err)
err = errorOf(function() gen.pen(c) end)
check("pen with a canvas raises", err and err:find("gen.pen takes no canvas argument", 1, true), err)
err = errorOf(function() gen.wfcDraw(c, {}, {}) end)
check("wfcDraw with a canvas first raises", err and err:find("gen.wfcDraw takes no canvas argument", 1, true), err)

print("\nRendering")

write("out/test/canvas-returns.lua", [[
gen.canvas(4, 4)
gen.background({1, 0, 0})
return 42, gen
]])
T.render("out/test/canvas-returns.lua", "out/test/canvas-returns.ppm")
local px = T.readPpm("out/test/canvas-returns.ppm")
check("the return value is ignored and the canvas renders", select(1, T.rgb(px, 1, 1)) == 255,
    string.format("%d %d %d", T.rgb(px, 1, 1)))

write("out/test/canvas-none.lua", "local x = 1\n")
local ok, msg = pcall(T.render, "out/test/canvas-none.lua", "out/test/canvas-none.ppm")
check("a script with no canvas does not render", not ok)
check("the error says to call gen.canvas", msg and msg:find("made no canvas", 1, true), msg)

write("out/test/canvas_stamp.lua", [[
local M = {}

function M.stamp(x, y)
    gen.draw(gen.rect(x, y, 2, 2), {fill = {0, 1, 0}})
end

return M
]])
write("out/test/canvas-helper.lua", [[
local stamp = require("canvas_stamp").stamp
gen.canvas(8, 8)
gen.background({0, 0, 0})
stamp(1, 1)
gen.draw(gen.rect(5, 5, 2, 2), {fill = {0, 0, 1}})
stamp(5, 1)
]])
T.render("out/test/canvas-helper.lua", "out/test/canvas-helper.ppm")
px = T.readPpm("out/test/canvas-helper.ppm")
local function green(x, y)
    local r, g, b = T.rgb(px, x, y)
    return r == 0 and g == 255 and b == 0
end
check("a required module draws into the script's canvas", green(1, 1) and green(5, 1),
    string.format("%d %d %d", T.rgb(px, 1, 1)))
check("the script's own draws land too", select(3, T.rgb(px, 5, 5)) == 255)
check("the background stays where nothing drew", select(2, T.rgb(px, 3, 6)) == 0)

T.summary()
