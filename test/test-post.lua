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

os.execute("mkdir -p out/test")
local f = assert(io.open("out/test/post-scene.lua", "w"))
f:write(scene)
f:close()

local function render(scale)
    local out = string.format("out/test/test-post-%d.ppm", scale)
    local cmd = string.format("%s out/test/post-scene.lua -s %d -o %s", arg[-1], scale, out)
    local ok = os.execute(cmd)
    if ok ~= true and ok ~= 0 then
        print("ABORT: render failed: " .. cmd)
        os.exit(1)
    end
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

T.summary()
