//! Lua state setup for the CLI. The genpuin Lua library is embedded and
//! served through package.preload. Setting GENPUIN_LUA_DIR to a repo
//! checkout loads the library from disk instead, so Lua edits need no
//! rebuild.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zlua = @import("zlua");
const lua_sources = @import("lua_sources");

const bind_field = @import("bind_field.zig");
const core = @import("core.zig");
const util = @import("util.zig");
const Lua = util.Lua;

pub const Host = util.Host;

pub const Options = struct {
    /// Directory of the script, added to package.path so scripts can
    /// require their neighbours.
    script_dir: []const u8 = ".",
    lua_dir: ?[]const u8 = null,
    /// argv for the script's global `arg`: [exe, script, extra...].
    argv: []const []const u8 = &.{},
};

/// Create a state wired to `host`. `host` must outlive the state.
pub fn create(host: *Host, opts: Options) !*Lua {
    const lua = try Lua.init(host.gpa);
    errdefer lua.deinit();
    lua.openLibs();
    util.setHost(lua, host);
    bind_field.registerMetatable(lua);

    _ = lua.getGlobal("package");
    _ = lua.getField(-1, "preload");
    lua.pushFunction(zlua.wrap(core.open));
    lua.setField(-2, "genpuin.core");
    if (opts.lua_dir == null) {
        for (lua_sources.modules) |m| {
            const name = try chunkName(host.gpa, m.name);
            defer host.gpa.free(name);
            util.loadBuffer(lua, m.source, name) catch |err| {
                std.log.err("embedded {s}: {s}", .{ m.name, lua.toString(-1) catch @errorName(err) });
                return err;
            };
            lua.setField(-2, m.name);
        }
    }
    lua.pop(1);

    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(host.gpa);
    if (opts.lua_dir) |d| try path.print(host.gpa, "{s}/?.lua;{s}/?/init.lua;", .{ d, d });
    try path.print(host.gpa, "{s}/?.lua;./?.lua;", .{opts.script_dir});
    _ = lua.getField(-1, "path");
    try path.appendSlice(host.gpa, lua.toString(-1) catch "");
    lua.pop(1);
    _ = lua.pushString(path.items);
    lua.setField(-2, "path");
    lua.pop(1);

    // arg[-1] is the executable and arg[0] the script, as in lua(1).
    lua.newTable();
    for (opts.argv, 0..) |a, i| {
        _ = lua.pushString(a);
        lua.setIndexRaw(-2, @as(i32, @intCast(i)) - 1);
    }
    lua.setGlobal("arg");
    return lua;
}

fn chunkName(gpa: Allocator, mod: []const u8) ![:0]const u8 {
    var name: std.ArrayList(u8) = .empty;
    try name.appendSlice(gpa, "@");
    for (mod) |c| try name.append(gpa, if (c == '.') '/' else c);
    if (std.mem.eql(u8, mod, "genpuin")) try name.appendSlice(gpa, "/init");
    try name.appendSlice(gpa, ".lua");
    return name.toOwnedSliceSentinel(gpa, 0);
}

/// Load and run a script, leaving its first return value on the stack.
/// On failure the error message or traceback is on top of the stack.
pub fn runScript(lua: *Lua, path: [:0]const u8) error{ScriptFailed}!void {
    _ = lua.getGlobal("debug");
    _ = lua.getField(-1, "traceback");
    lua.remove(-2);
    const handler = lua.getTop();
    util.loadFile(lua, path) catch {
        return error.ScriptFailed;
    };
    lua.protectedCall(.{ .args = 0, .results = 1, .msg_handler = handler }) catch {
        return error.ScriptFailed;
    };
    lua.remove(handler);
}
