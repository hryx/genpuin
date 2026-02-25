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

return M
