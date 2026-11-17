-- A risograph-style print of overlapping arches and a moon, cut by inverted stripes.
-- Shows gen.linearGradient, gen.radialGradient and blendMode.

local W, H = 800, 800
gen.seed(4)
gen.noiseSeed(4)

gen.canvas(W, H)
gen.background(gen.hex("#f4ecdc"))

local paper = gen.linearGradient(0, 0, 0, H, {
    {0, gen.hex("#f6efe0")}, {1, gen.hex("#ecd6c8")},
})
gen.draw(gen.rect(0, 0, W, H), {fill = paper})

local function arch(x, top, w, bottom)
    local r = w / 2
    local pts = {{x - r, bottom}}
    for i = 0, 40 do
        local a = math.pi + math.pi * i / 40
        pts[#pts + 1] = {x + r * math.cos(a), top + r + r * math.sin(a)}
    end
    pts[#pts + 1] = {x + r, bottom}
    return gen.polygon(pts)
end

local inks = {
    {gen.hex("#ff3d8b"), gen.hex("#ffc2d9")},
    {gen.hex("#0097a7"), gen.hex("#a8e6e8")},
    {gen.hex("#ffbf1f"), gen.hex("#fff0b8")},
    {gen.hex("#3d4ed8"), gen.hex("#c3c9ff")},
}

local arches = {
    {x = 250, top = 230, w = 300, ink = 1},
    {x = 430, top = 150, w = 340, ink = 2},
    {x = 590, top = 300, w = 240, ink = 3},
    {x = 340, top = 420, w = 200, ink = 4},
}
for _, a in ipairs(arches) do
    local ink = inks[a.ink]
    local fill = gen.linearGradient(0, a.top, 0, 720, {{0, ink[1]}, {1, ink[2]}})
    gen.draw(arch(a.x, a.top, a.w, 720), {fill = fill, blendMode = "multiply"})
end

local pink = inks[1][1]
local moon = gen.radialGradient(560, 210, 150, {
    {0, pink}, {0.8, gen.withAlpha(pink, 0.85)}, {1, gen.withAlpha(pink, 0)},
})
gen.draw(gen.circle({560, 210}, 150), {fill = moon, blendMode = "multiply"})

for i = 0, 13 do
    local y = 470 + i * 18
    gen.draw(gen.rect(100, y, 610, 8), {fill = gen.hex("#f4ecdc"), blendMode = "difference"})
end

local glow = gen.radialGradient(W / 2, H / 2, 620, {
    {0.55, gen.withAlpha(gen.hex("#2a1a3a"), 0)}, {1, gen.withAlpha(gen.hex("#2a1a3a"), 0.3)},
})
gen.draw(gen.rect(0, 0, W, H), {fill = glow, blendMode = "multiply"})
