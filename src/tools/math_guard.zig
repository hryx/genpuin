//! Build-time check that every transcendental the executable can call
//! comes from the one implementation genpuin pins: compiler-rt's sin, cos,
//! tan, exp, log, log2, log10 and fmod, and std.math's others, exported by
//! src/lua/math_exports.zig.
//!
//! It fails when a transcendental is imported from a shared library,
//! which means Lua or Zig code calls the platform libm, when sin or pow is
//! not defined at all, and when a name has definitions at two addresses.
//! A name the linker dropped because nothing calls it is fine. Exact
//! operations such as floor, sqrt and ldexp may come from anywhere. Reads
//! the Mach-O or ELF symbol table with std, no host tools.

const std = @import("std");
const macho = std.macho;
const elf = std.elf;

/// The functions Lua's math library and `^` call.
const exported = [_][]const u8{
    "sin",  "cos",  "tan", "asin", "acos", "atan",  "atan2", "sinh",
    "cosh", "tanh", "exp", "log",  "log2", "log10", "pow",   "fmod",
};

/// Every Lua flavor calls these, so the binary must define them.
const always = [_][]const u8{ "sin", "pow" };

/// Results that differ between libms. Each also stands for its f and l
/// forms.
const transcendental = exported ++ [_][]const u8{
    "exp2",  "expm1", "log1p", "cbrt", "hypot", "sincos", "__sincos_stret", "exp10", "__exp10",
    "asinh", "acosh", "atanh", "erf",  "erfc",  "lgamma", "tgamma",
};

fn transcendentalIndex(name: []const u8) ?usize {
    for (transcendental, 0..) |base, i| {
        if (!std.mem.startsWith(u8, name, base)) continue;
        const rest = name[base.len..];
        if (rest.len == 0) return i;
        if (rest.len == 1 and (rest[0] == 'f' or rest[0] == 'l')) return i;
    }
    return null;
}

fn exportedIndex(name: []const u8) ?usize {
    for (exported, 0..) |e, i| if (std.mem.eql(u8, e, name)) return i;
    return null;
}

const Error = error{ Truncated, UnknownFormat };

fn read(comptime T: type, bytes: []const u8, offset: u64) Error!T {
    if (offset + @sizeOf(T) > bytes.len) return error.Truncated;
    const o: usize = @intCast(offset);
    return std.mem.bytesToValue(T, bytes[o..][0..@sizeOf(T)]);
}

fn cString(bytes: []const u8, offset: u64) []const u8 {
    if (offset >= bytes.len) return "";
    return std.mem.sliceTo(bytes[@intCast(offset)..], 0);
}

const Symbol = union(enum) {
    undefined,
    defined: u64,
};

const Report = struct {
    /// Address of the first definition seen for each exported name.
    address: [exported.len]?u64 = @splat(null),
    /// Set when the name has definitions at two addresses.
    stray: [exported.len]bool = @splat(false),
    /// Transcendentals that some table lists as undefined.
    imported: [transcendental.len * 3][]const u8 = undefined,
    imported_len: usize = 0,
    tables: u32 = 0,

    fn add(r: *Report, name: []const u8, sym: Symbol) void {
        switch (sym) {
            .undefined => {
                if (transcendentalIndex(name) == null) return;
                for (r.imported[0..r.imported_len]) |n| if (std.mem.eql(u8, n, name)) return;
                if (r.imported_len < r.imported.len) {
                    r.imported[r.imported_len] = name;
                    r.imported_len += 1;
                }
            },
            .defined => |address| {
                const i = exportedIndex(name) orelse return;
                if (r.address[i] == null) r.address[i] = address;
                if (r.address[i].? != address) r.stray[i] = true;
            },
        }
    }

    fn nameOk(r: *const Report, i: usize) bool {
        if (r.address[i] == null) {
            for (always) |a| if (std.mem.eql(u8, a, exported[i])) return false;
            return true;
        }
        return !r.stray[i];
    }

    fn ok(r: *const Report) bool {
        for (0..exported.len) |i| if (!r.nameOk(i)) return false;
        return r.imported_len == 0;
    }
};

fn scanMachO(bytes: []const u8, r: *Report) Error!void {
    const header = try read(macho.mach_header_64, bytes, 0);
    var offset: u64 = @sizeOf(macho.mach_header_64);
    for (0..header.ncmds) |_| {
        const lc = try read(macho.load_command, bytes, offset);
        if (lc.cmd == .SYMTAB) {
            const st = try read(macho.symtab_command, bytes, offset);
            r.tables += 1;
            for (0..st.nsyms) |i| {
                const sym = try read(macho.nlist_64, bytes, st.symoff + i * @sizeOf(macho.nlist_64));
                const bits = sym.n_type.bits;
                if (bits.is_stab != 0) continue;
                const name = cString(bytes, @as(u64, st.stroff) + sym.n_strx);
                if (name.len < 2 or name[0] != '_') continue;
                r.add(name[1..], if (bits.type == .undf) .undefined else .{ .defined = sym.n_value });
            }
        }
        if (lc.cmdsize == 0) return error.Truncated;
        offset += lc.cmdsize;
    }
}

fn scanElf(bytes: []const u8, r: *Report) Error!void {
    const shoff = try read(u64, bytes, @offsetOf(elf.Elf64_Ehdr, "e_shoff"));
    const shentsize = try read(u16, bytes, @offsetOf(elf.Elf64_Ehdr, "e_shentsize"));
    const shnum = try read(u16, bytes, @offsetOf(elf.Elf64_Ehdr, "e_shnum"));
    for (0..shnum) |i| {
        const sh = try read(elf.Elf64_Shdr, bytes, shoff + i * shentsize);
        if (sh.sh_type != elf.SHT_SYMTAB and sh.sh_type != elf.SHT_DYNSYM) continue;
        const strtab = try read(elf.Elf64_Shdr, bytes, shoff + @as(u64, sh.sh_link) * shentsize);
        if (sh.sh_type == elf.SHT_SYMTAB) r.tables += 1;
        const count = sh.sh_size / @sizeOf(elf.Elf64_Sym);
        for (0..count) |k| {
            const sym = try read(elf.Elf64_Sym, bytes, sh.sh_offset + k * @sizeOf(elf.Elf64_Sym));
            const name = cString(bytes, strtab.sh_offset + sym.st_name);
            if (name.len == 0) continue;
            r.add(name, if (sym.st_shndx == elf.SHN_UNDEF) .undefined else .{ .defined = sym.st_value });
        }
    }
}

fn scan(bytes: []const u8, r: *Report) Error!void {
    if (bytes.len >= 4 and std.mem.readInt(u32, bytes[0..4], .little) == macho.MH_MAGIC_64) return scanMachO(bytes, r);
    if (bytes.len >= 5 and std.mem.eql(u8, bytes[0..4], elf.MAGIC) and bytes[elf.EI.CLASS] == elf.ELFCLASS64 and
        bytes[elf.EI.DATA] == elf.ELFDATA2LSB) return scanElf(bytes, r);
    return error.UnknownFormat;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) {
        std.debug.print("usage: math_guard <executable>\n", .{});
        std.process.exit(2);
    }
    const exe = args[1];
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, exe, arena, .limited(1 << 30));
    var r: Report = .{};
    scan(bytes, &r) catch |err| switch (err) {
        error.UnknownFormat => {
            std.debug.print("math guard: {s} is not 64-bit little-endian Mach-O or ELF, not checked\n", .{exe});
            return;
        },
        error.Truncated => {
            std.debug.print("math guard: {s} is truncated\n", .{exe});
            std.process.exit(1);
        },
    };
    if (r.tables == 0) {
        std.debug.print("math guard: {s} has no symbol table, so it cannot be checked\n", .{exe});
        std.process.exit(1);
    }
    if (r.ok()) return;

    std.debug.print("math guard: {s} does not run genpuin's math for every script math call.\n", .{exe});
    for (exported, 0..) |name, i| {
        if (r.nameOk(i)) continue;
        if (r.address[i] == null) {
            std.debug.print("  {s} is not defined\n", .{name});
        } else {
            std.debug.print("  {s} is defined at two addresses\n", .{name});
        }
    }
    for (r.imported[0..r.imported_len]) |name| {
        std.debug.print("  {s} is imported from a shared library\n", .{name});
    }
    std.debug.print(
        \\Lua's math.* and ^ and LuaJIT's traces must bind to compiler-rt and
        \\the exports in src/lua/math_exports.zig, whose anchor keeps
        \\compiler-rt loaded. Zig code must call src/math.zig instead of
        \\@sin, @exp, std.math.pow and friends.
        \\
    , .{});
    std.process.exit(1);
}

test "math guard: matches transcendental names and their float and long forms" {
    try std.testing.expect(transcendentalIndex("sin") != null);
    try std.testing.expect(transcendentalIndex("powf") != null);
    try std.testing.expect(transcendentalIndex("__sincos_stret") != null);
    try std.testing.expect(transcendentalIndex("expl") != null);
    try std.testing.expect(transcendentalIndex("sinq") == null);
    try std.testing.expect(transcendentalIndex("single") == null);
    try std.testing.expect(transcendentalIndex("floor") == null);
    try std.testing.expect(transcendentalIndex("ldexp") == null);
}

test "math guard: names are defined once and never imported" {
    var r: Report = .{};
    inline for (exported, 0..) |name, i| r.add(name, .{ .defined = 0x1000 + i });
    try std.testing.expect(r.ok());
    r.add("sin", .{ .defined = 0x2000 });
    try std.testing.expect(!r.ok());

    r = .{};
    r.add("sin", .{ .defined = 0x1000 });
    r.add("pow", .{ .defined = 0x1100 });
    try std.testing.expect(r.ok());
    r.add("expf", .undefined);
    try std.testing.expect(!r.ok());

    r = .{};
    r.add("pow", .{ .defined = 0x1100 });
    try std.testing.expect(!r.ok());
}
