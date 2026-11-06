//! Multi-package WIT resolver.
//!
//! Mirrors the directory layout convention used by `wasm-tools`'s
//! `wit-parser::Resolve::push_dir` (and accepted by `wasm-tools
//! component embed --deps`):
//!
//! ```text
//!   <root>/*.wit                  ← the "main" package (concatenated)
//!   <root>/deps/<pkg-dir>/*.wit   ← one dependency package per subdir
//!   <root>/deps/<pkg>.wit         ← single-file dependency package
//! ```
//!
//! Parsing is one-AST-per-package (each `*.wit` directory is
//! concatenated into a single source for a single `parser.parse` call).
//! The resolver keeps the parsed docs around and lets
//! `metadata_encode.encodeWorldFromResolver` look up qualified
//! interface references across the package set.
//!
//! The wamr fixtures (`zig-calculator-cmd`, `mixed-zig-rust-calc`)
//! use this exact layout: `wit/world.wit` + `wit/deps/adder/world.wit`.
//! Before this resolver, `encodeWorld` only saw the main doc and
//! would fail with `error.UnknownInterface` whenever the world
//! imported an interface declared in a sibling package.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ast = @import("ast.zig");
const parser = @import("parser.zig");
const wasi_canon = @import("wasi_canon.zig");

pub const ResolveError = parser.ParseError || error{
    /// File or directory IO failure during deps walk.
    FileSystemError,
    /// `<root>` not found, or `<root>/deps/<entry>` not a recognized
    /// shape (file or directory).
    InvalidLayout,
    /// A `*.wit` file under `<root>` was empty.
    EmptyWit,
    /// Two or more files in the same directory carry differing
    /// `package <ns>:<name>[@<ver>];` declarations.
    PackageDeclConflict,
    /// No file in the directory carries a `package <ns>:<name>;`
    /// declaration — qualified-name resolution would fail.
    NoPackageDeclInDirectory,
};

/// Optional diagnostic populated by the resolver on errors that
/// have a path-level explanation. Mirrors `parser.ParseDiagnostic`
/// but uses file paths instead of byte spans.
pub const ResolveDiagnostic = struct {
    msg: []const u8 = "",
    path: []const u8 = "",
    path2: []const u8 = "",
};

/// Lightweight scanner: returns the byte range `[start, end)` of
/// the first `package <ns>:<name>[@<ver>];` declaration in `buf`,
/// skipping only leading whitespace, `//` / `///` line comments,
/// `/* … */` block comments, and `@<id>(<args>?)` annotations
/// before the decl. Returns null if no leading decl is found
/// (the file may still contain `package` mid-stream, but that's
/// not a top-level decl).
pub fn scanForPackageDecl(buf: []const u8) ?struct { start: usize, end: usize } {
    var i: usize = 0;
    while (i < buf.len) {
        const c = buf[i];
        switch (c) {
            ' ', '\t', '\r', '\n' => i += 1,
            '/' => {
                if (i + 1 >= buf.len) return null;
                if (buf[i + 1] == '/') {
                    while (i < buf.len and buf[i] != '\n') i += 1;
                } else if (buf[i + 1] == '*') {
                    i += 2;
                    while (i + 1 < buf.len and !(buf[i] == '*' and buf[i + 1] == '/')) i += 1;
                    if (i + 1 < buf.len) i += 2;
                } else {
                    return null;
                }
            },
            '@' => {
                // Skip annotation: `@` <id> `(<balanced parens>)`?
                i += 1;
                // skip id chars
                while (i < buf.len and isIdentChar(buf[i])) i += 1;
                // skip optional `( ... )`
                while (i < buf.len and (buf[i] == ' ' or buf[i] == '\t' or buf[i] == '\r' or buf[i] == '\n')) i += 1;
                if (i < buf.len and buf[i] == '(') {
                    var depth: usize = 1;
                    i += 1;
                    while (i < buf.len and depth > 0) : (i += 1) {
                        if (buf[i] == '(') depth += 1;
                        if (buf[i] == ')') depth -= 1;
                    }
                }
            },
            'p' => {
                // Look for `package ` literal.
                if (i + 8 <= buf.len and std.mem.eql(u8, buf[i .. i + 8], "package ")) {
                    const decl_start = i;
                    // Advance until the next `;` or end of buf.
                    while (i < buf.len and buf[i] != ';') i += 1;
                    if (i >= buf.len) return null;
                    return .{ .start = decl_start, .end = i + 1 };
                }
                return null;
            },
            else => return null,
        }
    }
    return null;
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
}

pub const Resolver = struct {
    /// The "main" parsed doc — the package the world being embedded
    /// belongs to. Always present.
    main: ast.Document,
    /// Sibling packages found under `<root>/deps/`. May be empty.
    deps: []const ast.Document,

    pub fn init(main: ast.Document, deps: []const ast.Document) Resolver {
        return .{ .main = main, .deps = deps };
    }

    /// Look up the interface body for an interface reference.
    ///
    ///   * `ref.package == null`  → look in `self.main`.
    ///   * `ref.package != null`  → search `self.main` then `self.deps`
    ///     for a doc whose `package` declaration matches `ref.package`.
    pub fn findInterface(self: Resolver, ref: ast.InterfaceRef) ?ast.Interface {
        if (self.findInterfaceWithPkg(ref)) |hit| return hit.iface;
        return null;
    }

    /// Like `findInterface` but also returns the package the interface
    /// was found in. Needed by `metadata_encode` to compute qualified
    /// names for short in-package references — e.g. a `use foo.{T};`
    /// inside an interface located in `wasi:cli` must resolve `foo` as
    /// `wasi:cli/foo`, not as a ref into the world's main package.
    pub fn findInterfaceWithPkg(self: Resolver, ref: ast.InterfaceRef) ?Lookup {
        return self.findInterfaceWithPkgCtx(ref, null);
    }

    /// Variant of `findInterfaceWithPkg` that accepts a `ctx_pkg`
    /// fallback package id. When `ref.package == null` (a short ref
    /// like `use error.{error};`) the lookup tries `ctx_pkg` first
    /// — this is the package the *consuming* interface lives in.
    /// Falls back to `self.main` if `ctx_pkg` is null or doesn't
    /// contain the named interface. Same package matched (relaxed
    /// version compare) as `findInterfaceWithPkg`.
    pub fn findInterfaceWithPkgCtx(self: Resolver, ref: ast.InterfaceRef, ctx_pkg: ?ast.PackageId) ?Lookup {
        if (ref.package == null) {
            if (ctx_pkg) |cp| {
                if (self.main.package) |mp| {
                    if (packageMatches(mp, cp)) {
                        if (findInterfaceInDoc(self.main, ref.name)) |i| {
                            return .{ .iface = i, .pkg = mp };
                        }
                    }
                }
                for (self.deps) |dep| {
                    if (dep.package) |dp| {
                        if (packageMatches(dp, cp)) {
                            if (findInterfaceInDoc(dep, ref.name)) |i| {
                                return .{ .iface = i, .pkg = dp };
                            }
                        }
                    }
                }
                // Fall through to the original main-only lookup.
            }
            if (findInterfaceInDoc(self.main, ref.name)) |i| {
                return .{ .iface = i, .pkg = self.main.package orelse return null };
            }
            if (self.main.package) |mp| {
                for (self.deps) |dep| {
                    if (dep.package) |dp| {
                        if (packageMatches(dp, mp)) {
                            if (findInterfaceInDoc(dep, ref.name)) |i| {
                                return .{ .iface = i, .pkg = dp };
                            }
                        }
                    }
                }
            }
            return null;
        }

        const target_pkg = ref.package.?;
        if (self.main.package) |mp| {
            if (packageMatches(mp, target_pkg)) {
                if (findInterfaceInDoc(self.main, ref.name)) |i| return .{ .iface = i, .pkg = mp };
            }
        }
        for (self.deps) |dep| {
            if (dep.package) |dp| {
                if (packageMatches(dp, target_pkg)) {
                    if (findInterfaceInDoc(dep, ref.name)) |i| return .{ .iface = i, .pkg = dp };
                }
            }
        }
        return null;
    }

    pub const Lookup = struct {
        iface: ast.Interface,
        pkg: ast.PackageId,
    };

    /// Look up a world by reference. Same package-matching rules as
    /// `findInterfaceWithPkg`. Used by `metadata_encode` to expand
    /// `include` items.
    pub fn findWorld(self: Resolver, ref: ast.InterfaceRef) ?WorldLookup {
        return self.findWorldCtx(ref, null);
    }

    pub fn findWorldCtx(self: Resolver, ref: ast.InterfaceRef, ctx_pkg: ?ast.PackageId) ?WorldLookup {
        if (ref.package == null) {
            if (ctx_pkg) |cp| {
                if (self.main.package) |mp| {
                    if (packageMatches(mp, cp)) {
                        if (findWorldInDoc(self.main, ref.name)) |w| return .{ .world = w, .pkg = mp };
                    }
                }
                for (self.deps) |dep| {
                    if (dep.package) |dp| {
                        if (packageMatches(dp, cp)) {
                            if (findWorldInDoc(dep, ref.name)) |w| return .{ .world = w, .pkg = dp };
                        }
                    }
                }
            }
            if (findWorldInDoc(self.main, ref.name)) |w| {
                return .{ .world = w, .pkg = self.main.package orelse return null };
            }
            if (self.main.package) |mp| {
                for (self.deps) |dep| {
                    if (dep.package) |dp| {
                        if (packageMatches(dp, mp)) {
                            if (findWorldInDoc(dep, ref.name)) |w| return .{ .world = w, .pkg = dp };
                        }
                    }
                }
            }
            return null;
        }
        const target_pkg = ref.package.?;
        if (self.main.package) |mp| {
            if (packageMatches(mp, target_pkg)) {
                if (findWorldInDoc(self.main, ref.name)) |w| return .{ .world = w, .pkg = mp };
            }
        }
        for (self.deps) |dep| {
            if (dep.package) |dp| {
                if (packageMatches(dp, target_pkg)) {
                    if (findWorldInDoc(dep, ref.name)) |w| return .{ .world = w, .pkg = dp };
                }
            }
        }
        return null;
    }

    pub const WorldLookup = struct {
        world: ast.World,
        pkg: ast.PackageId,
    };
};

fn findWorldInDoc(doc: ast.Document, name: []const u8) ?ast.World {
    for (doc.items) |it| {
        if (it == .world and std.mem.eql(u8, it.world.name, name)) return it.world;
    }
    return null;
}

fn findInterfaceInDoc(doc: ast.Document, name: []const u8) ?ast.Interface {
    for (doc.items) |it| {
        if (it == .interface and std.mem.eql(u8, it.interface.name, name)) {
            return it.interface;
        }
    }
    return null;
}

/// Two `PackageId`s match when their namespace + name match, and
/// either both versions match exactly or one of them is unspecified.
/// This is the relaxed comparison `wasm-tools` performs when resolving
/// a `<ns>:<pkg>/<iface>[@<ver>]` ref against the packages it knows
/// about — wamr's fixtures pin the version on the ref but a number
/// of upstream patterns leave it off in the dep package's own
/// `package <id>;` line.
fn packageMatches(have: ast.PackageId, want: ast.PackageId) bool {
    if (!std.mem.eql(u8, have.namespace, want.namespace)) return false;
    if (!std.mem.eql(u8, have.name, want.name)) return false;
    const have_v = have.version orelse return true;
    const want_v = want.version orelse return true;
    return std.mem.eql(u8, have_v, want_v);
}

// ── source combiner ─────────────────────────────────────────────────────────

/// Describe a `*.wit` source. `path` is informational only (used in
/// error messages); the source text drives parsing.
pub const WitSource = struct {
    path: []const u8,
    text: []const u8,
};

/// Result of combining one package's `.wit` files: the concatenated
/// source buffer and the member file paths in emit order (caller frees
/// both).
pub const CombinedWit = struct { text: []u8, paths: [][]const u8 };

/// Combine multiple `.wit` files belonging to a single package into one
/// parser-digestible source. `sources` should be sorted by file name
/// for deterministic output.
///
/// Canonical WIT directories carry a single `package <id>;` declaration
/// inherited by every sibling file. We require the set contain exactly
/// one DISTINCT decl (`PackageDeclConflict` on mismatch,
/// `NoPackageDeclInDirectory` if none), emit the decl-bearing file
/// first (decl intact), then the rest with any duplicate decl stripped.
///
/// `dir_label` is used only in the `NoPackageDeclInDirectory`
/// diagnostic. Returns the concatenated buffer and the file paths in
/// emit order (caller frees both). Empty `sources` → `text.len == 0`.
pub fn combineWitSources(
    alloc: Allocator,
    sources: []const WitSource,
    dir_label: []const u8,
    diag: ?*ResolveDiagnostic,
) ResolveError!CombinedWit {
    if (sources.len == 0) {
        return .{ .text = try alloc.alloc(u8, 0), .paths = try alloc.alloc([]const u8, 0) };
    }

    const Scan = struct { has_pkg: bool, start: usize, end: usize };
    const scans = try alloc.alloc(Scan, sources.len);
    defer alloc.free(scans);

    var canonical_decl: ?[]const u8 = null;
    var canonical_path: []const u8 = "";
    var first_decl_idx: ?usize = null;
    for (sources, 0..) |src, i| {
        scans[i] = .{ .has_pkg = false, .start = 0, .end = 0 };
        if (scanForPackageDecl(src.text)) |range| {
            scans[i] = .{ .has_pkg = true, .start = range.start, .end = range.end };
            const decl_text = std.mem.trim(u8, src.text[range.start..range.end], " \t\r\n");
            if (canonical_decl) |canon| {
                if (!std.mem.eql(u8, canon, decl_text)) {
                    if (diag) |d| d.* = .{
                        .msg = "files in the same WIT directory have differing `package` decls",
                        .path = canonical_path,
                        .path2 = src.path,
                    };
                    return error.PackageDeclConflict;
                }
            } else {
                canonical_decl = decl_text;
                canonical_path = src.path;
                first_decl_idx = i;
            }
        }
    }

    if (first_decl_idx == null) {
        if (diag) |d| d.* = .{
            .msg = "no `package <ns>:<name>[@<ver>];` decl found in any file under this directory",
            .path = dir_label,
        };
        return error.NoPackageDeclInDirectory;
    }

    var combined: std.ArrayList(u8) = .empty;
    errdefer combined.deinit(alloc);
    var paths: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (paths.items) |p| alloc.free(p);
        paths.deinit(alloc);
    }

    // Emit order: the package-bearing file first (decl intact), then
    // every other file in alphabetical order with any duplicate decl
    // stripped.
    const first = first_decl_idx.?;
    {
        const src = sources[first];
        try combined.appendSlice(alloc, src.text);
        try combined.append(alloc, '\n');
        try paths.append(alloc, try alloc.dupe(u8, src.path));
    }
    for (sources, 0..) |src, i| {
        if (i == first) continue;
        try paths.append(alloc, try alloc.dupe(u8, src.path));
        if (scans[i].has_pkg) {
            // Strip the duplicate decl; keep surrounding content.
            try combined.appendSlice(alloc, src.text[0..scans[i].start]);
            try combined.appendSlice(alloc, src.text[scans[i].end..]);
        } else {
            try combined.appendSlice(alloc, src.text);
        }
        try combined.append(alloc, '\n');
    }

    return .{
        .text = try combined.toOwnedSlice(alloc),
        .paths = try paths.toOwnedSlice(alloc),
    };
}

/// Combine `sources` into a single package document and finalize a
/// `Resolver` with the embedded canonical WASI packages as fallback deps.
pub fn parseSourcesWithDiag(
    arena: Allocator,
    sources: []const WitSource,
    dir_label: []const u8,
    diag: ?*ResolveDiagnostic,
) ResolveError!Resolver {
    const combined = try combineWitSources(arena, sources, dir_label, diag);
    if (combined.text.len == 0) return error.EmptyWit;
    const main = try parser.parse(arena, combined.text, null);
    return finishWithEmbedded(arena, main, &.{});
}

/// Finalize a `Resolver`, appending the embedded canonical WASI
/// packages (all versions, see `wasi_canon.version_sets`) as
/// **lowest-priority** deps. An embedded package is skipped when `main`
/// or any on-disk dep already provides a matching package, so an on-disk
/// `wit/deps/<pkg>/` always wins and existing projects see no behavior
/// change. Resolution precedence becomes:
/// `main` → on-disk deps → embedded wasi-canon.
pub fn finishWithEmbedded(
    arena: Allocator,
    main: ast.Document,
    on_disk: []const ast.Document,
) ResolveError!Resolver {
    var all: std.ArrayList(ast.Document) = .empty;
    try all.appendSlice(arena, on_disk);

    const embedded = try embeddedWasiDocs(arena);
    for (embedded) |edoc| {
        const epkg = edoc.package orelse continue;
        var provided = false;
        for (on_disk) |d| {
            if (d.package) |dp| {
                if (packageMatches(dp, epkg)) {
                    provided = true;
                    break;
                }
            }
        }
        if (!provided) try all.append(arena, edoc);
    }

    return Resolver.init(main, try all.toOwnedSlice(arena));
}

/// Parse every embedded canonical WASI package (across all version
/// sets) into one `ast.Document` per package. Documents are emitted in
/// `wasi_canon.version_sets` order (newest version first) so that for an
/// UNVERSIONED `wasi:*` reference the first matching package — the
/// newest embedded version — wins. Documents are allocated into `arena`.
pub fn embeddedWasiDocs(arena: Allocator) ResolveError![]ast.Document {
    var docs: std.ArrayList(ast.Document) = .empty;
    for (wasi_canon.version_sets) |vs| {
        for (vs.packages) |pkg| {
            var sources = try arena.alloc(WitSource, pkg.files.len);
            for (pkg.files, 0..) |file, j| {
                sources[j] = .{ .path = file.path, .text = file.content };
            }
            const combined = try combineWitSources(arena, sources, pkg.name, null);
            try docs.append(arena, try parser.parse(arena, combined.text, null));
        }
    }
    return docs.toOwnedSlice(arena);
}

// ── tests ───────────────────────────────────────────────────────────────────

test "resolver: same-package interface lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const src =
        \\package docs:adder@0.1.0;
        \\interface add { add: func(x: u32, y: u32) -> u32; }
        \\world adder { export add; }
    ;
    const doc = try parser.parse(ar, src, null);
    const res = Resolver.init(doc, &.{});

    const ref: ast.InterfaceRef = .{ .package = null, .name = "add" };
    const iface = res.findInterface(ref);
    try std.testing.expect(iface != null);
    try std.testing.expectEqualStrings("add", iface.?.name);
}

test "resolver: cross-package interface lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const main_src =
        \\package docs:zigcalc@0.1.0;
        \\world app { import docs:adder/add@0.1.0; }
    ;
    const dep_src =
        \\package docs:adder@0.1.0;
        \\interface add { add: func(x: u32, y: u32) -> u32; }
        \\world adder { export add; }
    ;
    const main_doc = try parser.parse(ar, main_src, null);
    const dep_doc = try parser.parse(ar, dep_src, null);
    var deps = try ar.alloc(ast.Document, 1);
    deps[0] = dep_doc;
    const res = Resolver.init(main_doc, deps);

    const ref: ast.InterfaceRef = .{
        .package = .{ .namespace = "docs", .name = "adder", .version = "0.1.0" },
        .name = "add",
    };
    const iface = res.findInterface(ref);
    try std.testing.expect(iface != null);
    try std.testing.expectEqualStrings("add", iface.?.name);
    try std.testing.expectEqual(@as(usize, 1), iface.?.items.len);
}

test "resolver: package version mismatch returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const dep_src =
        \\package docs:adder@0.2.0;
        \\interface add { add: func(x: u32, y: u32) -> u32; }
    ;
    const dep_doc = try parser.parse(ar, dep_src, null);
    var deps = try ar.alloc(ast.Document, 1);
    deps[0] = dep_doc;
    const main_doc = try parser.parse(ar, "package docs:zigcalc@0.1.0;", null);
    const res = Resolver.init(main_doc, deps);

    const ref: ast.InterfaceRef = .{
        .package = .{ .namespace = "docs", .name = "adder", .version = "0.1.0" },
        .name = "add",
    };
    try std.testing.expect(res.findInterface(ref) == null);
}

test "resolver: package missing version on either side matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ar = arena.allocator();

    const dep_src =
        \\package docs:adder;
        \\interface add { add: func(x: u32, y: u32) -> u32; }
    ;
    const dep_doc = try parser.parse(ar, dep_src, null);
    var deps = try ar.alloc(ast.Document, 1);
    deps[0] = dep_doc;
    const main_doc = try parser.parse(ar, "package docs:zigcalc;", null);
    const res = Resolver.init(main_doc, deps);

    const ref: ast.InterfaceRef = .{
        .package = .{ .namespace = "docs", .name = "adder", .version = "0.1.0" },
        .name = "add",
    };
    const iface = res.findInterface(ref);
    try std.testing.expect(iface != null);
}

test "scanForPackageDecl: finds leading decl past whitespace/comments/annotations" {
    // Plain package decl at the very start.
    {
        const buf = "package wasi:http@0.2.6;\ninterface i { f: func(); }";
        const r = scanForPackageDecl(buf).?;
        try std.testing.expectEqualStrings("package wasi:http@0.2.6;", buf[r.start..r.end]);
    }
    // Leading line + block comments.
    {
        const buf =
            \\// header comment
            \\/* block */
            \\package wasi:http@0.2.6;
        ;
        const r = scanForPackageDecl(buf).?;
        try std.testing.expectEqualStrings("package wasi:http@0.2.6;", buf[r.start..r.end]);
    }
    // Leading doc comments + annotations.
    {
        const buf =
            \\/// doc
            \\@since(version = 0.2.0)
            \\package wasi:http@0.2.6;
        ;
        const r = scanForPackageDecl(buf).?;
        try std.testing.expectEqualStrings("package wasi:http@0.2.6;", buf[r.start..r.end]);
    }
    // No leading decl — returns null.
    {
        const buf = "interface i { f: func(); }";
        try std.testing.expect(scanForPackageDecl(buf) == null);
    }
    // `package` appearing mid-stream is NOT a leading decl.
    {
        const buf = "interface i { f: func(); }\npackage wasi:http@0.2.6;";
        try std.testing.expect(scanForPackageDecl(buf) == null);
    }
}

test "resolver #195p2: multi-file primary package — decl in non-first file" {
    // Repro mirrors wasi-http/wit/: handler.wit (no pkg decl),
    // proxy.wit (carries the decl), types.wit (no pkg decl).
    // Alphabetical concat → decl mid-stream → parse fails pre-fix.
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const allocator = ar.allocator();

    const sources = [_]WitSource{
        .{ .path = "a-handler.wit", .text = "interface handler { handle: func(); }" },
        .{ .path = "b-proxy.wit", .text = "package wasi:http@0.2.6;\nworld w { import handler; }" },
        .{ .path = "c-types.wit", .text = "interface types { t: func(); }" },
    };

    const res = try parseSourcesWithDiag(allocator, &sources, "wit", null);
    try std.testing.expect(res.main.package != null);
    try std.testing.expectEqualStrings("wasi", res.main.package.?.namespace);
    try std.testing.expectEqualStrings("http", res.main.package.?.name);
    try std.testing.expectEqualStrings("0.2.6", res.main.package.?.version.?);
    // All three files' items should be merged into one document.
    // Order: items from the decl-bearing file first (just `world w`),
    // then alphabetical others (`handler` then `types`).
    try std.testing.expectEqual(@as(usize, 3), res.main.items.len);
}

test "resolver #195p2: package decl conflict between files" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const allocator = ar.allocator();

    const sources = [_]WitSource{
        .{ .path = "a.wit", .text = "package wasi:http@0.2.6;\ninterface i { f: func(); }" },
        .{ .path = "b.wit", .text = "package wasi:http@0.2.5;\ninterface j { f: func(); }" },
    };

    var diag: ResolveDiagnostic = .{};
    const got = parseSourcesWithDiag(allocator, &sources, "wit", &diag);
    try std.testing.expectError(error.PackageDeclConflict, got);
    try std.testing.expect(diag.msg.len > 0);
    try std.testing.expect(diag.path.len > 0);
    try std.testing.expect(diag.path2.len > 0);
}

test "resolver #195p2: no package decl in directory" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const allocator = ar.allocator();

    const sources = [_]WitSource{
        .{ .path = "a.wit", .text = "interface i { f: func(); }" },
        .{ .path = "b.wit", .text = "interface j { f: func(); }" },
    };

    var diag: ResolveDiagnostic = .{};
    const got = parseSourcesWithDiag(allocator, &sources, "wit", &diag);
    try std.testing.expectError(error.NoPackageDeclInDirectory, got);
    try std.testing.expect(diag.msg.len > 0);
}

test "resolver #195p2: duplicate-but-matching package decls are deduped" {
    // wasi-http does NOT actually do this (only one file carries the
    // decl), but other multi-file packages might. Verify the resolver
    // accepts duplicated identical decls.
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const allocator = ar.allocator();

    const sources = [_]WitSource{
        .{ .path = "a.wit", .text = "package ex:p@1.0.0;\ninterface ia { f: func(); }" },
        .{ .path = "b.wit", .text = "package ex:p@1.0.0;\ninterface ib { f: func(); }" },
    };

    const res = try parseSourcesWithDiag(allocator, &sources, "wit", null);
    try std.testing.expect(res.main.package != null);
    try std.testing.expectEqualStrings("ex", res.main.package.?.namespace);
    try std.testing.expectEqualStrings("p", res.main.package.?.name);
    try std.testing.expectEqual(@as(usize, 2), res.main.items.len);
}

test "resolver #195p2: canonical wasi-http proxy world resolves through the layout" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const allocator = ar.allocator();

    const http_sources = [_]WitSource{
        .{ .path = "handler.wit", .text = @embedFile("wasi-canon/0.2.6/http/handler.wit") },
        .{ .path = "proxy.wit", .text = @embedFile("wasi-canon/0.2.6/http/proxy.wit") },
        .{ .path = "types.wit", .text = @embedFile("wasi-canon/0.2.6/http/types.wit") },
    };
    const res = try parseSourcesWithDiag(allocator, &http_sources, "http", null);

    // Main package is wasi:http@0.2.6.
    try std.testing.expect(res.main.package != null);
    try std.testing.expectEqualStrings("wasi", res.main.package.?.namespace);
    try std.testing.expectEqualStrings("http", res.main.package.?.name);
    try std.testing.expectEqualStrings("0.2.6", res.main.package.?.version.?);

    try std.testing.expect(res.deps.len >= 6);
    var saw_cli = false;
    var saw_clocks = false;
    var saw_filesystem = false;
    var saw_io = false;
    var saw_random = false;
    var saw_sockets = false;
    for (res.deps) |dep| {
        try std.testing.expect(dep.package != null);
        const n = dep.package.?.name;
        if (std.mem.eql(u8, n, "cli")) saw_cli = true;
        if (std.mem.eql(u8, n, "clocks")) saw_clocks = true;
        if (std.mem.eql(u8, n, "filesystem")) saw_filesystem = true;
        if (std.mem.eql(u8, n, "io")) saw_io = true;
        if (std.mem.eql(u8, n, "random")) saw_random = true;
        if (std.mem.eql(u8, n, "sockets")) saw_sockets = true;
    }
    try std.testing.expect(saw_cli);
    try std.testing.expect(saw_clocks);
    try std.testing.expect(saw_filesystem);
    try std.testing.expect(saw_io);
    try std.testing.expect(saw_random);
    try std.testing.expect(saw_sockets);
}

test "resolver #256: wasi:* refs resolve from embedded set (no on-disk deps)" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const allocator = ar.allocator();

    const main = try parser.parse(allocator,
        \\package example:app@0.1.0;
        \\world app {
        \\  import wasi:io/streams@0.2.6;
        \\  import wasi:http/types@0.2.6;
        \\  import wasi:http/incoming-handler@0.2.6;
        \\}
    , null);
    const res = try finishWithEmbedded(allocator, main, &.{});

    const v: []const u8 = "0.2.6";
    try std.testing.expect(res.findInterface(.{
        .package = .{ .namespace = "wasi", .name = "io", .version = v },
        .name = "streams",
    }) != null);
    try std.testing.expect(res.findInterface(.{
        .package = .{ .namespace = "wasi", .name = "http", .version = v },
        .name = "types",
    }) != null);
    // incoming-handler lives in handler.wit, which carries NO package
    // decl — exercises the embedded multi-file combine.
    try std.testing.expect(res.findInterface(.{
        .package = .{ .namespace = "wasi", .name = "http", .version = v },
        .name = "incoming-handler",
    }) != null);
    // A version-less ref still matches the pinned 0.2.6 embedded set
    // (relaxed packageMatches).
    try std.testing.expect(res.findInterface(.{
        .package = .{ .namespace = "wasi", .name = "random", .version = null },
        .name = "random",
    }) != null);
}

test "resolver #261: multi-version embedded set + proposals resolve (no on-disk deps)" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const allocator = ar.allocator();

    const main = try parser.parse(allocator,
        \\package example:app@0.1.0;
        \\world app {
        \\  import wasi:io/streams@0.2.12;
        \\  import wasi:io/streams@0.2.6;
        \\  import wasi:config/store@0.2.0-rc.1;
        \\  import wasi:keyvalue/store@0.2.0-draft;
        \\  import wasi:tls/types@0.2.0-draft;
        \\  import wasi:nn/tensor@0.2.0-rc-2024-10-28;
        \\}
    , null);
    const res = try finishWithEmbedded(allocator, main, &.{});

    // Both P2 core versions resolve, selected exactly by version.
    try std.testing.expect(res.findInterface(.{
        .package = .{ .namespace = "wasi", .name = "io", .version = "0.2.12" },
        .name = "streams",
    }) != null);
    try std.testing.expect(res.findInterface(.{
        .package = .{ .namespace = "wasi", .name = "io", .version = "0.2.6" },
        .name = "streams",
    }) != null);

    // Off-by-default proposals resolve from their own version sets.
    try std.testing.expect(res.findInterface(.{
        .package = .{ .namespace = "wasi", .name = "config", .version = "0.2.0-rc.1" },
        .name = "store",
    }) != null);
    try std.testing.expect(res.findInterface(.{
        .package = .{ .namespace = "wasi", .name = "keyvalue", .version = "0.2.0-draft" },
        .name = "store",
    }) != null);
    try std.testing.expect(res.findInterface(.{
        .package = .{ .namespace = "wasi", .name = "tls", .version = "0.2.0-draft" },
        .name = "types",
    }) != null);
    try std.testing.expect(res.findInterface(.{
        .package = .{ .namespace = "wasi", .name = "nn", .version = "0.2.0-rc-2024-10-28" },
        .name = "tensor",
    }) != null);

    // An UNVERSIONED wasi:io reference prefers the newest embedded P2
    // version (0.2.12), per version_sets precedence order.
    const hit = res.findInterfaceWithPkg(.{
        .package = .{ .namespace = "wasi", .name = "io", .version = null },
        .name = "streams",
    });
    try std.testing.expect(hit != null);
    try std.testing.expectEqualStrings("0.2.12", hit.?.pkg.version.?);
}

test "resolver #261: WASI 0.3.0 (P3) packages resolve from embedded set" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const allocator = ar.allocator();

    const main = try parser.parse(allocator,
        \\package example:app@0.1.0;
        \\world app {
        \\  import wasi:cli/run@0.3.0;
        \\  import wasi:filesystem/types@0.3.0;
        \\}
    , null);
    const res = try finishWithEmbedded(allocator, main, &.{});

    // `wasi:filesystem/types@0.3.0` exercises an interface whose
    // functions use `stream<u8>` / `future<result<...>>`.
    try std.testing.expect(res.findInterface(.{
        .package = .{ .namespace = "wasi", .name = "filesystem", .version = "0.3.0" },
        .name = "types",
    }) != null);
    try std.testing.expect(res.findInterface(.{
        .package = .{ .namespace = "wasi", .name = "cli", .version = "0.3.0" },
        .name = "run",
    }) != null);

    // Unversioned `wasi:cli` prefers the newest embedded version (0.3.0).
    const cli_hit = res.findInterfaceWithPkg(.{
        .package = .{ .namespace = "wasi", .name = "cli", .version = null },
        .name = "run",
    });
    try std.testing.expect(cli_hit != null);
    try std.testing.expectEqualStrings("0.3.0", cli_hit.?.pkg.version.?);

    // 0.3.0 has no `wasi:io`, so an unversioned `wasi:io` falls through
    // to the newest version that provides it (0.2.12).
    const io_hit = res.findInterfaceWithPkg(.{
        .package = .{ .namespace = "wasi", .name = "io", .version = null },
        .name = "streams",
    });
    try std.testing.expect(io_hit != null);
    try std.testing.expectEqualStrings("0.2.12", io_hit.?.pkg.version.?);
}

test "resolver #256: explicit dep overrides embedded copy" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const allocator = ar.allocator();

    const main = try parser.parse(allocator,
        \\package example:app@0.1.0;
        \\world app { import wasi:io/streams@0.2.6; }
    , null);
    const custom_io = try parser.parse(allocator,
        \\package wasi:io@0.2.6;
        \\interface streams { sentinel-marker: func(); }
    , null);
    const res = try finishWithEmbedded(allocator, main, &.{custom_io});

    const streams = res.findInterface(.{
        .package = .{ .namespace = "wasi", .name = "io", .version = "0.2.6" },
        .name = "streams",
    });
    try std.testing.expect(streams != null);
    // The explicit dep copy (one item) wins over the embedded set.
    try std.testing.expectEqual(@as(usize, 1), streams.?.items.len);
}

test "resolver #256: unknown wasi:* subinterface resolves to null (no panic)" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const allocator = ar.allocator();

    const main = try parser.parse(allocator,
        \\package example:app@0.1.0;
        \\world app { import wasi:io/streams@0.2.6; }
    , null);
    const res = try finishWithEmbedded(allocator, main, &.{});

    // Package matches embedded wasi:io, but the sub-interface does not
    // exist → clean null, not a crash.
    try std.testing.expect(res.findInterface(.{
        .package = .{ .namespace = "wasi", .name = "io", .version = "0.2.6" },
        .name = "does-not-exist",
    }) == null);
}

test "resolver #216: bundled wasi-cli deps expose stdin" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const allocator = ar.allocator();

    const main = try parser.parse(allocator, "package example:app@0.1.0;", null);
    const res = try finishWithEmbedded(allocator, main, &.{});

    const stdin_iface = res.findInterface(.{
        .package = .{ .namespace = "wasi", .name = "cli", .version = "0.2.6" },
        .name = "stdin",
    });
    try std.testing.expect(stdin_iface != null);
}
