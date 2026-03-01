-- lsystem-field.lua — L-system grid interference
-- Complexity from simple rules: one L-system rule + Perlin-varied orientation.
-- 1600 tiny fractal glyphs tiled across the canvas. Overlapping at low opacity
-- creates emergent density, moiré, and texture from pure repetition.

local gen = require("genpuin")

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#f4f1eb"))
gen.seed(53)
gen.noiseSeed(53)

-- One simple rule, 3 iterations: a small Koch-ish zigzag
local str = gen.rewrite("F", {F = "F+F-F-F+F"}, 3)

-- Dense grid of instances
local cols, rows = 45, 45
local cellW = W / cols
local cellH = H / rows

for row = 0, rows - 1 do
    for col = 0, cols - 1 do
        local cx = (col + 0.5) * cellW
        local cy = (row + 0.5) * cellH

        -- Starting angle from Perlin noise at this position
        local n = gen.perlin(cx * 0.006, cy * 0.006)
        local startAngle = n * math.pi * 2

        -- Lightness also from noise (different frequency)
        local n2 = gen.perlin(cx * 0.01 + 100, cy * 0.01 + 100)
        local val = gen.lerp(0.15, 0.5, (n2 + 1) * 0.5)

        -- Per-stamp shape variation: turn angle and step length from noise
        local n3 = gen.perlin(cx * 0.008 + 200, cy * 0.008 + 200)
        local turnAngle = math.rad(gen.lerp(60, 120, (n3 + 1) * 0.5))
        local n4 = gen.perlin(cx * 0.012 - 50, cy * 0.012 - 50)
        local stepLen = gen.lerp(3.0, 5.5, (n4 + 1) * 0.5)

        local p = gen.pen(c)
        p:moveTo({cx, cy})
        p:heading(startAngle)
        p:set("color", gen.hsv(0.6, 0.35, val))
        p:set("width", 0.4)

        for ch in str:gmatch(".") do
            if ch == "F" then
                p:forward(stepLen)
            elseif ch == "+" then
                p:turn(turnAngle)
            elseif ch == "-" then
                p:turn(-turnAngle)
            end
        end
        p:stroke()
    end
end

return c
