local rand = require("genpuin.rand")

local M = {}

-- Create a Markov chain from explicit transition weights.
-- transitions: {state = {{next_state, weight}, ...}, ...}
-- Returns a chain table (plain data).
function M.chain(transitions)
    local chain = {}
    for state, entries in pairs(transitions) do
        local nexts = {}
        local weights = {}
        for i = 1, #entries do
            nexts[i] = entries[i][1]
            weights[i] = entries[i][2]
        end
        chain[state] = {nexts = nexts, weights = weights}
    end
    return chain
end

-- Build a chain by counting transitions in an observed sequence.
-- sequence: array of states (any values usable as table keys).
function M.fromSequence(sequence)
    if #sequence < 2 then return {} end

    -- Count transitions
    local counts = {}
    for i = 1, #sequence - 1 do
        local from = sequence[i]
        local to = sequence[i + 1]
        if not counts[from] then counts[from] = {} end
        counts[from][to] = (counts[from][to] or 0) + 1
    end

    -- Convert to chain format
    local chain = {}
    for state, targets in pairs(counts) do
        local nexts = {}
        local weights = {}
        for target, count in pairs(targets) do
            nexts[#nexts + 1] = target
            weights[#weights + 1] = count
        end
        chain[state] = {nexts = nexts, weights = weights}
    end
    return chain
end

-- Pick the next state given current state.
-- Returns nil if current state has no transitions.
function M.step(chain, current)
    local entry = chain[current]
    if not entry then return nil end
    return rand.weightedPick(entry.nexts, entry.weights)
end

-- Generate a sequence of n states starting from start.
-- Stops early if a dead end is reached.
function M.generate(chain, start, n)
    local seq = {start}
    local current = start
    for _ = 2, n do
        current = M.step(chain, current)
        if current == nil then break end
        seq[#seq + 1] = current
    end
    return seq
end

return M
