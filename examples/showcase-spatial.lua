-- showcase-spatial.lua — Voronoi, packing, spatial queries
-- Demonstrates: voronoi, relax (Lloyd), packCircles, separate,
-- pointInPolygon, nearest, withinRadius, radialGradient,
-- lerpColor, lighten, withAlpha

local gen = require("genpuin")

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#0d1117"))
gen.seed(21)

-- === Top: Relaxed Voronoi with spatial queries ===

local palette = {
    gen.hex("#e6194b"), gen.hex("#3cb44b"), gen.hex("#ffe119"),
    gen.hex("#4363d8"), gen.hex("#f58231"), gen.hex("#911eb4"),
    gen.hex("#42d4f4"), gen.hex("#f032e6"), gen.hex("#bfef45"),
    gen.hex("#fabed4"),
}

local sites = {}
for i = 1, 40 do
    sites[i] = {20 + gen.rand() * (W - 40), 20 + gen.rand() * 350}
end
local vBounds = {10, 10, W - 20, 370}
local relaxed = gen.relax(sites, vBounds, 10)
local cells = gen.voronoi(relaxed, vBounds)
for i, v in ipairs(cells) do
    local clr = palette[(i - 1) % #palette + 1]
    gen.draw(c, v.cell, {
        fill = gen.withAlpha(clr, 0.35),
        stroke = gen.hex("#555555"), strokeWidth = 1,
    })
end
for _, s in ipairs(relaxed) do
    gen.draw(c, gen.circle(s, 2.5), {fill = gen.hex("#ffffff")})
end

-- Nearest + withinRadius overlay
local probe = {W / 2, 190}
local near = gen.nearest(probe, relaxed)
if near then
    gen.draw(c, gen.circle(near.point, 8), {
        stroke = gen.hex("#ff4444"), strokeWidth = 2,
    })
    gen.draw(c, gen.line(probe, near.point), {
        stroke = gen.hex("#ff4444"), strokeWidth = 1,
    })
end
local nearby = gen.withinRadius(probe, relaxed, 120)
for _, r in ipairs(nearby) do
    gen.draw(c, gen.circle(r.point, 6), {
        stroke = gen.hex("#ff8800"), strokeWidth = 1,
    })
end
gen.draw(c, gen.circle(probe, 120), {
    stroke = gen.withAlpha(gen.hex("#ff8800"), 0.3), strokeWidth = 1,
})

-- === Bottom-left: Circle packing with gradient highlights ===

local packed = gen.packCircles({
    bounds = {10, 420, 370, 360},
    count = 60,
    minRadius = 8,
    maxRadius = 30,
    padding = 3,
})
local packCenter = {195, 600}
for _, circ in ipairs(packed) do
    local d = gen.dist(circ.center, packCenter) / 200
    d = gen.clamp(d, 0, 1)
    local base = gen.lerpColor(gen.hex("#58a6ff"), gen.hex("#f778ba"), d)
    local bright = gen.lighten(base, 0.3)
    local rg = gen.radialGradient(
        circ.center[1], circ.center[2], circ.r,
        {{0, gen.withAlpha(bright, 0.9)}, {1, gen.withAlpha(base, 0.5)}}
    )
    gen.draw(c, circ, {fill = rg, stroke = base, strokeWidth = 1})
end

-- === Bottom-right: Separation + point-in-polygon ===

local testPoly = gen.polygon({
    {500, 440}, {420, 600}, {460, 770}, {620, 770}, {700, 620}, {660, 460},
})
gen.draw(c, testPoly, {stroke = gen.hex("#666666"), strokeWidth = 1})

-- Separated circles inside polygon
local overlapping = {}
for i = 1, 24 do
    overlapping[i] = gen.circle(
        {500 + gen.rand() * 140, 520 + gen.rand() * 180}, 14
    )
end
gen.separate(overlapping, {iterations = 100, padding = 3, bounds = {410, 420, 370, 370}})
for _, circ in ipairs(overlapping) do
    local inside = gen.pointInPolygon(circ.center, testPoly)
    local clr = inside and gen.hex("#e6194b") or gen.hex("#444444")
    gen.draw(c, circ, {
        fill = gen.withAlpha(clr, 0.3),
        stroke = clr, strokeWidth = 1,
    })
end

-- Scattered point-in-polygon test
for _ = 1, 200 do
    local pt = {410 + gen.rand() * 310, 430 + gen.rand() * 350}
    local inside = gen.pointInPolygon(pt, testPoly)
    if inside then
        gen.draw(c, gen.circle(pt, 1), {fill = gen.hex("#3cb44b"), opacity = 0.4})
    end
end

return c
