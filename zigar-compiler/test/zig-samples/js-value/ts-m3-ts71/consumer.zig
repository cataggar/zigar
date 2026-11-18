const std = @import("std");
const zigar = @import("zigar");
const gen = @import("generated/root.zig");

const js = gen.zigar_js;
const ts_sync = gen.typescript_sync;
const ts_fs = gen.typescript_fs;
const ts_ast = gen.typescript_ast;
const ts_is = gen.typescript_ast_is;

var live_allocs = std.atomic.Value(usize).init(0);

const TrackingAllocator = struct {
    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const ptr = zigar.mem.allocator.rawAlloc(len, alignment, ret_addr) orelse return null;
        _ = live_allocs.fetchAdd(1, .acq_rel);
        return ptr;
    }

    fn resize(_: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        return zigar.mem.allocator.rawResize(buf, alignment, new_len, ret_addr);
    }

    fn remap(_: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        return zigar.mem.allocator.rawRemap(buf, alignment, new_len, ret_addr);
    }

    fn free(_: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        zigar.mem.allocator.rawFree(buf, alignment, ret_addr);
        _ = live_allocs.fetchSub(1, .acq_rel);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocator() std.mem.Allocator {
        return .{ .ptr = undefined, .vtable = &vtable };
    }
};

const tracked_alloc = TrackingAllocator.allocator();

pub fn activeHandles() u32 {
    return js.activeHandleCount();
}

pub fn activeCallbacks() u32 {
    return js.activeCallbackCount();
}

pub fn liveZigAllocs() usize {
    return live_allocs.load(.acquire);
}

pub fn hasPendingCapturedError() bool {
    return js.hasLastError();
}

fn checkInvariants(handles_before: u32, cbs_before: u32, allocs_before: usize) !void {
    if (js.activeHandleCount() != handles_before) return error.Unexpected;
    if (js.activeCallbackCount() != cbs_before) return error.Unexpected;
    if (live_allocs.load(.acquire) != allocs_before) return error.Unexpected;
    if (js.hasLastError()) return error.Unexpected;
}

/// Instantiates TypeScript 7.1's `typescript/sync` `API` server from Zig, builds an in-memory
/// virtual filesystem with `createFileSystemWithLib`, opens a configured project snapshot via
/// `SnapshotOperationParams`, walks `SourceFile.statements` (`NodeArray<Statement>`), narrows
/// statements via `asVariableStatement`, queries `checker.getTypeAtLocation` + `checker.typeToString`,
/// and disposes both `[Symbol.dispose]` leases (`Snapshot` and `API`) cleanly via `defer`.
pub fn checkInMemoryTypeScriptProgram(out_alloc: std.mem.Allocator) ![]const u8 {
    const h0 = js.activeHandleCount();
    const c0 = js.activeCallbackCount();
    const a0 = live_allocs.load(.acquire);

    var summary: []const u8 = &.{};
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(tracked_alloc);

        const api = try ts_sync.ApiDefault().init(.{
            .api_options = .{
                .client_spawn_options = .{ .cwd = "/" },
            },
        });
        defer api.deinit();

        const fs_req = try ts_fs.createFileSystemWithLibAlloc(
            tracked_alloc,
            &.{
                .{
                    .id = .{ .str = "/tsconfig.json" },
                    .content = "{ \"compilerOptions\": { \"strict\": true } }",
                },
                .{
                    .id = .{ .str = "/index.ts" },
                    .content =
                    \\export const answer = 42;
                    \\export const summary = { total: answer } as const;
                    \\export function greet(name: string): `hi:${string}` { return `hi:${name}`; }
                    \\
                    ,
                },
            },
            null,
        );
        defer js.freeDecoded(@TypeOf(fs_req), tracked_alloc, fs_req);

        const create_snap = try api.createSnapshot();
        defer create_snap.deinit();

        const snap = try create_snap.callSnapshotOperationParamsDefault(.{
            .file_system = fs_req,
            .open_projects = &.{.{ .str = "/tsconfig.json" }},
        });
        defer snap.deinit();

        const proj = (try snap.getConfiguredProject("/tsconfig.json")) orelse return error.Unexpected;
        defer proj.deinit();

        const prog = try proj.program();
        defer prog.deinit();

        const checker = try proj.checker();
        defer checker.deinit();

        const get_sf = try prog.getSourceFile();
        defer get_sf.deinit();
        const sf = (try get_sf.call(.{ .str = "/index.ts" })) orelse return error.Unexpected;
        defer sf.deinit();

        const sf_kind = try sf.kind();
        if (sf_kind != .source_file) return error.Unexpected;

        const get_type = try checker.getTypeAtLocation();
        defer get_type.deinit();
        const type_to_str = try checker.typeToString();
        defer type_to_str.deinit();

        const stmts = try sf.statements();
        defer stmts.deinit();
        const stmts_end = try stmts.end();
        if (!(stmts_end > 0)) return error.Unexpected;

        var stmt_iter = try stmts.iterator();
        defer stmt_iter.deinit();

        var stmt_count: usize = 0;
        while (try stmt_iter.next()) |stmt| {
            defer stmt.deinit();
            stmt_count += 1;

            const stmt_node = stmt.as(ts_ast.Node);
            if (try ts_is.isVariableStatementNarrow(stmt_node)) |var_stmt| {
                defer var_stmt.deinit();
                const decl_list = try var_stmt.declarationList();
                defer decl_list.deinit();
                const decls = try decl_list.declarations();
                defer decls.deinit();

                var decl_iter = try decls.iterator();
                defer decl_iter.deinit();
                while (try decl_iter.next()) |decl| {
                    defer decl.deinit();
                    const bname = try decl.nameAlloc(tracked_alloc);
                    defer switch (bname) {
                        .identifier => |id| id.deinit(),
                        .binding_pattern => |bp| switch (bp) {
                            .object_binding_pattern => |ob| ob.deinit(),
                            .array_binding_pattern => |ab| ab.deinit(),
                        },
                    };
                    const ident_text = switch (bname) {
                        .identifier => |id| try id.textAlloc(tracked_alloc),
                        else => return error.Unexpected,
                    };
                    defer tracked_alloc.free(ident_text);

                    const decl_node = decl.as(ts_ast.Node);
                    const ty = try get_type.callNode(decl_node);
                    defer ty.deinit();
                    const ty_str = try type_to_str.callAlloc(tracked_alloc, ty, null, null);
                    defer tracked_alloc.free(ty_str);

                    if (out.items.len > 0) try out.appendSlice(tracked_alloc, "|");
                    try out.appendSlice(tracked_alloc, ident_text);
                    try out.appendSlice(tracked_alloc, "=");
                    try out.appendSlice(tracked_alloc, ty_str);
                }
            }
        }

        try out.print(tracked_alloc, "|stmts={d}", .{stmt_count});
        summary = try out_alloc.dupe(u8, out.items);
    }

    errdefer out_alloc.free(summary);
    try checkInvariants(h0, c0, a0);
    return summary;
}
