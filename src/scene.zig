//! The display list a canvas becomes when it is rendered. Built by the
//! Lua marshaller in an arena and read by `render`.

const std = @import("std");

const Field = @import("Field.zig");
const coverage = @import("coverage.zig");
const passes = @import("passes.zig");

pub const Vec2 = coverage.Vec2;
pub const Cap = coverage.Cap;
pub const Rgba = [4]f32;

pub const Scene = struct {
    w: f64,
    h: f64,
    bg: [3]f32,
    items: []const Item,
    /// Named runs of items, in item order and disjoint. Rendering ignores
    /// them. SVG export writes each as a group.
    layers: []const Layer = &.{},
};

pub const Item = union(enum) {
    draw: Draw,
    pass: Post,
};

pub const Post = struct {
    pass: passes.Pass,
    /// The script's name for the pass, such as "pixelSort".
    name: []const u8 = "",
    /// Where the script added it, as "file:line", for error messages.
    where: []const u8 = "",
};

/// Items [item_first, item_end) of the scene.
pub const Layer = struct {
    name: []const u8,
    item_first: usize,
    item_end: usize,
};

pub const Draw = struct {
    shape: Shape,
    style: Style,
};

pub const Shape = union(enum) {
    line: [2]Vec2,
    polyline: []const Vec2,
    polygon: []const Vec2,
    circle: struct { c: Vec2, r: f64 },
    ellipse: struct { c: Vec2, rx: f64, ry: f64 },
    arc: struct { c: Vec2, r: f64, start: f64, end: f64 },
    rect: struct { x: f64, y: f64, w: f64, h: f64, rx: f64 = 0, ry: f64 = 0 },
    bezier: [4]Vec2,
    spline: []const Vec2,
    compound: []const []const Vec2,
    field: FieldImage,
};

/// A Field stretched over a rectangle and colored through a palette.
pub const FieldImage = struct {
    field: *const Field,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    palette: []const Stop,
    /// Values mapped to palette 0..1. Null means the field's own min/max.
    range: ?[2]f32 = null,
    tone: Tone = .linear,
    smooth: bool = true,
};

pub const Tone = union(enum) {
    linear,
    /// log(1 + k*v) / log(1 + k), for density renders.
    log: f32,
    gamma: f32,
};

pub const Stop = struct {
    offset: f32,
    color: Rgba,
};

pub const Gradient = struct {
    geometry: union(enum) {
        linear: struct { a: Vec2, b: Vec2 },
        radial: struct { c: Vec2, r: f64 },
    },
    stops: []const Stop,
};

pub const Paint = union(enum) {
    none,
    solid: Rgba,
    gradient: *const Gradient,
};

pub const Blend = enum { normal, multiply, screen, overlay, darken, lighten, difference, exclusion, add };

pub const ColorMap = struct {
    m: [3][4]f32,
    /// Elements sharing a matrix share one record of how far each pixel
    /// is remapped, so a pixel is remapped in full at most once per
    /// matrix (the SVG filter applies per group).
    key: u32,
};

pub const Style = struct {
    fill: Paint = .none,
    stroke: Paint = .none,
    opacity: f32 = 1,
    fill_opacity: f32 = 1,
    stroke_opacity: f32 = 1,
    stroke_width: f64 = 1,
    cap: Cap = .butt,
    dash: ?[2]f64 = null,
    dash_offset: f64 = 0,
    blend: Blend = .normal,
    color_map: ?ColorMap = null,
};

pub fn samplePalette(stops: []const Stop, t_in: f32) Rgba {
    std.debug.assert(stops.len > 0);
    const t = std.math.clamp(t_in, 0, 1);
    if (t <= stops[0].offset) return stops[0].color;
    for (stops[1..], 1..) |s, i| {
        if (t <= s.offset) {
            const p = stops[i - 1];
            const span = s.offset - p.offset;
            const k: f32 = if (span > 0) (t - p.offset) / span else 1;
            var out: Rgba = undefined;
            for (0..4) |c| out[c] = std.math.lerp(p.color[c], s.color[c], k);
            return out;
        }
    }
    return stops[stops.len - 1].color;
}
