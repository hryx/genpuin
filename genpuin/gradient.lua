local M = {}

local counter = 0

-- Create a linear gradient between (x1,y1) and (x2,y2).
-- stops is a list of {offset, color} pairs.
function M.linearGradient(x1, y1, x2, y2, stops)
    counter = counter + 1
    return {
        type = "linearGradient", id = "grad-" .. counter,
        x1 = x1, y1 = y1, x2 = x2, y2 = y2, stops = stops,
    }
end

-- Create a radial gradient centered at (cx,cy) with radius r.
-- stops is a list of {offset, color} pairs.
function M.radialGradient(cx, cy, r, stops)
    counter = counter + 1
    return {
        type = "radialGradient", id = "grad-" .. counter,
        cx = cx, cy = cy, r = r, stops = stops,
    }
end

return M
