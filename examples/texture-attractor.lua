-- A Clifford attractor as glowing embers, orbit points splatted into a
-- density field. Shows gen.attractor and gen.image with log tone.

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#070302"))
gen.seed(3)

local density = gen.attractor({
    kind = "clifford",
    a = -1.7, b = 1.3, c = -0.1, d = -1.21,
    n = 12e6,
    w = W, h = H,
    supersample = 2,
})

local hot = {
    {0.00, gen.hex("#070302")},
    {0.25, gen.hex("#3a0804")},
    {0.50, gen.hex("#a3200b")},
    {0.72, gen.hex("#f06a12")},
    {0.88, gen.hex("#ffc53d")},
    {1.00, gen.hex("#fff4c9")},
}

gen.draw(c, gen.image(density, 0, 0, W, H, {palette = hot, tone = "log", toneK = 400}))

return c
