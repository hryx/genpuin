-- A dry rock garden seen from above, gravel raked in rings around mossy
-- stone islands. Shows gen.sdPolygon, gen.sdTranslate and gen.stipple.

gen.seed(5)
gen.noiseSeed(5)
local W, H = 800, 800
gen.canvas(W, H)
gen.background(gen.hex("#d6d4cb"))

local groups = {
    {{235, 220}, 3, 1.0},
    {{575, 300}, 2, 0.8},
    {{310, 585}, 4, 1.15},
    {{650, 650}, 1, 0.6},
}
local function rock(c, r)
    local pts, n, tilt = {}, gen.randInt(5, 8), gen.randRange(0, math.pi)
    for i = 1, n do
        local a = (i + gen.randRange(-0.3, 0.3)) / n * 2 * math.pi
        local k = r * gen.randRange(0.7, 1.1)
        local q = {math.cos(a) * k * 1.4, math.sin(a) * k * 0.8}
        q = gen.vec2Rotate(q, tilt)
        pts[i] = {c[1] + q[1], c[2] + q[2]}
    end
    return pts
end

local rocks, islands
for _, g in ipairs(groups) do
    local c, n, size = g[1], g[2], g[3]
    local cluster, island
    local heading = gen.randRange(0, 2 * math.pi)
    for i = 1, n do
        local a = heading + gen.gaussian(0, 0.6)
        local step = (i - (n + 1) / 2) * 62 * size
        local p = {c[1] + math.cos(a) * step, c[2] + math.sin(a) * step}
        local r = gen.randRange(22, 34) * size
        local s = gen.sdRound(gen.sdPolygon(rock(p, r)), 5)
        cluster = cluster and gen.sdSmoothUnion(cluster, s, 4) or s
        local pad = gen.sdCircle({p[1] + gen.gaussian(0, 20), p[2] + gen.gaussian(0, 20)}, r * 1.5)
        island = island and gen.sdSmoothUnion(island, pad, 40) or pad
    end
    island = gen.sdSmoothUnion(island, gen.sdRound(cluster, 16), 30)
    rocks = rocks and gen.sdUnion(rocks, cluster) or cluster
    islands = islands and gen.sdUnion(islands, island) or island
end

local rect = {0, 0, W, H}
local function field(node) return gen.sdfField(node, {rect = rect, cols = W, rows = H}) end
local function fill(f, level, color, opacity)
    for _, l in ipairs(gen.contours(f, level, {rect = rect, simplify = 0.3})) do
        gen.draw(l, {fill = color, opacity = opacity})
    end
end

local pitch, rings = 10, 6
local d = field(islands)
local sand = d:clone()
sand:map(function(v, x, y)
    local wobble = 5 * gen.perlin(x * 0.006, y * 0.006)
    local phase = v < pitch * rings and v or y + 0.5 + wobble
    return math.cos(phase / pitch * 2 * math.pi)
end)
gen.draw(gen.image(sand, 0, 0, W, H, {palette = {
    gen.hex("#9c9a92"), gen.hex("#cfccc2"), gen.hex("#ecebe4"),
}}))

local mossDots = {gen.hex("#3d4b22"), gen.hex("#7a8f45"), gen.hex("#8d9b55")}
fill(d, 0, gen.hex("#4e5f2e"))
fill(d, -6, gen.hex("#617536"))
for _, l in ipairs(gen.contours(d, -2, {rect = rect})) do
    for _, p in ipairs(gen.stipple(l, 0.08)) do
        gen.draw(gen.circle(p, gen.randRange(0.8, 2.2)), {fill = gen.pick(mossDots)})
    end
end
fill(field(gen.sdTranslate(rocks, {7, 9})), 0, gen.hex("#1d2618"), 0.6)

local stone = field(rocks)
local lit = field(gen.sdTranslate(gen.sdRound(rocks, -5), {-4, -5}))
lit:combine("max", stone)
fill(stone, 0, gen.hex("#33373d"))
fill(lit, 0, gen.hex("#4f545b"))
fill(lit, -6, gen.hex("#686d73"))
fill(lit, -14, gen.hex("#83878b"))
gen.post.grain({amount = 0.06})
