-- Minimal test scene for filled shape anti-aliasing
-- Black filled shapes on white background at known positions.
-- Used by test/test-fills.lua to verify AA on polygon/ellipse/rect edges.

local W, H = 200, 200
local c = gen.canvas(W, H)
gen.background(c, {1, 1, 1})

local black = {0, 0, 0}

-- 45-degree rotated square (as polygon), center at (50, 50), side ~42px
-- Vertices at cardinal directions, 30px from center
gen.draw(c, gen.polygon({
    {50, 20},   -- top
    {80, 50},   -- right
    {50, 80},   -- bottom
    {20, 50},   -- left
}), { fill = black })

-- Equilateral triangle, center near (150, 50)
-- Base at bottom, pointing up
gen.draw(c, gen.polygon({
    {150, 20},   -- top vertex
    {120, 70},   -- bottom-left
    {180, 70},   -- bottom-right
}), { fill = black })

-- Filled ellipse, center at (50, 140), rx=35, ry=20
gen.draw(c, gen.ellipse({50, 140}, 35, 20), { fill = black })

return c
