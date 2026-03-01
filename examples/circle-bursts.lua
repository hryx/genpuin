-- circle-bursts.lua — Recursive circle systems
-- Only circles. Clusters burst from a few origins, with sub-systems
-- packed inside larger rings. Sparse debris floats in the gaps.

local gen = require("genpuin")

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#ffffff"))
gen.seed(41)

-- Color palette: returns color, isDark
local function pickColor()
    local r = gen.rand()
    if r < 0.70 then
        return gen.hsv(0, 0, gen.randRange(0.08, 0.3)), true
    elseif r < 0.80 then
        return gen.hsv(0.08, gen.randRange(0.2, 0.35), gen.randRange(0.5, 0.65)), false
    elseif r < 0.88 then
        return gen.hsv(0.95, gen.randRange(0.2, 0.3), gen.randRange(0.55, 0.7)), false
    elseif r < 0.95 then
        return gen.hsv(0.58, gen.randRange(0.15, 0.25), gen.randRange(0.45, 0.6)), false
    else
        return gen.hsv(0.35, gen.randRange(0.15, 0.25), gen.randRange(0.4, 0.55)), false
    end
end

-- Collect black outline circles for bonding later
local bondable = {}

-- Recursive burst: draw a parent circle, spawn children inside (and slightly outside)
local function burst(cx, cy, radius, depth, maxDepth)
    local strokeW = gen.lerp(1.2, 0.25, (depth - 1) / math.max(maxDepth - 1, 1))

    -- Draw parent ring
    local parentColor, parentDark = pickColor()
    gen.draw(c, gen.circle({cx, cy}, radius), {
        stroke = parentColor,
        strokeWidth = strokeW,
        opacity = gen.randRange(0.4, 0.85),
    })
    if parentDark then
        bondable[#bondable + 1] = {cx, cy, radius}
    end

    -- Number of children scales with area, fewer at deeper levels
    local nChildren = gen.randInt(
        math.max(3, math.floor(radius * 0.15)),
        math.max(5, math.floor(radius * 0.35))
    )

    for _ = 1, nChildren do
        -- Child radius: fraction of parent, smaller at deeper levels
        local maxChildR = radius * gen.randRange(0.15, 0.45)
        local childR = math.max(2, maxChildR)

        -- Place mostly inside, some escape
        local placementR = radius
        if gen.rand() < 0.12 then
            placementR = radius * 1.3  -- escape
        end
        local pos = gen.randInCircle({cx, cy}, placementR - childR * 0.5)

        local filled = gen.rand() < 0.15
        local color, isDark = pickColor()

        if not filled and childR > 12 and depth < maxDepth and gen.rand() < 0.6 then
            -- Recurse into this child
            burst(pos[1], pos[2], childR, depth + 1, maxDepth)
        else
            -- Terminal circle
            local style = {}
            if filled then
                style.fill = color
                style.opacity = gen.randRange(0.15, 0.5)
            else
                style.stroke = color
                style.strokeWidth = gen.randRange(0.2, strokeW)
                style.opacity = gen.randRange(0.3, 0.8)
                if isDark then
                    bondable[#bondable + 1] = {pos[1], pos[2], childR}
                end
            end
            gen.draw(c, gen.circle(pos, childR), style)
        end
    end
end

-- Primary bursts: semi-random positions, clustered toward center but can reach edges
local nBursts = gen.randInt(5, 7)
for _ = 1, nBursts do
    local bx = gen.gaussian(W / 2, W * 0.28)
    local by = gen.gaussian(H / 2, H * 0.28)
    local br = gen.randRange(60, 180)
    burst(bx, by, br, 1, 3)
end

-- Scattered debris: tiny circles in the gaps
gen.scatter(120, {20, 20, W - 40, H - 40}, function(pos)
    local r = gen.randRange(0.5, 3.5)
    local filled = gen.rand() < 0.4
    local color = pickColor()

    if filled then
        gen.draw(c, gen.circle(pos, r), {
            fill = color,
            opacity = gen.randRange(0.15, 0.45),
        })
    else
        gen.draw(c, gen.circle(pos, r), {
            stroke = color,
            strokeWidth = gen.randRange(0.2, 0.6),
            opacity = gen.randRange(0.2, 0.5),
        })
    end
end)

-- Bonds: thin lines between nearby black outline circles of similar size
for i = 1, #bondable do
    local a = bondable[i]
    for j = i + 1, #bondable do
        local b = bondable[j]
        -- Similar size: ratio within 3x
        local ratio = a[3] / b[3]
        if ratio < 0.33 or ratio > 3 then goto skip end
        -- Proximity: gap between edges < 4x the smaller radius
        local dx, dy = b[1] - a[1], b[2] - a[2]
        local d = math.sqrt(dx * dx + dy * dy)
        local gap = d - a[3] - b[3]
        local minR = math.min(a[3], b[3])
        if gap < 0 or gap > minR * 4 then goto skip end
        -- Only ~10% of eligible pairs
        if gen.rand() > 0.10 then goto skip end
        -- Line from circumference to circumference
        local nx, ny = dx / d, dy / d
        local p1 = {a[1] + nx * a[3], a[2] + ny * a[3]}
        local p2 = {b[1] - nx * b[3], b[2] - ny * b[3]}
        gen.draw(c, gen.line(p1, p2), {
            stroke = gen.hsv(0, 0, gen.randRange(0.1, 0.3)),
            strokeWidth = gen.randRange(0.2, 0.6),
            opacity = gen.randRange(0.25, 0.55),
        })
        ::skip::
    end
end

return c
