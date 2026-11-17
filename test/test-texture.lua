-- test-texture.lua: noise grids, flow tracing, density renders and splats.
-- Field values are checked directly. One render checks that a splatted
-- point lights the right pixels through gen.image.

local T = require("test.testkit")
local check = T.check

local function near(a, b, tol)
    return math.abs(a - b) <= (tol or 1e-5)
end

local function sum(f)
    local w, h = f:size()
    local s = 0
    for y = 0, h - 1 do
        for x = 0, w - 1 do s = s + f:get(x, y) end
    end
    return s
end

print("Noise")

gen.noiseSeed(5)
local g = gen.noiseGrid(8, 4, {scale = 0.1, x = 0, y = 0, w = 80, h = 40})
-- Cell (3, 2) is centered at scene (35, 25), noise (3.5, 2.5).
check("noiseGrid matches gen.simplex at a cell center",
    near(g:get(3, 2), gen.simplex(3.5, 2.5)),
    string.format("grid %f, simplex %f", g:get(3, 2), gen.simplex(3.5, 2.5)))

check("noiseGrid without opts.seed uses the noise seed",
    gen.noiseGrid(4, 4, {scale = 0.3}):get(1, 1) == gen.noiseGrid(4, 4, {scale = 0.3, seed = 5}):get(1, 1))
local s5 = gen.simplex(1.3, 2.7)
gen.noiseSeed(6)
check("noiseSeed reseeds simplex", gen.simplex(1.3, 2.7) ~= s5)
gen.noiseSeed(5)
check("the same noiseSeed repeats simplex", gen.simplex(1.3, 2.7) == s5)
check("there is no separate texture seed", rawget(gen, "textureSeed") == nil)

local lo, hi = gen.noiseGrid(64, 64, {scale = 0.05, octaves = 4}):minMax()
check("simplex fBm stays within -1..1", lo >= -1 and hi <= 1, string.format("%f..%f", lo, hi))

local tlo = gen.noiseGrid(32, 32, {scale = 0.1, octaves = 3, fractal = "turbulence"}):minMax()
check("turbulence is non-negative", tlo >= 0, string.format("min %f", tlo))

local f1, f2 = gen.worley(2.3, 7.9)
check("worley F2 >= F1 >= 0", f1 >= 0 and f2 >= f1, string.format("F1 %f F2 %f", f1, f2))
local elo = gen.noiseGrid(32, 32, {kind = "worleyEdge", scale = 0.2}):minMax()
check("worleyEdge is non-negative", elo >= 0, string.format("min %f", elo))

local dx, dy = gen.curl(1.5, 2.5)
check("curl returns a vector", type(dx) == "number" and type(dy) == "number")

print("\nFlow")

local starts = {{10, 10}, {50, 50}, {90, 20}}
local paths = gen.traceFlow({starts = starts, bounds = {0, 0, 100, 100}, steps = 40, stepSize = 2, seed = 1})
check("traceFlow returns one path per start", #paths == 3, "got " .. #paths)
check("paths begin at their starts", paths[2][1][1] == 50 and paths[2][1][2] == 50)
local p = paths[1]
local step = math.sqrt((p[2][1] - p[1][1]) ^ 2 + (p[2][2] - p[1][2]) ^ 2)
check("paths move one step size per step", near(step, 2, 1e-4), "step " .. step)

local flow = gen.curlFlow({seed = 3})
local line = gen.trace(flow, {100, 100}, 10, 1)
check("curlFlow works with gen.trace", #line.points == 11)

print("\nFields")

local spike = gen.field(21, 21, 0)
spike:set(10, 10, 1)
local blurred = gen.blurField(spike, 2)
check("blurField keeps the total", near(sum(blurred), 1, 1e-4), "sum " .. sum(blurred))
check("blurField spreads the spike", blurred:get(10, 10) < 0.1 and blurred:get(12, 10) > 0)

local ramp = gen.field(5, 5, 0)
for y = 0, 4 do for x = 0, 4 do ramp:set(x, y, 2 * x) end end
local gx, gy = gen.fieldGradient(ramp)
check("fieldGradient of a ramp", gx:get(2, 2) == 2 and gy:get(2, 2) == 0)

print("\nDensity")

local a = gen.attractor({kind = "dejong", n = 50000, w = 64, h = 64, seed = 2})
local total = sum(a)
check("attractor counts its iterations", total > 49000 and total <= 50000.5, "total " .. total)

local d, hue = gen.flame({
    transforms = {
        {1, affine = {0.5, 0, 0, 0, 0.5, 0}, color = 0},
        {1, affine = {0.5, 0, 0.5, 0, 0.5, 0}, variations = {linear = 1}, color = 1},
        {1, affine = {0.5, 0, 0, 0, 0.5, 0.5}, color = 0.5},
    },
    n = 20000, w = 16, h = 16, seed = 1, bounds = {0, 0, 1, 1}, splat = "nearest",
})
check("flame plots every point inside the unit square", near(sum(d), 20000, 0.5), "sum " .. sum(d))
local clo, chi = hue:minMax()
check("flame color stays in 0..1", clo >= 0 and chi <= 1, string.format("%f..%f", clo, chi))
check("sierpinski hole is empty", d:get(12, 12) == 0)

local rf = gen.randomFlame(4, 2)
check("randomFlame gives transforms", #rf.transforms == 2 and rf.transforms[1].affine ~= nil)

print("\nSplat render")

os.execute("mkdir -p out/test")
local script = "out/test/texture-splat.lua"
local fh = assert(io.open(script, "w"))
fh:write([[
local c = gen.canvas(40, 40)
gen.background(c, {0, 0, 0})
local f = gen.field(4, 4, 0)
gen.splat(f, {{15, 25}, {15, 25, 3}}, {x = 0, y = 0, w = 40, h = 40, splat = "nearest"})
gen.draw(c, gen.image(f, 0, 0, 40, 40, {smooth = false}))
return c
]])
fh:close()
T.render(script, "out/test/texture-splat.ppm")
local px = T.readPpm("out/test/texture-splat.ppm")
check("splatted cell is white", T.gray(px, 15, 25) == 255, "gray " .. T.gray(px, 15, 25))
check("other cells stay black", T.gray(px, 35, 5) == 0, "gray " .. T.gray(px, 35, 5))

T.summary()
