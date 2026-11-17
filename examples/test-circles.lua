-- test-circles.lua — Minimal test scene for circle anti-aliasing
-- Black circles on white background at known positions/radii.
-- Used by test/test-circles.lua to verify AA pixel values.
-- Centers sit on half units, the centers of pixels, so the circle at
-- (50.5, 50.5) is centered on pixel (50, 50) and its cardinal edges cut
-- pixels in half.

local gen = require("genpuin")

local W, H = 200, 200
local c = gen.canvas(W, H)
gen.background(c, {1, 1, 1})

local black = {0, 0, 0}

-- Filled circle, r=30, centered on pixel (50, 50)
gen.draw(c, gen.circle({50.5, 50.5}, 30), { fill = black })

-- Stroked circle, r=30, strokeWidth=1, centered on pixel (140, 50)
gen.draw(c, gen.circle({140.5, 50.5}, 30), {
    stroke = black, strokeWidth = 1.0,
})

-- Small filled circle, r=5, centered on pixel (50, 140)
gen.draw(c, gen.circle({50.5, 140.5}, 5), { fill = black })

-- Small stroked circle, r=5, strokeWidth=0.5, centered on pixel (140, 140)
gen.draw(c, gen.circle({140.5, 140.5}, 5), {
    stroke = black, strokeWidth = 0.5,
})

return c
