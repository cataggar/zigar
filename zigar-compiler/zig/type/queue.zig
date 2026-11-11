const std = @import("std");
const builtin = @import("builtin");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

pub fn Queue(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        lock: std.atomic.Mutex align(64) = .unlocked,
        buf: []T = &.{},
        head: usize = 0,
        count: usize = 0,
        seq: std.atomic.Value(u32) align(64) = .init(0),
        parked: std.atomic.Value(u32) = .init(0),
        stopped: std.atomic.Value(bool) = .init(false),
        io: std.Io,

        const initial_capacity: usize = 64;

        pub const PullResult = union(enum) {
            item: T,
            empty: u32,
            stopped,
        };

        inline fn lockQueue(self: *@This()) void {
            while (!self.lock.tryLock()) {
                std.atomic.spinLoopHint();
            }
        }

        inline fn unlockQueue(self: *@This()) void {
            self.lock.unlock();
        }

        pub fn init(allocator: std.mem.Allocator, io: std.Io) @This() {
            return .{
                .allocator = allocator,
                .io = io,
            };
        }

        pub fn push(self: *@This(), value: T) !void {
            self.lockQueue();
            while (true) {
                if (self.stopped.load(.acquire)) {
                    self.unlockQueue();
                    return;
                }
                if (self.count < self.buf.len) {
                    const tail = (self.head + self.count) & (self.buf.len - 1);
                    self.buf[tail] = value;
                    self.count += 1;
                    self.unlockQueue();
                    break;
                }
                const cur_len = self.buf.len;
                self.unlockQueue();

                const target_cap = if (cur_len == 0)
                    initial_capacity
                else
                    std.math.mul(usize, cur_len, 2) catch return error.OutOfMemory;
                const new_buf = try self.allocator.alloc(T, target_cap);

                self.lockQueue();
                if (self.stopped.load(.acquire)) {
                    self.unlockQueue();
                    self.allocator.free(new_buf);
                    return;
                }
                if (self.count < self.buf.len) {
                    const tail = (self.head + self.count) & (self.buf.len - 1);
                    self.buf[tail] = value;
                    self.count += 1;
                    self.unlockQueue();
                    self.allocator.free(new_buf);
                    break;
                }
                if (new_buf.len <= self.count) {
                    self.unlockQueue();
                    self.allocator.free(new_buf);
                    self.lockQueue();
                    continue;
                }
                if (self.count > 0) {
                    const first_len = @min(self.count, self.buf.len - self.head);
                    @memcpy(new_buf[0..first_len], self.buf[self.head .. self.head + first_len]);
                    const second_len = self.count - first_len;
                    if (second_len > 0) {
                        @memcpy(new_buf[first_len..self.count], self.buf[0..second_len]);
                    }
                }
                new_buf[self.count] = value;
                const old_buf = self.buf;
                self.buf = new_buf;
                self.head = 0;
                self.count += 1;
                self.unlockQueue();
                if (old_buf.len > 0) {
                    self.allocator.free(old_buf);
                }
                break;
            }
            _ = self.seq.fetchAdd(1, .seq_cst);
            if (self.parked.load(.seq_cst) > 0) {
                std.Io.futexWake(self.io, u32, &self.seq.raw, 1);
            }
        }

        pub fn pullOrSnapshot(self: *@This()) PullResult {
            self.lockQueue();
            if (self.count > 0) {
                const item = self.buf[self.head];
                self.buf[self.head] = undefined;
                self.head = (self.head + 1) & (self.buf.len - 1);
                self.count -= 1;
                self.unlockQueue();
                return .{ .item = item };
            }
            if (self.stopped.load(.acquire)) {
                self.unlockQueue();
                return .stopped;
            }
            const observed = self.seq.load(.seq_cst);
            self.unlockQueue();
            return .{ .empty = observed };
        }

        pub fn pull(self: *@This()) ?T {
            self.lockQueue();
            if (self.count > 0) {
                const item = self.buf[self.head];
                self.buf[self.head] = undefined;
                self.head = (self.head + 1) & (self.buf.len - 1);
                self.count -= 1;
                self.unlockQueue();
                return item;
            }
            self.unlockQueue();
            return null;
        }

        pub fn waitFor(self: *@This(), observed_seq: u32) void {
            _ = self.parked.fetchAdd(1, .seq_cst);
            defer _ = self.parked.fetchSub(1, .monotonic);
            if (self.seq.load(.seq_cst) == observed_seq and !self.stopped.load(.seq_cst)) {
                std.Io.futexWaitUncancelable(self.io, u32, &self.seq.raw, observed_seq);
            }
        }

        pub fn wait(self: *@This()) void {
            self.lockQueue();
            if (self.count > 0 or self.stopped.load(.acquire)) {
                self.unlockQueue();
                return;
            }
            const observed = self.seq.load(.seq_cst);
            self.unlockQueue();
            self.waitFor(observed);
        }

        pub fn isStopped(self: *const @This()) bool {
            return self.stopped.load(.acquire);
        }

        pub fn stop(self: *@This()) void {
            self.lockQueue();
            if (self.stopped.swap(true, .seq_cst)) {
                self.unlockQueue();
                return;
            }
            self.head = 0;
            self.count = 0;
            self.unlockQueue();
            _ = self.seq.fetchAdd(1, .seq_cst);
            std.Io.futexWake(self.io, u32, &self.seq.raw, std.math.maxInt(u32));
        }

        pub fn deinit(self: *@This()) void {
            if (self.buf.len > 0) {
                self.allocator.free(self.buf);
            }
            self.buf = &.{};
            self.head = 0;
            self.count = 0;
        }
    };
}

test "Queue.pull()" {
    var thread_io = std.Io.Threaded.init_single_threaded;
    var queue: Queue(i32) = .init(std.testing.allocator, thread_io.io());
    defer queue.deinit();
    try queue.push(123);
    try queue.push(456);
    const value1 = queue.pull();
    try expectEqual(123, value1);
    const value2 = queue.pull();
    try expectEqual(456, value2);
    const value3 = queue.pull();
    try expectEqual(null, value3);
    try queue.push(888);
    const value4 = queue.pull();
    try expectEqual(888, value4);
}

test "Queue: FIFO wrap-around across multiple resizes" {
    var thread_io = std.Io.Threaded.init_single_threaded;
    var queue: Queue(usize) = .init(std.testing.allocator, thread_io.io());
    defer queue.deinit();

    // Advance head into the middle of the initial 64-slot ring buffer
    for (0..40) |i| try queue.push(i);
    for (0..30) |i| try expectEqual(i, queue.pull());

    // Fill remaining 54 slots so count == 64 with head == 30 (wrapped tail)
    for (40..94) |i| try queue.push(i);
    try expectEqual(@as(usize, 64), queue.buf.len);

    // Trigger resize 64 -> 128 across wrap-around boundary
    try queue.push(94);
    try expectEqual(@as(usize, 128), queue.buf.len);

    // Advance head again, then force multiple resizes (128 -> 256 -> 512)
    for (30..80) |i| try expectEqual(i, queue.pull());
    for (95..395) |i| try queue.push(i);
    try expectEqual(@as(usize, 512), queue.buf.len);

    for (80..395) |i| {
        switch (queue.pullOrSnapshot()) {
            .item => |v| try expectEqual(i, v),
            else => return error.TestUnexpectedResult,
        }
    }
    try expectEqual(null, queue.pull());
    switch (queue.pullOrSnapshot()) {
        .empty => {},
        else => return error.TestUnexpectedResult,
    }
}

test "Queue: stop() drains items and prevents blocking" {
    var thread_io = std.Io.Threaded.init_single_threaded;
    var queue: Queue(i32) = .init(std.testing.allocator, thread_io.io());
    defer queue.deinit();

    try queue.push(10);
    try queue.push(20);
    try queue.push(30);
    try expectEqual(10, queue.pull());
    try expect(!queue.isStopped());

    const seq_before_stop = queue.seq.load(.seq_cst);
    queue.stop();
    try expect(queue.isStopped());
    try expectEqual(null, queue.pull());
    try expectEqual(Queue(i32).PullResult.stopped, queue.pullOrSnapshot());

    // Pushing after stop is a safe no-op without leaking
    try queue.push(99);
    try expectEqual(null, queue.pull());
    try expectEqual(Queue(i32).PullResult.stopped, queue.pullOrSnapshot());

    // wait() and waitFor() return immediately when stopped
    queue.wait();
    queue.waitFor(seq_before_stop);
    queue.stop();
}

test "Queue: multithreaded MPMC stress with resize and stop()" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const operations: usize = 25_000;
    const num_producers: usize = 4;
    const num_consumers: usize = 6;

    const Ctx = struct {
        queue: Queue(usize),
        ready_futex: std.atomic.Value(u32) = .init(0),
        ready_count: std.atomic.Value(usize) = .init(0),
        producers_done: std.atomic.Value(usize) = .init(0),
        all_done_futex: std.atomic.Value(u32) = .init(0),
        consumed_count: std.atomic.Value(usize) = .init(0),
        consumer_sums: [num_consumers]u64 = @splat(0),
        consumers_exited: std.atomic.Value(usize) = .init(0),
        consumers_done_futex: std.atomic.Value(u32) = .init(0),

        fn waitReady(self: *@This()) void {
            if (self.ready_count.fetchAdd(1, .acq_rel) == num_producers + num_consumers - 1) {
                self.ready_futex.store(1, .release);
                std.Io.futexWake(self.queue.io, u32, &self.ready_futex.raw, std.math.maxInt(u32));
            } else {
                std.Io.futexWaitUncancelable(self.queue.io, u32, &self.ready_futex.raw, 0);
            }
        }

        fn producer(self: *@This(), id: usize) !void {
            self.waitReady();
            const base = id * operations;
            for (0..operations) |i| {
                try self.queue.push(base + i + 1);
            }
            if (self.producers_done.fetchAdd(1, .acq_rel) == num_producers - 1) {
                self.all_done_futex.store(1, .release);
                std.Io.futexWake(self.queue.io, u32, &self.all_done_futex.raw, 1);
            }
        }

        fn consumer(self: *@This(), id: usize) void {
            self.waitReady();
            var local_sum: u64 = 0;
            while (true) {
                switch (self.queue.pullOrSnapshot()) {
                    .item => |val| {
                        local_sum += val;
                        if (self.consumed_count.fetchAdd(1, .acq_rel) + 1 == num_producers * operations) {
                            self.all_done_futex.store(2, .release);
                            std.Io.futexWake(self.queue.io, u32, &self.all_done_futex.raw, 1);
                        }
                    },
                    .empty => |seq| self.queue.waitFor(seq),
                    .stopped => break,
                }
            }
            self.consumer_sums[id] = local_sum;
            if (self.consumers_exited.fetchAdd(1, .acq_rel) == num_consumers - 1) {
                self.consumers_done_futex.store(1, .release);
                std.Io.futexWake(self.queue.io, u32, &self.consumers_done_futex.raw, 1);
            }
        }
    };

    var thread_io = std.Io.Threaded.init_single_threaded;
    const io = thread_io.io();
    var ctx: Ctx = .{
        .queue = .init(std.testing.allocator, io),
    };
    defer ctx.queue.deinit();

    var prod_threads: [num_producers]std.Thread = undefined;
    var cons_threads: [num_consumers]std.Thread = undefined;
    for (0..num_consumers) |i| {
        cons_threads[i] = try std.Thread.spawn(.{}, Ctx.consumer, .{ &ctx, i });
    }
    for (0..num_producers) |i| {
        prod_threads[i] = try std.Thread.spawn(.{}, Ctx.producer, .{ &ctx, i });
    }
    for (&prod_threads) |t| t.join();

    const total_items: usize = num_producers * operations;
    while (ctx.consumed_count.load(.acquire) < total_items) {
        const cur = ctx.all_done_futex.load(.acquire);
        if (ctx.consumed_count.load(.acquire) >= total_items) break;
        std.Io.futexWaitUncancelable(io, u32, &ctx.all_done_futex.raw, cur);
    }

    // Stop queue and ensure all parked consumers wake and exit cleanly
    ctx.queue.stop();
    for (&cons_threads) |t| t.join();

    var actual_sum: u64 = 0;
    for (ctx.consumer_sums) |s| actual_sum += s;
    const total_u64: u64 = total_items;
    const expected_sum: u64 = total_u64 * (total_u64 + 1) / 2;
    try expectEqual(total_items, ctx.consumed_count.load(.acquire));
    try expectEqual(expected_sum, actual_sum);
    try expectEqual(num_consumers, ctx.consumers_exited.load(.acquire));
}
