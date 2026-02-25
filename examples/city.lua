-- city.lua — Generative City
-- Top-down city map with grid blocks, buildings, roads,
-- radial plazas, and parks.

local gen = require("genpuin")

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#1a1c24"))
gen.seed(42)
gen.noiseSeed(42)

local roadColor = gen.hsv(0.1, 0.05, 0.2)
local roadLine = gen.hsv(0.1, 0.08, 0.35)

-- === City grid parameters ===
local blockSize = 60
local roadWidth = 8
local margin = 40

-- === Layer 1: Road grid ===
-- Horizontal roads
for y = margin, H - margin, blockSize do
    gen.draw(c, gen.rect(margin, y - roadWidth / 2, W - 2 * margin, roadWidth), {
        fill = roadColor,
    })
    -- center line
    gen.draw(c, gen.line({margin, y}, {W - margin, y}), {
        stroke = roadLine,
        strokeWidth = 0.5,
        opacity = 0.4,
    })
end

-- Vertical roads
for x = margin, W - margin, blockSize do
    gen.draw(c, gen.rect(x - roadWidth / 2, margin, roadWidth, H - 2 * margin), {
        fill = roadColor,
    })
    gen.draw(c, gen.line({x, margin}, {x, H - margin}), {
        stroke = roadLine,
        strokeWidth = 0.5,
        opacity = 0.4,
    })
end

-- === Plazas: pick a few intersections to become radial plazas ===
local plazas = {}
local plazaCount = gen.randInt(3, 5)
for i = 1, plazaCount do
    local gx = gen.randInt(1, math.floor((W - 2 * margin) / blockSize) - 1)
    local gy = gen.randInt(1, math.floor((H - 2 * margin) / blockSize) - 1)
    local px = margin + gx * blockSize
    local py = margin + gy * blockSize
    plazas[#plazas + 1] = {px, py}
end

-- === Layer 2: City blocks with buildings ===
local cols = math.floor((W - 2 * margin) / blockSize)
local rows = math.floor((H - 2 * margin) / blockSize)

for row = 0, rows - 1 do
    for col = 0, cols - 1 do
        local bx = margin + col * blockSize + roadWidth / 2
        local by = margin + row * blockSize + roadWidth / 2
        local bw = blockSize - roadWidth
        local bh = blockSize - roadWidth

        -- skip blocks that overlap plazas
        local nearPlaza = false
        local blockCx, blockCy = bx + bw / 2, by + bh / 2
        for _, plaza in ipairs(plazas) do
            if gen.dist({blockCx, blockCy}, plaza) < blockSize * 1.2 then
                nearPlaza = true
                break
            end
        end

        -- noise-based district type
        local n = gen.perlin(bx * 0.008, by * 0.008)

        if nearPlaza then
            -- leave space for plaza
        elseif n > 0.2 then
            -- dense downtown: tall buildings (bright, packed)
            local numBuildings = gen.randInt(3, 6)
            for b = 1, numBuildings do
                local pad = 3
                local bldgW = gen.randRange(8, bw / 2 - pad)
                local bldgH = gen.randRange(8, bh / 2 - pad)
                local ox = gen.randRange(pad, bw - bldgW - pad)
                local oy = gen.randRange(pad, bh - bldgH - pad)

                -- building height mapped to brightness
                local height = gen.randRange(0.3, 1.0)
                local hue = gen.lerp(0.55, 0.65, height)
                local bright = gen.lerp(0.15, 0.45, height)

                gen.draw(c, gen.rect(bx + ox, by + oy, bldgW, bldgH), {
                    fill = gen.hsv(hue, 0.3, bright),
                    stroke = gen.hsv(hue, 0.2, bright + 0.1),
                    strokeWidth = 0.5,
                    opacity = 0.85,
                })

                -- windows: tiny dots inside the building
                local winStep = 4
                for wy = by + oy + 2, by + oy + bldgH - 2, winStep do
                    for wx = bx + ox + 2, bx + ox + bldgW - 2, winStep do
                        if gen.rand() < 0.6 then
                            local lit = gen.rand() < 0.3
                            gen.draw(c, gen.circle({wx, wy}, 0.6), {
                                fill = lit and gen.hsv(0.15, 0.6, 0.9)
                                           or gen.hsv(0.6, 0.2, 0.25),
                                opacity = lit and 0.9 or 0.5,
                            })
                        end
                    end
                end
            end

        elseif n > -0.1 then
            -- residential: smaller, sparser buildings
            local numBuildings = gen.randInt(1, 3)
            for b = 1, numBuildings do
                local pad = 5
                local bldgW = gen.randRange(10, 20)
                local bldgH = gen.randRange(10, 20)
                local ox = gen.randRange(pad, bw - bldgW - pad)
                local oy = gen.randRange(pad, bh - bldgH - pad)

                gen.draw(c, gen.rect(bx + ox, by + oy, bldgW, bldgH), {
                    fill = gen.hsv(0.08, 0.2, 0.2),
                    stroke = gen.hsv(0.08, 0.15, 0.3),
                    strokeWidth = 0.3,
                    opacity = 0.75,
                })
            end

        else
            -- park: green stippled area
            local parkPts = {
                {bx + 3, by + 3},
                {bx + bw - 3, by + 3},
                {bx + bw - 3, by + bh - 3},
                {bx + 3, by + bh - 3},
            }
            local parkShape = gen.polygon(parkPts)

            -- green fill
            gen.draw(c, parkShape, {
                fill = gen.hsv(0.35, 0.4, 0.12),
                opacity = 0.6,
            })

            -- stippled trees
            local dots = gen.stipple(parkShape, 0.015)
            for _, d in ipairs(dots) do
                local treeSize = gen.randRange(1.5, 3.5)
                gen.draw(c, gen.circle(d, treeSize), {
                    fill = gen.hsv(gen.randRange(0.28, 0.38), 0.5, gen.randRange(0.2, 0.35)),
                    opacity = 0.6,
                })
            end
        end
    end
end

-- === Layer 3: Radial plazas ===
for _, plaza in ipairs(plazas) do
    local plazaR = blockSize * 0.7

    -- plaza circle fill
    gen.draw(c, gen.circle(plaza, plazaR), {
        fill = gen.hsv(0.08, 0.15, 0.15),
        opacity = 0.9,
    })

    -- radial avenues emanating from plaza
    local numAvenues = gen.randInt(6, 10)
    gen.radial(numAvenues, plaza, plazaR + 15, function(pos, angle, i)
        -- extend the avenue further
        local farX = plaza[1] + math.cos(angle) * plazaR * 2
        local farY = plaza[2] + math.sin(angle) * plazaR * 2
        gen.draw(c, gen.line(plaza, {farX, farY}), {
            stroke = roadLine,
            strokeWidth = 1,
            opacity = 0.3,
        })
    end)

    -- concentric rings
    for r = 1, 3 do
        gen.draw(c, gen.circle(plaza, plazaR * r / 3), {
            stroke = roadLine,
            strokeWidth = 0.4,
            fill = "none",
            opacity = 0.3,
        })
    end

    -- central fountain
    gen.draw(c, gen.circle(plaza, 4), {
        fill = gen.hsv(0.55, 0.4, 0.5),
        opacity = 0.8,
    })
    gen.draw(c, gen.circle(plaza, 7), {
        stroke = gen.hsv(0.55, 0.3, 0.4),
        strokeWidth = 0.5,
        fill = "none",
        opacity = 0.5,
    })
end

-- === Layer 4: Major diagonal boulevards ===
-- A couple of diagonal roads across the city
for i = 1, 2 do
    local x0 = gen.randRange(margin, W / 3)
    local y0 = gen.randRange(margin, H / 3)
    local x1 = gen.randRange(W * 2/3, W - margin)
    local y1 = gen.randRange(H * 2/3, H - margin)

    local p = gen.pen(c)
    p:moveTo({x0, y0})
    p:set("width", 3)
    p:set("color", roadColor)

    -- slightly curving boulevard
    local steps = 40
    for s = 1, steps do
        local t = s / steps
        local tx = gen.lerp(x0, x1, t) + gen.perlin(t * 5, i * 10) * 30
        local ty = gen.lerp(y0, y1, t) + gen.perlin(t * 5 + 100, i * 10) * 30
        p:forwardTo({tx, ty})
    end
    p:stroke()
end

gen.exportSvg(c, "out/city.svg")
gen.exportPpm(c, "out/city.ppm")
print("Wrote out/city.svg and out/city.ppm")
