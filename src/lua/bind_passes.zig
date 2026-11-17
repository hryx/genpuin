//! core.post: raster pass parsing. Stub until the passes extension lands.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zlua = @import("zlua");
const genpuin = @import("genpuin");

const util = @import("util.zig");
const Lua = util.Lua;
const Pass = genpuin.passes.Pass;

pub const functions = [_]zlua.FnReg{};

/// Build a Pass from its name and the options table at `opts`.
pub fn parse(lua: *Lua, arena: Allocator, name: []const u8, opts: i32) !Pass {
    _ = arena;
    _ = opts;
    const tag = std.meta.stringToEnum(std.meta.Tag(Pass), name) orelse
        lua.raiseErrorStr("unknown post pass '%s'", .{(try lua.allocator().dupeSentinel(u8, name, 0)).ptr});
    return switch (tag) {
        .invert => .invert,
    };
}
