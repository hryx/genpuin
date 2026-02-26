-- blossom.lua — Blooming Tendrils
-- Recursive random-walk tendrils with rightward wind,
-- hue drift, vein lines, spore dust, and a center glow.

local gen = require("genpuin")

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#0a0a1a"))
gen.seed(99)
gen.noiseSeed(99)

local numTendrils = 18

-- Collect all tendril points for spore dust proximity
local allPoints = {}

-- Recursive tendril: walks, draws with fade, then branches at the tip
local maxDepth = 3

local function drawTendril(ox, oy, startAngle, hue, numSteps, maxWidth, depth)
    -- Walk the path: random jitter + rightward wind
    local points = {{ox, oy}}
    local angle = startAngle
    for step = 1, numSteps do
        local px, py = points[#points][1], points[#points][2]
        -- Rightward wind: pull toward angle=0
        local wind = -math.sin(angle) * 0.07
        angle = angle + gen.randRange(-0.4, 0.4) + wind
        local dist = gen.randRange(2, 5)
        local nx = px + math.cos(angle) * dist
        local ny = py + math.sin(angle) * dist
        points[#points + 1] = {nx, ny}
    end

    -- Record points for spore dust (only root + depth 1 to keep it manageable)
    if depth <= 1 then
        for _, pt in ipairs(points) do
            allPoints[#allPoints + 1] = pt
        end
    end

    -- Hue drift: shift hue along length
    local hueDrift = gen.randRange(0.06, 0.12)

    -- Draw with per-segment fade: smooth across all generations
    -- depth 0 covers globalT 0..1/3, depth 1 covers 1/3..2/3, depth 2 covers 2/3..1
    for i = 2, #points do
        local t = (i - 1) / (#points - 1)
        local globalT = (depth + t) / maxDepth

        local width = gen.lerp(maxWidth, 0.15, globalT)
        local bright = gen.lerp(0.9, 0.3, globalT)
        local sat = gen.lerp(0.65, 0.2, globalT)
        local opacity = gen.lerp(0.8, 0.05, globalT * globalT)

        -- Hue drifts along length
        local segHue = (hue + t * hueDrift + gen.randRange(-0.02, 0.02)) % 1

        -- Main tendril stroke
        gen.draw(c, gen.line(points[i - 1], points[i]), {
            stroke = gen.hsv(segHue, sat, bright),
            strokeWidth = width,
            opacity = opacity,
            strokeLinecap = "round",
        })

        -- Vein line: faint thinner parallel line, slightly offset
        if depth <= 1 and width > 0.5 then
            local dx = points[i][1] - points[i - 1][1]
            local dy = points[i][2] - points[i - 1][2]
            local len = math.sqrt(dx * dx + dy * dy)
            if len > 0.01 then
                -- perpendicular offset
                local nx, ny = -dy / len, dx / len
                local off = width * 0.6
                gen.draw(c, gen.line(
                    {points[i - 1][1] + nx * off, points[i - 1][2] + ny * off},
                    {points[i][1] + nx * off, points[i][2] + ny * off}
                ), {
                    stroke = gen.hsv(segHue, sat * 0.5, bright * 0.6),
                    strokeWidth = width * 0.2,
                    opacity = opacity * 0.4,
                    strokeLinecap = "round",
                })
            end
        end
    end

    -- Recurse: branch at the tip
    if depth < maxDepth then
        local tip = points[#points]
        local prevPt = points[math.max(1, #points - 3)]
        local tipAngle = math.atan(tip[2] - prevPt[2], tip[1] - prevPt[1])

        local numBranches = gen.randInt(4, 7)
        local childSteps = math.floor(numSteps / 2)
        local childWidth = maxWidth * 0.6
        local childHue = (hue + hueDrift) % 1

        for br = 1, numBranches do
            local spread = (br - (numBranches + 1) / 2) / numBranches * 1.2
            local brAngle = tipAngle + spread + gen.randRange(-0.2, 0.2)
            drawTendril(tip[1], tip[2], brAngle, childHue,
                        gen.randInt(math.floor(childSteps * 0.7), childSteps),
                        childWidth, depth + 1)
        end
    end
end

-- Root tendrils from center
local startX = 200
local startY = H / 2
for trail = 1, numTendrils do
    local hue = gen.lerp(0.55, 0.20, (trail - 1) / (numTendrils - 1))
    local angle = gen.randRange(0, 2 * math.pi)
    local steps = gen.randInt(60, 117)

    drawTendril(startX, startY, angle, hue, steps, 2.2, 0)
end

-- Spore dust: scatter tiny dots, denser near tendril paths
for i = 1, 3000 do
    local sx = gen.randRange(0, W)
    local sy = gen.randRange(0, H)

    -- Find distance to nearest recorded tendril point (sample a subset)
    local minDist = math.huge
    local step = math.max(1, math.floor(#allPoints / 200))
    for j = 1, #allPoints, step do
        local dx = sx - allPoints[j][1]
        local dy = sy - allPoints[j][2]
        local d = dx * dx + dy * dy
        if d < minDist then minDist = d end
    end
    minDist = math.sqrt(minDist)

    -- Probability falls off with distance: dense near tendrils, sparse far away
    local proximity = gen.clamp(1 - minDist / 80, 0, 1)
    if gen.rand() < proximity * 0.7 + 0.05 then
        local dotHue = (0.55 + gen.perlin(sx * 0.01, sy * 0.01) * 0.2) % 1
        local dotSize = gen.randRange(0.5, 1.8) * (0.5 + proximity * 0.5)
        gen.draw(c, gen.circle({sx, sy}, dotSize), {
            fill = gen.hsv(dotHue, 0.4, gen.randRange(0.5, 0.8)),
            opacity = gen.randRange(0.1, 0.35) * (0.3 + proximity * 0.7),
        })
    end
end

gen.exportSvg(c, "out/tangle.svg")
print("Wrote out/tangle.svg")
