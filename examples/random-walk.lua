-- random-walk.lua — basic pen walk demo
-- Multiple pens take random walks from the center

local gen = require("genpuin")

local c = gen.canvas(800, 800)
gen.background(c, gen.hex("#0a0a1a"))
gen.seed(99)

for trail = 1, 12 do
    local p = gen.pen(c)
    p:moveTo({400, 400})
    p:set("width", 1.2)
    p:set("color", gen.hsv(trail / 12, 0.7, 0.9))

    for step = 1, 300 do
        p:turn(gen.randRange(-0.5, 0.5))
        p:forward(gen.randRange(2, 6))
    end
    p:stroke()
end

gen.exportSvg(c, "out/random-walk.svg")
print("Wrote out/random-walk.svg")
