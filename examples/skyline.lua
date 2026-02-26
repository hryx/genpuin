-- skyline.lua — Side-view cityscape with sunset
-- Silhouetted buildings against a multi-color gradient sky,
-- sun glow, clouds, and reflections.

local gen = require("genpuin")

local W, H = 1000, 600
local c = gen.canvas(W, H)
gen.seed(42)
gen.noiseSeed(42)

-- ================================================================
-- Sky gradient (simulated with horizontal bands)
-- ================================================================

-- Multi-stop gradient: top → horizon
local skyStops = {
    {0.00, gen.hex("#0b0e2a")},   -- deep night blue
    {0.25, gen.hex("#1a1040")},   -- dark purple
    {0.45, gen.hex("#3b1854")},   -- violet
    {0.60, gen.hex("#8b2a4a")},   -- wine
    {0.72, gen.hex("#d4543a")},   -- burnt orange
    {0.82, gen.hex("#e8863a")},   -- orange
    {0.90, gen.hex("#f0b84a")},   -- golden
    {0.96, gen.hex("#f5d576")},   -- pale gold
    {1.00, gen.hex("#fae8a0")},   -- horizon glow
}

local horizonY = H * 0.62

-- Interpolate through multi-stop gradient
local function skyColor(t)
    t = gen.clamp(t, 0, 1)
    for i = 2, #skyStops do
        if t <= skyStops[i][1] then
            local t0, c0 = skyStops[i - 1][1], skyStops[i - 1][2]
            local t1, c1 = skyStops[i][1], skyStops[i][2]
            local frac = (t - t0) / (t1 - t0)
            return gen.lerpColor(c0, c1, frac)
        end
    end
    return skyStops[#skyStops][2]
end

-- Draw sky bands
local bands = 120
for i = 0, bands - 1 do
    local t = i / bands
    local y0 = t * horizonY
    local bandH = horizonY / bands + 1
    gen.draw(c, gen.rect(0, y0, W, bandH), {
        fill = skyColor(t),
    })
end

-- ================================================================
-- Sun
-- ================================================================

local sunX = W * 0.72
local sunY = horizonY - 15

-- Outer glow rings
for r = 80, 20, -10 do
    local t = 1 - (r - 20) / 60
    gen.draw(c, gen.circle({sunX, sunY}, r), {
        fill = gen.lerpColor(gen.hex("#f5d576"), gen.hex("#e8863a"), 1 - t),
        opacity = 0.04 + t * 0.04,
    })
end

-- Sun body (half-hidden behind horizon)
gen.draw(c, gen.circle({sunX, sunY}, 28), {
    fill = gen.hex("#fef0c0"),
    opacity = 0.9,
})

-- Mask below horizon: draw a rect to cover the bottom half of the sun
-- We'll draw the ground layer later which covers this naturally

-- ================================================================
-- Clouds
-- ================================================================

local function drawCloud(cx, cy, spread, height)
    -- A cloud is a cluster of overlapping ellipse-like shapes
    -- (approximated with wide, short polygons)
    local numPuffs = gen.randInt(4, 8)
    for p = 1, numPuffs do
        local ox = gen.randRange(-spread, spread)
        local oy = gen.randRange(-height * 0.3, height * 0.3)
        local pw = gen.randRange(spread * 0.3, spread * 0.6)
        local ph = gen.randRange(height * 0.3, height * 0.7)

        -- build an ellipse-ish polygon
        local pts = {}
        local segs = 12
        for i = 0, segs - 1 do
            local a = (i / segs) * 2 * math.pi
            pts[#pts + 1] = {
                cx + ox + pw * math.cos(a),
                cy + oy + ph * 0.4 * math.sin(a),
            }
        end

        -- tint based on vertical position: lower clouds catch sunset glow
        local glowT = gen.clamp((cy - horizonY * 0.2) / (horizonY * 0.5), 0, 1)
        local cloudCol = gen.lerpColor(gen.hex("#3a2848"), gen.hex("#d4876a"), glowT)

        gen.draw(c, gen.polygon(pts), {
            fill = cloudCol,
            opacity = gen.randRange(0.08, 0.2),
        })
    end
end

-- Scatter clouds in the upper sky
drawCloud(150, horizonY * 0.25, 80, 20)
drawCloud(350, horizonY * 0.18, 60, 15)
drawCloud(550, horizonY * 0.35, 100, 22)
drawCloud(750, horizonY * 0.22, 70, 18)
drawCloud(900, horizonY * 0.40, 90, 20)
-- Near-horizon clouds (catch more sunset color)
drawCloud(200, horizonY * 0.55, 110, 14)
drawCloud(600, horizonY * 0.60, 80, 12)
drawCloud(850, horizonY * 0.52, 90, 16)

-- ================================================================
-- Ground plane (below horizon)
-- ================================================================

gen.draw(c, gen.rect(0, horizonY, W, H - horizonY), {
    fill = gen.hex("#0a0b12"),
})

-- Faint horizon glow on ground
for i = 0, 15 do
    local t = i / 15
    local y = horizonY + t * 30
    gen.draw(c, gen.rect(0, y, W, 3), {
        fill = gen.lerpColor(gen.hex("#3a2520"), gen.hex("#0a0b12"), t),
        opacity = 0.4 * (1 - t),
    })
end

-- ================================================================
-- Buildings
-- ================================================================

-- Generate a skyline profile: list of {x, width, height}
local buildings = {}
local bx = -10
while bx < W + 10 do
    local bw = gen.randRange(20, 65)
    local maxH = gen.lerp(180, 320, gen.rand())
    -- buildings near center and near sun are taller
    local centerT = 1 - math.abs(bx + bw / 2 - W * 0.5) / (W * 0.5)
    maxH = maxH * gen.lerp(0.5, 1.0, centerT)
    local bh = gen.randRange(60, maxH)

    buildings[#buildings + 1] = {x = bx, w = bw, h = bh}
    bx = bx + bw + gen.randRange(-4, 6)
end

-- Sort by height so taller buildings draw behind shorter ones (painter's order)
table.sort(buildings, function(a, b) return a.h > b.h end)

-- Draw buildings
for _, b in ipairs(buildings) do
    local bTop = horizonY - b.h
    local bCenterX = b.x + b.w / 2

    -- Buildings closer to the sun get a warm edge highlight
    local sunDist = math.abs(bCenterX - sunX) / W
    local warmth = gen.clamp(1 - sunDist * 3, 0, 1)

    -- Base building color: dark silhouette
    local baseBright = gen.randRange(0.04, 0.10)
    local baseColor = gen.hsv(0.6, 0.3, baseBright)

    -- Main building body
    gen.draw(c, gen.rect(b.x, bTop, b.w, b.h), {
        fill = baseColor,
    })

    -- Warm edge on sun-facing side
    if warmth > 0.1 then
        local edgeW = gen.lerp(1, 3, warmth)
        local edgeSide = (bCenterX < sunX) and (b.x + b.w - edgeW) or b.x
        gen.draw(c, gen.rect(edgeSide, bTop, edgeW, b.h), {
            fill = gen.lerpColor(gen.hex("#2a1a18"), gen.hex("#6b3a25"), warmth),
            opacity = warmth * 0.6,
        })
    end

    -- Rooftop details
    if gen.rand() < 0.4 then
        -- antenna
        local ax = b.x + b.w * gen.randRange(0.3, 0.7)
        gen.draw(c, gen.line({ax, bTop}, {ax, bTop - gen.randRange(8, 25)}), {
            stroke = gen.hsv(0.0, 0.0, 0.12),
            strokeWidth = 0.5,
        })
    end
    if gen.rand() < 0.3 then
        -- rooftop box (AC unit / water tower)
        local rw = gen.randRange(4, b.w * 0.3)
        local rh = gen.randRange(3, 8)
        local rx = b.x + gen.randRange(2, b.w - rw - 2)
        gen.draw(c, gen.rect(rx, bTop - rh, rw, rh), {
            fill = gen.hsv(0.6, 0.2, baseBright + 0.02),
        })
    end

    -- Windows
    local winW = 2
    local winH = 3
    local winSpaceX = gen.randRange(5, 9)
    local winSpaceY = gen.randRange(7, 11)
    local winMarginX = 4
    local winMarginY = 6

    for wy = bTop + winMarginY, horizonY - winMarginY, winSpaceY do
        for wx = b.x + winMarginX, b.x + b.w - winMarginX - winW, winSpaceX do
            if gen.rand() < 0.35 then
                -- lit window
                local litHue = gen.pick({0.12, 0.15, 0.08, 0.55})
                local litSat = gen.randRange(0.3, 0.7)
                local litBright = gen.randRange(0.5, 0.9)
                gen.draw(c, gen.rect(wx, wy, winW, winH), {
                    fill = gen.hsv(litHue, litSat, litBright),
                    opacity = gen.randRange(0.5, 0.9),
                })
            end
        end
    end
end

-- ================================================================
-- Reflections on ground (mirrored, faded)
-- ================================================================

-- Sort buildings by height descending again for reflections
for _, b in ipairs(buildings) do
    local reflH = b.h * gen.randRange(0.15, 0.3)
    local reflTop = horizonY + 2

    -- faint stretched reflection
    gen.draw(c, gen.rect(b.x - 1, reflTop, b.w + 2, reflH), {
        fill = gen.hsv(0.6, 0.2, 0.06),
        opacity = 0.15,
    })
end

-- Sun reflection on ground
for i = 0, 20 do
    local t = i / 20
    local rw = gen.lerp(50, 5, t)
    local ry = horizonY + 2 + t * (H - horizonY - 10)
    gen.draw(c, gen.rect(sunX - rw / 2, ry, rw, 3), {
        fill = gen.lerpColor(gen.hex("#e8a060"), gen.hex("#3a2520"), t),
        opacity = gen.lerp(0.25, 0.02, t),
    })
end

-- ================================================================
-- Foreground details: a few distant birds
-- ================================================================

local function drawBird(bx, by, size)
    -- V-shape
    gen.draw(c, gen.polyline({
        {bx - size, by + size * 0.4},
        {bx, by},
        {bx + size, by + size * 0.4},
    }), {
        stroke = gen.hex("#1a1020"),
        strokeWidth = 0.8,
        fill = "none",
        opacity = 0.5,
    })
end

for i = 1, 7 do
    local birdX = gen.randRange(100, W - 100)
    local birdY = gen.randRange(horizonY * 0.15, horizonY * 0.50)
    drawBird(birdX, birdY, gen.randRange(4, 10))
end

gen.exportSvg(c, "out/skyline.svg")
print("Wrote out/skyline.svg")
