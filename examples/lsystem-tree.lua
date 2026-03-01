-- lsystem-tree.lua — Stochastic L-system branching tree
-- Demonstrates: gen.rewrite with stochastic rules, Pen turtle graphics

local gen = require("genpuin")

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#0a0e14"))
gen.seed(77)

-- Stochastic branching plant
-- F = draw forward, + = turn left, - = turn right, [ = push, ] = pop
local axiom = "F"
local rules = {
    F = {
        {"FF-[-F+F+F]+[+F-F-F]", 0.4},
        {"FF+[+F-F]-[-F+F+F]",   0.3},
        {"F[-F][+F]F",            0.2},
    },
}
local str = gen.rewrite(axiom, rules, 4)

-- Draw the tree using turtle graphics
local p = gen.pen(c)
local startX, startY = W / 2, H - 60
p:moveTo({startX, startY})
p:heading(-math.pi / 2)  -- point upward

local stack = {}
local stepLen = 11
local turnAngle = math.rad(22)
local depth = 0

for ch in str:gmatch(".") do
    if ch == "F" then
        -- Color fades from brown trunk to green tips
        local t = depth / 8
        local hue = gen.lerp(0.08, 0.3, math.min(t, 1))
        local sat = gen.lerp(0.4, 0.7, math.min(t, 1))
        local val = gen.lerp(0.35, 0.55, math.min(t, 1))
        p:set("color", gen.hsv(hue, sat, val))
        p:set("width", math.max(0.5, 6 - depth * 0.6))
        p:forward(stepLen * gen.randRange(0.7, 1.3))
    elseif ch == "+" then
        p:turn(turnAngle + gen.randRange(-0.05, 0.05))
    elseif ch == "-" then
        p:turn(-turnAngle + gen.randRange(-0.05, 0.05))
    elseif ch == "[" then
        p:stroke()
        depth = depth + 1
        table.insert(stack, {p.x, p.y, p:heading(), depth})
    elseif ch == "]" then
        p:stroke()
        local s = table.remove(stack)
        if s then
            p:moveTo({s[1], s[2]})
            p:heading(s[3])
            depth = s[4] - 1
        end
    end
end
p:stroke()

-- Scatter small leaf dots at branch tips
gen.seed(77)
local tipStr = gen.rewrite(axiom, rules, 4)
p:moveTo({startX, startY})
p:heading(-math.pi / 2)
local tipStack = {}
local tipDepth = 0

for ch in tipStr:gmatch(".") do
    if ch == "F" then
        p:forward(stepLen * gen.randRange(0.7, 1.3))
        if tipDepth >= 5 and gen.rand() < 0.3 then
            local r = gen.randRange(3, 8)
            local hue = gen.randRange(0.25, 0.42)
            gen.draw(c, gen.circle(p:pos(), r), {
                fill = gen.hsv(hue, 0.6, 0.5),
                opacity = gen.randRange(0.3, 0.7),
            })
        end
    elseif ch == "+" then
        p:turn(turnAngle + gen.randRange(-0.05, 0.05))
    elseif ch == "-" then
        p:turn(-turnAngle + gen.randRange(-0.05, 0.05))
    elseif ch == "[" then
        p:lift()
        tipDepth = tipDepth + 1
        table.insert(tipStack, {p.x, p.y, p:heading(), tipDepth})
    elseif ch == "]" then
        p:lift()
        local s = table.remove(tipStack)
        if s then
            p:moveTo({s[1], s[2]})
            p:heading(s[3])
            tipDepth = s[4] - 1
        end
    end
end

return c
