-- test-pathops.lua: path operation checks through the Lua API.
-- Exact areas from booleans and offsets, then a rendered scene of xor,
-- inset and hatch results checked pixel by pixel.

local T = require("test.testkit")

local check = T.check
local gray = T.gray

local function area(shape)
    local a = 0
    for _, c in ipairs(shape.contours) do
        for i = 1, #c do
            local p, q = c[i], c[i % #c + 1]
            a = a + p[1] * q[2] - q[1] * p[2]
        end
    end
    return a / 2
end

local function near(name, got, want, tol)
    check(name, math.abs(got - want) <= tol, string.format("got %.6f, want %.6f +- %g", got, want, tol))
end

print("Booleans")
local a = gen.rect(0, 0, 10, 10)
local b = gen.rect(10, 0, 10, 10)
near("shared edge union", area(gen.clip(a, b, "union")), 200, 1e-9)
check("shared edge union is one contour", #gen.clip(a, b, "union").contours == 1)
near("shared edge intersect", area(gen.clip(a, b, "intersect")), 0, 1e-9)
near("self difference", area(gen.clip(a, a, "difference")), 0, 1e-9)
near("self intersect", area(gen.clip(a, a, "intersect")), 100, 1e-9)
local corner = gen.rect(10, 10, 10, 10)
check("touching corners stay apart", #gen.clip(a, corner, "union").contours == 2)
local ring = gen.compound({
    {{0, 0}, {30, 0}, {30, 30}, {0, 30}},
    {{10, 10}, {10, 20}, {20, 20}, {20, 10}},
})
near("ring with hole minus bar", area(gen.clip(ring, gen.rect(0, 12, 30, 6), "difference")), 900 - 100 - 180 + 60, 1e-9)
local twice = {gen.rect(0, 0, 4, 4), gen.rect(0, 0, 4, 4)}
near("doubled square nonzero", area(gen.clip(twice, nil, "union")), 16, 1e-9)
near("doubled square evenodd", area(gen.clip(twice, nil, "union", {rule = "evenodd"})), 0, 1e-9)

print("\nOffsets and distance")
near("square grown by 2", area(gen.offset(a, 2, {resolution = 0.05})), 100 + 80 + 4 * math.pi, 0.5)
near("square shrunk by 2", area(gen.offset(a, -2, {resolution = 0.05})), 36, 0.3)
near("sdBox outside corner", gen.sdEval(gen.sdBox({0, 0}, 2, 2), {4, 5}), 5, 1e-12)
near("sdPolygon inside", gen.sdEval(gen.sdPolygon(a), {3, 5}), -3, 1e-12)
local rings = gen.offsets(gen.circle({0, 0}, 40), {step = -10, count = 3})
near("third inward ring", area(rings[3]), math.pi * 100, 8)

print("\nContours")
local f = gen.sdfField(gen.sdCircle({50, 50}, 30), {rect = {0, 0, 100, 100}, cols = 100})
local lines = gen.contours(f, {0, 10}, {rect = {0, 0, 100, 100}})
check("two closed contours", #lines == 2 and lines[1].closed and lines[2].closed)
local maxErr = 0
for _, p in ipairs(lines[1].points) do
    maxErr = math.max(maxErr, math.abs(math.sqrt((p[1] - 50) ^ 2 + (p[2] - 50) ^ 2) - 30))
end
check("contour on the circle", maxErr < 0.05, "max error " .. maxErr)

print("\nPaths")
local dashes = {}
for i = 0, 19 do
    local k = (i * 7) % 20
    dashes[#dashes + 1] = gen.line({k * 10, 0}, {k * 10 + 5, 0})
end
local ordered, before, after = gen.orderPaths(dashes)
check("ordering keeps every path", #ordered == 20)
near("ordering removes the detours", after, 19 * 5, 1e-9)
check("ordering beat the input", before > after * 5, string.format("%.1f -> %.1f", before, after))
local joined = gen.joinPaths({gen.line({0, 0}, {5, 0}), gen.line({5, 5}, {5, 0}), gen.line({5, 5}, {0, 0})})
check("joined into one closed path", #joined == 1 and joined[1].type == "polygon" and #joined[1].points == 3)
check("simplify keeps a square's corners", #gen.simplify(gen.polygon({{0, 0}, {5, 0}, {10, 0}, {10, 10}, {0, 10}}), 0.1).points == 4)

------------------------------------------------------------
-- Render: xor of two squares, a disc shrunk by an offset, and a hatch.
------------------------------------------------------------
print("\nRendering test-pathops.ppm...")
gen.canvas(200, 200)
gen.background({1, 1, 1})
gen.draw(gen.clip(gen.rect(20, 20, 80, 80), gen.rect(60, 60, 80, 80), "xor"), {fill = {0, 0, 0}})
gen.draw(gen.offset(gen.circle({160, 40}, 30), -10), {fill = {0, 0, 0}})
for _, l in ipairs(gen.hatch(gen.rect(20, 150, 160, 40), {spacing = 8, offset = 2})) do
    gen.draw(l, {stroke = {0, 0, 0}, strokeWidth = 2})
end
gen.exportPpm("out/test/test-pathops.ppm")
local px = T.readPpm("out/test/test-pathops.ppm")

local function ink(name, x, y, dark)
    local v = gray(px, x, y)
    check(name, dark and v < 30 or (not dark and v > 225), string.format("(%d,%d) gray=%d", x, y, v))
end
ink("xor: first square only", 40, 40, true)
ink("xor: overlap is empty", 80, 80, false)
ink("xor: second square only", 120, 120, true)
ink("offset disc: center filled", 160, 40, true)
ink("offset disc: shrunk ring empty", 160, 15, false)
ink("hatch: on a line", 100, 154, true)
ink("hatch: between lines", 100, 158, false)
ink("hatch: outside the rect", 10, 154, false)

T.summary()
