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

print("\nSnap")

local function same(f, g)
    local w, h = f:size()
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            if f:get(x, y) ~= g:get(x, y) then return false end
        end
    end
    return true
end

local function errorOf(fn)
    local ok, err = pcall(fn)
    if ok then return nil end
    return err
end

local base = {kind = "dejong", n = 20000, w = 48, h = 48, seed = 2, supersample = 2}
local function with(snap)
    local o = {}
    for k, v in pairs(base) do o[k] = v end
    o.snap = snap
    return o
end

local plain = gen.attractor(with(nil))
check("snap with amount 0 is the unsnapped Field",
    same(plain, gen.attractor(with({cell = 4, amount = 0, chance = 0.5}))))
check("snap = 6 is {cell = 6}", same(gen.attractor(with(6)), gen.attractor(with({cell = 6}))))
check("snap changes the Field", not same(plain, gen.attractor(with(6))))
local j = {cell = 5, mode = "hex", jitter = 0.4, chance = 0.7, angle = 15}
check("snap is deterministic per seed", same(gen.attractor(with(j)), gen.attractor(with(j))))
local polar = {cell = 3, mode = "polar", spokes = 16, center = {20, 30}, feedback = true}
check("polar feedback renders", sum(gen.attractor(with(polar))) > 19000)

local sd = gen.flame({
    transforms = {
        {1, affine = {0.5, 0, 0, 0, 0.5, 0}},
        {1, affine = {0.5, 0, 0.5, 0, 0.5, 0}},
        {1, affine = {0.5, 0, 0, 0, 0.5, 0.5}},
    },
    n = 20000, w = 20, h = 20, seed = 1, bounds = {0, 0, 1, 1}, splat = "nearest",
    snap = {cell = 4, mode = "columns"},
})
local offLattice = 0
for y = 0, 19 do
    for x = 0, 19 do
        if x % 4 ~= 0 then offLattice = offLattice + sd:get(x, y) end
    end
end
check("flame columns snap lights only lattice columns", offLattice == 0, "off lattice " .. offLattice)

local sf = gen.field(10, 10, 0)
gen.splat(sf, {{1.2, 1.3}, {8.9, 4.4}}, {snap = {cell = 3}, splat = "nearest", seed = 1})
check("splat snaps points onto the lattice", sf:get(0, 0) == 1 and sf:get(9, 3) == 1)

local function snapError(what, snap)
    local fn = what == "flame" and gen.flame or gen.attractor
    local opts = what == "flame" and {transforms = {{1}}, n = 10, w = 8, h = 8, snap = snap}
        or {n = 10, w = 8, h = 8, snap = snap}
    local line = debug.getinfo(1, "l").currentline; local err = errorOf(function() fn(opts) end)
    return err, line
end

local err, line = snapError("attractor", {cell = 4, jiter = 0.2})
check("an unknown snap key raises with a suggestion",
    err and err:find("gen.attractor snap: unknown option 'jiter' (did you mean 'jitter'?)", 1, true), err)
check("the unknown key error names the calling line",
    err and err:find("test-texture.lua:" .. line .. ":", 1, true), err)
err = snapError("flame", {cell = 4, feedbak = true})
check("flame checks snap keys too",
    err and err:find("unknown option 'feedbak' (did you mean 'feedback'?)", 1, true), err)

local bad = {
    {0, "snap.cell' must be above 0"},
    {true, "'snap' must be a cell size or a table"},
    {{mode = "grid"}, "'snap.cell' must be a number"},
    {{cell = -2}, "'snap.cell' must be above 0"},
    {{cell = 4, amount = 1.5}, "'snap.amount' is out of range"},
    {{cell = 4, chance = -0.1}, "'snap.chance' is out of range"},
    {{cell = 4, jitter = "lots"}, "'snap.jitter' must be a number"},
    {{cell = 4, mode = "hexx"}, "unknown value 'hexx' (grid, rows, columns, hex or polar)"},
    {{cell = 4, spokes = 2.5}, "'snap.spokes' must be a whole number"},
    {{cell = 4, spokes = 0}, "'snap.spokes' is out of range"},
    {{cell = 4, center = 3}, "'snap.center' must be {x, y}"},
    {{cell = 4, feedback = "yes"}, "'snap.feedback' must be true or false"},
}
for _, case in ipairs(bad) do
    for _, what in ipairs({"attractor", "flame"}) do
        local e, l = snapError(what, case[1])
        check(what .. " rejects " .. case[2], e and e:find(case[2], 1, true), e)
        check(what .. " names the line for " .. case[2], e and e:find("test-texture.lua:" .. l .. ":", 1, true), e)
    end
end
err = errorOf(function() gen.splat(gen.field(4, 4, 0), {{1, 1}}, {snap = {cell = 2, feedback = true}}) end)
check("splat has no snap feedback",
    err and err:find("gen.splat snap: unknown option 'feedback'", 1, true), err)

print("\nSplat render")

local script = "out/test/texture-splat.lua"
local fh = assert(io.open(script, "w"))
fh:write([[
gen.canvas(40, 40)
gen.background({0, 0, 0})
local f = gen.field(4, 4, 0)
gen.splat(f, {{15, 25}, {15, 25, 3}}, {x = 0, y = 0, w = 40, h = 40, splat = "nearest"})
gen.draw(gen.image(f, 0, 0, 40, 40, {smooth = false}))
]])
fh:close()
T.render(script, "out/test/texture-splat.ppm")
local px = T.readPpm("out/test/texture-splat.ppm")
check("splatted cell is white", T.gray(px, 15, 25) == 255, "gray " .. T.gray(px, 15, 25))
check("other cells stay black", T.gray(px, 35, 5) == 0, "gray " .. T.gray(px, 35, 5))

T.summary()
