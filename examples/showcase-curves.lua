-- showcase-curves.lua — Curves, gradients, blend modes, dashes
-- Demonstrates: bezier, spline, ellipse, arc, linear/radial gradients,
-- blend modes (multiply, screen, difference), dashed lines, pen + gradient,
-- vec2 math, rounded rects

local gen = require("genpuin")

local W, H = 800, 600
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#f0f0f0"))

-- === Row 1: Curve primitives ===

-- Ellipse with radial gradient fill
local eg = gen.radialGradient(100, 80, 70, {
    {0, gen.hex("#ffffff")},
    {1, gen.hex("#4488cc")},
})
gen.draw(c, gen.ellipse({100, 80}, 80, 45), {
    fill = eg, stroke = gen.hex("#224466"), strokeWidth = 2,
})

-- Rounded rectangle with linear gradient
local rrg = gen.linearGradient(220, 40, 380, 40, {
    {0, gen.hex("#ff9900")},
    {1, gen.hex("#cc0066")},
})
gen.draw(c, gen.rect(220, 40, 160, 80, 14), {fill = rrg})

-- Cubic bezier with sampled points
local p0, p1, p2, p3 = {420, 100}, {470, 20}, {560, 20}, {610, 100}
gen.draw(c, gen.bezier(p0, p1, p2, p3), {
    stroke = gen.hex("#228833"), strokeWidth = 3,
})
for i = 0, 6 do
    local t = i / 6
    local pt = gen.bezierPoint(p0, p1, p2, p3, t)
    gen.draw(c, gen.circle(pt, 3), {fill = gen.hex("#ff6600")})
end

-- Vector math arrow
local base = gen.vec2(700, 60)
local dir = gen.vec2FromAngle(math.rad(-30))
local tip = gen.vec2Add(base, gen.vec2Scale(dir, 50))
local perp = gen.vec2Rotate(dir, math.pi / 2)
local wing1 = gen.vec2Add(tip, gen.vec2Scale(gen.vec2Add(gen.vec2Scale(dir, -1), perp), 12))
local wing2 = gen.vec2Add(tip, gen.vec2Scale(gen.vec2Sub(gen.vec2Scale(dir, -1), perp), 12))
gen.draw(c, gen.line(base, tip), {stroke = gen.hex("#333333"), strokeWidth = 2})
gen.draw(c, gen.polygon({tip, wing1, wing2}), {fill = gen.hex("#333333")})

-- === Row 2: Splines, dashes, arc ===

-- Catmull-Rom spline
gen.draw(c, gen.spline({{30, 200}, {130, 160}, {230, 220}, {330, 170}, {430, 210}}), {
    stroke = gen.hex("#6644aa"), strokeWidth = 2.5,
})

-- Dashed polyline (SVG strokeDasharray)
gen.draw(c, gen.polyline({{30, 260}, {250, 260}, {250, 300}}), {
    stroke = gen.hex("#cc6600"), strokeWidth = 2, strokeDasharray = {10, 5},
})

-- Dashed circle via FX dash()
local dashes = gen.dash(gen.circle({380, 270}, 40), 10, 7)
for _, seg in ipairs(dashes) do
    gen.draw(c, seg, {stroke = gen.hex("#0066cc"), strokeWidth = 2.5})
end

-- Dashed spline
gen.draw(c, gen.spline({{480, 260}, {540, 230}, {600, 290}, {660, 250}, {720, 280}}), {
    stroke = gen.hex("#338855"), strokeWidth = 2, strokeDasharray = {6, 4},
})

-- Pen with dash
local dp = gen.pen(c)
dp:set("color", gen.hex("#aa0066"))
dp:set("width", 2)
dp:set("dash", {6, 4})
dp:moveTo({480, 200})
dp:forward(100):turn(math.rad(90)):forward(60)
dp:stroke()

-- === Row 3: Gradients ===

-- Linear gradient fill
local lg = gen.linearGradient(30, 380, 230, 380, {
    {0, gen.hex("#ff0000")},
    {0.5, gen.hex("#ffee00")},
    {1, gen.hex("#0000ff")},
})
gen.draw(c, gen.rect(30, 350, 200, 60), {fill = lg})

-- Radial gradient with 3 stops
local rg = gen.radialGradient(370, 380, 60, {
    {0, gen.hex("#ffee00")},
    {0.5, gen.hex("#33aa33")},
    {1, gen.hex("#003300")},
})
gen.draw(c, gen.circle({370, 380}, 60), {fill = rg})

-- Gradient stroke on polyline
local sg = gen.linearGradient(470, 370, 750, 370, {
    {0, gen.hex("#ff6600")},
    {1, gen.hex("#6600ff")},
})
gen.draw(c, gen.polyline({{470, 370}, {540, 340}, {630, 400}, {750, 360}}), {
    stroke = sg, strokeWidth = 4,
})

-- === Row 4: Blend modes + pen with gradient ===

-- Blend mode: multiply
gen.draw(c, gen.rect(30, 460, 100, 80), {fill = gen.hex("#ff0000")})
gen.draw(c, gen.rect(80, 480, 100, 80), {fill = gen.hex("#0000ff"), blendMode = "multiply"})

-- Blend mode: screen
gen.draw(c, gen.rect(220, 460, 100, 80), {fill = gen.hex("#003399")})
gen.draw(c, gen.rect(270, 480, 100, 80), {fill = gen.hex("#990033"), blendMode = "screen"})

-- Blend mode: difference
gen.draw(c, gen.rect(410, 460, 100, 80), {fill = gen.hex("#ffcc00")})
gen.draw(c, gen.rect(460, 480, 100, 80), {fill = gen.hex("#00ccff"), blendMode = "difference"})

-- Pen with gradient stroke
local pg = gen.linearGradient(600, 500, 780, 500, {
    {0, gen.hex("#00ccff")},
    {1, gen.hex("#ff00cc")},
})
local gp = gen.pen(c)
gp:set("color", pg)
gp:set("width", 4)
gp:moveTo({600, 500})
gp:forward(60):turn(math.rad(-50)):forward(70):turn(math.rad(50)):forward(60)
gp:stroke()

return c
