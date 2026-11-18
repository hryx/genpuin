//! Vector path operations: polygon booleans, signed distance fields,
//! contour tracing, offsets, hatching, simplification and plotter path
//! ordering. Everything works on plain point slices and Fields.

pub const geom = @import("pathops/geom.zig");
pub const EdgeSet = @import("pathops/EdgeSet.zig");
pub const boolean = @import("pathops/boolean.zig");
pub const sdf = @import("pathops/sdf.zig");
pub const contour = @import("pathops/contour.zig");
pub const simplify = @import("pathops/simplify.zig");
pub const offset = @import("pathops/offset.zig");
pub const hatch = @import("pathops/hatch.zig");
pub const order = @import("pathops/order.zig");
pub const flatten = @import("pathops/flatten.zig");

pub const Vec2 = geom.Vec2;
pub const FillRule = geom.FillRule;

test {
    _ = geom;
    _ = EdgeSet;
    _ = boolean;
    _ = sdf;
    _ = contour;
    _ = simplify;
    _ = offset;
    _ = hatch;
    _ = order;
    _ = flatten;
}
