//! Raster export: binary PPM, and PNG at 8 or 16 bits per channel.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const zigimg = @import("zigimg");

const Raster = @import("Raster.zig");

pub const Format = enum {
    ppm,
    png,
    svg,

    pub fn fromPath(path: []const u8) ?Format {
        const ext = std.fs.path.extension(path);
        if (std.ascii.eqlIgnoreCase(ext, ".ppm")) return .ppm;
        if (std.ascii.eqlIgnoreCase(ext, ".png")) return .png;
        if (std.ascii.eqlIgnoreCase(ext, ".svg")) return .svg;
        return null;
    }
};

pub const Depth = enum { @"8", @"16" };

fn to8(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

fn to16(v: f32) u16 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 65535));
}

pub fn writePpm(io: Io, r: *const Raster, path: []const u8) !void {
    try makeParent(io, path);
    var file = try Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;
    try w.print("P6\n{d} {d}\n255\n", .{ r.w, r.h });
    for (r.pix) |v| try w.writeByte(to8(v));
    try w.flush();
}

fn toImage(gpa: Allocator, r: *const Raster, depth: Depth) !zigimg.Image {
    switch (depth) {
        .@"8" => {
            const img = try zigimg.Image.create(gpa, r.w, r.h, .rgb24);
            for (img.pixels.rgb24, 0..) |*p, i| {
                p.* = .{ .r = to8(r.pix[i * 3]), .g = to8(r.pix[i * 3 + 1]), .b = to8(r.pix[i * 3 + 2]) };
            }
            return img;
        },
        .@"16" => {
            const img = try zigimg.Image.create(gpa, r.w, r.h, .rgb48);
            for (img.pixels.rgb48, 0..) |*p, i| {
                p.* = .{ .r = to16(r.pix[i * 3]), .g = to16(r.pix[i * 3 + 1]), .b = to16(r.pix[i * 3 + 2]) };
            }
            return img;
        },
    }
}

pub fn writePng(gpa: Allocator, io: Io, r: *const Raster, path: []const u8, depth: Depth) !void {
    try makeParent(io, path);
    var img = try toImage(gpa, r, depth);
    defer img.deinit(gpa);
    var buf: [64 * 1024]u8 = undefined;
    try img.writeToFilePath(gpa, io, path, &buf, .{ .png = .{} });
}

/// PNG bytes in memory for a w by h image of straight-alpha RGBA pixels,
/// row-major.
pub fn encodePngRgba(gpa: Allocator, w: u32, h: u32, pix: []const [4]u8) ![]u8 {
    std.debug.assert(pix.len == @as(usize, w) * h);
    var img = try zigimg.Image.create(gpa, w, h, .rgba32);
    defer img.deinit(gpa);
    for (img.pixels.rgba32, pix) |*p, c| p.* = .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] };
    const cap = @as(usize, w) * h * 5 + 64 * 1024;
    const buf = try gpa.alloc(u8, cap);
    errdefer gpa.free(buf);
    const written = try img.writeToMemory(gpa, buf, .{ .png = .{} });
    return gpa.realloc(buf, written.len);
}

pub fn write(gpa: Allocator, io: Io, r: *const Raster, path: []const u8, depth: Depth) !void {
    switch (Format.fromPath(path) orelse .png) {
        .ppm => try writePpm(io, r, path),
        .png => try writePng(gpa, io, r, path, depth),
        .svg => return error.SvgIsNotRaster,
    }
}

fn makeParent(io: Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
}
