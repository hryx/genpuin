-- A random fractal flame, different for every --seed. Shows
-- gen.randomFlame, gen.flame and gen.image.

local W, H = 800, 800
gen.canvas(W, H)
gen.background({0, 0, 0})
gen.seed(3)

local opts = gen.randomFlame(nil, 3)
opts.n = 6e6
opts.w, opts.h = W, H
opts.supersample = 2
local density, hue = gen.flame(opts)

local palette = {
    gen.hex("#2b59c3"),
    gen.hex("#7b3fd1"),
    gen.hex("#e0457b"),
    gen.hex("#ff9e3d"),
    gen.hex("#ffe8a8"),
}
-- Brightness stops follow t^0.45, a display gamma on top of the log tone.
local light = {}
for i = 0, 8 do
    local t = i / 8
    local v = t ^ 0.45
    light[#light + 1] = {t, {v, v, v}}
end

gen.draw(gen.image(hue, 0, 0, W, H, {palette = palette, range = {0, 1}}))
gen.draw(gen.image(density, 0, 0, W, H, {palette = light, tone = "log", toneK = 500}), {blendMode = "multiply"})
