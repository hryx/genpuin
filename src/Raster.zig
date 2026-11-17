//! An RGB image with f32 channels in 0..1, row-major and interleaved.
//! Rendering, post passes and export all work on this one type.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Raster = @This();

w: u32,
h: u32,
pix: []f32,

pub const Rgb = [3]f32;

pub fn init(gpa: Allocator, w: u32, h: u32, bg: Rgb) !Raster {
    assert(w > 0 and h > 0);
    const pix = try gpa.alloc(f32, @as(usize, w) * h * 3);
    var i: usize = 0;
    while (i < pix.len) : (i += 3) @memcpy(pix[i..][0..3], &bg);
    return .{ .w = w, .h = h, .pix = pix };
}

pub fn deinit(self: *Raster, gpa: Allocator) void {
    gpa.free(self.pix);
    self.* = undefined;
}

pub fn clone(self: *const Raster, gpa: Allocator) !Raster {
    return .{ .w = self.w, .h = self.h, .pix = try gpa.dupe(f32, self.pix) };
}

pub fn index(self: *const Raster, x: u32, y: u32) usize {
    assert(x < self.w and y < self.h);
    return (@as(usize, y) * self.w + x) * 3;
}

pub fn get(self: *const Raster, x: u32, y: u32) Rgb {
    const i = self.index(x, y);
    return self.pix[i..][0..3].*;
}

pub fn set(self: *Raster, x: u32, y: u32, c: Rgb) void {
    const i = self.index(x, y);
    self.pix[i..][0..3].* = c;
}

/// Clamped read, for passes that sample outside the image.
pub fn getClamped(self: *const Raster, x: i64, y: i64) Rgb {
    const cx: u32 = @intCast(std.math.clamp(x, 0, @as(i64, self.w) - 1));
    const cy: u32 = @intCast(std.math.clamp(y, 0, @as(i64, self.h) - 1));
    return self.get(cx, cy);
}

/// Box-filter downsample by an integer factor. Used for supersampling.
pub fn downsample(self: *const Raster, gpa: Allocator, factor: u32) !Raster {
    assert(factor >= 1);
    assert(self.w % factor == 0 and self.h % factor == 0);
    const w = self.w / factor;
    const h = self.h / factor;
    var out: Raster = try .init(gpa, w, h, .{ 0, 0, 0 });
    const inv: f32 = 1.0 / @as(f32, @floatFromInt(factor * factor));
    for (0..h) |y| {
        for (0..w) |x| {
            var acc: @Vector(3, f32) = @splat(0);
            for (0..factor) |sy| {
                for (0..factor) |sx| {
                    const c = self.get(@intCast(x * factor + sx), @intCast(y * factor + sy));
                    acc += c;
                }
            }
            out.set(@intCast(x), @intCast(y), acc * @as(@Vector(3, f32), @splat(inv)));
        }
    }
    return out;
}

/// Nearest-neighbor resize to an exact size. Used for contact sheet tiles.
pub fn resizeBox(self: *const Raster, gpa: Allocator, w: u32, h: u32) !Raster {
    var out: Raster = try .init(gpa, w, h, .{ 0, 0, 0 });
    const sx: f32 = @as(f32, @floatFromInt(self.w)) / @as(f32, @floatFromInt(w));
    const sy: f32 = @as(f32, @floatFromInt(self.h)) / @as(f32, @floatFromInt(h));
    for (0..h) |y| {
        const y0: u32 = @intFromFloat(@as(f32, @floatFromInt(y)) * sy);
        const y1: u32 = @max(y0 + 1, @min(self.h, @as(u32, @intFromFloat(@as(f32, @floatFromInt(y + 1)) * sy))));
        for (0..w) |x| {
            const x0: u32 = @intFromFloat(@as(f32, @floatFromInt(x)) * sx);
            const x1: u32 = @max(x0 + 1, @min(self.w, @as(u32, @intFromFloat(@as(f32, @floatFromInt(x + 1)) * sx))));
            var acc: @Vector(3, f32) = @splat(0);
            var n: f32 = 0;
            var yy = y0;
            while (yy < y1) : (yy += 1) {
                var xx = x0;
                while (xx < x1) : (xx += 1) {
                    acc += self.get(xx, yy);
                    n += 1;
                }
            }
            out.set(@intCast(x), @intCast(y), acc / @as(@Vector(3, f32), @splat(n)));
        }
    }
    return out;
}

/// Copy `src` into this raster with its top-left at (x, y), clipped.
pub fn blit(self: *Raster, src: *const Raster, x: i64, y: i64) void {
    for (0..src.h) |sy| {
        const ty = y + @as(i64, @intCast(sy));
        if (ty < 0 or ty >= self.h) continue;
        for (0..src.w) |sx| {
            const tx = x + @as(i64, @intCast(sx));
            if (tx < 0 or tx >= self.w) continue;
            self.set(@intCast(tx), @intCast(ty), src.get(@intCast(sx), @intCast(sy)));
        }
    }
}

pub fn luminance(c: Rgb) f32 {
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}

test "Raster: downsample averages blocks" {
    const gpa = std.testing.allocator;
    var r: Raster = try .init(gpa, 4, 2, .{ 0, 0, 0 });
    defer r.deinit(gpa);
    r.set(0, 0, .{ 1, 1, 1 });
    r.set(1, 1, .{ 1, 0, 0 });
    var d = try r.downsample(gpa, 2);
    defer d.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 2), d.w);
    try std.testing.expectEqual(Rgb{ 0.5, 0.25, 0.25 }, d.get(0, 0));
    try std.testing.expectEqual(Rgb{ 0, 0, 0 }, d.get(1, 0));
}
