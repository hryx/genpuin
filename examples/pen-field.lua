-- pen-field.lua — pen driven by flow field
-- Multiple pens steer through a noise field, changing color along the way

local gen = require("genpuin")

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#0a0a1a"))
gen.seed(42)
gen.noiseSeed(42)

local f = gen.noiseField(0.004)

for i = 1, 80 do
    local x = gen.randRange(50, W - 50)
    local y = gen.randRange(50, H - 50)
    local baseHue = gen.rand()

    local p = gen.pen(c)
    p:moveTo({x, y})
    p:set("width", gen.randRange(0.5, 2.0))

    for step = 0, 120 do
        local pos = p:pos()
        -- steer toward the field angle
        local fieldAngle = f.sample(pos[1], pos[2])
        p:set("color", gen.hsv((baseHue + step / 400) % 1, 0.6, 0.9))
        p:heading(fieldAngle)
        p:forward(2.5)

        -- stop if out of bounds
        local np = p:pos()
        if np[1] < 0 or np[1] > W or np[2] < 0 or np[2] > H then
            break
        end
    end
    p:stroke()
end

return c
