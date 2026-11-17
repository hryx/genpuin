//! Raster post passes. A pass sits in the display list between draws and
//! rewrites the pixels drawn so far.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Raster = @import("Raster.zig");

pub const Pass = union(enum) {
    invert,
};

pub const Context = struct {
    /// Pixels per scene unit, so pass distances can be given in scene units.
    scale: f64,
};

pub fn apply(gpa: Allocator, r: *Raster, pass: *const Pass, ctx: Context) !void {
    _ = gpa;
    _ = ctx;
    switch (pass.*) {
        .invert => for (r.pix) |*v| {
            v.* = 1 - v.*;
        },
    }
}
