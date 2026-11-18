local import = ...
local algo = import("core").algo

local M = {}

-- 1D elementary cellular automaton (Wolfram rules 0-255).
-- Returns all generations as rows[generation][cell], values 0 or 1.
-- Toroidal (wrapping) boundary.
-- init: optional 1D array for initial state (default: single 1 at center).
M.elementary = algo.elementary

-- Evolve a 2D grid by one generation.
-- grid: [y][x] 2D array of values.
-- rule(value, neighbors, x, y) -> new value
--   neighbors: {NW, N, NE, W, E, SW, S, SE} (Moore neighborhood)
-- opts: {wrap = true/false} (default true, toroidal boundary)
-- With gen.life as the rule on a grid of numbers the step runs in Zig.
function M.step(grid, rule, opts)
    local wrap = true
    if opts and opts.wrap == false then wrap = false end

    local height = #grid
    if height == 0 then return {} end
    if rule == M.life then
        local next = algo.lifeStep(grid, wrap)
        if next then return next end
    end
    local width = #grid[1]

    local function get(y, x)
        if wrap then
            return grid[((y - 1) % height) + 1][((x - 1) % width) + 1]
        else
            if y < 1 or y > height or x < 1 or x > width then return 0 end
            return grid[y][x]
        end
    end

    local next = {}
    for y = 1, height do
        next[y] = {}
        for x = 1, width do
            local neighbors = {
                get(y - 1, x - 1), get(y - 1, x), get(y - 1, x + 1),
                get(y, x - 1),                     get(y, x + 1),
                get(y + 1, x - 1), get(y + 1, x), get(y + 1, x + 1),
            }
            next[y][x] = rule(grid[y][x], neighbors, x, y)
        end
    end

    return next
end

-- Conway's Game of Life rule (B3/S23).
function M.life(value, neighbors)
    local count = 0
    for i = 1, 8 do
        if neighbors[i] ~= 0 then count = count + 1 end
    end
    if value ~= 0 then
        return (count == 2 or count == 3) and 1 or 0
    else
        return (count == 3) and 1 or 0
    end
end

return M
