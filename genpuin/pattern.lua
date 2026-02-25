local M = {}

function M.grid(cols, rows, spacing, fn)
    for row = 0, rows - 1 do
        for col = 0, cols - 1 do
            fn(col * spacing, row * spacing, col, row)
        end
    end
end

function M.radial(n, center, radius, fn)
    for i = 0, n - 1 do
        local angle = (i / n) * 2 * math.pi
        local x = center[1] + radius * math.cos(angle)
        local y = center[2] + radius * math.sin(angle)
        fn({x, y}, angle, i)
    end
end

function M.scatter(n, bounds, fn)
    local rand = require("genpuin.rand")
    local bx, by, bw, bh = bounds[1], bounds[2], bounds[3], bounds[4]
    for i = 0, n - 1 do
        local pos = {bx + rand.rand() * bw, by + rand.rand() * bh}
        fn(pos, i)
    end
end

return M
