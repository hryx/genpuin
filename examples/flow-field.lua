-- flow-field.lua — noise-driven flow field with pen trails
-- Streamlines traced through a Perlin noise field

local gen = require("genpuin")

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#0a0a1a"))
gen.seed(42)
gen.noiseSeed(42)

local f = gen.noiseField(0.005)

for i = 1, 200 do
    local x = gen.randRange(0, W)
    local y = gen.randRange(0, H)
    local trail = gen.trace(f, {x, y}, 80, 2)

    local hue = gen.perlin(x * 0.003, y * 0.003) * 0.5 + 0.5
    gen.draw(c, trail, {
        stroke = gen.hsv(hue, 0.6, 0.9),
        strokeWidth = 0.8,
        opacity = 0.5,
        strokeLinecap = "round",
    })
end

return c
