//! Opt-in allocation counter and live-byte wrapper (`zigar.mem.TrackingAllocator`).
//!
//! ### Architectural Rationale
//!
//! 1. **Why Zig-side (`zigar.mem`), not JavaScript `zigar-runtime`**:
//!    JavaScript's `zigar-runtime` (`src/features/allocator-methods.js`) only observes
//!    cross-boundary `alloc` / `free` / `dupe` calls initiated from JS. Wrapping a Zig
//!    `std.mem.Allocator` VTable intercepts *all* allocations—both Zig-internal heap usage
//!    (`std.ArrayList`, `std.fmt.allocPrint`, `zigar.js` `*Alloc` / `toOwnedSlice` decoders)
//!    and cross-boundary JS->Zig allocations when the allocator is exported.
//!
//! 2. **Completes Zigar's leak-auditing & observability triad**:
//!    Pairs directly with `zigar.js.activeHandleCount()` and `zigar.js.activeCallbackCount()`
//!    for zero-leak assertions in tests and live memory telemetry (`activeCount()`,
//!    `activeBytes()`) in long-running servers and cloud handlers, while composing cleanly
//!    with `zigar.mem.allocator` (`ShardedPool` / `wasm_allocator` on WebAssembly,
//!    `smp_allocator` / `c_allocator` / `page_allocator` on native targets).
//!
//! 3. **Why opt-in per instance rather than unconditional on `zigar.mem.allocator`**:
//!    - *Avoids global cache-line contention*: `zigar.mem.allocator` uses a 16-shard slab
//!      pool (`sharded-allocator.zig`) to avoid a single contended lock across threads/Web
//!      Workers. Unconditional global atomic updates on `default_allocator` would re-introduce
//!      a single contended cache line on every allocation and free in release builds.
//!    - *Isolates module/request leak checks from permanent runtime allocations*: Zigar
//!      internals (such as `CallbackRegistry` slab tables in `type/js.zig`) allocate
//!      long-lived tables from `host.default_allocator` once and reuse them for the module's
//!      lifetime. Separate `TrackingAllocator` instances keep application leak assertions
//!      (`activeCount() == 0`, `activeBytes() == 0`) strictly isolated from runtime state.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// Thread-safe `std.mem.Allocator` wrapper that tracks live allocation count and live byte
/// total across `alloc`, `resize`, `remap`, and `free` using lock-free atomics.
///
/// Supports comptime initialization at module scope:
/// ```zig
/// var gpa: zigar.mem.TrackingAllocator = .init(zigar.mem.allocator);
/// const alloc = gpa.allocator();
/// ```
pub const TrackingAllocator = struct {
    backing: Allocator,
    active_allocs: std.atomic.Value(usize) = .init(0),
    active_bytes: std.atomic.Value(usize) = .init(0),

    pub fn init(backing: Allocator) TrackingAllocator {
        return .{ .backing = backing };
    }

    pub fn allocator(self: *TrackingAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    /// Number of currently live non-empty allocations not yet freed.
    pub fn activeCount(self: *const TrackingAllocator) usize {
        return self.active_allocs.load(.acquire);
    }

    /// Total byte length across all currently live allocations.
    pub fn activeBytes(self: *const TrackingAllocator) usize {
        return self.active_bytes.load(.acquire);
    }

    const vtable: Allocator.VTable = .{
        .alloc = rawAlloc,
        .resize = rawResize,
        .remap = rawRemap,
        .free = rawFree,
    };

    fn rawAlloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        if (len > 0) {
            _ = self.active_allocs.fetchAdd(1, .acq_rel);
            _ = self.active_bytes.fetchAdd(len, .acq_rel);
        }
        return ptr;
    }

    fn rawResize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.recordResize(memory.len, new_len);
        return true;
    }

    fn rawRemap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.recordResize(memory.len, new_len);
        return ptr;
    }

    fn rawFree(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const len = memory.len;
        self.backing.rawFree(memory, alignment, ret_addr);
        if (len > 0) {
            _ = self.active_bytes.fetchSub(len, .acq_rel);
            _ = self.active_allocs.fetchSub(1, .acq_rel);
        }
    }

    fn recordResize(self: *TrackingAllocator, old_len: usize, new_len: usize) void {
        if (old_len == 0 and new_len > 0) {
            _ = self.active_allocs.fetchAdd(1, .acq_rel);
        } else if (old_len > 0 and new_len == 0) {
            _ = self.active_allocs.fetchSub(1, .acq_rel);
        }
        if (new_len > old_len) {
            _ = self.active_bytes.fetchAdd(new_len - old_len, .acq_rel);
        } else if (new_len < old_len) {
            _ = self.active_bytes.fetchSub(old_len - new_len, .acq_rel);
        }
    }
};

var comptime_test_tracker: TrackingAllocator = .init(std.testing.allocator);
const comptime_test_ally: Allocator = comptime_test_tracker.allocator();

test "comptime module-scope initialization" {
    const slice = try comptime_test_ally.alloc(u32, 8);
    try std.testing.expectEqual(@as(usize, 1), comptime_test_tracker.activeCount());
    try std.testing.expectEqual(@as(usize, 8 * @sizeOf(u32)), comptime_test_tracker.activeBytes());
    comptime_test_ally.free(slice);
    try std.testing.expectEqual(@as(usize, 0), comptime_test_tracker.activeCount());
    try std.testing.expectEqual(@as(usize, 0), comptime_test_tracker.activeBytes());
}

test "std.heap allocator validation suites" {
    var tracker: TrackingAllocator = .init(std.testing.allocator);
    const ally = tracker.allocator();

    try std.heap.testAllocator(ally);
    try std.heap.testAllocatorAligned(ally);
    try std.heap.testAllocatorLargeAlignment(ally);
    try std.heap.testAllocatorAlignedShrink(ally);

    try std.testing.expectEqual(@as(usize, 0), tracker.activeCount());
    try std.testing.expectEqual(@as(usize, 0), tracker.activeBytes());
}

test "exact count and byte accounting across alloc, resize, realloc, OOM, and zero-length slices" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    var tracker: TrackingAllocator = .init(failing.allocator());
    const ally = tracker.allocator();

    // Zero-length allocations do not touch VTable or increment activeCount
    const empty = try ally.alloc(u8, 0);
    try std.testing.expectEqual(@as(usize, 0), tracker.activeCount());
    try std.testing.expectEqual(@as(usize, 0), tracker.activeBytes());
    ally.free(empty);

    // Allocation #0 (64 bytes)
    var buf1 = try ally.alloc(u8, 64);
    try std.testing.expectEqual(@as(usize, 1), tracker.activeCount());
    try std.testing.expectEqual(@as(usize, 64), tracker.activeBytes());

    // Allocation #1 (128 bytes)
    const buf2 = try ally.alloc(u8, 128);
    try std.testing.expectEqual(@as(usize, 2), tracker.activeCount());
    try std.testing.expectEqual(@as(usize, 192), tracker.activeBytes());

    // Allocation #2 hits fail_index -> error.OutOfMemory; counters must remain unchanged
    try std.testing.expectError(error.OutOfMemory, ally.alloc(u8, 256));
    try std.testing.expectEqual(@as(usize, 2), tracker.activeCount());
    try std.testing.expectEqual(@as(usize, 192), tracker.activeBytes());

    // In-place shrink via resize updates activeBytes while preserving activeCount
    if (ally.resize(buf1, 24)) {
        buf1 = buf1[0..24];
        try std.testing.expectEqual(@as(usize, 2), tracker.activeCount());
        try std.testing.expectEqual(@as(usize, 152), tracker.activeBytes());
    }

    ally.free(buf2);
    try std.testing.expectEqual(@as(usize, 1), tracker.activeCount());
    try std.testing.expectEqual(@as(usize, buf1.len), tracker.activeBytes());

    ally.free(buf1);
    try std.testing.expectEqual(@as(usize, 0), tracker.activeCount());
    try std.testing.expectEqual(@as(usize, 0), tracker.activeBytes());

    // Verify realloc grow + shrink against std.testing.allocator
    var realloc_tracker: TrackingAllocator = .init(std.testing.allocator);
    const rally = realloc_tracker.allocator();
    var dynamic = try rally.alloc(u8, 16);
    @memset(dynamic, 0x5a);
    try std.testing.expectEqual(@as(usize, 1), realloc_tracker.activeCount());
    try std.testing.expectEqual(@as(usize, 16), realloc_tracker.activeBytes());

    dynamic = try rally.realloc(dynamic, 512);
    try std.testing.expectEqual(@as(usize, 1), realloc_tracker.activeCount());
    try std.testing.expectEqual(@as(usize, 512), realloc_tracker.activeBytes());

    dynamic = try rally.realloc(dynamic, 32);
    try std.testing.expectEqual(@as(usize, 1), realloc_tracker.activeCount());
    try std.testing.expectEqual(@as(usize, 32), realloc_tracker.activeBytes());
    for (dynamic[0..16]) |b| try std.testing.expectEqual(@as(u8, 0x5a), b);

    rally.free(dynamic);
    try std.testing.expectEqual(@as(usize, 0), realloc_tracker.activeCount());
    try std.testing.expectEqual(@as(usize, 0), realloc_tracker.activeBytes());
}

test "multithreaded concurrent alloc/realloc/free accounting" {
    if (builtin.single_threaded or builtin.target.cpu.arch.isWasm()) return;

    var tracker: TrackingAllocator = .init(std.heap.smp_allocator);
    const ally = tracker.allocator();

    const Worker = struct {
        fn run(a: Allocator, seed: usize) !void {
            var i: usize = 0;
            while (i < 500) : (i += 1) {
                const n = ((i + seed) % 97) + 1;
                var mem = try a.alloc(u8, n);
                @memset(mem, @truncate(i));
                mem = try a.realloc(mem, n * 2);
                a.free(mem);
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, idx| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ ally, idx * 17 });
    }
    for (threads) |t| {
        t.join();
    }

    try std.testing.expectEqual(@as(usize, 0), tracker.activeCount());
    try std.testing.expectEqual(@as(usize, 0), tracker.activeBytes());
}
