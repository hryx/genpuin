-- Minimal test scene for overlapping transparent shapes
-- Tests alpha compositing between shapes (Venn diagram style).
-- Used by test/test-blend.lua to verify color buildup in overlap regions.

local W, H = 200, 200
gen.canvas(W, H)
gen.background({1, 1, 1})

-- Two overlapping black circles, opacity 0.5
-- Circle A: center (60, 60), r=40
-- Circle B: center (100, 60), r=40
-- Overlap region centered around x=80
gen.draw(gen.circle({60, 60}, 40), { fill = {0, 0, 0}, opacity = 0.5 })
gen.draw(gen.circle({100, 60}, 40), { fill = {0, 0, 0}, opacity = 0.5 })

-- Two overlapping colored circles, opacity 0.5
-- Red circle: center (60, 150), r=35
-- Blue circle: center (100, 150), r=35
gen.draw(gen.circle({60, 150}, 35), { fill = {1, 0, 0}, opacity = 0.5 })
gen.draw(gen.circle({100, 150}, 35), { fill = {0, 0, 1}, opacity = 0.5 })
