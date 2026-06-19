//! Thread-safe general-purpose allocator for WebAssembly.
//!
//! Zig 0.16's `std.heap.WasmAllocator` is `@compileError("unimplemented")` for
//! non-single-threaded wasm (it wraps `BrkAllocator`, which itself bails out
//! with `@compileError("unsupported")` unless `builtin.single_threaded`). That
//! leaves multi-threaded wasm with no usable `std.heap` allocator, because
//! `wasm_allocator`, `page_allocator`, and the bundled-libc `malloc` all bottom
//! out at `WasmAllocator`.
//!
//! This module reimplements `BrkAllocator`'s size-class free-list algorithm —
//! which grows the linear memory via `@wasmMemoryGrow` — and guards its shared
//! bookkeeping with a small atomic spin lock so it is safe to call from multiple
//! threads sharing one linear memory. `@wasmMemoryGrow` is itself serialized by
//! the engine on a shared memory, so only the free lists need protection.
//!
//! The core is generic over a page source so the allocation logic can be unit
//! tested on the host (where `@wasmMemoryGrow` is unavailable). Production code
//! should use the `wasm_allocator` value exported below.

const std = @import("std");
const builtin = @import("builtin");
const math = std.math;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

const max_usize = math.maxInt(usize);
const bigpage_size: comptime_int = @max(64 * 1024, std.heap.page_size_max);
const bigpage_count = max_usize / bigpage_size;

/// Because of storing free list pointers, the minimum size class is 3.
const min_class = math.log2(math.ceilPowerOfTwoAssert(usize, 1 + @sizeOf(usize)));
const size_class_count = math.log2(bigpage_size) - min_class;
const big_size_class_count = math.log2(bigpage_count);

/// Atomic spin lock. Compiles to nothing in single-threaded builds; uses a
/// wasm/atomics compare-exchange otherwise. A spin lock (rather than
/// `std.Io.Mutex`) is used because it needs no `Io` instance and the critical
/// sections here are tiny free-list manipulations.
const SpinLock = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn lock(self: *SpinLock) void {
        if (builtin.single_threaded) return;
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinLock) void {
        if (builtin.single_threaded) return;
        self.state.store(0, .release);
    }
};

/// Page source backed by the wasm linear memory. `grow` reserves `bigpages`
/// (a power of two) fresh big pages and returns the base byte address, or 0 on
/// failure.
pub const WasmPages = struct {
    pub fn grow(_: *WasmPages, bigpages: usize) usize {
        comptime assert(std.heap.page_size_max == std.heap.page_size_min);
        const page_size = std.heap.page_size_max;
        const pages_per_bigpage = bigpage_size / page_size;
        const page_index = @wasmMemoryGrow(0, bigpages * pages_per_bigpage);
        if (page_index == -1) return 0;
        return @as(usize, @intCast(page_index)) * page_size;
    }
};

/// A thread-safe `BrkAllocator`, parameterized over a page source providing
/// `fn grow(*Pages, bigpages: usize) usize`.
pub fn ThreadSafeBrkAllocator(comptime Pages: type) type {
    return struct {
        const Self = @This();

        lock: SpinLock = .{},
        next_addrs: [size_class_count]usize = @splat(0),
        /// For each size class, points to the freed pointer.
        frees: [size_class_count]usize = @splat(0),
        /// For each big size class, points to the freed pointer.
        big_frees: [big_size_class_count]usize = @splat(0),
        pages: Pages = .{},

        pub const vtable: Allocator.VTable = .{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        };

        pub fn allocator(self: *Self) Allocator {
            return .{ .ptr = self, .vtable = &vtable };
        }

        fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, return_address: usize) ?[*]u8 {
            _ = return_address;
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.lock.lock();
            defer self.lock.unlock();
            // Make room for the freelist next pointer.
            const actual_len = @max(len +| @sizeOf(usize), alignment.toByteUnits());
            const slot_size = math.ceilPowerOfTwo(usize, actual_len) catch return null;
            const class = math.log2(slot_size) - min_class;
            if (class < size_class_count) {
                const addr = a: {
                    const top_free_ptr = self.frees[class];
                    if (top_free_ptr != 0) {
                        const node: *usize = @ptrFromInt(top_free_ptr + (slot_size - @sizeOf(usize)));
                        self.frees[class] = node.*;
                        break :a top_free_ptr;
                    }

                    const next_addr = self.next_addrs[class];
                    if (next_addr % bigpage_size == 0) {
                        const fresh = self.allocBigPages(1);
                        if (fresh == 0) return null;
                        self.next_addrs[class] = fresh + slot_size;
                        break :a fresh;
                    } else {
                        self.next_addrs[class] = next_addr + slot_size;
                        break :a next_addr;
                    }
                };
                return @ptrFromInt(addr);
            }
            const bigpages_needed = bigPagesNeeded(actual_len);
            const addr = self.allocBigPages(bigpages_needed);
            if (addr == 0) return null;
            return @ptrFromInt(addr);
        }

        fn resize(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, return_address: usize) bool {
            _ = ctx;
            _ = return_address;
            // We don't want to move anything from one size class to another, but
            // we can recover bytes in between powers of two. This only inspects
            // sizes, so it needs no lock.
            const buf_align = alignment.toByteUnits();
            const old_actual_len = @max(buf.len + @sizeOf(usize), buf_align);
            const new_actual_len = @max(new_len +| @sizeOf(usize), buf_align);
            const old_small_slot_size = math.ceilPowerOfTwoAssert(usize, old_actual_len);
            const old_small_class = math.log2(old_small_slot_size) - min_class;
            if (old_small_class < size_class_count) {
                const new_small_slot_size = math.ceilPowerOfTwo(usize, new_actual_len) catch return false;
                return old_small_slot_size == new_small_slot_size;
            } else {
                const old_bigpages_needed = bigPagesNeeded(old_actual_len);
                const old_big_slot_pages = math.ceilPowerOfTwoAssert(usize, old_bigpages_needed);
                const new_bigpages_needed = bigPagesNeeded(new_actual_len);
                const new_big_slot_pages = math.ceilPowerOfTwo(usize, new_bigpages_needed) catch return false;
                return old_big_slot_pages == new_big_slot_pages;
            }
        }

        fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, return_address: usize) ?[*]u8 {
            return if (resize(ctx, memory, alignment, new_len, return_address)) memory.ptr else null;
        }

        fn free(ctx: *anyopaque, buf: []u8, alignment: Alignment, return_address: usize) void {
            _ = return_address;
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.lock.lock();
            defer self.lock.unlock();
            const buf_align = alignment.toByteUnits();
            const actual_len = @max(buf.len + @sizeOf(usize), buf_align);
            const slot_size = math.ceilPowerOfTwoAssert(usize, actual_len);
            const class = math.log2(slot_size) - min_class;
            const addr = @intFromPtr(buf.ptr);
            if (class < size_class_count) {
                const node: *usize = @ptrFromInt(addr + (slot_size - @sizeOf(usize)));
                node.* = self.frees[class];
                self.frees[class] = addr;
            } else {
                const bigpages_needed = bigPagesNeeded(actual_len);
                const pow2_pages = math.ceilPowerOfTwoAssert(usize, bigpages_needed);
                const big_slot_size_bytes = pow2_pages * bigpage_size;
                const node: *usize = @ptrFromInt(addr + (big_slot_size_bytes - @sizeOf(usize)));
                const big_class = math.log2(pow2_pages);
                node.* = self.big_frees[big_class];
                self.big_frees[big_class] = addr;
            }
        }

        /// Caller must hold `self.lock`.
        fn allocBigPages(self: *Self, n: usize) usize {
            const pow2_pages = math.ceilPowerOfTwoAssert(usize, n);
            const slot_size_bytes = pow2_pages * bigpage_size;
            const class = math.log2(pow2_pages);

            const top_free_ptr = self.big_frees[class];
            if (top_free_ptr != 0) {
                const node: *usize = @ptrFromInt(top_free_ptr + (slot_size_bytes - @sizeOf(usize)));
                self.big_frees[class] = node.*;
                return top_free_ptr;
            }

            return self.pages.grow(pow2_pages);
        }
    };
}

inline fn bigPagesNeeded(byte_count: usize) usize {
    return (byte_count + (bigpage_size + (@sizeOf(usize) - 1))) / bigpage_size;
}

var global = ThreadSafeBrkAllocator(WasmPages){};

/// Process-wide wasm allocator. In single-threaded builds this is just
/// `std.heap.wasm_allocator` (unchanged, battle-tested); otherwise it is the
/// thread-safe implementation above.
pub const wasm_allocator: Allocator = if (builtin.single_threaded)
    std.heap.wasm_allocator
else
    .{ .ptr = &global, .vtable = &ThreadSafeBrkAllocator(WasmPages).vtable };

// ---------------------------------------------------------------------------
// Tests (run on the host with a buffer-backed page source).
// ---------------------------------------------------------------------------

/// Page source backed by a static buffer so the allocator can be exercised on
/// non-wasm hosts.
const TestPages = struct {
    const region_bytes = 64 * bigpage_size;
    var buffer: [region_bytes]u8 align(bigpage_size) = undefined;
    used: usize = 0,

    fn grow(self: *TestPages, bigpages: usize) usize {
        const want = bigpages * bigpage_size;
        if (self.used + want > buffer.len) return 0;
        const base = @intFromPtr(&buffer) + self.used;
        self.used += want;
        return base;
    }
};

const TestAllocator = ThreadSafeBrkAllocator(TestPages);

test "small allocations - free in same order" {
    var inst = TestAllocator{};
    const ally = inst.allocator();
    var list: [256]*u64 = undefined;
    for (&list) |*slot| slot.* = try ally.create(u64);
    for (list) |ptr| ally.destroy(ptr);
}

test "small allocations - free in reverse order" {
    var inst = TestAllocator{};
    const ally = inst.allocator();
    var list: [256]*u64 = undefined;
    for (&list) |*slot| slot.* = try ally.create(u64);
    var i: usize = list.len;
    while (i > 0) {
        i -= 1;
        ally.destroy(list[i]);
    }
}

test "freed slots are reused" {
    var inst = TestAllocator{};
    const ally = inst.allocator();
    const a = try ally.create(u64);
    ally.destroy(a);
    const b = try ally.create(u64);
    try std.testing.expectEqual(a, b);
    ally.destroy(b);
}

test "varied sizes and writes" {
    var inst = TestAllocator{};
    const ally = inst.allocator();
    const sizes = [_]usize{ 1, 7, 16, 100, 1000, 5000, 70000 };
    var bufs: [sizes.len][]u8 = undefined;
    for (sizes, 0..) |n, i| {
        const buf = try ally.alloc(u8, n);
        @memset(buf, @intCast(i));
        bufs[i] = buf;
    }
    for (sizes, 0..) |n, i| {
        for (bufs[i]) |byte| try std.testing.expectEqual(@as(u8, @intCast(i)), byte);
        try std.testing.expectEqual(n, bufs[i].len);
    }
    for (bufs) |buf| ally.free(buf);
}

test "alignment is honored" {
    var inst = TestAllocator{};
    const ally = inst.allocator();
    inline for (.{ 1, 2, 4, 8, 16, 32, 64 }) |a| {
        const buf = try ally.alignedAlloc(u8, comptime Alignment.fromByteUnits(a), 48);
        try std.testing.expect(std.mem.isAligned(@intFromPtr(buf.ptr), a));
        ally.free(buf);
    }
}
