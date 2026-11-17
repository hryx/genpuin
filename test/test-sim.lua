-- test-sim.lua: sanity properties of the simulations in genpuin.sim, plus
-- one render check that a physarum ring draws where the agents are.

local T = require("test.testkit")
local gen = require("genpuin")

local check = T.check

local function fieldsEqual(a, b)
    local w, h = a:size()
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            if a:get(x, y) ~= b:get(x, y) then return false, x, y end
        end
    end
    return true
end

local function fieldSum(f)
    local w, h = f:size()
    local s = 0
    for y = 0, h - 1 do
        for x = 0, w - 1 do s = s + f:get(x, y) end
    end
    return s
end

local function dist(p, q)
    return math.sqrt((p[1] - q[1]) ^ 2 + (p[2] - q[2]) ^ 2)
end

print("Reaction-diffusion")

local a0 = gen.field(12, 10, 0.5)
local b0 = gen.field(12, 10, 0.25)
local b, a = gen.reactionDiffusion{a = a0, b = b0, steps = 30, seed = 1}
local lo, hi = b:minMax()
check("uniform B stays uniform", lo == hi, string.format("B spans %g..%g", lo, hi))
lo, hi = a:minMax()
check("uniform A stays uniform", lo == hi, string.format("A spans %g..%g", lo, hi))

local one = gen.reactionDiffusion{w = 40, h = 40, preset = "mitosis", steps = 200, seed = 9}
local two = gen.reactionDiffusion{w = 40, h = 40, preset = "mitosis", steps = 200, seed = 9}
check("same seed, same field", fieldsEqual(one, two))

local whole = gen.reactionDiffusion{w = 32, h = 32, steps = 80, seed = 4}
local halfB, halfA = gen.reactionDiffusion{w = 32, h = 32, steps = 40, seed = 4}
local resumed = gen.reactionDiffusion{a = halfA, b = halfB, steps = 40}
check("40 + 40 steps equals 80 steps", fieldsEqual(whole, resumed))

print("\nPhysarum")

local trail, agents = gen.physarum{w = 30, h = 20, agents = 64, steps = 9, deposit = 2, decay = 0, diffuse = 0, seed = 3}
local cols, rows = agents:size()
check("agents field is 3 x count", cols == 3 and rows == 64, string.format("%d x %d", cols, rows))
local sum = fieldSum(trail)
check("deposits add up with no decay", sum == 64 * 9 * 2, string.format("sum %g", sum))

local lonely = gen.physarum{w = 30, h = 20, agents = 64, steps = 5, deposit = 1, decay = 0, seed = 3}
local more = gen.physarum{trail = lonely, agents = 64, steps = 5, deposit = 1, decay = 0, seed = 3}
check("diffusion conserves a resumed trail", math.abs(fieldSum(more) - 64 * 10) < 1e-3,
    string.format("sum %g", fieldSum(more)))

print("\nDLA")

local r = 1.5
local segs, pts = gen.dla{n = 400, radius = r, seeds = {{0, 0}}, seed = 2}
check("one segment per particle", #segs == 400, tostring(#segs))
check("points include the seed", #pts == 401, tostring(#pts))
local touching, ordered, deep = true, true, true
for i, s in ipairs(segs) do
    if math.abs(dist(s[1], s[2]) - 2 * r) > 1e-9 then touching = false end
    if s.order ~= i then ordered = false end
    if s.depth < 1 or s.weight < 1 then deep = false end
end
check("every segment joins touching particles", touching)
check("order counts arrivals", ordered)
check("depth and weight are positive", deep)
local again = gen.dla{n = 400, radius = r, seeds = {{0, 0}}, seed = 2}
check("same seed, same cluster", again[400][2][1] == segs[400][2][1] and again[400][2][2] == segs[400][2][2])

local floor = gen.dla{n = 150, radius = 1, seeds = gen.line({0, 60}, {80, 60}),
    bounds = gen.rect(0, 0, 80, 60), bias = {0, 0.3}, seed = 6}
local inside = true
for _, s in ipairs(floor) do
    if s[2][2] > 62 or s[2][2] < -2 then inside = false end
end
check("line seeds and bounds hold the cluster", #floor == 150 and inside)

print("\nDifferential growth")

local loop = {}
for i = 1, 16 do
    local t = (i - 1) / 16 * 2 * math.pi
    loop[i] = {50 + 8 * math.cos(t), 50 + 8 * math.sin(t)}
end
local maxEdge = 2
local grown = gen.differentialGrowth{points = loop, steps = 60, maxEdge = maxEdge, repelRadius = 6, seed = 5}
local longest = dist(grown[#grown], grown[1])
for i = 1, #grown - 1 do longest = math.max(longest, dist(grown[i], grown[i + 1])) end
check("the loop grew", #grown > 60, tostring(#grown))
check("no edge longer than maxEdge", longest <= maxEdge + 1e-9, string.format("longest %g", longest))

local box = gen.rect(40, 40, 20, 20)
local boxed = gen.differentialGrowth{points = loop, steps = 150, maxEdge = 2, repelRadius = 6, bounds = box, seed = 5}
local held = true
for _, p in ipairs(boxed) do
    if p[1] < 40 or p[1] > 60 or p[2] < 40 or p[2] > 60 then held = false end
end
check("bounds hold every node", held)
local twice = gen.differentialGrowth{points = loop, steps = 60, maxEdge = maxEdge, repelRadius = 6, seed = 5}
check("same seed, same line", #twice == #grown and twice[#twice][1] == grown[#grown][1])

print("\nRender")

-- Agents start on a ring of radius 0.35 * 60 = 21 around the center,
-- facing inward. After three unit steps the trail is a ring about 18
-- cells out and the middle has never been touched.
local ring = gen.physarum{w = 60, h = 60, agents = 6000, steps = 3, spawn = "ring", decay = 0, diffuse = 0, seed = 8}
local c = gen.canvas(60, 60)
gen.background(c, {1, 1, 1})
gen.draw(c, gen.image(ring, 0, 0, 60, 60, {palette = {{0, 0, 0}, {1, 1, 1}}, range = {0, 1}, smooth = false}))
os.execute("mkdir -p out/test")
gen.exportPpm(c, "out/test/test-sim.ppm")
local pixels = T.readPpm("out/test/test-sim.ppm")
check("center of the ring is dark", T.gray(pixels, 30, 30) == 0, tostring(T.gray(pixels, 30, 30)))
check("the ring is lit", T.gray(pixels, 30 + 18, 30) == 255 and T.gray(pixels, 30, 30 - 18) == 255,
    string.format("%d %d", T.gray(pixels, 48, 30), T.gray(pixels, 30, 12)))

local full = gen.canvas(60, 60)
gen.background(full, {1, 0, 0})
gen.draw(full, gen.image(ring, 0, 0, 60, 60, {palette = {{0, 0, 1}, {0, 0, 1}}}))
gen.exportPpm(full, "out/test/test-sim-full.ppm")
local fp = T.readPpm("out/test/test-sim-full.ppm")
local function blue(x, y)
    local r, g, b = T.rgb(fp, x, y)
    return r == 0 and g == 0 and b == 255
end
check("full-canvas image covers the first pixel", blue(0, 0), string.format("%d %d %d", T.rgb(fp, 0, 0)))
check("full-canvas image covers the last pixel", blue(59, 59), string.format("%d %d %d", T.rgb(fp, 59, 59)))

T.summary()
