-- ca-traces.lua — Elementary CA as vector field
-- Complexity from simple rules: Rule 30 output steers hundreds of walkers.
-- The CA's chaotic-but-structured grid creates corridors and boundaries
-- that the trace lines reveal as they flow across the canvas.
-- Traces taper, shift hue, and fade as they travel. Bright nodes mark
-- points where the CA forces a sharp direction reversal.

local gen = require("genpuin")

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#0e0e12"))
gen.seed(7)

-- Generate a Rule 30 CA sized to the canvas
local caWidth = W
local caSteps = H
local rows = gen.elementary(30, caWidth, caSteps)

-- Steering parameters
local baseAngle = 0
local turnAmount = 0.35
local stepSize = 2.5
local maxSteps = 800

-- Collect nodes (direction reversals) to draw on top of traces
local nodes = {}

-- Spawn walkers spread across the left edge
local nWalkers = 350
for i = 0, nWalkers - 1 do
    local startY = (i + 0.5) * (H / nWalkers)
    local x, y = -30, startY
    local heading = baseAngle

    -- Base color by starting position
    local baseHue = gen.lerp(0.52, 0.72, i / nWalkers)

    local prevTurn = 0  -- track previous turn direction for reversal detection

    for step = 1, maxSteps do
        -- Read CA cell at current position
        local col = math.max(1, math.min(caWidth, math.floor(x) + 1))
        local row = math.max(1, math.min(#rows, math.floor(y) + 1))
        local cell = rows[row][col]

        -- Steer
        local turn = cell == 1 and 1 or -1
        heading = heading + turn * turnAmount

        local nx = x + math.cos(heading) * stepSize
        local ny = y + math.sin(heading) * stepSize

        if nx > W or ny < 0 or ny > H then break end

        -- Properties evolve along the trace
        local t = step / maxSteps
        local hue = (baseHue + t * 0.12) % 1
        local width = gen.lerp(1.2, 0.15, t)
        local opacity = gen.lerp(0.6, 0.08, t * t)

        -- Only draw once on canvas
        if nx >= 0 then
            gen.draw(c, gen.line({math.max(0, x), y}, {nx, ny}), {
                stroke = gen.hsv(hue, 0.5, gen.lerp(0.65, 0.35, t)),
                strokeWidth = width,
                strokeLinecap = "round",
                opacity = opacity,
            })
        end

        -- Detect direction reversal (CA forced a flip)
        if prevTurn ~= 0 and turn ~= prevTurn and step > 5 then
            nodes[#nodes + 1] = {
                pos = {nx, ny},
                t = t,
                hue = hue,
            }
        end
        prevTurn = turn

        x, y = nx, ny
    end
end

-- Draw reversal nodes on top — small bright dots at turbulence points
for _, n in ipairs(nodes) do
    if gen.rand() < 0.08 then  -- sparse: only ~8% of reversals
        local r = gen.lerp(1.0, 0.3, n.t)
        gen.draw(c, gen.circle(n.pos, r), {
            fill = gen.hsv(n.hue, 0.3, 0.9),
            opacity = gen.lerp(0.5, 0.1, n.t),
        })
    end
end

return c
