local import = ...
local core = import("core")
local rand = import("rand")

local M = {}

local function withSeed(opts)
    local o = {}
    for k, v in pairs(opts or {}) do o[k] = v end
    if o.seed == nil then o.seed = rand.randInt(1, 2147483646) end
    return o
end

-- Gray-Scott reaction-diffusion. Returns the B concentration as a Field, then A.
-- opts: w, h (default 256), steps (2000), feed, kill, dA (1), dB (0.5), dt (1),
-- wrap (true), seed.
-- preset = "coral", "mitosis", "worms", "spots", "maze", "fingerprint", "holes",
-- "waves" or "chaos" picks feed and kill. Explicit feed or kill win over it.
-- feedMap, killMap: Fields of absolute rates, stretched over the grid, so the
-- pattern can change across the picture.
-- seeds: a count of random blobs, or a list of {x, y, r} in cells (seedRadius
-- sets the default r, 5). init: a Field to start B from.
-- To keep stepping, pass the returned fields back as opts.b and opts.a.
function M.reactionDiffusion(opts)
    return core.sim.reactionDiffusion(withSeed(opts))
end

-- Physarum slime mold agents (Jones 2010). Returns the trail map Field, then
-- an agents Field (3 columns: x, y, heading per agent).
-- opts: w, h (512), agents (100000), steps (300), sensorAngle (pi/4),
-- sensorDist (9), turn (pi/4), speed (1), deposit (5), decay (0.1),
-- diffuse (1, the 3x3 blur mix), wrap (true), seed.
-- spawn = "random", "disc", "ring" (facing inward) or a list of {x, y} cells.
-- food: a Field added to the trail each step (times foodWeight) to steer agents.
-- To keep stepping, pass the results back as opts.trail and opts.agents.
function M.physarum(opts)
    return core.sim.physarum(withSeed(opts))
end

-- Off-lattice diffusion-limited aggregation. Returns a list of segments and a
-- list of every particle center.
-- Each segment is {parentPoint, childPoint, order = n, depth = d, weight = w}:
-- order is arrival order from 1, depth the generation from the seed, weight the
-- number of particles hanging off the child (itself included), for tapering.
-- opts: n particles (1000), radius (2), stickiness (0..1, default 1), seed,
-- seeds (a list of points or a gen.line, default the bounds center or {0, 0}),
-- bias {x, y} drift per step, bounds {x, y, w, h} walls walkers bounce off,
-- maxSteps a walker may take before growth stops early (1000000).
function M.dla(opts)
    return core.sim.dla(withSeed(opts))
end

-- Differential growth of a line (after Anders Hoff). Returns the grown point list.
-- opts: points (a list of points, a gen.polygon or a gen.polyline), closed
-- (default true, false for a polyline), steps (200), maxEdge (4) edges split
-- above this, restLength (maxEdge / 2), repelRadius (10), repel (0.6),
-- attract (0.4), align (0.3) smoothing, noise (0.1), growth (0) chance per
-- step that a short edge splits anyway, maxNodes (20000), seed.
-- bounds {x, y, w, h} confines nodes. mask: a Field covering bounds (or its own
-- size in points when there are no bounds), growth stays where it is above 0.5.
-- To keep stepping, pass the result back as opts.points.
function M.differentialGrowth(opts)
    return core.sim.differentialGrowth(withSeed(opts))
end

return M
