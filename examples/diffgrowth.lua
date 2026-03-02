-- diffgrowth.lua — Differential line growth in a Perlin noise field
-- Inspired by differential-line by inconvergent: https://github.com/inconvergent/differential-line
-- A closed loop of nodes grows organically, steered by noise, producing
-- coral/brain-like forms. Growth history rendered as layered snapshots.

local gen = require("genpuin")

local W, H = 800, 800
local c = gen.canvas(W, H)
gen.background(c, gen.hex("#0a0a0e"))
gen.seed(42)

-- ============================================================
-- Parameters
-- ============================================================

local NEARL = 4          -- min comfortable edge length
local FARL = 20          -- repulsion search radius
local SPLIT_DIST = 8     -- insert midpoint when edge > this
local REPULSION = 1.0    -- repulsion force scale
local ATTRACTION = 0.8   -- attraction force scale
local NOISE_SCALE = 0.004
local NOISE_STRENGTH = 0.4
local GROWTH = 0.6       -- outward growth force
local MAX_DISP = 2.0     -- max displacement per step
local ITERATIONS = 600
local SNAPSHOT_EVERY = 20

local cx, cy = W / 2, H / 2
local floor = math.floor
local sqrt = math.sqrt
local cos = math.cos
local sin = math.sin
local pi = math.pi

-- ============================================================
-- Initialize closed loop
-- ============================================================

local START_NODES = 30
local START_RADIUS = 15

local nodes = {}
for i = 1, START_NODES do
    local angle = (i - 1) / START_NODES * 2 * pi
    nodes[i] = {cx + START_RADIUS * cos(angle), cy + START_RADIUS * sin(angle)}
end

-- ============================================================
-- Grid hash for spatial queries
-- ============================================================

local gridCellSize = FARL
local grid = {}

local function buildGrid()
    grid = {}
    for i = 1, #nodes do
        local gx = floor(nodes[i][1] / gridCellSize)
        local gy = floor(nodes[i][2] / gridCellSize)
        local key = gx * 100003 + gy  -- numeric key, faster than string concat
        if not grid[key] then grid[key] = {} end
        local bucket = grid[key]
        bucket[#bucket + 1] = i
    end
end

local function queryNearby(x, y)
    local results = {}
    local gx = floor(x / gridCellSize)
    local gy = floor(y / gridCellSize)
    local r2 = FARL * FARL
    for dx = -1, 1 do
        for dy = -1, 1 do
            local key = (gx + dx) * 100003 + (gy + dy)
            local bucket = grid[key]
            if bucket then
                for _, idx in ipairs(bucket) do
                    local nx, ny = nodes[idx][1], nodes[idx][2]
                    local ddx, ddy = nx - x, ny - y
                    if ddx * ddx + ddy * ddy <= r2 then
                        results[#results + 1] = idx
                    end
                end
            end
        end
    end
    return results
end

-- ============================================================
-- Snapshot storage
-- ============================================================

local snapshots = {}

local function takeSnapshot()
    local snap = {}
    for i = 1, #nodes do
        snap[i] = {nodes[i][1], nodes[i][2]}
    end
    snapshots[#snapshots + 1] = snap
end

-- Take initial snapshot
takeSnapshot()

-- ============================================================
-- Simulation
-- ============================================================

for iter = 1, ITERATIONS do
    local n = #nodes
    buildGrid()

    -- Compute centroid for growth force
    local centX, centY = 0, 0
    for i = 1, n do
        centX = centX + nodes[i][1]
        centY = centY + nodes[i][2]
    end
    centX, centY = centX / n, centY / n

    -- Accumulate forces
    local fx, fy = {}, {}
    for i = 1, n do fx[i], fy[i] = 0, 0 end

    for i = 1, n do
        local px, py = nodes[i][1], nodes[i][2]

        -- Connected neighbor indices (closed loop)
        local prevIdx = i == 1 and n or i - 1
        local nextIdx = i == n and 1 or i + 1

        -- Repulsion from nearby non-connected nodes
        local nearby = queryNearby(px, py)
        for _, j in ipairs(nearby) do
            if j ~= i and j ~= prevIdx and j ~= nextIdx then
                local ox, oy = nodes[j][1], nodes[j][2]
                local ddx, ddy = px - ox, py - oy
                local dist = sqrt(ddx * ddx + ddy * ddy)
                if dist > 0.001 and dist < FARL then
                    local strength = REPULSION * (FARL - dist) / FARL
                    fx[i] = fx[i] + ddx / dist * strength
                    fy[i] = fy[i] + ddy / dist * strength
                end
            end
        end

        -- Attraction to connected neighbors
        local prev = nodes[prevIdx]
        local next = nodes[nextIdx]
        local dpx, dpy = prev[1] - px, prev[2] - py
        local dnx, dny = next[1] - px, next[2] - py
        local dpLen = sqrt(dpx * dpx + dpy * dpy)
        local dnLen = sqrt(dnx * dnx + dny * dny)

        if dpLen > NEARL then
            local pull = ATTRACTION * (dpLen - NEARL) / dpLen
            fx[i] = fx[i] + dpx * pull
            fy[i] = fy[i] + dpy * pull
        end
        if dnLen > NEARL then
            local pull = ATTRACTION * (dnLen - NEARL) / dnLen
            fx[i] = fx[i] + dnx * pull
            fy[i] = fy[i] + dny * pull
        end

        -- Growth force: push outward from centroid
        local growDx, growDy = px - centX, py - centY
        local growLen = sqrt(growDx * growDx + growDy * growDy)
        if growLen > 0.001 then
            fx[i] = fx[i] + growDx / growLen * GROWTH
            fy[i] = fy[i] + growDy / growLen * GROWTH
        end

        -- Noise field bias
        local noiseAngle = gen.perlin(px * NOISE_SCALE, py * NOISE_SCALE) * 2 * pi
        fx[i] = fx[i] + cos(noiseAngle) * NOISE_STRENGTH
        fy[i] = fy[i] + sin(noiseAngle) * NOISE_STRENGTH
    end

    -- Apply forces with max displacement clamp
    for i = 1, n do
        local dx, dy = fx[i], fy[i]
        local mag = sqrt(dx * dx + dy * dy)
        if mag > MAX_DISP then
            dx = dx / mag * MAX_DISP
            dy = dy / mag * MAX_DISP
        end
        nodes[i][1] = nodes[i][1] + dx
        nodes[i][2] = nodes[i][2] + dy
    end

    -- Split long edges (insert midpoints)
    local newNodes = {}
    for i = 1, #nodes do
        newNodes[#newNodes + 1] = nodes[i]
        local nextIdx = i == #nodes and 1 or i + 1
        local ax, ay = nodes[i][1], nodes[i][2]
        local bx, by = nodes[nextIdx][1], nodes[nextIdx][2]
        local edx, edy = bx - ax, by - ay
        local edgeLen = sqrt(edx * edx + edy * edy)
        if edgeLen > SPLIT_DIST then
            newNodes[#newNodes + 1] = {(ax + bx) * 0.5, (ay + by) * 0.5}
        end
    end
    nodes = newNodes

    -- Snapshot
    if iter % SNAPSHOT_EVERY == 0 then
        takeSnapshot()
    end
end

-- Final snapshot
takeSnapshot()

io.stderr:write(string.format("Final: %d nodes, %d snapshots\n", #nodes, #snapshots))
-- Compute bounding box
local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
for _, nd in ipairs(nodes) do
    if nd[1] < minX then minX = nd[1] end
    if nd[2] < minY then minY = nd[2] end
    if nd[1] > maxX then maxX = nd[1] end
    if nd[2] > maxY then maxY = nd[2] end
end
io.stderr:write(string.format("Bounds: %.0f,%.0f to %.0f,%.0f (%.0fx%.0f)\n",
    minX, minY, maxX, maxY, maxX - minX, maxY - minY))

-- ============================================================
-- Drawing
-- ============================================================

-- Compute bounding box of all snapshots to fit on canvas
local fitMinX, fitMinY = math.huge, math.huge
local fitMaxX, fitMaxY = -math.huge, -math.huge
for _, snap in ipairs(snapshots) do
    for _, pt in ipairs(snap) do
        if pt[1] < fitMinX then fitMinX = pt[1] end
        if pt[2] < fitMinY then fitMinY = pt[2] end
        if pt[1] > fitMaxX then fitMaxX = pt[1] end
        if pt[2] > fitMaxY then fitMaxY = pt[2] end
    end
end
local margin = 30
local fitW = fitMaxX - fitMinX
local fitH = fitMaxY - fitMinY
local fitScale = math.min((W - 2 * margin) / fitW, (H - 2 * margin) / fitH)
local fitOX = W / 2 - (fitMinX + fitW / 2) * fitScale
local fitOY = H / 2 - (fitMinY + fitH / 2) * fitScale

local function fitSnap(snap)
    local pts = {}
    for i, pt in ipairs(snap) do
        pts[i] = {pt[1] * fitScale + fitOX, pt[2] * fitScale + fitOY}
    end
    return pts
end

local colorEarly = gen.hsv(0.08, 0.5, 0.4)
local colorLate = gen.hsv(0.55, 0.6, 0.5)
local numSnaps = #snapshots

for si = 1, numSnaps do
    local t = (si - 1) / math.max(numSnaps - 1, 1)
    local clr = gen.lerpColor(colorEarly, colorLate, t)
    local opacity = gen.lerp(0.4, 0.15, t)
    local sw = gen.lerp(1.2, 0.4, t)
    local shape = gen.polygon(fitSnap(snapshots[si]))
    shape = gen.smooth(shape, 2)
    gen.draw(c, shape, {
        stroke = clr,
        strokeWidth = sw,
        fill = "none",
        opacity = opacity,
    })
end

return c
