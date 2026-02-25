-- organic.lua — fx module demo: jitter, smooth, taper, stipple
-- Shows organic, hand-drawn-style effects on geometric shapes

local gen = require("genpuin")

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#faf3e8"))
gen.seed(42)

-- 1. Stippled polygon — a large triangle filled with dots
local tri = gen.polygon({
    {200, 600}, {400, 200}, {600, 600},
})
local dots = gen.stipple(tri, 0.08)
for _, d in ipairs(dots) do
    gen.draw(c, gen.circle(d, 1.2), {
        fill = gen.rgba(60/255, 40/255, 30/255, 0.6),
    })
end

-- 2. Jittered + smoothed polyline — wobbly organic curve
local pts = {}
for i = 0, 20 do
    table.insert(pts, {100 + i * 30, 400 + 80 * math.sin(i * 0.4)})
end
local curve = gen.polyline(pts)
local wobbly = gen.smooth(gen.jitter(curve, 8), 3)
gen.draw(c, wobbly, {
    stroke = gen.hex("#2a5c3f"),
    strokeWidth = 2,
    fill = "none",
    strokeLinecap = "round",
})

-- 3. Tapered stroke — thick to thin brush stroke
local brushPts = {}
for i = 0, 30 do
    local t = i / 30
    table.insert(brushPts, {
        100 + t * 600,
        150 + 40 * math.sin(t * math.pi * 2),
    })
end
local brushPath = gen.polyline(brushPts)
local segments = gen.taper(brushPath, 8, 0.5, 40)
for _, seg in ipairs(segments) do
    gen.draw(c, seg.shape, {
        stroke = gen.hex("#8b4513"),
        strokeWidth = seg.width,
        fill = "none",
        strokeLinecap = "round",
    })
end

-- 4. Subdivided polygon — smooth organic blob
local hex = {}
for i = 0, 5 do
    local angle = (i / 6) * 2 * math.pi
    local r = 80 + gen.randRange(-15, 15)
    table.insert(hex, {550 + r * math.cos(angle), 300 + r * math.sin(angle)})
end
local blob = gen.smooth(gen.subdivide(gen.polygon(hex), 2), 3)
gen.draw(c, blob, {
    stroke = gen.hex("#4a6fa5"),
    strokeWidth = 2,
    fill = gen.rgba(74/255, 111/255, 165/255, 0.15),
})

gen.exportSvg(c, "out/organic.svg")
print("Wrote out/organic.svg")
