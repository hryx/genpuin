-- A riverbed of pebbles in dark mortar, cold stones midstream and warm ones on the banks.
-- Shows gen.packCircles, gen.relax and gen.voronoi.

local W, H = 800, 800
gen.seed(11)
gen.noiseSeed(11)

local c = gen.canvas(W, H)
local mortar = gen.hex("#16181c")
gen.background(c, mortar)

local bounds = {0, 0, W, H}
local circles = gen.packCircles{
    bounds = {-20, -20, W + 40, H + 40},
    count = 1200, minRadius = 6, maxRadius = 50, padding = 1,
}
local sites = {}
for i, circle in ipairs(circles) do
    sites[i] = circle.center
end
sites = gen.relax(sites, bounds, 2)

local bank = {gen.hex("#e6dccb"), gen.hex("#c8b394"), gen.hex("#a8714b"), gen.hex("#7a4a35")}
local stream = {gen.hex("#d9e2e4"), gen.hex("#8fa6b0"), gen.hex("#56707e"), gen.hex("#2e3f4c")}

local function riverDistance(x, y)
    local mid = W * 0.5 + math.sin(y * 0.008) * 150 + gen.fbm(y * 0.004, 3, 3) * 120
    return math.abs(x - mid) / 170
end

local function area(pts)
    local s = 0
    for i = 1, #pts do
        local a, b = pts[i], pts[i % #pts + 1]
        s = s + a[1] * b[2] - b[1] * a[2]
    end
    return math.abs(s) * 0.5
end

for _, v in ipairs(gen.voronoi(sites, bounds)) do
    local pts = v.cell.points
    local cx, cy = 0, 0
    for _, p in ipairs(pts) do
        cx, cy = cx + p[1] / #pts, cy + p[2] / #pts
    end
    local r = math.sqrt(area(pts) / math.pi)
    local k = math.max(0.2, 1 - 4 / r)
    local stone = gen.smooth(gen.scaleAround(v.cell, k, k, {cx, cy}), 3)

    local wet = gen.clamp(1.4 - riverDistance(cx, cy) + gen.gaussian(0, 0.25), 0, 1)
    local set = wet > 0.5 and stream or bank
    local tone = gen.clamp(gen.fbm(cx * 0.01, cy * 0.01, 3) * 0.6 + 0.5 + gen.gaussian(0, 0.22), 0, 0.999)
    local i = math.floor(tone * #set) + 1
    local base = gen.lerpColor(set[i], set[math.min(i + 1, #set)], gen.rand())
    gen.draw(c, stone, {fill = base})

    local shine = gen.translate(gen.scaleAround(stone, 0.55, 0.45, {cx, cy}), -r * 0.18, -r * 0.22)
    gen.draw(c, gen.smooth(shine, 2), {fill = gen.lighten(base, 0.12), opacity = 0.6})
end

return c
