-- test-post.lua: raster post passes land where the scene says, at any scale.
-- Scene: black 40x20 canvas, red rect over x 10..20, red channel shifted
-- right by 3 scene units, then the left 5 units inverted.

local T = require("test.testkit")

local check = T.check
local rgb = T.rgb

local scene = [[
local c = gen.canvas(40, 20)
gen.background(c, {0, 0, 0})
gen.draw(c, gen.rect(10, 0, 10, 20), {fill = {1, 0, 0}})
gen.post(c, "channelShift", {r = {3, 0}})
gen.post(c, "invert", {region = {0, 0, 5, 20}})
gen.draw(c, gen.rect(30, 0, 10, 20), {fill = {0.3, 0.3, 0.3}})
gen.post(c, "posterize", {levels = 2, region = {35, 0, 5, 20}})
return c
]]

local f = assert(io.open("out/test/post-scene.lua", "w"))
f:write(scene)
f:close()

local function render(scale)
    local out = string.format("out/test/test-post-%d.ppm", scale)
    T.render("out/test/post-scene.lua", out, {scale = scale})
    return T.readPpm(out)
end

local function isRgb(name, pixels, x, y, er, eg, eb)
    local r, g, b = rgb(pixels, x, y)
    local ok = math.abs(r - er) <= 2 and math.abs(g - eg) <= 2 and math.abs(b - eb) <= 2
    check(name, ok, string.format("(%d,%d) rgb=(%d,%d,%d), expected (%d,%d,%d)", x, y, r, g, b, er, eg, eb))
end

for _, s in ipairs({1, 2}) do
    print(string.format("Scale %d", s))
    local px = render(s)
    local y = 10 * s
    isRgb("left of the red edge goes black", px, 12 * s, y, 0, 0, 0)
    isRgb("red lands 3 units right", px, 21 * s, y, 255, 0, 0)
    isRgb("inside stays red", px, 16 * s, y, 255, 0, 0)
    isRgb("past the shifted edge is black", px, 24 * s, y, 0, 0, 0)
    isRgb("region inverts black to white", px, 2 * s, y, 255, 255, 255)
    isRgb("outside the region stays black", px, 7 * s, y, 0, 0, 0)
    isRgb("gray before posterize region", px, 32 * s, y, 77, 77, 77)
    isRgb("posterize to 2 levels", px, 37 * s, y, 0, 0, 0)
end

print("\nBad passes fail at the gen.post line")

local function postError(name, opts)
    local c = gen.canvas(10, 10)
    local line = debug.getinfo(1, "l").currentline + 1
    local ok, err = pcall(function() gen.post(c, name, opts) end)
    if ok then return nil, line end
    return err, line
end

local function postCheck(what, name, opts, message)
    local err, line = postError(name, opts)
    check(what .. " raises", err ~= nil)
    check(what .. " says why", err and err:find(message, 1, true), err)
    check(what .. " names the script line",
        err and err:find("test%-post%.lua:" .. line .. ": gen%.post: "), err)
end

postCheck("unknown pass", "nope", {}, "unknown post pass 'nope'")
postCheck("misspelled pass", "pixelsort", {}, "unknown post pass 'pixelsort' (did you mean 'pixelSort'?)")
postCheck("bad option value", "tear", {axis = "q"}, "option 'axis': unknown value 'q'")
postCheck("angle given as direction", "pixelSort", {direction = 45}, "Use angle for degrees")
postCheck("unknown option key", "blur", {radus = 2}, "post pass 'blur' has no option 'radus' (did you mean 'radius'?)")
postCheck("unknown key, nothing close", "invert", {wobble = true}, "post pass 'invert' has no option 'wobble'")
check("no suggestion when nothing is close",
    not (postError("invert", {wobble = true})):find("did you mean", 1, true))
check("angle still sets pixelSort's direction", postError("pixelSort", {angle = 45}) == nil)
check("region and seed are accepted everywhere", postError("invert", {region = {0, 0, 5, 5}, seed = 3}) == nil)

print("\nErrors found at render time")

local late = [[
local c = gen.canvas(10, 10)
gen.post(c, "blur", {})
c.elements[#c.elements].opts.radius = "big"
return c
]]
f = assert(io.open("out/test/post-late.lua", "w"))
f:write(late)
f:close()
local ok, err = pcall(T.render, "out/test/post-late.lua", "out/test/post-late.ppm")
check("an option edited after gen.post fails the render", not ok)
check("the render error says why", err and err:find("option 'radius' must be a number", 1, true), err)

local c = gen.canvas(10, 10)
table.insert(c.elements, {shape = {type = "blob"}, style = {}})
ok, err = pcall(gen.exportPng, c, "out/test/post-blob.png")
check("exportPng raises for a bad shape", not ok)
check("the export error says why", err and err:find("unknown shape type 'blob'", 1, true), err)
ok = pcall(gen.exportPng, gen.canvas(4, 4), "out/test/post-ok.png")
check("the state still exports after a failed export", ok)

T.summary()
