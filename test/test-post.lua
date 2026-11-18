-- test-post.lua: raster post passes land where the scene says, at any width.
-- Scene: black 40x20 canvas, red rect over x 10..20, red channel shifted
-- right by 3 scene units, then the left 5 units inverted.

local T = require("test.testkit")

local check = T.check
local rgb = T.rgb

local scene = [[
gen.canvas(40, 20)
gen.background({0, 0, 0})
gen.draw(gen.rect(10, 0, 10, 20), {fill = {1, 0, 0}})
gen.post.channelShift({r = {3, 0}})
gen.post.invert({region = {0, 0, 5, 20}})
gen.draw(gen.rect(30, 0, 10, 20), {fill = {0.3, 0.3, 0.3}})
gen.post.posterize({levels = 2, region = {35, 0, 5, 20}})
]]
local f = assert(io.open("out/test/post-scene.lua", "w"))
f:write(scene)
f:close()

local function render(width)
    local out = string.format("out/test/test-post-%d.ppm", width)
    T.render("out/test/post-scene.lua", out, {width = width})
    return T.readPpm(out)
end

local function isRgb(name, pixels, x, y, er, eg, eb)
    local r, g, b = rgb(pixels, x, y)
    local ok = math.abs(r - er) <= 2 and math.abs(g - eg) <= 2 and math.abs(b - eb) <= 2
    check(name, ok, string.format("(%d,%d) rgb=(%d,%d,%d), expected (%d,%d,%d)", x, y, r, g, b, er, eg, eb))
end

for _, s in ipairs({1, 2, 3}) do
    print(string.format("Width %d", 40 * s))
    local px = render(40 * s)
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

gen.canvas(10, 10)

local function postError(name, opts)
    local line = debug.getinfo(1, "l").currentline + 1
    local ok, err = pcall(function() gen.post[name](opts) end)
    if ok then return nil, line end
    return err, line
end

local function postCheck(what, name, opts, message)
    local err, line = postError(name, opts)
    check(what .. " raises", err ~= nil)
    check(what .. " says why", err and err:find(message, 1, true), err)
    check(what .. " names the script line",
        err and err:find("test%-post%.lua:" .. line .. ": gen%.post"), err)
end

postCheck("unknown pass", "nope", {}, "gen.post.nope does not exist")
postCheck("misspelled pass", "pixelsort", {}, "gen.post.pixelsort does not exist (did you mean gen.post.pixelSort?)")
postCheck("bad option value", "tear", {axis = "q"}, "gen.post.tear: option 'axis': unknown value 'q'")
postCheck("angle given as direction", "pixelSort", {direction = 45}, "Use angle for degrees")
postCheck("unknown option key", "blur", {radus = 2}, "post pass 'blur' has no option 'radus' (did you mean 'radius'?)")
postCheck("unknown key, nothing close", "invert", {wobble = true}, "post pass 'invert' has no option 'wobble'")
postCheck("passesField alone", "pixelSort", {passesField = gen.field(2, 2, 1)}, "option 'passesField' scales passes")
postCheck("fractional passes", "pixelSort", {passes = 2.5}, "option 'passes' must be a whole number")
check("no suggestion when nothing is close",
    not (postError("invert", {wobble = true})):find("did you mean", 1, true))
check("angle still sets pixelSort's direction", postError("pixelSort", {angle = 45}) == nil)
check("passes and passesField are accepted",
    postError("pixelSort", {passes = 3, passesField = gen.field(2, 2, 1)}) == nil)
check("region and seed are accepted everywhere", postError("invert", {region = {0, 0, 5, 5}, seed = 3}) == nil)
check("every pass runs without options", postError("grain") == nil)

local ok, err = pcall(function() gen.post(nil, "blur", {}) end)
check("gen.post is not callable", not ok)
check("calling gen.post says how to call a pass", err and err:find("Call gen.post.name(opts)", 1, true), err)

print("\nErrors found at render time")

local blob = [[
gen.canvas(10, 10)
gen.draw({type = "blob"})
]]
f = assert(io.open("out/test/post-blob.lua", "w"))
f:write(blob)
f:close()
ok, err = pcall(T.render, "out/test/post-blob.lua", "out/test/post-blob.png")
check("a bad shape fails the render", not ok)
check("the render error says why", err and err:find("unknown shape type 'blob'", 1, true), err)

print("\nPartial pixel sort")

local melt = [[
gen.canvas(32, 4)
gen.background({0, 0, 0})
for x = 0, 31 do
    local v = 0.9 - x * 0.02
    gen.draw(gen.rect(x, 0, 1, 4), {fill = {v, v, v}})
end
gen.post.pixelSort({lo = 0, hi = 1, passes = PASSES})
]]
local function inversions(passes)
    local path = string.format("out/test/post-melt-%s.lua", passes)
    f = assert(io.open(path, "w"))
    f:write((melt:gsub("PASSES", passes)))
    f:close()
    local out = string.format("out/test/post-melt-%s.ppm", passes)
    T.render(path, out)
    local px = T.readPpm(out)
    local n = 0
    for i = 0, 31 do
        for j = i + 1, 31 do
            if T.gray(px, i, 2) > T.gray(px, j, 2) then n = n + 1 end
        end
    end
    return n
end
local none, some, all = inversions("0"), inversions("6"), inversions("nil")
check("passes = 0 leaves the ramp", none == 32 * 31 / 2, tostring(none))
check("a few passes sort partway", some > 0 and some < none, tostring(some))
check("no passes sorts fully", all == 0, tostring(all))

T.summary()
