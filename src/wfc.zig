//! Wave function collapse after Maxim Gumin,
//! https://github.com/mxgmn/WaveFunctionCollapse. The simple tiled model
//! matches edge sockets, the overlapping model grows a texture from the
//! n by n windows of a sample. Both share one solver.

pub const Solver = @import("wfc/Solver.zig");
pub const tiled = @import("wfc/tiled.zig");
pub const overlap = @import("wfc/overlap.zig");

test {
    _ = Solver;
    _ = tiled;
    _ = overlap;
}
