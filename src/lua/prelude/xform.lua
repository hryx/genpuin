-- Affine transforms on shape tables. Each returns a new shape and leaves the
-- input alone. The geometry is in Zig (src/algo/xform.zig).
--
-- Shapes the renderer only knows axis aligned (rect, ellipse, circle) keep
-- their type while the transform allows it, and otherwise become a polygon
-- flattened at about one point per unit of length. A transformed arc stays an
-- arc under rotation, uniform scale and reflection. A non-uniform scale would
-- make it elliptical, which neither the arc shape nor a polyline (it would lose
-- the pie fill) can stand in for, so that raises an error. A field image only
-- takes translation and positive axis scales, anything else raises an error.

local import = ...
local X = import("core").xform

local M = {}

-- Translate a shape by (dx, dy).
M.translate = X.translate

-- Rotate a shape around the origin by the given angle in radians.
-- Rects and non-circular ellipses become polygons unless the angle is a
-- multiple of a quarter turn. Arcs keep their type with both angles turned.
M.rotate = X.rotate

-- Rotate a shape around a pivot point by the given angle in radians.
-- Shape types change as for rotate.
M.rotateAround = X.rotateAround

-- Scale a shape from the origin. If sy is omitted, scales uniformly.
-- A circle under a non-uniform scale becomes an ellipse. An arc raises an
-- error unless |sx| equals |sy|.
M.scale = X.scale

-- Scale a shape around a pivot point. Shape types change as for scale.
M.scaleAround = X.scaleAround

-- Reflect a shape across the Y axis (negate x).
M.reflectX = X.reflectX

-- Reflect a shape across the X axis (negate y).
M.reflectY = X.reflectY

-- Reflect a shape across an arbitrary axis through center at the given angle.
-- Rects and non-circular ellipses become polygons unless the axis is a
-- multiple of 45 degrees.
M.reflect = X.reflect

-- n-fold kaleidoscope: for each shape and each slice i from 0 to n - 1, a
-- copy rotated by i slices around center and one reflected across the axis
-- at (i + 1) / 2 slices.
M.kaleidoscope = X.kaleidoscope

return M
