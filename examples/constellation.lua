-- constellation.lua — both modes together
-- Scattered circles + pen walks between them

local gen = require("genpuin")

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#0a0a1a"))
gen.seed(42)

-- Constructive: scatter circles
local points = {}
for i = 0, 29 do
    local x = gen.randRange(50, W - 50)
    local y = gen.randRange(50, H - 50)
    local hue = i / 30
    local r = gen.randRange(5, 25)
    gen.draw(c, gen.circle({x, y}, r), {
        fill = gen.hsv(hue, 0.7, 0.9),
        opacity = 0.6,
    })
    table.insert(points, {x, y})
end

-- Procedural: pen walks with sine-based turning
local p = gen.pen(c)
p:moveTo({W / 2, H / 2})
p:set("width", 1.5)
for step = 0, 199 do
    local t = step / 200
    local angle = 0.15 * math.sin(step * 0.1)
    local hue = (t * 2) % 1
    p:set("color", gen.hsv(hue, 0.8, 0.95))
    p:turn(angle)
    p:forward(4)
end
p:stroke()

gen.exportSvg(c, "out/constellation.svg")
print("Wrote out/constellation.svg")
