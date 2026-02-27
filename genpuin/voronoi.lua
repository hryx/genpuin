local geo = require("genpuin.geo")

local M = {}

-- Sutherland-Hodgman clip of polygon against a half-plane.
-- Keeps the side where dot(p - point, normal) <= 0.
local function clipPolygon(poly, px, py, nx, ny)
    local out = {}
    local n = #poly
    if n == 0 then return out end

    local prev = poly[n]
    local prevDot = (prev[1] - px) * nx + (prev[2] - py) * ny

    for i = 1, n do
        local curr = poly[i]
        local currDot = (curr[1] - px) * nx + (curr[2] - py) * ny

        if currDot <= 0 then
            if prevDot > 0 then
                local t = prevDot / (prevDot - currDot)
                out[#out + 1] = {
                    prev[1] + t * (curr[1] - prev[1]),
                    prev[2] + t * (curr[2] - prev[2]),
                }
            end
            out[#out + 1] = curr
        elseif prevDot <= 0 then
            local t = prevDot / (prevDot - currDot)
            out[#out + 1] = {
                prev[1] + t * (curr[1] - prev[1]),
                prev[2] + t * (curr[2] - prev[2]),
            }
        end

        prev = curr
        prevDot = currDot
    end

    return out
end

-- Clip bounding rect against all other sites for site at index idx.
-- Returns raw point array.
local function clipCell(sites, idx, bx, by, bw, bh)
    local cell = {{bx, by}, {bx + bw, by}, {bx + bw, by + bh}, {bx, by + bh}}
    local site = sites[idx]
    local sx, sy = site[1], site[2]

    for j = 1, #sites do
        if j ~= idx then
            local other = sites[j]
            local mx = (sx + other[1]) * 0.5
            local my = (sy + other[2]) * 0.5
            local nx = other[1] - sx
            local ny = other[2] - sy
            cell = clipPolygon(cell, mx, my, nx, ny)
            if #cell == 0 then break end
        end
    end

    return cell
end

-- Proper polygon centroid using the signed-area formula.
local function polygonCentroid(points)
    local n = #points
    if n == 0 then return {0, 0} end
    if n == 1 then return {points[1][1], points[1][2]} end
    if n == 2 then
        return {(points[1][1] + points[2][1]) * 0.5,
                (points[1][2] + points[2][2]) * 0.5}
    end

    local area = 0
    local cx, cy = 0, 0
    for i = 1, n do
        local j = (i % n) + 1
        local cross = points[i][1] * points[j][2] - points[j][1] * points[i][2]
        area = area + cross
        cx = cx + (points[i][1] + points[j][1]) * cross
        cy = cy + (points[i][2] + points[j][2]) * cross
    end

    area = area * 0.5
    if math.abs(area) < 1e-10 then
        cx, cy = 0, 0
        for i = 1, n do
            cx = cx + points[i][1]
            cy = cy + points[i][2]
        end
        return {cx / n, cy / n}
    end

    local factor = 1 / (6 * area)
    return {cx * factor, cy * factor}
end

function M.voronoi(sites, bounds)
    local bx, by, bw, bh = bounds[1], bounds[2], bounds[3], bounds[4]
    local cells = {}

    for i = 1, #sites do
        local cell = clipCell(sites, i, bx, by, bw, bh)
        if #cell >= 3 then
            cells[#cells + 1] = {
                site = sites[i],
                cell = geo.polygon(cell),
            }
        end
    end

    return cells
end

function M.relax(sites, bounds, iterations)
    iterations = iterations or 5
    local bx, by, bw, bh = bounds[1], bounds[2], bounds[3], bounds[4]

    local pts = {}
    for i = 1, #sites do
        pts[i] = {sites[i][1], sites[i][2]}
    end

    for _ = 1, iterations do
        for i = 1, #pts do
            local cell = clipCell(pts, i, bx, by, bw, bh)
            if #cell >= 3 then
                pts[i] = polygonCentroid(cell)
            end
        end
    end

    return pts
end

return M
