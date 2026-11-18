local import = ...
local algo = import("core").algo
local native = import("compat").native

local M = {}

-- xorshift32 stream, one per Lua state, kept in Zig.

-- Seed the random number generator.
-- With --seed N on the command line, every call acts as seed(N), and a
-- script that never seeds starts as if it called seed(N).
M.seed = algo.seed

-- Return a random number in [0, 1).
M.rand = native.rand

-- Return a random number in [lo, hi).
M.randRange = native.randRange

-- Return a random integer in [lo, hi] (inclusive).
M.randInt = native.randInt

-- Sample from a normal distribution with the given mean and stddev.
M.gaussian = native.gaussian

-- Pick a random element from a list.
M.pick = algo.pick

-- Return a shuffled copy of a list.
M.shuffle = algo.shuffle

-- Pick from a list with weighted probabilities.
M.weightedPick = algo.weightedPick

-- Return a random point uniformly distributed inside a circle.
M.randInCircle = algo.randInCircle

-- Return a random point on the circumference of a circle.
M.randOnCircle = algo.randOnCircle

-- Return a random point inside a rectangle.
M.randInRect = algo.randInRect

-- Poisson disk sampling using Bridson's algorithm.
-- bounds = {x, y, w, h}, minDist = minimum distance between points,
-- maxAttempts = candidates tried around each point (default 30).
function M.poissonDisk(bounds, minDist, maxAttempts)
    return algo.poissonDisk(bounds, minDist, maxAttempts or 30)
end

return M
