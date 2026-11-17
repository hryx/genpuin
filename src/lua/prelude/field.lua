local import = ...
local noise = import("noise")
local geo = import("geo")
local algo = import("core").algo

local M = {}

-- Create a flow field from a sampling function.
-- fn(x, y) should return an angle in radians.
function M.flowField(fn)
    return { type = "flow", sample = fn }
end

-- Create a Perlin noise-based flow field.
-- scale controls the noise frequency (default 0.01).
function M.noiseField(scale)
    scale = scale or 0.01
    local f = M.flowField(function(x, y)
        return noise.perlin(x * scale, y * scale) * math.pi * 2
    end)
    f.noiseScale = scale
    return f
end

-- Trace a path through a flow field starting at a point.
-- Returns a polyline shape with the given number of steps (default 100)
-- of length stepSize (default 1). Noise fields are traced in Zig, other
-- fields call field.sample at each step.
function M.trace(field, start, steps, stepSize)
    steps = steps or 100
    stepSize = stepSize or 1.0
    if field.noiseScale then
        return geo.polyline(algo.traceNoise(start, steps, stepSize, field.noiseScale))
    end
    local points = { {start[1], start[2]} }
    local x, y = start[1], start[2]
    for i = 1, steps do
        local angle = field.sample(x, y)
        x = x + math.cos(angle) * stepSize
        y = y + math.sin(angle) * stepSize
        points[i + 1] = {x, y}
    end
    return geo.polyline(points)
end

return M
