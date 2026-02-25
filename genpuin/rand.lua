local M = {}

-- SplitMix64: fast, statistically excellent single-state PRNG
local state = 0

function M.seed(n)
    state = n
end

function M.rand()
    state = state + 0x9e3779b97f4a7c15
    local z = state
    z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
    z = (z ~ (z >> 27)) * 0x94d049bb133111eb
    z = z ~ (z >> 31)
    -- map to [0, 1) using upper bits
    return (z >> 11) * (1.0 / (1 << 53))
end

function M.randRange(lo, hi)
    return lo + M.rand() * (hi - lo)
end

function M.randInt(lo, hi)
    return lo + math.floor(M.rand() * (1 + hi - lo))
end

function M.gaussian(mean, stddev)
    local u1 = M.rand()
    local u2 = M.rand()
    local z = math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
    return mean + z * stddev
end

function M.pick(list)
    return list[M.randInt(1, #list)]
end

function M.shuffle(list)
    local out = {}
    for i = 1, #list do out[i] = list[i] end
    for i = #out, 2, -1 do
        local j = M.randInt(1, i)
        out[i], out[j] = out[j], out[i]
    end
    return out
end

function M.weightedPick(list, weights)
    local total = 0
    for i = 1, #weights do total = total + weights[i] end
    local r = M.rand() * total
    local acc = 0
    for i = 1, #list do
        acc = acc + weights[i]
        if r < acc then return list[i] end
    end
    return list[#list]
end

function M.randInCircle(center, r)
    local angle = M.rand() * 2 * math.pi
    local dist = r * math.sqrt(M.rand())
    return {center[1] + dist * math.cos(angle),
            center[2] + dist * math.sin(angle)}
end

function M.randOnCircle(center, r)
    local angle = M.rand() * 2 * math.pi
    return {center[1] + r * math.cos(angle),
            center[2] + r * math.sin(angle)}
end

function M.randInRect(x, y, w, h)
    return {x + M.rand() * w, y + M.rand() * h}
end

-- Bridson's algorithm for Poisson disk sampling
-- bounds = {x, y, w, h}, minDist = minimum distance between points
function M.poissonDisk(bounds, minDist, maxAttempts)
    maxAttempts = maxAttempts or 30
    local bx, by, bw, bh = bounds[1], bounds[2], bounds[3], bounds[4]
    local cellSize = minDist / math.sqrt(2)
    local cols = math.ceil(bw / cellSize)
    local rows = math.ceil(bh / cellSize)

    -- grid stores point indices (0 = empty)
    local grid = {}
    for i = 0, cols * rows - 1 do grid[i] = 0 end

    local points = {}
    local active = {}

    local function gridIdx(px, py)
        local c = math.floor((px - bx) / cellSize)
        local r = math.floor((py - by) / cellSize)
        return r * cols + c
    end

    local function tooClose(px, py)
        local c = math.floor((px - bx) / cellSize)
        local r = math.floor((py - by) / cellSize)
        for dr = -2, 2 do
            for dc = -2, 2 do
                local nc, nr = c + dc, r + dr
                if nc >= 0 and nc < cols and nr >= 0 and nr < rows then
                    local idx = grid[nr * cols + nc]
                    if idx > 0 then
                        local other = points[idx]
                        local dx, dy = px - other[1], py - other[2]
                        if dx * dx + dy * dy < minDist * minDist then
                            return true
                        end
                    end
                end
            end
        end
        return false
    end

    -- seed with first point
    local p0 = {bx + M.rand() * bw, by + M.rand() * bh}
    table.insert(points, p0)
    grid[gridIdx(p0[1], p0[2])] = #points
    table.insert(active, #points)

    while #active > 0 do
        local ai = M.randInt(1, #active)
        local pi = active[ai]
        local pt = points[pi]
        local found = false

        for _ = 1, maxAttempts do
            local angle = M.rand() * 2 * math.pi
            local dist = minDist + M.rand() * minDist
            local nx = pt[1] + math.cos(angle) * dist
            local ny = pt[2] + math.sin(angle) * dist

            if nx >= bx and nx < bx + bw and ny >= by and ny < by + bh then
                if not tooClose(nx, ny) then
                    table.insert(points, {nx, ny})
                    grid[gridIdx(nx, ny)] = #points
                    table.insert(active, #points)
                    found = true
                    break
                end
            end
        end

        if not found then
            table.remove(active, ai)
        end
    end

    return points
end

return M
