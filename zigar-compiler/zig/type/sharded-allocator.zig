const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// Sharded power-of-two slab allocator for multithreaded WebAssembly.
///
/// Eliminates global spinlock contention on `std.heap.BrkAllocator` across
/// Web Workers while carving multi-slot chunks sized to pack tightly into
/// `BrkAllocator` pages without 2x metadata-header size-class rounding.
pub const ShardedPool = struct {
    pub const num_shards: usize = 16;
    pub const num_classes: usize = 9;
    pub const min_class_log2: u6 = 4; // 16 B
    pub const max_class_log2: u6 = 12; // 4096 B
    pub const min_slot_size: usize = @as(usize, 1) << min_class_log2;
    pub const max_slot_size: usize = @as(usize, 1) << max_class_log2;
    pub const max_slab_alignment: Alignment = .@"64";
    pub const chunk_alignment: Alignment = .@"64";
    pub const max_local_per_class: u32 = 64;
    pub const overflow_batch_size: u32 = 16;

    const FreeNode = struct {
        next: ?*FreeNode,
    };

    const ChunkNode = struct {
        next: ?*ChunkNode,
        class_idx: usize,
    };

    comptime {
        std.debug.assert(min_slot_size >= @sizeOf(FreeNode));
        for (0..num_classes) |c| {
            const slots = slotsPerChunk(c);
            const slot_sz = slotSize(c);
            std.debug.assert(slots >= 15);
            std.debug.assert(slots * slot_sz + @sizeOf(ChunkNode) <= chunkAllocLen(c));
            std.debug.assert((slots * slot_sz) % @alignOf(ChunkNode) == 0);
        }
    }

    const Shard = struct {
        lock: std.atomic.Mutex align(64) = .unlocked,
        heads: [num_classes]?*FreeNode = @splat(null),
        counts: [num_classes]u32 = @splat(0),
        chunks_head: ?*ChunkNode = null,

        inline fn acquire(self: *Shard) void {
            while (!self.lock.tryLock()) {
                std.atomic.spinLoopHint();
            }
        }

        inline fn release(self: *Shard) void {
            self.lock.unlock();
        }
    };

    const OverflowBin = struct {
        lock: std.atomic.Mutex align(64) = .unlocked,
        head: ?*FreeNode = null,

        inline fn acquire(self: *OverflowBin) void {
            while (!self.lock.tryLock()) {
                std.atomic.spinLoopHint();
            }
        }

        inline fn release(self: *OverflowBin) void {
            self.lock.unlock();
        }
    };

    backing: Allocator,
    shards: [num_shards]Shard = @splat(.{}),
    overflow: [num_classes]OverflowBin = @splat(.{}),

    var next_shard: std.atomic.Value(u32) = .init(0);
    threadlocal var tls_shard_id: u32 = 0;

    pub fn init(backing: Allocator) ShardedPool {
        return .{ .backing = backing };
    }

    /// Releases all carved slab chunks back to the backing allocator.
    /// Intended for deterministic teardown and leak checking in tests; caller
    /// must ensure no threads are concurrently using this pool.
    pub fn deinit(self: *ShardedPool) void {
        for (&self.overflow) |*bin| {
            bin.head = null;
        }
        for (&self.shards) |*shard| {
            var cur = shard.chunks_head;
            shard.chunks_head = null;
            shard.heads = @splat(null);
            shard.counts = @splat(0);
            while (cur) |chunk_node| {
                const next = chunk_node.next;
                const class_idx = chunk_node.class_idx;
                const alloc_len = chunkAllocLen(class_idx);
                const tail_offset = slotsPerChunk(class_idx) * slotSize(class_idx);
                const chunk_ptr = @as([*]u8, @ptrCast(chunk_node)) - tail_offset;
                self.backing.rawFree(chunk_ptr[0..alloc_len], chunk_alignment, 0);
                cur = next;
            }
        }
    }

    pub fn allocator(self: *ShardedPool) Allocator {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub const vtable: Allocator.VTable = .{
        .alloc = rawAlloc,
        .resize = rawResize,
        .remap = rawRemap,
        .free = rawFree,
    };

    pub inline fn classIndex(len: usize, alignment: Alignment) ?usize {
        if (len > max_slot_size or alignment.compare(.gt, max_slab_alignment)) {
            return null;
        }
        const required = @max(len, alignment.toByteUnits(), min_slot_size);
        const slot_size = std.math.ceilPowerOfTwoAssert(usize, required);
        return std.math.log2_int(usize, slot_size) - min_class_log2;
    }

    pub inline fn slotSize(class_idx: usize) usize {
        return @as(usize, 1) << @intCast(class_idx + min_class_log2);
    }

    pub inline fn chunkAllocLen(class_idx: usize) usize {
        if (class_idx < num_classes - 1) {
            // Classes 16..2048 B: request `2^k - @sizeOf(usize)` so BrkAllocator's
            // `len + @sizeOf(usize)` lands on an exact `2^k <= 32 KiB` small class.
            const raw_chunk = @min(@as(usize, 32 * 1024), @max(@as(usize, 1024), slotSize(class_idx) * 32));
            return raw_chunk - @sizeOf(usize);
        }
        // Class 4096 B: request `64 KiB - 2 * @sizeOf(usize)` so BrkAllocator's
        // `bigPagesNeeded(len + @sizeOf(usize))` allocates exactly 1 64 KiB bigpage.
        return 64 * 1024 - 2 * @sizeOf(usize);
    }

    pub inline fn slotsPerChunk(class_idx: usize) usize {
        return (chunkAllocLen(class_idx) - @sizeOf(ChunkNode)) / slotSize(class_idx);
    }

    inline fn currentShard(self: *ShardedPool) *Shard {
        var id = tls_shard_id;
        if (id == 0) {
            @branchHint(.unlikely);
            id = (next_shard.fetchAdd(1, .monotonic) % @as(u32, num_shards)) + 1;
            tls_shard_id = id;
        }
        return &self.shards[id - 1];
    }

    fn rawAlloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ShardedPool = @ptrCast(@alignCast(ctx));
        const class_idx = classIndex(len, alignment) orelse {
            return self.backing.rawAlloc(len, alignment, ret_addr);
        };

        const shard = self.currentShard();

        // 1. Fast path: pop from thread-assigned local shard.
        {
            shard.acquire();
            if (shard.heads[class_idx]) |node| {
                shard.heads[class_idx] = node.next;
                shard.counts[class_idx] -= 1;
                shard.release();
                return @ptrCast(node);
            }
            shard.release();
        }

        // 2. Medium path: claim up to `overflow_batch_size` nodes from shared overflow bin.
        {
            const bin = &self.overflow[class_idx];
            var popped_head: ?*FreeNode = null;
            var rem_head: ?*FreeNode = null;
            var rem_tail: *FreeNode = undefined;
            var rem_count: u32 = 0;

            bin.acquire();
            if (bin.head) |first| {
                popped_head = first;
                if (first.next) |second| {
                    first.next = null;
                    rem_head = second;
                    var tail = second;
                    rem_count = 1;
                    while (rem_count < overflow_batch_size - 1) {
                        const next = tail.next orelse break;
                        tail = next;
                        rem_count += 1;
                    }
                    bin.head = tail.next;
                    tail.next = null;
                    rem_tail = tail;
                } else {
                    bin.head = null;
                }
            }
            bin.release();

            if (popped_head) |ret_node| {
                if (rem_head) |rh| {
                    shard.acquire();
                    rem_tail.next = shard.heads[class_idx];
                    shard.heads[class_idx] = rh;
                    shard.counts[class_idx] += rem_count;
                    shard.release();
                }
                return @ptrCast(ret_node);
            }
        }

        // 3. Slow path: carve a new multi-slot chunk from the backing allocator
        // without holding any shard or overflow lock.
        const alloc_len = chunkAllocLen(class_idx);
        const chunk_ptr = self.backing.rawAlloc(alloc_len, chunk_alignment, ret_addr) orelse return null;

        const slot_size = slotSize(class_idx);
        const slots = slotsPerChunk(class_idx);

        const chain_head: *FreeNode = @ptrCast(@alignCast(chunk_ptr + slot_size));
        var prev: *FreeNode = chain_head;
        var i: usize = 2;
        while (i < slots) : (i += 1) {
            const node: *FreeNode = @ptrCast(@alignCast(chunk_ptr + i * slot_size));
            prev.next = node;
            prev = node;
        }
        prev.next = null;
        const chain_count: u32 = @intCast(slots - 1);

        const chunk_node: *ChunkNode = @ptrCast(@alignCast(chunk_ptr + slots * slot_size));
        chunk_node.class_idx = class_idx;

        shard.acquire();
        chunk_node.next = shard.chunks_head;
        shard.chunks_head = chunk_node;
        prev.next = shard.heads[class_idx];
        shard.heads[class_idx] = chain_head;
        shard.counts[class_idx] += chain_count;
        shard.release();

        return chunk_ptr;
    }

    fn rawResize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *ShardedPool = @ptrCast(@alignCast(ctx));
        const old_class = classIndex(memory.len, alignment);
        const new_class = classIndex(new_len, alignment);
        if (old_class) |oc| {
            return if (new_class) |nc| oc == nc else false;
        }
        if (new_class != null) return false;
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn rawRemap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *ShardedPool = @ptrCast(@alignCast(ctx));
        const old_class = classIndex(memory.len, alignment);
        const new_class = classIndex(new_len, alignment);
        if (old_class) |oc| {
            return if (new_class) |nc| (if (oc == nc) memory.ptr else null) else null;
        }
        if (new_class != null) return null;
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn rawFree(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *ShardedPool = @ptrCast(@alignCast(ctx));
        const class_idx = classIndex(memory.len, alignment) orelse {
            self.backing.rawFree(memory, alignment, ret_addr);
            return;
        };

        @memset(memory, undefined);
        const node: *FreeNode = @ptrCast(@alignCast(memory.ptr));
        const shard = self.currentShard();

        var evict_head: ?*FreeNode = null;
        var evict_tail: *FreeNode = undefined;

        {
            shard.acquire();
            node.next = shard.heads[class_idx];
            shard.heads[class_idx] = node;
            shard.counts[class_idx] += 1;

            if (shard.counts[class_idx] > max_local_per_class) {
                const keep_count = max_local_per_class - overflow_batch_size;
                const evict_count = shard.counts[class_idx] - keep_count;
                const head = shard.heads[class_idx].?;
                var tail = head;
                var n: u32 = 1;
                while (n < evict_count) : (n += 1) {
                    tail = tail.next.?;
                }
                shard.heads[class_idx] = tail.next;
                tail.next = null;
                shard.counts[class_idx] = keep_count;
                evict_head = head;
                evict_tail = tail;
            }
            shard.release();
        }

        if (evict_head) |eh| {
            const bin = &self.overflow[class_idx];
            bin.acquire();
            evict_tail.next = bin.head;
            bin.head = eh;
            bin.release();
        }
    }

    pub fn totalCarvedChunks(self: *ShardedPool) usize {
        var total: usize = 0;
        for (&self.shards) |*shard| {
            shard.acquire();
            var cur = shard.chunks_head;
            while (cur) |c| : (cur = c.next) {
                total += 1;
            }
            shard.release();
        }
        return total;
    }

    pub fn overflowCount(self: *ShardedPool, class_idx: usize) usize {
        const bin = &self.overflow[class_idx];
        bin.acquire();
        defer bin.release();
        var count: usize = 0;
        var cur = bin.head;
        while (cur) |node| : (cur = node.next) {
            count += 1;
        }
        return count;
    }
};

var global_wasm_pool: ShardedPool = .init(std.heap.wasm_allocator);

pub const allocator: Allocator = if (builtin.target.cpu.arch.isWasm())
    if (builtin.single_threaded)
        std.heap.wasm_allocator
    else
        .{ .ptr = @ptrCast(&global_wasm_pool), .vtable = &ShardedPool.vtable }
else if (!builtin.single_threaded)
    std.heap.smp_allocator
else if (builtin.link_libc)
    std.heap.c_allocator
else
    std.heap.page_allocator;

test "default exported allocator" {
    const buf = try allocator.alloc(u64, 32);
    defer allocator.free(buf);
    for (buf, 0..) |*v, i| v.* = i * 9;
    for (buf, 0..) |v, i| try std.testing.expectEqual(i * 9, v);
}

test "std.heap allocator validation suites" {
    var pool: ShardedPool = .init(std.testing.allocator);
    defer pool.deinit();
    const ally = pool.allocator();

    try std.heap.testAllocator(ally);
    try std.heap.testAllocatorAligned(ally);
    try std.heap.testAllocatorLargeAlignment(ally);
    try std.heap.testAllocatorAlignedShrink(ally);
}

test "all 9 slab classes and alignments 1..64" {
    var pool: ShardedPool = .init(std.testing.allocator);
    defer pool.deinit();
    const ally = pool.allocator();

    const sizes = [_]usize{ 1, 8, 16, 17, 32, 33, 64, 65, 128, 129, 256, 257, 512, 513, 1024, 1025, 2048, 2049, 4096 };
    const alignments = [_]Alignment{ .@"1", .@"2", .@"4", .@"8", .@"16", .@"32", .@"64" };

    for (alignments) |a| {
        const align_bytes = a.toByteUnits();
        for (sizes) |sz| {
            const expected_slot = std.math.ceilPowerOfTwoAssert(usize, @max(sz, align_bytes, 16));
            const expected_class = std.math.log2_int(usize, expected_slot) - 4;
            try std.testing.expectEqual(@as(?usize, expected_class), ShardedPool.classIndex(sz, a));

            const ptr = ally.rawAlloc(sz, a, 0) orelse return error.OutOfMemory;
            try std.testing.expect(a.check(@intFromPtr(ptr)));
            const slice = ptr[0..sz];
            @memset(slice, @truncate(sz ^ align_bytes));
            for (slice) |b| {
                try std.testing.expectEqual(@as(u8, @truncate(sz ^ align_bytes)), b);
            }
            ally.rawFree(slice, a, 0);

            // Re-allocating immediately hits the local shard free list and returns the same slot.
            const ptr2 = ally.rawAlloc(sz, a, 0) orelse return error.OutOfMemory;
            try std.testing.expectEqual(@intFromPtr(ptr), @intFromPtr(ptr2));
            ally.rawFree(ptr2[0..sz], a, 0);
        }
    }
}

test "oversized length and alignment passthrough" {
    var pool: ShardedPool = .init(std.testing.allocator);
    defer pool.deinit();
    const ally = pool.allocator();

    const align_128 = comptime Alignment.fromByteUnits(128);
    const align_256 = comptime Alignment.fromByteUnits(256);

    try std.testing.expectEqual(@as(?usize, null), ShardedPool.classIndex(4097, .@"1"));
    try std.testing.expectEqual(@as(?usize, null), ShardedPool.classIndex(16, align_128));
    try std.testing.expectEqual(@as(?usize, null), ShardedPool.classIndex(std.math.maxInt(usize), .@"1"));

    const chunks_before = pool.totalCarvedChunks();

    const big = try ally.alloc(u8, 8192);
    @memset(big, 0x5a);
    const over_aligned = try ally.alignedAlloc(u8, align_128, 64);
    try std.testing.expect(align_128.check(@intFromPtr(over_aligned.ptr)));
    @memset(over_aligned, 0xa5);

    const over_aligned_256 = try ally.alignedAlloc(u8, align_256, 256);
    try std.testing.expect(align_256.check(@intFromPtr(over_aligned_256.ptr)));

    // Oversized allocations bypass slab chunk carving completely.
    try std.testing.expectEqual(chunks_before, pool.totalCarvedChunks());

    ally.free(over_aligned_256);
    ally.free(over_aligned);
    ally.free(big);
}

test "class-preserving resize and remap across slab and oversized boundaries" {
    var pool: ShardedPool = .init(std.testing.allocator);
    defer pool.deinit();
    const ally = pool.allocator();

    // 1. Within same slab class (33..64 B -> class 2): in-place resize and remap succeed.
    {
        var buf = try ally.alloc(u8, 40);
        const orig_ptr = buf.ptr;
        @memset(buf, 0x11);
        try std.testing.expect(ally.resize(buf, 64));
        buf = orig_ptr[0..64];
        try std.testing.expect(ally.resize(buf, 33));
        buf = orig_ptr[0..33];
        const remapped = ally.remap(buf, 60) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@intFromPtr(orig_ptr), @intFromPtr(remapped.ptr));
        buf = remapped;
        for (buf[0..33]) |b| try std.testing.expectEqual(@as(u8, 0x11), b);

        // Crossing to another slab class (60 B -> 65 B or 60 B -> 32 B) must refuse in-place resize/remap.
        try std.testing.expect(!ally.resize(buf, 65));
        try std.testing.expect(!ally.resize(buf, 32));
        try std.testing.expect(ally.remap(buf, 65) == null);
        try std.testing.expect(ally.remap(buf, 32) == null);

        // High-level realloc across slab classes preserves data and frees cleanly.
        buf = try ally.realloc(buf, 128);
        for (buf[0..33]) |b| try std.testing.expectEqual(@as(u8, 0x11), b);
        buf = try ally.realloc(buf, 16);
        for (buf[0..16]) |b| try std.testing.expectEqual(@as(u8, 0x11), b);
        ally.free(buf);
    }

    // 2. Slab (<= 4096 B) -> Oversized (> 4096 B) and Oversized (> 4096 B) -> Slab (<= 4096 B).
    {
        var buf = try ally.alloc(u8, 2048);
        for (buf, 0..) |*b, i| b.* = @truncate(i *% 7 + 3);

        // Must refuse in-place resize/remap from slab to oversized.
        try std.testing.expect(!ally.resize(buf, 5000));
        try std.testing.expect(ally.remap(buf, 5000) == null);

        // Realloc to oversized (> 4096 B) relocates to backing and returns old slot to slab.
        buf = try ally.realloc(buf, 8192);
        for (buf[0..2048], 0..) |b, i| {
            try std.testing.expectEqual(@as(u8, @truncate(i *% 7 + 3)), b);
        }

        // CRITICAL: Must refuse in-place resize/remap from oversized (> 4096 B) down to slab (<= 4096 B),
        // preventing an oversized backing block from later being freed into a slab free list!
        try std.testing.expect(!ally.resize(buf, 4096));
        try std.testing.expect(!ally.resize(buf, 64));
        try std.testing.expect(ally.remap(buf, 4096) == null);
        try std.testing.expect(ally.remap(buf, 64) == null);

        // Realloc from oversized back down to slab allocates a slab slot, copies, and frees oversized to backing.
        buf = try ally.realloc(buf, 512);
        for (buf, 0..) |b, i| {
            try std.testing.expectEqual(@as(u8, @truncate(i *% 7 + 3)), b);
        }
        ally.free(buf);
    }
}

test "all 16 shards exercised across spawned threads" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var pool: ShardedPool = .init(std.testing.allocator);
    defer pool.deinit();
    const ally = pool.allocator();

    const Worker = struct {
        fn run(a: Allocator) !void {
            var ptrs: [32][]u8 = undefined;
            for (&ptrs, 0..) |*slot, i| {
                const buf = try a.alloc(u8, 64);
                @memset(buf, @truncate(i));
                slot.* = buf;
            }
            for (ptrs, 0..) |buf, i| {
                try std.testing.expectEqual(@as(u8, @truncate(i)), buf[0]);
                a.free(buf);
            }
        }
    };

    var threads: [ShardedPool.num_shards]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ally});
    }
    for (&threads) |*t| {
        t.join();
    }

    var active_shards: usize = 0;
    for (&pool.shards) |*s| {
        if (s.chunks_head != null or s.counts[2] > 0) active_shards += 1;
    }
    try std.testing.expectEqual(ShardedPool.num_shards, active_shards);
}

test "asymmetric producer-consumer overflow recycling and bounded memory" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var pool: ShardedPool = .init(std.testing.allocator);
    defer pool.deinit();
    const ally = pool.allocator();

    const batch_items = 500;
    var items: [batch_items][]u8 = undefined;

    const Producer = struct {
        fn allocateAll(a: Allocator, out: *[batch_items][]u8, seed: u8) !void {
            for (out, 0..) |*slot, i| {
                const buf = try a.alloc(u8, 64);
                @memset(buf, @truncate(seed +% @as(u8, @truncate(i))));
                slot.* = buf;
            }
        }
    };

    const Consumer = struct {
        fn freeAll(a: Allocator, in: *const [batch_items][]u8, seed: u8) !void {
            for (in, 0..) |buf, i| {
                try std.testing.expectEqual(@as(u8, @truncate(seed +% @as(u8, @truncate(i)))), buf[0]);
                try std.testing.expectEqual(@as(u8, @truncate(seed +% @as(u8, @truncate(i)))), buf[63]);
                a.free(buf);
            }
        }
    };

    // Round 1: Producer thread allocates 500 64-byte items; Consumer thread frees all 500.
    {
        const prod = try std.Thread.spawn(.{}, Producer.allocateAll, .{ ally, &items, 1 });
        prod.join();
        const cons = try std.Thread.spawn(.{}, Consumer.freeAll, .{ ally, &items, 1 });
        cons.join();
    }

    const class_64 = ShardedPool.classIndex(64, .@"1").?;
    // Consumer kept at most `max_local_per_class` (64) locally; the remaining >= 436 must be in global overflow!
    try std.testing.expect(pool.overflowCount(class_64) >= batch_items - ShardedPool.max_local_per_class);

    // Persistent producer + consumer pair: run 2 warmup rounds so consumer's shard fills its
    // bounded 64-slot local cache, then assert ZERO new chunks are carved across 20 rounds (10,000 items)!
    const PersistentPair = struct {
        pool_ally: Allocator,
        ring: [batch_items]?[]u8 = @splat(null),
        phase: std.atomic.Value(u32) = .init(0),
        chunks_after_warmup: usize = 0,
        pool_ref: *ShardedPool,

        fn producerLoop(ctx: *@This(), rounds: u32) !void {
            var r: u32 = 0;
            while (r < rounds) : (r += 1) {
                while (ctx.phase.load(.acquire) != r * 2) std.atomic.spinLoopHint();
                if (r == 2) {
                    ctx.chunks_after_warmup = ctx.pool_ref.totalCarvedChunks();
                }
                for (&ctx.ring, 0..) |*slot, i| {
                    const b = try ctx.pool_ally.alloc(u8, 64);
                    b[0] = @truncate(r ^ i);
                    b[63] = @truncate(r +% i);
                    slot.* = b;
                }
                ctx.phase.store(r * 2 + 1, .release);
            }
        }

        fn consumerLoop(ctx: *@This(), rounds: u32) !void {
            var r: u32 = 0;
            while (r < rounds) : (r += 1) {
                while (ctx.phase.load(.acquire) != r * 2 + 1) std.atomic.spinLoopHint();
                for (&ctx.ring, 0..) |*slot, i| {
                    const b = slot.*.?;
                    try std.testing.expectEqual(@as(u8, @truncate(r ^ i)), b[0]);
                    try std.testing.expectEqual(@as(u8, @truncate(r +% i)), b[63]);
                    ctx.pool_ally.free(b);
                    slot.* = null;
                }
                ctx.phase.store(r * 2 + 2, .release);
            }
        }
    };

    var pair: PersistentPair = .{ .pool_ally = ally, .pool_ref = &pool };
    const p_thread = try std.Thread.spawn(.{}, PersistentPair.producerLoop, .{ &pair, 22 });
    const c_thread = try std.Thread.spawn(.{}, PersistentPair.consumerLoop, .{ &pair, 22 });
    p_thread.join();
    c_thread.join();

    // Across 20 full steady-state rounds (10,000 cross-thread alloc+free ops), ZERO new chunks carved!
    try std.testing.expectEqual(pair.chunks_after_warmup, pool.totalCarvedChunks());
}

test "multi-threaded contention across 4 threads with alloc, realloc, and cross-thread free" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var pool: ShardedPool = .init(std.testing.allocator);
    defer pool.deinit();
    const ally = pool.allocator();

    const num_threads = 4;
    const iterations = 1500;
    const mailbox_slots = 64;

    const Shared = struct {
        mailboxes: [num_threads][mailbox_slots]std.atomic.Value(?[*]u8) =
            @splat(@splat(.init(null))),
        mailbox_lens: [num_threads][mailbox_slots]usize = @splat(@splat(0)),

        fn worker(self: *@This(), a: Allocator, tid: usize) !void {
            const sizes = [_]usize{ 16, 24, 48, 96, 192, 384, 768, 1536, 3072, 4096, 6000 };
            var local_ring: [16]?[]u8 = @splat(null);
            defer for (&local_ring) |*slot| {
                if (slot.*) |s| a.free(s);
            };

            var iter: usize = 0;
            while (iter < iterations) : (iter += 1) {
                const idx = iter % local_ring.len;
                if (local_ring[idx]) |existing| {
                    const next_sz = sizes[(iter + tid * 3) % sizes.len];
                    const resized = try a.realloc(existing, next_sz);
                    resized[0] = @truncate(tid ^ iter);
                    resized[resized.len - 1] = @truncate(tid +% iter);
                    a.free(resized);
                    local_ring[idx] = null;
                } else {
                    const sz = sizes[(iter + tid) % sizes.len];
                    const buf = try a.alloc(u8, sz);
                    buf[0] = @truncate(tid);
                    buf[sz - 1] = @truncate(iter);
                    local_ring[idx] = buf;
                }

                // Periodically hand an allocation to a neighbor thread to free.
                const m_slot = iter % mailbox_slots;
                const peer = (tid + 1) % num_threads;
                if (self.mailboxes[peer][m_slot].load(.acquire) == null) {
                    const xfer = try a.alloc(u8, 128);
                    @memset(xfer, @truncate(peer + 0x40));
                    self.mailbox_lens[peer][m_slot] = xfer.len;
                    if (self.mailboxes[peer][m_slot].cmpxchgStrong(null, xfer.ptr, .release, .monotonic) != null) {
                        a.free(xfer);
                    }
                }

                // Drain any allocation sent to our mailbox.
                if (self.mailboxes[tid][m_slot].swap(null, .acq_rel)) |ptr| {
                    const len = self.mailbox_lens[tid][m_slot];
                    const slice = ptr[0..len];
                    try std.testing.expectEqual(@as(u8, @truncate(tid + 0x40)), slice[0]);
                    try std.testing.expectEqual(@as(u8, @truncate(tid + 0x40)), slice[len - 1]);
                    a.free(slice);
                }
            }
        }
    };

    var shared: Shared = .{};
    var threads: [num_threads]std.Thread = undefined;
    for (&threads, 0..) |*t, tid| {
        t.* = try std.Thread.spawn(.{}, Shared.worker, .{ &shared, ally, tid });
    }
    for (&threads) |*t| {
        t.join();
    }
    // Drain any remaining items left in mailboxes after join.
    for (0..num_threads) |tid| {
        for (0..mailbox_slots) |m_slot| {
            if (shared.mailboxes[tid][m_slot].swap(null, .acquire)) |ptr| {
                const len = shared.mailbox_lens[tid][m_slot];
                ally.free(ptr[0..len]);
            }
        }
    }
}
