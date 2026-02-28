local geo = require("genpuin.geo")
local rand = require("genpuin.rand")
local xform = require("genpuin.xform")

local M = {}

M.GOLDEN_ANGLE = math.pi * (3 - math.sqrt(5))

function M.grid(cols, rows, size, fn, opts)
    -- Parse opts: string shorthand or table
    local tiling = "rect"
    local offset = nil
    if type(opts) == "string" then
        tiling = opts
    elseif type(opts) == "table" then
        tiling = opts.tiling or "rect"
        offset = opts.offset
    end

    -- Compute row offset for rect and tri tilings
    local function rowOffset(row)
        if not offset then return 0 end
        if type(offset) == "function" then return offset(row) end
        -- number: apply to odd rows
        return (row % 2 == 1) and offset or 0
    end

    if tiling == "rect" then
        for row = 0, rows - 1 do
            local dx = rowOffset(row)
            for col = 0, cols - 1 do
                fn(col * size + dx, row * size, col, row)
            end
        end

    elseif tiling == "hex" then
        local rowH = size * math.sqrt(3) / 2
        for row = 0, rows - 1 do
            local dx = (row % 2 == 1) and (size / 2) or 0
            for col = 0, cols - 1 do
                fn(col * size + dx, row * rowH, col, row)
            end
        end

    elseif tiling == "tri" then
        -- Triangular grid: alternating up/down triangles.
        -- Each cell is half the width of a rect cell.
        -- User can check (col + row) % 2 for up/down orientation.
        local halfW = size / 2
        local rowH = size * math.sqrt(3) / 2
        for row = 0, rows - 1 do
            local dx = rowOffset(row)
            for col = 0, cols - 1 do
                local up = (col + row) % 2 == 0
                local cx = col * halfW + halfW / 2 + dx
                local cy = row * rowH + (up and (rowH * 2 / 3) or (rowH / 3))
                fn(cx, cy, col, row)
            end
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
    local bx, by, bw, bh = bounds[1], bounds[2], bounds[3], bounds[4]
    for i = 0, n - 1 do
        local pos = {bx + rand.rand() * bw, by + rand.rand() * bh}
        fn(pos, i)
    end
end

function M.spiral(n, center, opts, fn)
    opts = opts or {}
    local angleInc = opts.angle or M.GOLDEN_ANGLE
    local spacing = opts.spacing or 5
    local growth = opts.growth or "sqrt"

    for i = 0, n - 1 do
        local a = i * angleInc
        local r
        if growth == "sqrt" then
            r = spacing * math.sqrt(i)
        else -- "linear"
            r = spacing * i
        end
        local x = center[1] + r * math.cos(a)
        local y = center[2] + r * math.sin(a)
        fn({x, y}, a, i)
    end
end

function M.alongPath(path, n, fn)
    -- Sample n+2 points so we can compute tangents at endpoints
    local sampled = geo.sampleAlong(path, n + 2)
    local pts = sampled.points
    if not pts or #pts < 3 then return end

    for i = 2, #pts - 1 do
        local prev = pts[i - 1]
        local curr = pts[i]
        local next = pts[i + 1]
        local dx = next[1] - prev[1]
        local dy = next[2] - prev[2]
        local tangentAngle = math.atan2(dy, dx)
        local t = (i - 2) / math.max(n - 1, 1)
        fn(curr, tangentAngle, t)
    end
end

function M.subdivideRect(x, y, w, h, fn)
    local function recurse(rx, ry, rw, rh, depth)
        local result = fn(rx, ry, rw, rh, depth)
        if result == "h" then
            -- Split horizontally (top/bottom)
            local split = rand.rand() * 0.4 + 0.3  -- 0.3..0.7
            local h1 = rh * split
            recurse(rx, ry, rw, h1, depth + 1)
            recurse(rx, ry + h1, rw, rh - h1, depth + 1)
        elseif result == "v" then
            -- Split vertically (left/right)
            local split = rand.rand() * 0.4 + 0.3
            local w1 = rw * split
            recurse(rx, ry, w1, rh, depth + 1)
            recurse(rx + w1, ry, rw - w1, rh, depth + 1)
        end
        -- nil: stop recursion (leaf node)
    end
    recurse(x, y, w, h, 0)
end

function M.kaleidoscope(n, center, shapes)
    local result = {}
    local sliceAngle = (2 * math.pi) / n
    -- Axis angle for reflection within each slice
    for _, shape in ipairs(shapes) do
        for i = 0, n - 1 do
            local angle = i * sliceAngle
            -- Rotated copy
            local rotated = xform.rotateAround(shape, angle, center)
            result[#result + 1] = rotated
            -- Reflected + rotated copy
            local reflected = xform.reflect(shape, center, angle + sliceAngle / 2)
            result[#result + 1] = reflected
        end
    end
    return result
end

return M
