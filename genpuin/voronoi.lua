local geo = require("genpuin.geo")
local algo = require("genpuin.core").algo

local M = {}

-- Compute Voronoi cells for a set of sites within bounds {x, y, w, h}.
-- Returns a list of {site, cell} where cell is a polygon shape. Sites
-- whose cell is empty inside the bounds are left out.
function M.voronoi(sites, bounds)
    local cells, index = algo.voronoi(sites, bounds)
    local out = {}
    for k = 1, #cells do
        out[k] = {site = sites[index[k]], cell = geo.polygon(cells[k])}
    end
    return out
end

-- Lloyd relaxation: move each site to its cell centroid, repeated
-- iterations times (default 5). Returns new points.
function M.relax(sites, bounds, iterations)
    return algo.relax(sites, bounds, iterations or 5)
end

return M
