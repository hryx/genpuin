-- test-aa.lua — Minimal test scene for anti-aliasing verification
-- Black lines on white background at known positions/widths/angles.
-- Used by tests/test-aa.lua to programmatically verify AA pixel values.
-- Coordinates sit on half units, the centers of pixels, so a horizontal
-- line at y=50.5 is centered on pixel row 50.

local W, H = 200, 200
local c = gen.canvas(W, H)
gen.background(c, {1, 1, 1})

local black = {0, 0, 0}
local style03 = { stroke = black, strokeWidth = 0.3, strokeLinecap = "round" }
local style10 = { stroke = black, strokeWidth = 1.0, strokeLinecap = "round" }
local style25 = { stroke = black, strokeWidth = 2.5, strokeLinecap = "round" }

-- Horizontal lines (check vertical cross-section at x=100)
gen.draw(c, gen.line({20.5, 20.5}, {180.5, 20.5}), style03)   -- 0.3px, row 20
gen.draw(c, gen.line({20.5, 50.5}, {180.5, 50.5}), style10)   -- 1.0px, row 50
gen.draw(c, gen.line({20.5, 80.5}, {180.5, 80.5}), style25)   -- 2.5px, row 80

-- 45° diagonal lines (down-right)
gen.draw(c, gen.line({10.5, 110.5}, {70.5, 170.5}), style10)   -- 1.0px
gen.draw(c, gen.line({10.5, 155.5}, {55.5, 200.5}), style25)   -- 2.5px

-- ~66° steep line (nearly vertical)
gen.draw(c, gen.line({150.5, 110.5}, {170.5, 190.5}), style10) -- 1.0px

return c
