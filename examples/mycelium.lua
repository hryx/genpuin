-- mycelium.lua — Mycelium Network
-- Poisson-seeded spore points sprout pen walkers that branch
-- through a noise field, with tapered strokes and junction nodes.

local gen = require("genpuin")

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#0c0c0f"))
gen.seed(42)
gen.noiseSeed(42)

local field = gen.noiseField(0.003)

-- Poisson disk spore points — the network origins
local spores = gen.poissonDisk({80, 80, W - 160, H - 160}, 120)

-- Collect all junction points for drawing nodes later
local junctions = {}

-- Grow a tendril from a starting point
local function growTendril(startX, startY, baseHue, maxSteps, width)
    local p = gen.pen(c)
    p:moveTo({startX, startY})
    p:set("width", width)
    p:set("color", gen.hsv(baseHue, 0.3, 0.65))

    local steps = gen.randInt(math.floor(maxSteps * 0.4), maxSteps)
    for step = 0, steps do
        local pos = p:pos()
        local px, py = pos[1], pos[2]

        -- stop if out of bounds
        if px < 10 or px > W - 10 or py < 10 or py > H - 10 then break end

        -- steer by noise field + slight random wobble
        local angle = field.sample(px, py)
        angle = angle + gen.randRange(-0.3, 0.3)
        p:heading(angle)
        p:forward(gen.randRange(1.5, 3.5))

        -- fade color along length
        local t = step / steps
        local hue = (baseHue + t * 0.08) % 1
        local brightness = gen.lerp(0.65, 0.25, t)
        p:set("color", gen.hsv(hue, 0.3, brightness))

        -- branch at random intervals
        if step > 10 and gen.rand() < 0.04 and width > 0.3 then
            p:stroke()
            junctions[#junctions + 1] = {px, py}
            -- recursive branch (thinner, shorter)
            local branchAngle = angle + gen.pick({-1, 1}) * gen.randRange(0.5, 1.2)
            local bx = px + math.cos(branchAngle) * 3
            local by = py + math.sin(branchAngle) * 3
            growTendril(bx, by, (baseHue + gen.randRange(-0.05, 0.05)) % 1,
                        math.floor(maxSteps * 0.5), width * 0.6)
            -- continue main tendril
            p:moveTo({px, py})
            p:set("width", width * 0.9)
            p:set("color", gen.hsv(hue, 0.3, brightness))
        end
    end
    p:stroke()
end

-- Grow tendrils from each spore
for i, spore in ipairs(spores) do
    junctions[#junctions + 1] = {spore[1], spore[2]}

    -- each spore sends out 2-4 tendrils in different directions
    local numTendrils = gen.randInt(2, 4)
    local baseHue = (0.75 + gen.perlin(spore[1] * 0.005, spore[2] * 0.005) * 0.15) % 1

    for t = 1, numTendrils do
        local angle = (t / numTendrils) * 2 * math.pi + gen.randRange(-0.4, 0.4)
        local sx = spore[1] + math.cos(angle) * 5
        local sy = spore[2] + math.sin(angle) * 5
        growTendril(sx, sy, baseHue, gen.randInt(60, 140), gen.randRange(0.8, 1.8))
    end
end

-- Draw junction nodes — small bright dots at branch points
for _, j in ipairs(junctions) do
    local hue = (0.75 + gen.perlin(j[1] * 0.005, j[2] * 0.005) * 0.15) % 1
    gen.draw(c, gen.circle(j, gen.randRange(1.0, 2.5)), {
        fill = gen.hsv(hue, 0.2, 0.8),
        opacity = 0.7,
    })
end

-- Draw spore bodies — slightly larger glowing centers
for _, spore in ipairs(spores) do
    local hue = (0.75 + gen.perlin(spore[1] * 0.005, spore[2] * 0.005) * 0.15) % 1
    -- outer glow
    gen.draw(c, gen.circle(spore, 6), {
        fill = gen.hsv(hue, 0.15, 0.5),
        opacity = 0.15,
    })
    -- inner body
    gen.draw(c, gen.circle(spore, 2.5), {
        fill = gen.hsv(hue, 0.25, 0.9),
        opacity = 0.8,
    })
end

return c
