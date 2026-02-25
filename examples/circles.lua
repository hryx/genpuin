-- circles.lua — constructive mode demo
-- Concentric rings of circles with shifting hue

local gen = require("genpuin")

local c = gen.canvas(800, 800)
gen.background(c, gen.hex("#0a0a1a"))
gen.seed(7)

local cx, cy = 400, 400

for ring = 1, 8 do
    local r = ring * 45
    local n = ring * 6
    for i = 1, n do
        local angle = (i / n) * 2 * math.pi
        local x = cx + r * math.cos(angle)
        local y = cy + r * math.sin(angle)
        local hue = (ring / 8 + i / n * 0.3) % 1
        local size = gen.randRange(3, 10)
        gen.draw(c, gen.circle({x, y}, size), {
            fill = gen.hsv(hue, 0.6, 0.9),
            opacity = 0.7,
        })
    end
end

gen.exportSvg(c, "out/circles.svg")
print("Wrote out/circles.svg")
