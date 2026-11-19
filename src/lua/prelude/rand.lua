local import = ...
local algo = import("core").algo
local native = import("compat").native

local M = {}

-- xoshiro256++ stream, one per Lua state, kept in Zig. Seeds are whole
-- numbers from 0 to 4294967295. Anything else is an error.

-- Set the base seed and start the stream from it. Call it at most once,
-- before any random draw, gen.mixSeed, or function that takes its seed
-- from the stream. A script that never calls it runs as seed(0).
-- With --seed N on the command line, the call acts as seed(N), and a
-- script that never seeds runs as seed(N).
M.seed = algo.seed

-- Restart the stream from a fixed mix of the base seed and k, so one seed
-- gives many unrelated streams, such as one per plate of a sheet. The
-- same base and k always give the same stream. The base seed stays as
-- it was, and --seed changes the base, never k.
M.mixSeed = algo.mixSeed

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
