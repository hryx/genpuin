local noise = require("genpuin.noise")
local geo = require("genpuin.geo")

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
    return M.flowField(function(x, y)
        return noise.perlin(x * scale, y * scale) * math.pi * 2
    end)
end

-- Trace a path through a flow field starting at a point.
-- Returns a polyline shape with the given number of steps.
function M.trace(field, start, steps, stepSize)
    steps = steps or 100
    stepSize = stepSize or 1.0
    local points = { {start[1], start[2]} }
    local x, y = start[1], start[2]
    for i = 1, steps do
        local angle = field.sample(x, y)
        x = x + math.cos(angle) * stepSize
        y = y + math.sin(angle) * stepSize
        table.insert(points, {x, y})
    end
    return geo.polyline(points)
end

return M
