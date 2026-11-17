//! genpuin core: scene types, rasterizer, raster passes, fields and export.
//! The CLI binds it to Lua in src/lua/, with the script API in src/lua/prelude/.

pub const Raster = @import("Raster.zig");
pub const Field = @import("Field.zig");
pub const coverage = @import("coverage.zig");
pub const scene = @import("scene.zig");
pub const render = @import("render.zig");
pub const passes = @import("passes.zig");
pub const image_io = @import("image_io.zig");
pub const sheet = @import("sheet.zig");
pub const noise = @import("noise.zig");
pub const density = @import("density.zig");
pub const sim = @import("sim.zig");
pub const pathops = @import("pathops.zig");
pub const wfc = @import("wfc.zig");
pub const algo = @import("algo.zig");
pub const libm = @import("libm.zig");

test {
    _ = Raster;
    _ = Field;
    _ = coverage;
    _ = scene;
    _ = render;
    _ = passes;
    _ = image_io;
    _ = sheet;
    _ = noise;
    _ = density;
    _ = sim;
    _ = pathops;
    _ = wfc;
    _ = algo;
    _ = libm;
}
