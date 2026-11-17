-- A mycelium network: pen walkers sprout from Poisson spores and branch
-- through a noise field. Shows gen.pen, gen.noiseField and gen.poissonDisk.

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#0c0c0f"))
gen.seed(42)
gen.noiseSeed(42)

local field = gen.noiseField(0.003)

local spores = gen.poissonDisk({80, 80, W - 160, H - 160}, 120)

local junctions = {}

local function growTendril(startX, startY, baseHue, maxSteps, width)
    local p = gen.pen(c)
    p:moveTo({startX, startY})
    p:set("width", width)
    p:set("color", gen.hsv(baseHue, 0.3, 0.8))

    local steps = gen.randInt(math.floor(maxSteps * 0.4), maxSteps)
    for step = 0, steps do
        local pos = p:pos()
        local px, py = pos[1], pos[2]

        if px < 10 or px > W - 10 or py < 10 or py > H - 10 then break end

        local angle = field.sample(px, py)
        angle = angle + gen.randRange(-0.3, 0.3)
        p:heading(angle)
        p:forward(gen.randRange(2, 4))

        local t = step / steps
        local hue = gen.mod(baseHue + t * 0.08, 1)
        local brightness = gen.lerp(0.8, 0.35, t)
        p:set("color", gen.hsv(hue, 0.3, brightness))

        if step > 10 and gen.rand() < 0.04 and width > 0.3 then
            p:stroke()
            junctions[#junctions + 1] = {px, py}
            local branchAngle = angle + gen.pick({-1, 1}) * gen.randRange(0.5, 1.2)
            local bx = px + math.cos(branchAngle) * 3
            local by = py + math.sin(branchAngle) * 3
            growTendril(bx, by, gen.mod(baseHue + gen.randRange(-0.05, 0.05), 1),
                        math.floor(maxSteps * 0.5), width * 0.6)
            p:moveTo({px, py})
            p:set("width", width * 0.9)
            p:set("color", gen.hsv(hue, 0.3, brightness))
        end
    end
    p:stroke()
end

for i, spore in ipairs(spores) do
    junctions[#junctions + 1] = {spore[1], spore[2]}

    local numTendrils = gen.randInt(2, 4)
    local baseHue = gen.mod(0.75 + gen.perlin(spore[1] * 0.005, spore[2] * 0.005) * 0.15, 1)

    for t = 1, numTendrils do
        local angle = (t / numTendrils) * 2 * math.pi + gen.randRange(-0.4, 0.4)
        local sx = spore[1] + math.cos(angle) * 5
        local sy = spore[2] + math.sin(angle) * 5
        growTendril(sx, sy, baseHue, gen.randInt(90, 180), gen.randRange(1.2, 2.4))
    end
end

for _, j in ipairs(junctions) do
    local hue = gen.mod(0.75 + gen.perlin(j[1] * 0.005, j[2] * 0.005) * 0.15, 1)
    gen.draw(c, gen.circle(j, gen.randRange(1.0, 2.5)), {
        fill = gen.hsv(hue, 0.2, 0.9),
        opacity = 0.8,
    })
end

for _, spore in ipairs(spores) do
    local hue = gen.mod(0.75 + gen.perlin(spore[1] * 0.005, spore[2] * 0.005) * 0.15, 1)
    gen.draw(c, gen.circle(spore, 6), {
        fill = gen.hsv(hue, 0.15, 0.85),
        opacity = 0.2,
    })
    gen.draw(c, gen.circle(spore, 2.5), {
        fill = gen.hsv(hue, 0.25, 0.9),
        opacity = 0.8,
    })
end

return c
