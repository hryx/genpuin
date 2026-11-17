-- colormap.lua: derive an affine color matrix from {from, to} pairs.
--
-- Given pairs like {{from = red, to = yellow}, {from = yellow, to = red}},
-- computes a 3x4 affine matrix M such that:
--   R' = M[1][1]*R + M[1][2]*G + M[1][3]*B + M[1][4]
--   G' = M[2][1]*R + M[2][2]*G + M[2][3]*B + M[2][4]
--   B' = M[3][1]*R + M[3][2]*G + M[3][3]*B + M[3][4]
--
-- Up to three pairs give a per-channel fit with no cross-channel terms.
-- Four or more use the minimum-norm solution (pseudoinverse).
-- Colors are in [0,1] space. The solver is in Zig (src/algo/colormap.zig)
-- and the raster renderer calls it directly.

local algo = require("genpuin.core").algo

local M = {}

-- Derive the affine color matrix from color pairs.
-- Each pair is {from = {r,g,b,...}, to = {r,g,b,...}}.
-- Returns a 3x4 matrix (three rows of {a,b,c,d}).
M.solve = algo.colormapSolve

-- Apply the matrix to a color in [0,1] space. Returns r, g, b.
M.apply = algo.colormapApply

-- Convert the matrix to the SVG feColorMatrix "values" attribute string.
-- SVG uses a 4x5 row-major matrix (RGBA output x RGBA+offset input).
function M.toSvgValues(matrix)
    local m = matrix
    return string.format(
        "%g %g %g 0 %g  %g %g %g 0 %g  %g %g %g 0 %g  0 0 0 1 0",
        m[1][1], m[1][2], m[1][3], m[1][4],
        m[2][1], m[2][2], m[2][3], m[2][4],
        m[3][1], m[3][2], m[3][3], m[3][4])
end

return M
