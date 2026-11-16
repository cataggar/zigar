const std = @import("std");
const cli = @import("cli.zig");
const naming = @import("naming.zig");
const ir = @import("ir.zig");
const emit = @import("emit.zig");
const host_mod = @import("host.zig");

pub const VirtualFile = struct {
    vfs_path: []const u8,
    contents: []const u8,

    pub fn deinit(self: VirtualFile, allocator: std.mem.Allocator) void {
        allocator.free(self.vfs_path);
        allocator.free(self.contents);
    }
};

pub const LoadedSources = struct {
    files: []VirtualFile,
    root_vfs_paths: [][]const u8,
    base_dir: []const u8,

    pub fn deinit(self: *LoadedSources, allocator: std.mem.Allocator) void {
        for (self.files) |f| f.deinit(allocator);
        allocator.free(self.files);
        for (self.root_vfs_paths) |p| allocator.free(p);
        allocator.free(self.root_vfs_paths);
        allocator.free(self.base_dir);
        self.* = undefined;
    }
};

pub const DriverOutcome = union(enum) {
    ok: struct {
        module_count: usize,
        file_count: usize,
    },
    err: []u8,

    pub fn deinit(self: *DriverOutcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ok => {},
            .err => |msg| allocator.free(msg),
        }
    }
};

const virtual_rel_anchor = "/__ts_zigar_cwd__/d0/d1/d2/d3";

/// Normalizes a POSIX path by collapsing `.`, `..`, and duplicate slashes, always returning an
/// owned path starting with `/`.
pub fn normalizePosixPath(allocator: std.mem.Allocator, raw_path: []const u8) ![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    var start: usize = 0;
    var i: usize = 0;
    while (i <= raw_path.len) : (i += 1) {
        const is_sep = (i == raw_path.len) or (raw_path[i] == '/') or (raw_path[i] == '\\');
        if (!is_sep) continue;
        const seg = raw_path[start..i];
        start = i + 1;
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
            continue;
        }
        try parts.append(allocator, seg);
    }

    if (parts.items.len == 0) return try allocator.dupe(u8, "/");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (parts.items) |seg| {
        try out.append(allocator, '/');
        try out.appendSlice(allocator, seg);
    }
    return try out.toOwnedSlice(allocator);
}

fn toVfsPath(allocator: std.mem.Allocator, disk_path: []const u8) ![]u8 {
    if (disk_path.len > 0 and (disk_path[0] == '/' or disk_path[0] == '\\')) {
        return normalizePosixPath(allocator, disk_path);
    }
    const joined = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ virtual_rel_anchor, disk_path });
    defer allocator.free(joined);
    return normalizePosixPath(allocator, joined);
}

fn posixDirname(p: []const u8) []const u8 {
    var end = p.len;
    while (end > 1 and (p[end - 1] == '/' or p[end - 1] == '\\')) : (end -= 1) {}
    const trimmed = p[0..end];
    if (std.mem.lastIndexOfAny(u8, trimmed, "/\\")) |idx| {
        if (idx == 0) return "/";
        return trimmed[0..idx];
    }
    return ".";
}

fn joinDiskPath(allocator: std.mem.Allocator, dir_path: []const u8, sub: []const u8) ![]u8 {
    if (sub.len > 0 and (sub[0] == '/' or sub[0] == '\\')) {
        return try allocator.dupe(u8, sub);
    }
    if (std.mem.eql(u8, dir_path, ".") or dir_path.len == 0) {
        return try allocator.dupe(u8, sub);
    }
    if (std.mem.eql(u8, dir_path, "/")) {
        return try std.fmt.allocPrint(allocator, "/{s}", .{sub});
    }
    const trimmed = std.mem.trimEnd(u8, dir_path, "/\\");
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ trimmed, sub });
}

fn isTypeScriptDeclarationOrSource(name: []const u8) bool {
    const exts = [_][]const u8{ ".d.ts", ".d.mts", ".d.cts", ".ts", ".mts", ".cts" };
    for (exts) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}

fn shouldSkipNeighborSubdir(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.') return true;
    const skipped = [_][]const u8{
        "node_modules",
        "zig-out",
        "zig-cache",
        "coverage",
    };
    for (skipped) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

const SourceCollector = struct {
    const PendingScan = struct {
        disk_path: []u8,
        vfs_path: []u8,
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    vfs_seen: std.StringHashMapUnmanaged(usize) = .empty,
    files: std.ArrayList(VirtualFile) = .empty,
    root_vfs_paths: std.ArrayList([]const u8) = .empty,
    entry_base_dirs: std.ArrayList([]u8) = .empty,
    scan_queue: std.ArrayList(PendingScan) = .empty,

    fn deinitScratch(self: *SourceCollector) void {
        self.vfs_seen.deinit(self.allocator);
        for (self.entry_base_dirs.items) |d| self.allocator.free(d);
        self.entry_base_dirs.deinit(self.allocator);
        for (self.scan_queue.items) |item| {
            self.allocator.free(item.disk_path);
            self.allocator.free(item.vfs_path);
        }
        self.scan_queue.deinit(self.allocator);
    }

    fn deinitAllOnErr(self: *SourceCollector) void {
        self.deinitScratch();
        for (self.files.items) |f| f.deinit(self.allocator);
        self.files.deinit(self.allocator);
        for (self.root_vfs_paths.items) |p| self.allocator.free(p);
        self.root_vfs_paths.deinit(self.allocator);
    }

    fn addRootVfsPath(self: *SourceCollector, vfs_path: []const u8) !void {
        for (self.root_vfs_paths.items) |existing| {
            if (std.mem.eql(u8, existing, vfs_path)) return;
        }
        const owned = try self.allocator.dupe(u8, vfs_path);
        errdefer self.allocator.free(owned);
        try self.root_vfs_paths.append(self.allocator, owned);
    }

    fn tryMountDiskFile(self: *SourceCollector, disk_path: []const u8, enqueue_scan: bool) !?[]const u8 {
        const vfs_path = try toVfsPath(self.allocator, disk_path);
        errdefer self.allocator.free(vfs_path);

        if (self.vfs_seen.get(vfs_path)) |existing_idx| {
            self.allocator.free(vfs_path);
            return self.files.items[existing_idx].vfs_path;
        }

        const contents = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            disk_path,
            self.allocator,
            .limited(64 * 1024 * 1024),
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                self.allocator.free(vfs_path);
                return null;
            },
        };
        errdefer self.allocator.free(contents);

        const idx = self.files.items.len;
        try self.files.append(self.allocator, .{
            .vfs_path = vfs_path,
            .contents = contents,
        });
        try self.vfs_seen.put(self.allocator, vfs_path, idx);

        if (enqueue_scan and isTypeScriptDeclarationOrSource(vfs_path)) {
            const dp_copy = try self.allocator.dupe(u8, disk_path);
            errdefer self.allocator.free(dp_copy);
            const vp_copy = try self.allocator.dupe(u8, vfs_path);
            errdefer self.allocator.free(vp_copy);
            try self.scan_queue.append(self.allocator, .{
                .disk_path = dp_copy,
                .vfs_path = vp_copy,
            });
        }

        return vfs_path;
    }

    fn mountDirectoryTree(self: *SourceCollector, dir_disk_path: []const u8, depth: usize) error{OutOfMemory}!void {
        if (depth > 16) return;
        var dir = std.Io.Dir.cwd().openDir(self.io, dir_disk_path, .{ .iterate = true }) catch return;
        defer dir.close(self.io);

        var subdir_names: std.ArrayList([]u8) = .empty;
        defer {
            for (subdir_names.items) |s| self.allocator.free(s);
            subdir_names.deinit(self.allocator);
        }
        var file_names: std.ArrayList([]u8) = .empty;
        defer {
            for (file_names.items) |f| self.allocator.free(f);
            file_names.deinit(self.allocator);
        }

        var iter = dir.iterate();
        while (iter.next(self.io) catch null) |entry| {
            switch (entry.kind) {
                .directory => {
                    if (!shouldSkipNeighborSubdir(entry.name)) {
                        try subdir_names.append(self.allocator, try self.allocator.dupe(u8, entry.name));
                    }
                },
                .file, .sym_link => {
                    if (isTypeScriptDeclarationOrSource(entry.name) or std.mem.eql(u8, entry.name, "package.json")) {
                        try file_names.append(self.allocator, try self.allocator.dupe(u8, entry.name));
                    }
                },
                else => {},
            }
        }

        const StrLess = struct {
            fn lt(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        };
        std.mem.sort([]u8, subdir_names.items, {}, StrLess.lt);
        std.mem.sort([]u8, file_names.items, {}, StrLess.lt);

        for (file_names.items) |fname| {
            const full = try joinDiskPath(self.allocator, dir_disk_path, fname);
            defer self.allocator.free(full);
            _ = try self.tryMountDiskFile(full, true);
        }

        for (subdir_names.items) |sname| {
            const sub_full = try joinDiskPath(self.allocator, dir_disk_path, sname);
            defer self.allocator.free(sub_full);
            try self.mountDirectoryTree(sub_full, depth + 1);
        }
    }

    fn probeAndMountTypeTarget(self: *SourceCollector, base_disk_dir: []const u8, raw_rel: []const u8) !?[]const u8 {
        const clean_rel = std.mem.trim(u8, raw_rel, " \t\r\n");
        if (clean_rel.len == 0) return null;

        const joined = try joinDiskPath(self.allocator, base_disk_dir, clean_rel);
        defer self.allocator.free(joined);

        // 1. Exact path match if it has a TS extension.
        if (isTypeScriptDeclarationOrSource(joined)) {
            if (try self.tryMountDiskFile(joined, true)) |vp| return vp;
        }

        // 2. Strip `.js`/`.mjs`/`.cjs` (ESM TypeScript `.js` import convention!) and probe `.d.ts` etc.
        const stem = if (std.mem.endsWith(u8, joined, ".js"))
            joined[0 .. joined.len - 3]
        else if (std.mem.endsWith(u8, joined, ".mjs") or std.mem.endsWith(u8, joined, ".cjs"))
            joined[0 .. joined.len - 4]
        else
            joined;

        const probes = [_][]const u8{
            ".d.ts",
            ".d.mts",
            ".d.cts",
            ".ts",
            ".mts",
            ".cts",
            "/index.d.ts",
            "/index.d.mts",
            "/index.d.cts",
            "/index.ts",
        };
        for (probes) |sfx| {
            const cand = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ stem, sfx });
            defer self.allocator.free(cand);
            if (try self.tryMountDiskFile(cand, true)) |vp| return vp;
        }

        return null;
    }

    fn resolvePackageJsonEntry(self: *SourceCollector, pkg_dir_disk: []const u8) !?[]const u8 {
        const pkg_json_disk = try joinDiskPath(self.allocator, pkg_dir_disk, "package.json");
        defer self.allocator.free(pkg_json_disk);

        const pkg_vfs = (try self.tryMountDiskFile(pkg_json_disk, false)) orelse return null;
        const pkg_idx = self.vfs_seen.get(pkg_vfs) orelse return null;
        const raw_json = self.files.items[pkg_idx].contents;

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw_json, .{}) catch return null;
        defer parsed.deinit();

        if (parsed.value != .object) return null;
        const obj = parsed.value.object;

        if (obj.get("types")) |tv| {
            if (tv == .string and tv.string.len > 0) {
                if (try self.probeAndMountTypeTarget(pkg_dir_disk, tv.string)) |vp| return vp;
            }
        }
        if (obj.get("typings")) |tv| {
            if (tv == .string and tv.string.len > 0) {
                if (try self.probeAndMountTypeTarget(pkg_dir_disk, tv.string)) |vp| return vp;
            }
        }
        if (obj.get("exports")) |ev| {
            if (extractTypesCondition(ev)) |exp_types| {
                if (try self.probeAndMountTypeTarget(pkg_dir_disk, exp_types)) |vp| return vp;
            }
        }
        return null;
    }

    fn loadPackageDirectory(self: *SourceCollector, dir_disk_path: []const u8, add_as_primary_root: bool) !bool {
        var test_dir = std.Io.Dir.cwd().openDir(self.io, dir_disk_path, .{ .iterate = true }) catch return false;
        test_dir.close(self.io);

        if (add_as_primary_root) {
            const vfs_dir = try toVfsPath(self.allocator, dir_disk_path);
            try self.entry_base_dirs.append(self.allocator, vfs_dir);
        }

        const count_before = self.files.items.len;
        try self.mountDirectoryTree(dir_disk_path, 0);

        if (try self.resolvePackageJsonEntry(dir_disk_path)) |entry_vp| {
            if (add_as_primary_root) try self.addRootVfsPath(entry_vp);
            return true;
        }

        const index_fallbacks = [_][]const u8{
            "index.d.ts",
            "index.d.mts",
            "index.d.cts",
            "index.ts",
        };
        for (index_fallbacks) |idx_name| {
            const cand = try joinDiskPath(self.allocator, dir_disk_path, idx_name);
            defer self.allocator.free(cand);
            if (try self.tryMountDiskFile(cand, true)) |vp| {
                if (add_as_primary_root) try self.addRootVfsPath(vp);
                return true;
            }
        }

        // No package.json types or index.d.ts — register all discovered TS/DTS files in the directory.
        var added_any = false;
        for (self.files.items[count_before..]) |f| {
            if (isTypeScriptDeclarationOrSource(f.vfs_path)) {
                if (add_as_primary_root) try self.addRootVfsPath(f.vfs_path);
                added_any = true;
            }
        }
        return added_any;
    }

    fn drainReferenceScanQueue(self: *SourceCollector) !void {
        var q_idx: usize = 0;
        while (q_idx < self.scan_queue.items.len) : (q_idx += 1) {
            const item_disk = try self.allocator.dupe(u8, self.scan_queue.items[q_idx].disk_path);
            defer self.allocator.free(item_disk);
            const item_vfs = self.scan_queue.items[q_idx].vfs_path;

            const file_idx = self.vfs_seen.get(item_vfs) orelse continue;
            // Copy slice text since `self.files` may reallocate as new files are mounted.
            const content = try self.allocator.dupe(u8, self.files.items[file_idx].contents);
            defer self.allocator.free(content);

            const cur_disk_dir = posixDirname(item_disk);

            var line_it = std.mem.splitScalar(u8, content, '\n');
            while (line_it.next()) |raw_line| {
                const line = std.mem.trim(u8, raw_line, " \t\r");

                // 1. Triple-slash directives: `/// <reference path="..." />` & `/// <reference types="..." />`
                if (std.mem.startsWith(u8, line, "///") and std.mem.indexOf(u8, line, "<reference") != null) {
                    if (extractXmlAttr(line, "path")) |ref_path| {
                        _ = try self.probeAndMountTypeTarget(cur_disk_dir, ref_path);
                    }
                    if (extractXmlAttr(line, "types")) |types_pkg| {
                        try self.mountNodeModulesTypesPkg(cur_disk_dir, types_pkg);
                    }
                    continue;
                }

                // 2. Relative ESM/CJS specifiers (`./...` or `../...`) on import/export lines.
                try self.scanRelativeSpecifiersInLine(cur_disk_dir, line);
            }
        }
    }

    fn mountNodeModulesTypesPkg(self: *SourceCollector, start_disk_dir: []const u8, pkg_name: []const u8) !void {
        if (pkg_name.len == 0 or std.mem.indexOf(u8, pkg_name, "..") != null) return;

        var cur_dir = try self.allocator.dupe(u8, start_disk_dir);
        defer self.allocator.free(cur_dir);

        for (0..6) |_| {
            const at_types = try std.fmt.allocPrint(self.allocator, "{s}/node_modules/@types/{s}", .{ cur_dir, pkg_name });
            defer self.allocator.free(at_types);
            if (try self.loadPackageDirectory(at_types, false)) return;

            const direct_pkg = try std.fmt.allocPrint(self.allocator, "{s}/node_modules/{s}", .{ cur_dir, pkg_name });
            defer self.allocator.free(direct_pkg);
            if (try self.loadPackageDirectory(direct_pkg, false)) return;

            const parent = posixDirname(cur_dir);
            if (std.mem.eql(u8, parent, cur_dir)) break;
            const next = try self.allocator.dupe(u8, parent);
            self.allocator.free(cur_dir);
            cur_dir = next;
        }
    }

    fn scanRelativeSpecifiersInLine(self: *SourceCollector, cur_disk_dir: []const u8, line: []const u8) !void {
        var i: usize = 0;
        while (i < line.len) : (i += 1) {
            const q = line[i];
            if (q != '"' and q != '\'') continue;
            const end_rel = std.mem.indexOfScalar(u8, line[i + 1 ..], q) orelse break;
            const lit = line[i + 1 .. i + 1 + end_rel];
            if (std.mem.startsWith(u8, lit, "./") or std.mem.startsWith(u8, lit, "../")) {
                _ = try self.probeAndMountTypeTarget(cur_disk_dir, lit);
            }
            i += end_rel + 1;
        }
    }
};

fn extractTypesCondition(val: std.json.Value) ?[]const u8 {
    switch (val) {
        .string => |s| {
            if (isTypeScriptDeclarationOrSource(s)) return s;
            return null;
        },
        .object => |obj| {
            if (obj.get(".")) |dot| {
                if (extractTypesCondition(dot)) |res| return res;
            }
            if (obj.get("types")) |tv| {
                if (tv == .string and tv.string.len > 0) return tv.string;
                if (extractTypesCondition(tv)) |res| return res;
            }
            if (obj.get("import")) |iv| {
                if (extractTypesCondition(iv)) |res| return res;
            }
            if (obj.get("default")) |dv| {
                if (extractTypesCondition(dv)) |res| return res;
            }
            return null;
        },
        else => return null,
    }
}

fn extractXmlAttr(line: []const u8, attr_name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < line.len) {
        const match_rel = std.mem.indexOf(u8, line[pos..], attr_name) orelse return null;
        const start = pos + match_rel;
        pos = start + attr_name.len;
        if (start > 0 and std.ascii.isAlphanumeric(line[start - 1])) continue;

        var eq = pos;
        while (eq < line.len and (line[eq] == ' ' or line[eq] == '\t')) : (eq += 1) {}
        if (eq >= line.len or line[eq] != '=') continue;
        eq += 1;
        while (eq < line.len and (line[eq] == ' ' or line[eq] == '\t')) : (eq += 1) {}
        if (eq >= line.len) return null;
        const quote = line[eq];
        if (quote != '"' and quote != '\'') continue;
        const close_rel = std.mem.indexOfScalar(u8, line[eq + 1 ..], quote) orelse return null;
        return line[eq + 1 .. eq + 1 + close_rel];
    }
    return null;
}

fn computeCommonBaseDir(allocator: std.mem.Allocator, dirs: []const []u8) ![]u8 {
    if (dirs.len == 0) return try allocator.dupe(u8, "/");
    var prefix: []const u8 = dirs[0];
    for (dirs[1..]) |other| {
        var common_len: usize = 0;
        const max_len = @min(prefix.len, other.len);
        var last_slash: usize = 0;
        while (common_len < max_len and prefix[common_len] == other[common_len]) : (common_len += 1) {
            if (prefix[common_len] == '/') last_slash = common_len;
        }
        if (common_len == prefix.len and (other.len == common_len or other[common_len] == '/')) {
            // `prefix` is already an ancestor directory of `other`.
        } else if (common_len == other.len and (prefix.len == common_len or prefix[common_len] == '/')) {
            prefix = other;
        } else {
            prefix = if (last_slash == 0) "/" else prefix[0..last_slash];
        }
    }
    return try allocator.dupe(u8, prefix);
}

pub const LoadTypesResult = union(enum) {
    ok: LoadedSources,
    err: []u8,
};

/// Resolves all `-t / --types <path>` files and package directories from disk, recursively loading
/// `package.json` `"types"`/`"typings"`/`index.d.ts`, neighboring `.d.ts` files, relative imports,
/// and triple-slash `/// <reference ... />` targets into an in-memory `LoadedSources` bundle.
pub fn loadTypesFromDisk(
    allocator: std.mem.Allocator,
    io: std.Io,
    types_paths: []const []const u8,
) std.mem.Allocator.Error!LoadTypesResult {
    var collector = SourceCollector{
        .allocator = allocator,
        .io = io,
    };

    for (types_paths) |raw_entry| {
        const trimmed = std.mem.trimEnd(u8, raw_entry, "/\\");
        const entry_path = if (trimmed.len == 0) "/" else trimmed;

        // First try as file if it ends with `.ts`, else probe directory then file.
        var handled = false;
        if (isTypeScriptDeclarationOrSource(entry_path)) {
            if (try collector.tryMountDiskFile(entry_path, true)) |vp| {
                const owned_vp = try allocator.dupe(u8, vp);
                defer allocator.free(owned_vp);
                try collector.addRootVfsPath(owned_vp);
                const parent_disk = posixDirname(entry_path);
                const vfs_dir = try toVfsPath(allocator, parent_disk);
                try collector.entry_base_dirs.append(allocator, vfs_dir);
                // Mount sibling/neighbor `.d.ts` files in the entry's directory tree too!
                try collector.mountDirectoryTree(parent_disk, 0);
                handled = true;
            }
        }

        if (!handled) {
            if (try collector.loadPackageDirectory(entry_path, true)) {
                handled = true;
            } else if (try collector.tryMountDiskFile(entry_path, true)) |vp| {
                const owned_vp = try allocator.dupe(u8, vp);
                defer allocator.free(owned_vp);
                try collector.addRootVfsPath(owned_vp);
                const parent_disk = posixDirname(entry_path);
                const vfs_dir = try toVfsPath(allocator, parent_disk);
                try collector.entry_base_dirs.append(allocator, vfs_dir);
                try collector.mountDirectoryTree(parent_disk, 0);
                handled = true;
            }
        }

        if (!handled) {
            collector.deinitAllOnErr();
            return .{
                .err = try std.fmt.allocPrint(
                    allocator,
                    "Input path not found or contains no TypeScript declarations: '{s}'.",
                    .{raw_entry},
                ),
            };
        }
    }

    try collector.drainReferenceScanQueue();

    if (collector.root_vfs_paths.items.len == 0) {
        collector.deinitAllOnErr();
        return .{
            .err = try allocator.dupe(u8, "No root TypeScript declaration files were discovered."),
        };
    }

    const base_dir = try computeCommonBaseDir(allocator, collector.entry_base_dirs.items);
    errdefer allocator.free(base_dir);
    collector.deinitScratch();

    const files_slice = try collector.files.toOwnedSlice(allocator);
    errdefer {
        for (files_slice) |f| f.deinit(allocator);
        allocator.free(files_slice);
    }
    const roots_slice = try collector.root_vfs_paths.toOwnedSlice(allocator);

    return .{
        .ok = .{
            .files = files_slice,
            .root_vfs_paths = roots_slice,
            .base_dir = base_dir,
        },
    };
}

fn formatDiagnostics(
    allocator: std.mem.Allocator,
    heading: []const u8,
    diags: []const host_mod.types.Diagnostic,
) ![]u8 {
    var msg: std.ArrayList(u8) = .empty;
    errdefer msg.deinit(allocator);
    try msg.appendSlice(allocator, heading);
    try msg.append(allocator, '\n');
    for (diags) |d| {
        if (d.span) |sp| {
            try msg.print(allocator, "  {s}:{d}:{d} TS{d}: {s}\n", .{
                sp.file_name,
                sp.line,
                sp.column,
                d.code,
                d.message,
            });
        } else {
            try msg.print(allocator, "  TS{d}: {s}\n", .{ d.code, d.message });
        }
    }
    return try msg.toOwnedSlice(allocator);
}

/// Runs the complete `ts-zigar` extraction -> IR lowering -> AST-validated Zig 0.17 emission
/// pipeline against an initialized `TypeScriptHost`.
pub fn runPipelineWithHost(
    allocator: std.mem.Allocator,
    io: std.Io,
    ts_host: *host_mod.TypeScriptHost,
    opts: *const cli.CliOptions,
) std.mem.Allocator.Error!DriverOutcome {
    var loaded = switch (try loadTypesFromDisk(allocator, io, opts.types_paths)) {
        .ok => |s| s,
        .err => |msg| return .{ .err = msg },
    };
    defer loaded.deinit(allocator);

    var vfs = ts_host.createVfs(allocator, true) catch |err| {
        return .{ .err = try std.fmt.allocPrint(allocator, "Failed to create TypeScript VFS: {s}", .{@errorName(err)}) };
    };
    defer vfs.deinit();

    for (loaded.files) |vf| {
        vfs.writeFile(allocator, vf.vfs_path, vf.contents) catch |err| {
            return .{ .err = try std.fmt.allocPrint(allocator, "Failed to mount '{s}' into VFS: {s}", .{ vf.vfs_path, @errorName(err) }) };
        };
    }

    var compiler_opts = host_mod.defaultCompilerOptions();
    compiler_opts.skip_lib_check = true;

    const prog_outcome = ts_host.createProgram(
        allocator,
        vfs,
        loaded.root_vfs_paths,
        compiler_opts,
    ) catch |err| {
        return .{ .err = try std.fmt.allocPrint(allocator, "Failed to invoke TypeScript compiler component: {s}", .{@errorName(err)}) };
    };
    defer prog_outcome.deinitErr(allocator);

    var prog = switch (prog_outcome) {
        .ok => |p| p,
        .err => |diags| {
            return .{ .err = try formatDiagnostics(allocator, "TypeScript program creation failed:", diags) };
        },
    };
    defer prog.deinit();

    const extract_cfg = host_mod.defaultExtractConfig(&.{});
    const graph_res = ts_host.extractModuleGraph(allocator, prog, extract_cfg) catch |err| {
        return .{ .err = try std.fmt.allocPrint(allocator, "Failed to extract TypeScript declaration graph: {s}", .{@errorName(err)}) };
    };
    defer host_mod.TypeScriptHost.freeValue(@TypeOf(graph_res), allocator, graph_res);

    const graph_val = switch (graph_res) {
        .ok => |g| g,
        .err => |diags| {
            return .{ .err = try formatDiagnostics(allocator, "TypeScript declaration extraction failed:", diags) };
        },
    };

    var pkg_ir = ir.lowerGraph(allocator, graph_val, .{
        .base_dir = loaded.base_dir,
        .modules = opts.modules,
        .substitutions = opts.substitutions,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NoMatchingModules => {
            var msg: std.ArrayList(u8) = .empty;
            errdefer msg.deinit(allocator);
            try msg.appendSlice(allocator, "No extracted TypeScript module matched filter(s): ");
            for (opts.modules, 0..) |m, idx| {
                if (idx > 0) try msg.appendSlice(allocator, ", ");
                try msg.print(allocator, "'{s}'", .{m});
            }
            try msg.append(allocator, '.');
            return .{ .err = try msg.toOwnedSlice(allocator) };
        },
    };
    defer pkg_ir.deinit();

    var emit_outcome = try emit.emitPackage(allocator, &pkg_ir);
    defer emit_outcome.deinit(allocator);

    const bundle = switch (emit_outcome) {
        .ok => |b| b,
        .ast_error => |diag| return .{ .err = try allocator.dupe(u8, diag) },
    };

    emit.writeBundleToDisk(io, opts.out_dir, &bundle) catch |err| {
        return .{
            .err = try std.fmt.allocPrint(
                allocator,
                "Failed to write generated Zig modules to '{s}': {s}",
                .{ opts.out_dir, @errorName(err) },
            ),
        };
    };

    return .{
        .ok = .{
            .module_count = pkg_ir.modules.len,
            .file_count = bundle.files.len,
        },
    };
}
