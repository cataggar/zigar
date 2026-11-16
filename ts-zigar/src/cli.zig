const std = @import("std");

pub const version_string = "0.17.0 (TypeScript 7.1.0)";

pub const help_text =
    \\Usage: ts-zigar [options]
    \\       zigar ts [options]
    \\       ts2zig [options]
    \\
    \\Generate Zig 0.17 bindings from TypeScript (.d.ts / .ts) declarations using
    \\the embedded TypeScript 7.1 WASM Component compiler and semantic extractor.
    \\
    \\Options:
    \\  -t, --types <path>          Input .d.ts / .ts file or package directory (repeatable, required)
    \\  -d, --out-dir <dir>         Output directory for generated .zig modules (required)
    \\  -m, --module <name>         Emit only matching module(s) and their dependencies (repeatable)
    \\  -s, --substitute <from=to>  Substitute module/namespace path prefix (repeatable, e.g. node:fs=fs)
    \\      --component <path>      Override path to typescript-compiler.component.wasm
    \\  -h, --help                  Print this help message and exit
    \\  -v, --version               Print version information and exit
    \\
;

pub const Substitution = struct {
    from: []const u8,
    to: []const u8,

    pub fn deinit(self: Substitution, allocator: std.mem.Allocator) void {
        allocator.free(self.from);
        allocator.free(self.to);
    }
};

pub const CliOptions = struct {
    types_paths: [][]const u8,
    out_dir: []const u8,
    modules: [][]const u8,
    substitutions: []Substitution,
    component_path: ?[]const u8,

    pub fn deinit(self: *CliOptions, allocator: std.mem.Allocator) void {
        for (self.types_paths) |p| allocator.free(p);
        allocator.free(self.types_paths);

        allocator.free(self.out_dir);

        for (self.modules) |m| allocator.free(m);
        allocator.free(self.modules);

        for (self.substitutions) |s| s.deinit(allocator);
        allocator.free(self.substitutions);

        if (self.component_path) |cp| allocator.free(cp);
        self.* = undefined;
    }
};

pub const ParseOutcome = union(enum) {
    help,
    version,
    run: CliOptions,
    err: []u8,

    pub fn deinit(self: *ParseOutcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .help, .version => {},
            .run => |*opts| opts.deinit(allocator),
            .err => |msg| allocator.free(msg),
        }
    }
};

pub fn parseSubstituteRule(allocator: std.mem.Allocator, raw: []const u8) !Substitution {
    const eq_idx = std.mem.indexOfScalar(u8, raw, '=') orelse return error.MissingEquals;
    const from_raw = std.mem.trim(u8, raw[0..eq_idx], " \t");
    const to_raw = std.mem.trim(u8, raw[eq_idx + 1 ..], " \t");
    if (from_raw.len == 0) return error.EmptyFrom;
    if (to_raw.len == 0) return error.EmptyTo;
    if (std.mem.indexOfScalar(u8, to_raw, '=') != null) return error.MultipleEquals;

    const from_owned = try allocator.dupe(u8, from_raw);
    errdefer allocator.free(from_owned);
    const to_owned = try allocator.dupe(u8, to_raw);

    return .{
        .from = from_owned,
        .to = to_owned,
    };
}

fn splitInlineValue(arg: []const u8, short_flag: ?[]const u8, long_flag: []const u8) ?[]const u8 {
    if (short_flag) |sf| {
        if (std.mem.startsWith(u8, arg, sf) and arg.len > sf.len and arg[sf.len] == '=') {
            return arg[sf.len + 1 ..];
        }
    }
    if (std.mem.startsWith(u8, arg, long_flag) and arg.len > long_flag.len and arg[long_flag.len] == '=') {
        return arg[long_flag.len + 1 ..];
    }
    return null;
}

/// Parses CLI arguments (excluding `argv[0]`). Never panics on user input; returns `.err` with a
/// clear human-readable message for missing/invalid options.
pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) std.mem.Allocator.Error!ParseOutcome {
    var types_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (types_list.items) |p| allocator.free(p);
        types_list.deinit(allocator);
    }

    var modules_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (modules_list.items) |m| allocator.free(m);
        modules_list.deinit(allocator);
    }

    var subs_list: std.ArrayList(Substitution) = .empty;
    defer {
        for (subs_list.items) |s| s.deinit(allocator);
        subs_list.deinit(allocator);
    }

    var out_dir: ?[]u8 = null;
    defer if (out_dir) |d| allocator.free(d);

    var component_path: ?[]u8 = null;
    defer if (component_path) |c| allocator.free(c);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return .help;
        }
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            return .version;
        }

        if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--types")) {
            if (i + 1 >= args.len) {
                return .{ .err = try std.fmt.allocPrint(allocator, "Missing path argument for '{s}'.", .{arg}) };
            }
            i += 1;
            const val = args[i];
            if (val.len == 0) {
                return .{ .err = try std.fmt.allocPrint(allocator, "Empty path argument for '{s}'.", .{arg}) };
            }
            const duped = try allocator.dupe(u8, val);
            errdefer allocator.free(duped);
            try types_list.append(allocator, duped);
            continue;
        }
        if (splitInlineValue(arg, "-t", "--types")) |val| {
            if (val.len == 0) {
                return .{ .err = try allocator.dupe(u8, "Empty path argument for '--types'.") };
            }
            const duped = try allocator.dupe(u8, val);
            errdefer allocator.free(duped);
            try types_list.append(allocator, duped);
            continue;
        }

        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--out-dir")) {
            if (i + 1 >= args.len) {
                return .{ .err = try std.fmt.allocPrint(allocator, "Missing directory argument for '{s}'.", .{arg}) };
            }
            i += 1;
            const val = args[i];
            if (val.len == 0) {
                return .{ .err = try std.fmt.allocPrint(allocator, "Empty directory argument for '{s}'.", .{arg}) };
            }
            if (out_dir) |old| allocator.free(old);
            out_dir = try allocator.dupe(u8, val);
            continue;
        }
        if (splitInlineValue(arg, "-d", "--out-dir")) |val| {
            if (val.len == 0) {
                return .{ .err = try allocator.dupe(u8, "Empty directory argument for '--out-dir'.") };
            }
            if (out_dir) |old| allocator.free(old);
            out_dir = try allocator.dupe(u8, val);
            continue;
        }

        if (std.mem.eql(u8, arg, "-m") or std.mem.eql(u8, arg, "--module")) {
            if (i + 1 >= args.len) {
                return .{ .err = try std.fmt.allocPrint(allocator, "Missing module name for '{s}'.", .{arg}) };
            }
            i += 1;
            const val = args[i];
            if (val.len == 0) {
                return .{ .err = try std.fmt.allocPrint(allocator, "Empty module name for '{s}'.", .{arg}) };
            }
            const duped = try allocator.dupe(u8, val);
            errdefer allocator.free(duped);
            try modules_list.append(allocator, duped);
            continue;
        }
        if (splitInlineValue(arg, "-m", "--module")) |val| {
            if (val.len == 0) {
                return .{ .err = try allocator.dupe(u8, "Empty module name for '--module'.") };
            }
            const duped = try allocator.dupe(u8, val);
            errdefer allocator.free(duped);
            try modules_list.append(allocator, duped);
            continue;
        }

        if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--substitute")) {
            if (i + 1 >= args.len) {
                return .{ .err = try std.fmt.allocPrint(allocator, "Missing <from=to> rule for '{s}'.", .{arg}) };
            }
            i += 1;
            const raw_rule = args[i];
            const parsed = parseSubstituteRule(allocator, raw_rule) catch |err| {
                return .{ .err = try formatSubstituteError(allocator, raw_rule, err) };
            };
            errdefer parsed.deinit(allocator);
            try subs_list.append(allocator, parsed);
            continue;
        }
        if (splitInlineValue(arg, "-s", "--substitute")) |raw_rule| {
            const parsed = parseSubstituteRule(allocator, raw_rule) catch |err| {
                return .{ .err = try formatSubstituteError(allocator, raw_rule, err) };
            };
            errdefer parsed.deinit(allocator);
            try subs_list.append(allocator, parsed);
            continue;
        }

        if (std.mem.eql(u8, arg, "--component")) {
            if (i + 1 >= args.len) {
                return .{ .err = try allocator.dupe(u8, "Missing file path for '--component'.") };
            }
            i += 1;
            const val = args[i];
            if (val.len == 0) {
                return .{ .err = try allocator.dupe(u8, "Empty file path for '--component'.") };
            }
            if (component_path) |old| allocator.free(old);
            component_path = try allocator.dupe(u8, val);
            continue;
        }
        if (splitInlineValue(arg, null, "--component")) |val| {
            if (val.len == 0) {
                return .{ .err = try allocator.dupe(u8, "Empty file path for '--component'.") };
            }
            if (component_path) |old| allocator.free(old);
            component_path = try allocator.dupe(u8, val);
            continue;
        }

        return .{ .err = try std.fmt.allocPrint(allocator, "Unknown option or unexpected argument: '{s}'. Run with --help for usage.", .{arg}) };
    }

    if (types_list.items.len == 0) {
        return .{ .err = try allocator.dupe(u8, "Missing required option '-t, --types <path>'. Run with --help for usage.") };
    }
    const final_out_dir = out_dir orelse {
        return .{ .err = try allocator.dupe(u8, "Missing required option '-d, --out-dir <dir>'. Run with --help for usage.") };
    };

    const owned_types = try types_list.toOwnedSlice(allocator);
    errdefer {
        for (owned_types) |p| allocator.free(p);
        allocator.free(owned_types);
    }

    const owned_modules = try modules_list.toOwnedSlice(allocator);
    errdefer {
        for (owned_modules) |m| allocator.free(m);
        allocator.free(owned_modules);
    }

    const owned_subs = try subs_list.toOwnedSlice(allocator);
    errdefer {
        for (owned_subs) |s| s.deinit(allocator);
        allocator.free(owned_subs);
    }

    out_dir = null;
    const owned_comp = component_path;
    component_path = null;

    return .{
        .run = .{
            .types_paths = owned_types,
            .out_dir = final_out_dir,
            .modules = owned_modules,
            .substitutions = owned_subs,
            .component_path = owned_comp,
        },
    };
}

fn formatSubstituteError(allocator: std.mem.Allocator, raw_rule: []const u8, err: anyerror) ![]u8 {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.MissingEquals => std.fmt.allocPrint(
            allocator,
            "Invalid --substitute rule '{s}': expected '<from>=<to>' containing '='.",
            .{raw_rule},
        ),
        error.EmptyFrom => std.fmt.allocPrint(
            allocator,
            "Invalid --substitute rule '{s}': '<from>' side before '=' cannot be empty.",
            .{raw_rule},
        ),
        error.EmptyTo => std.fmt.allocPrint(
            allocator,
            "Invalid --substitute rule '{s}': '<to>' side after '=' cannot be empty.",
            .{raw_rule},
        ),
        error.MultipleEquals => std.fmt.allocPrint(
            allocator,
            "Invalid --substitute rule '{s}': expected a single '=' separating '<from>' and '<to>'.",
            .{raw_rule},
        ),
        else => std.fmt.allocPrint(allocator, "Invalid --substitute rule '{s}'.", .{raw_rule}),
    };
}

test "parseArgs parses repeatable -t, -d, repeatable -m, repeatable -s, and --component" {
    const alloc = std.testing.allocator;
    const args = [_][]const u8{
        "-t",                            "a.d.ts",
        "--types=b.d.ts",                "-d",
        "out/zig",                       "-m",
        "node:http",                     "--module=dns/promises",
        "-s",                            "node:fs=fs",
        "--substitute=foo/internal=foo", "--component",
        "custom.wasm",
    };

    var outcome = try parseArgs(alloc, &args);
    defer outcome.deinit(alloc);

    try std.testing.expect(outcome == .run);
    const opts = outcome.run;
    try std.testing.expectEqual(@as(usize, 2), opts.types_paths.len);
    try std.testing.expectEqualStrings("a.d.ts", opts.types_paths[0]);
    try std.testing.expectEqualStrings("b.d.ts", opts.types_paths[1]);
    try std.testing.expectEqualStrings("out/zig", opts.out_dir);
    try std.testing.expectEqual(@as(usize, 2), opts.modules.len);
    try std.testing.expectEqualStrings("node:http", opts.modules[0]);
    try std.testing.expectEqualStrings("dns/promises", opts.modules[1]);
    try std.testing.expectEqual(@as(usize, 2), opts.substitutions.len);
    try std.testing.expectEqualStrings("node:fs", opts.substitutions[0].from);
    try std.testing.expectEqualStrings("fs", opts.substitutions[0].to);
    try std.testing.expectEqualStrings("foo/internal", opts.substitutions[1].from);
    try std.testing.expectEqualStrings("foo", opts.substitutions[1].to);
    try std.testing.expectEqualStrings("custom.wasm", opts.component_path.?);
}

test "parseArgs handles --help, --version, missing required flags, unknown flags, and malformed -s" {
    const alloc = std.testing.allocator;

    {
        var out = try parseArgs(alloc, &.{"--help"});
        defer out.deinit(alloc);
        try std.testing.expect(out == .help);
    }
    {
        var out = try parseArgs(alloc, &.{"-v"});
        defer out.deinit(alloc);
        try std.testing.expect(out == .version);
    }
    {
        var out = try parseArgs(alloc, &.{ "-d", "out" });
        defer out.deinit(alloc);
        try std.testing.expect(out == .err);
        try std.testing.expect(std.mem.indexOf(u8, out.err, "--types") != null);
    }
    {
        var out = try parseArgs(alloc, &.{ "-t", "a.d.ts" });
        defer out.deinit(alloc);
        try std.testing.expect(out == .err);
        try std.testing.expect(std.mem.indexOf(u8, out.err, "--out-dir") != null);
    }
    {
        var out = try parseArgs(alloc, &.{ "-t", "a.d.ts", "-d", "out", "--bogus" });
        defer out.deinit(alloc);
        try std.testing.expect(out == .err);
        try std.testing.expect(std.mem.indexOf(u8, out.err, "--bogus") != null);
    }
    for ([_][]const u8{ "noequals", "=rhs", "lhs=", "a=b=c" }) |bad_sub| {
        var out = try parseArgs(alloc, &.{ "-t", "a.d.ts", "-d", "out", "-s", bad_sub });
        defer out.deinit(alloc);
        try std.testing.expect(out == .err);
        try std.testing.expect(std.mem.indexOf(u8, out.err, "--substitute") != null);
    }
}
