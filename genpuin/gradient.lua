local M = {}

local counter = 0

function M.linearGradient(x1, y1, x2, y2, stops)
    counter = counter + 1
    return {
        type = "linearGradient", id = "grad-" .. counter,
        x1 = x1, y1 = y1, x2 = x2, y2 = y2, stops = stops,
    }
end

function M.radialGradient(cx, cy, r, stops)
    counter = counter + 1
    return {
        type = "radialGradient", id = "grad-" .. counter,
        cx = cx, cy = cy, r = r, stops = stops,
    }
end

return M
