//! Lua state setup for the CLI. The prelude in src/lua/prelude/ is
//! embedded and loaded privately, out of reach of `require`. Each prelude
//! chunk gets an `import(name)` function as its argument, which runs a
//! sibling file once and caches its result. The native module is
//! imported as "core". Before a script runs, the prelude's init.lua is
//! installed as the global `gen` and global reads turn strict (see
//! prelude/strict.lua). Setting GENPUIN_LUA_DIR to a prelude directory,
//! such as src/lua/prelude in a checkout, loads the same files from disk
//! instead, so prelude edits need no rebuild. Files new since the build
//! are not picked up. The math table is evened out across Lua flavours
//! by bind_libm.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;

const zlua = @import("zlua");
const lua_sources = @import("lua_sources");

const bind_field = @import("bind_field.zig");
const bind_libm = @import("bind_libm.zig");
const core = @import("core.zig");
const util = @import("util.zig");
const Lua = util.Lua;

pub const Host = util.Host;

pub const Options = struct {
    /// Directory of the script, added to package.path so scripts can
    /// require their neighbours.
    script_dir: []const u8 = ".",
    /// Prelude directory to load instead of the embedded copy.
    lua_dir: ?[]const u8 = null,
    /// argv for the script's global `arg`: [exe, script, extra...].
    argv: []const []const u8 = &.{},
};

/// Called with the table of prelude chunks and the native module opener.
/// Returns `import`, which the host keeps in the registry.
const boot =
    \\local chunks, openCore = ...
    \\local loaded = {core = openCore()}
    \\local function import(name)
    \\    local m = loaded[name]
    \\    if m == nil then
    \\        local chunk = chunks[name] or error("prelude has no module " .. name)
    \\        m = chunk(import)
    \\        loaded[name] = m
    \\    end
    \\    return m
    \\end
    \\import("strict").globals()
    \\gen = import("init")
    \\return import
;

const import_key = "genpuin.import";

/// Create a state wired to `host`. `host` must outlive the state.
pub fn create(host: *Host, opts: Options) !*Lua {
    const lua = try Lua.init(host.gpa);
    errdefer lua.deinit();
    lua.openLibs();
    bind_libm.install(lua);
    util.setHost(lua, host);
    bind_field.registerMetatable(lua);

    // Only the script's neighbours and the working directory, so a Lua
    // install elsewhere on the machine cannot shadow anything.
    _ = lua.getGlobal("package");
    const path = try std.fmt.allocPrint(host.gpa, "{s}/?.lua;./?.lua", .{opts.script_dir});
    defer host.gpa.free(path);
    _ = lua.pushString(path);
    lua.setField(-2, "path");
    lua.pop(1);

    // arg[-1] is the executable and arg[0] the script, as in lua(1).
    lua.newTable();
    for (opts.argv, 0..) |a, i| {
        _ = lua.pushString(a);
        lua.setIndexRaw(-2, @as(i32, @intCast(i)) - 1);
    }
    lua.setGlobal("arg");

    util.loadBuffer(lua, boot, "=boot") catch |err| return logError(lua, "boot", err);
    lua.newTable();
    for (lua_sources.modules) |m| {
        try loadModule(lua, host.gpa, m.file, m.source, opts.lua_dir);
        lua.setField(-2, m.name);
    }
    lua.pushFunction(zlua.wrap(core.open));
    lua.protectedCall(.{ .args = 2, .results = 1 }) catch |err| return logError(lua, "prelude", err);
    lua.setField(zlua.registry_index, import_key);
    return lua;
}

/// Push the prelude module `name` (a file stem, such as "svg").
pub fn pushModule(lua: *Lua, name: [:0]const u8) void {
    _ = lua.getField(zlua.registry_index, import_key);
    _ = lua.pushStringZ(name);
    lua.call(.{ .args = 1, .results = 1 });
}

/// Push the loaded chunk for one prelude file, from `dir` when given.
fn loadModule(lua: *Lua, gpa: Allocator, file: []const u8, source: [:0]const u8, dir: ?[]const u8) !void {
    if (dir) |d| {
        const path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ d, file }, 0);
        defer gpa.free(path);
        util.loadFile(lua, path) catch |err| return logError(lua, "GENPUIN_LUA_DIR", err);
    } else {
        const name = try std.fmt.allocPrintSentinel(gpa, "@prelude/{s}", .{file}, 0);
        defer gpa.free(name);
        util.loadBuffer(lua, source, name) catch |err| return logError(lua, file, err);
    }
}

fn logError(lua: *Lua, what: []const u8, err: anyerror) anyerror {
    std.log.err("{s}: {s}", .{ what, lua.toString(-1) catch @errorName(err) });
    return err;
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
