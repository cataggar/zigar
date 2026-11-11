const std = @import("std");
const expectEqual = std.testing.expectEqual;
const builtin = @import("builtin");

const system = @import("../system.zig");
const fn_transform = @import("../zigft/fn-transform.zig");
const Generator = @import("generator.zig").Generator;
const GeneratorOf = @import("generator.zig").GeneratorOf;
const Promise = @import("promise.zig").Promise;
const PromiseOf = @import("promise.zig").PromiseOf;
const Queue = @import("queue.zig").Queue;
const util = @import("util.zig");

pub fn WorkQueue(comptime ns: type, comptime internal_ns: type) type {
    const decl_names = std.meta.declarations(ns);
    return struct {
        queue: Queue(WorkItem) = undefined,
        thread_count: usize = 0,
        status: Status = .uninitialized,
        init_remaining: usize = undefined,
        init_futex: std.atomic.Value(u32) = undefined,
        init_result: WaitResult = undefined,
        init_promise: ?Promise(WaitResult) = undefined,
        deinit_promise: ?Promise(void) = undefined,

        pub const ThreadStartError = switch (@hasDecl(ns, "onThreadStart")) {
            false => error{},
            true => switch (@typeInfo(util.ReturnValue(ns.onThreadStart))) {
                .error_union => |eu| eu.error_set,
                else => error{},
            },
        };
        pub const ThreadStartParams = switch (@hasDecl(ns, "onThreadStart")) {
            false => struct {},
            true => std.meta.ArgsTuple(@TypeOf(ns.onThreadStart)),
        };
        pub const ThreadEndParams = switch (@hasDecl(ns, "onThreadEnd")) {
            false => struct {},
            true => std.meta.ArgsTuple(@TypeOf(ns.onThreadEnd)),
        };
        pub const Error = std.mem.Allocator.Error || error{Unexpected};
        pub const Options = init: {
            // when thread_start_params or thread_end_params is void, we want it to have a default value
            const Templ = struct {
                allocator: std.mem.Allocator = def_allocator,
                stack_size: usize = if (builtin.target.cpu.arch.isWasm()) 262144 else std.Thread.SpawnConfig.default_stack_size,
                n_jobs: usize = 1,
                thread_start_params: ThreadStartParams,
                thread_end_params: ThreadEndParams,
            };
            const templ_info = @typeInfo(Templ).@"struct";
            var field_attrs: [templ_info.field_names.len]std.lang.Type.Struct.FieldAttributes = undefined;
            for (templ_info.field_attrs, 0..) |fa, i| {
                const FieldType = templ_info.field_types[i];
                field_attrs[i] = .{
                    .default_value_ptr = fa.default_value_ptr orelse switch (@sizeOf(FieldType)) {
                        0 => @ptrCast(&@as(FieldType, .{})),
                        else => null,
                    },
                };
            }
            break :init @Struct(.auto, null, templ_info.field_names, templ_info.field_types, &field_attrs);
        };
        pub const InitResult = @typeInfo(@TypeOf(init)).@"fn".return_type.?;
        pub const InitError = @typeInfo(InitResult).error_union.error_set;

        pub fn init(self: *@This(), options: Options) !void {
            while (true) {
                const prev = @cmpxchgStrong(Status, &self.status, .uninitialized, .initializing, .acq_rel, .acquire) orelse break;
                switch (prev) {
                    .uninitialized => unreachable,
                    .initializing => std.atomic.spinLoopHint(),
                    .initialized => return,
                    .deinitializing => return error.Deinitializing,
                }
            }
            const allocator = options.allocator;
            self.queue = .init(allocator, system.io);
            @atomicStore(usize, &self.thread_count, options.n_jobs, .monotonic);
            @atomicStore(usize, &self.init_remaining, options.n_jobs, .monotonic);
            self.init_futex = std.atomic.Value(u32).init(0);
            self.init_result = {};
            self.init_promise = null;
            self.deinit_promise = null;
            if (@hasDecl(internal_ns, "onQueueInit")) {
                const result = @call(.auto, internal_ns.onQueueInit, .{});
                switch (@typeInfo(@TypeOf(result))) {
                    .error_union => if (result) |_| {} else |err| {
                        self.queue.deinit();
                        @atomicStore(Status, &self.status, .uninitialized, .release);
                        return err;
                    },
                    else => {},
                }
            }
            var spawned: usize = 0;
            errdefer {
                const unspawned = options.n_jobs - spawned;
                @atomicStore(Status, &self.status, .deinitializing, .release);
                self.queue.stop();
                if (@atomicRmw(usize, &self.thread_count, .Sub, unspawned, .acq_rel) == unspawned) {
                    self.queue.deinit();
                    if (@hasDecl(internal_ns, "onQueueDeinit")) {
                        _ = @call(.auto, internal_ns.onQueueDeinit, .{});
                    }
                    @atomicStore(Status, &self.status, .uninitialized, .release);
                }
            }
            const min_stack_size: usize = if (std.Thread.use_pthreads) switch (@bitSizeOf(usize)) {
                32 => 4096,
                else => 1048576,
            } else std.heap.pageSize();
            const spawn_config: std.Thread.SpawnConfig = .{
                .stack_size = @max(min_stack_size, options.stack_size),
                .allocator = allocator,
            };
            for (0..options.n_jobs) |_| {
                const thread = try std.Thread.spawn(spawn_config, handleWorkItems, .{
                    self,
                    options.thread_start_params,
                    options.thread_end_params,
                });
                thread.detach();
                spawned += 1;
            }
            if (options.n_jobs == 0) {
                self.init_futex.store(1, .release);
            }
            _ = @cmpxchgStrong(Status, &self.status, .initializing, .initialized, .acq_rel, .acquire);
        }

        pub fn wait(self: *@This()) WaitResult {
            std.Io.futexWaitUncancelable(system.io, u32, &self.init_futex.raw, 0);
            return self.init_result;
        }

        pub fn waitAsync(self: *@This(), promise: Promise(WaitResult)) void {
            if (self.init_futex.load(.acquire) == 1) {
                promise.resolve(self.init_result);
            } else {
                self.init_promise = promise;
            }
        }

        pub fn deinitAsync(self: *@This(), promise: ?Promise(void)) void {
            while (true) {
                const prev = @cmpxchgStrong(Status, &self.status, .initialized, .deinitializing, .acq_rel, .acquire) orelse break;
                switch (prev) {
                    .initialized => unreachable,
                    .initializing => std.atomic.spinLoopHint(),
                    .uninitialized, .deinitializing => {
                        if (promise) |p| p.resolve({});
                        return;
                    },
                }
            }
            self.deinit_promise = promise;
            self.queue.stop();
        }

        pub fn push(self: *@This(), comptime func: anytype, args: ArgsOf(func), dest: ?PromiseOrGenerator(func)) Error!void {
            while (true) {
                switch (@atomicLoad(Status, &self.status, .acquire)) {
                    .initialized => break,
                    .initializing => std.atomic.spinLoopHint(),
                    .uninitialized => {
                        // see if we can do initialize automatically
                        const can_auto_init = comptime (@typeInfo(ThreadStartParams).@"struct".field_names.len == 0 and
                            @typeInfo(ThreadEndParams).@"struct".field_names.len == 0);
                        if (can_auto_init) {
                            self.init(.{ .n_jobs = 1 }) catch |err| {
                                return switch (err) {
                                    error.OutOfMemory => error.OutOfMemory,
                                    else => error.Unexpected,
                                };
                            };
                            break;
                        } else {
                            return error.Unexpected;
                        }
                    },
                    .deinitializing => return error.Unexpected,
                }
            }
            const key = comptime enumOf(func);
            const fieldName = @tagName(key);
            const Call = @FieldType(WorkItem, fieldName);
            const item = switch (@hasField(Call, "generator")) {
                true => @unionInit(WorkItem, fieldName, .{ .args = args, .generator = dest }),
                false => @unionInit(WorkItem, fieldName, .{ .args = args, .promise = dest }),
            };
            try self.queue.push(item);
        }

        pub fn clear(self: *@This()) void {
            switch (@atomicLoad(Status, &self.status, .acquire)) {
                .initialized => {},
                else => return,
            }
            while (self.queue.pull() != null) {}
        }

        pub fn asyncify(comptime self: *@This(), comptime func: anytype) Asyncified(@TypeOf(func)) {
            const FT = @TypeOf(func);
            const Args = std.meta.ArgsTuple(FT);
            const AFT = Asyncified(FT);
            const AsyncArgs = std.meta.ArgsTuple(AFT);
            const async_fn_info = @typeInfo(AFT).@"fn";
            const AsyncRT = async_fn_info.return_type.?;
            const cc = async_fn_info.attrs.@"callconv";
            const async_ns = struct {
                fn push(async_args: AsyncArgs) AsyncRT {
                    var args: Args = undefined;
                    inline for (&args, 0..) |*ptr, i| ptr.* = async_args[i];
                    const p_or_g = async_args[async_args.len - 1];
                    return self.push(func, args, p_or_g);
                }
            };
            return fn_transform.spreadArgs(async_ns.push, cc);
        }

        pub fn Promisified(comptime func: anytype) type {
            const FT = @TypeOf(func);
            return switch (@typeInfo(FT)) {
                .@"fn" => Asyncified(FT),
                .enum_literal => switch (func) {
                    .startup => fn (usize, Promise(WaitResult)) InitError!void,
                    .startup1 => fn (Promise(WaitResult)) InitError!void,
                    .shutdown => fn (Promise(void)) void,
                    else => @compileError("Expected .startup, startup1, or shutdown, received ." ++ @tagName(func)),
                },
                else => @compileError("Expected function or enum literal, received " ++ @typeName(FT)),
            };
        }

        pub fn promisify(comptime self: *@This(), comptime func: anytype) Promisified(func) {
            const FT = @TypeOf(func);
            switch (@typeInfo(FT)) {
                .@"fn" => {
                    const PorG = PromiseOrGenerator(@TypeOf(func));
                    if (PorG.internal_type == .generator) {
                        @compileError("Generator function encountered");
                    }
                    return self.asyncify(func);
                },
                .enum_literal => {
                    switch (func) {
                        .startup, .startup1 => {
                            if (@typeInfo(ThreadStartParams).@"struct".field_names.len > 0) {
                                @compileError("Cannot generate function due to onThreadStart() requiring arguments");
                            }
                            if (@typeInfo(ThreadEndParams).@"struct".field_names.len > 0) {
                                @compileError("Cannot generate function due to onThreadEnd() requiring arguments");
                            }
                            const f_ns = switch (func == .startup) {
                                true => struct {
                                    fn startup(thread_count: usize, promise: Promise(WaitResult)) !void {
                                        try self.init(.{ .n_jobs = thread_count });
                                        self.waitAsync(promise);
                                    }
                                },
                                false => struct {
                                    fn startup(promise: Promise(WaitResult)) !void {
                                        try self.init(.{ .n_jobs = 1 });
                                        self.waitAsync(promise);
                                    }
                                },
                            };
                            return f_ns.startup;
                        },
                        .shutdown => {
                            const f_ns = struct {
                                fn shutdown(promise: Promise(void)) void {
                                    return self.deinitAsync(promise);
                                }
                            };
                            return f_ns.shutdown;
                        },
                        else => unreachable,
                    }
                },
                else => @compileError("Expected function or enum literal, received " ++ @typeName(FT)),
            }
        }

        pub fn Asyncified(comptime FT: type) type {
            const PorG = PromiseOrGenerator(FT);
            const fn_info = @typeInfo(FT).@"fn";
            const param_count = fn_info.param_types.len + 1;
            var param_types: [param_count]type = undefined;
            var param_attrs: [param_count]std.lang.Type.Fn.ParamAttributes = undefined;
            inline for (fn_info.param_types, 0..) |param_type, i| {
                param_types[i] = param_type.?;
                param_attrs[i] = fn_info.param_attrs[i];
            }
            param_types[param_count - 1] = PorG;
            param_attrs[param_count - 1] = .{};
            return @Fn(&param_types, &param_attrs, Error!void, fn_info.attrs);
        }

        test "Asyncified" {
            const FT1 = Asyncified(fn () void);
            try expectEqual(fn (Promise(void)) Error!void, FT1);
            const FT2 = Asyncified(fn (i32, *anyopaque) error{CheeseMelted}!i64);
            try expectEqual(fn (i32, *anyopaque, Promise(error{CheeseMelted}!i64)) Error!void, FT2);
            const Iterator = struct {
                ptr: *anyopaque,

                pub fn next(_: *@This()) error{CowboyHatesCows}!?i32 {
                    return 0;
                }
            };
            const FT3 = Asyncified(fn () Iterator);
            try expectEqual(fn (Generator(error{CowboyHatesCows}!?i32, false)) Error!void, FT3);
        }

        const def_allocator = switch (builtin.target.cpu.arch.isWasm()) {
            true => @import("sharded-allocator.zig").allocator,
            false => std.heap.c_allocator,
        };
        const Status = enum(u8) {
            uninitialized,
            initializing,
            initialized,
            deinitializing,
        };
        const WaitResult = switch (ThreadStartError) {
            error{} => void,
            else => ThreadStartError!void,
        };
        const WorkItem = init: {
            var fields: [decl_names.len]struct {
                name: [:0]const u8,
                type: type,
            } = undefined;
            var count = 0;
            for (decl_names) |decl_name| {
                const DT = @TypeOf(@field(ns, decl_name));
                switch (@typeInfo(DT)) {
                    .@"fn" => |f| {
                        if (f.return_type) |RT| {
                            // if the return value is an iterator, then a generator is expected
                            // otherwise an optional promise can be provided
                            const Request = if (util.IteratorReturnValue(RT)) |IT| struct {
                                args: std.meta.ArgsTuple(DT),
                                generator: ?Generator(IT, util.isIteratorAllocating(RT)),
                            } else struct {
                                args: std.meta.ArgsTuple(DT),
                                promise: ?Promise(RT),
                            };
                            fields[count] = .{
                                .name = decl_name,
                                .type = Request,
                            };
                            count += 1;
                        }
                    },
                    else => {},
                }
            }
            const TagInt = if (count <= 256) u8 else u16;
            var field_names: [count][]const u8 = undefined;
            var field_types: [count]type = undefined;
            var field_attrs: [count]std.lang.Type.Union.FieldAttributes = undefined;
            var tag_values: [count]TagInt = undefined;
            for (fields[0..count], 0..) |field, i| {
                field_names[i] = field.name;
                field_types[i] = field.type;
                field_attrs[i] = .{};
                tag_values[i] = i;
            }
            const Tag = @Enum(TagInt, .exhaustive, &field_names, &tag_values);
            break :init @Union(.auto, Tag, &field_names, &field_types, &field_attrs);
        };
        const WorkItemEnum = @typeInfo(WorkItem).@"union".tag_type.?;

        fn enumOf(comptime func: anytype) WorkItemEnum {
            return for (decl_names) |decl_name| {
                const dv = @field(ns, decl_name);
                if (@TypeOf(dv) == @TypeOf(func)) {
                    if (dv == func) break @field(WorkItemEnum, decl_name);
                }
            } else @compileError("Function not found in " ++ @typeName(ns));
        }

        fn ArgsOf(comptime func: anytype) type {
            return std.meta.ArgsTuple(@TypeOf(func));
        }

        fn PromiseOrGenerator(comptime func: anytype) type {
            const RT = util.ReturnValue(func);
            return if (util.IteratorReturnValue(RT)) |IT|
                Generator(IT, util.isIteratorAllocating(RT))
            else
                Promise(RT);
        }

        fn handleWorkItems(
            self: *@This(),
            thread_start_params: ThreadStartParams,
            thread_end_params: ThreadEndParams,
        ) void {
            var start_succeeded = true;
            if (@hasDecl(ns, "onThreadStart")) {
                const result = @call(.auto, ns.onThreadStart, thread_start_params);
                if (ThreadStartError != error{}) {
                    if (result) |_| {} else |err| {
                        self.init_result = err;
                        start_succeeded = false;
                    }
                }
            }
            if (@atomicRmw(usize, &self.init_remaining, .Sub, 1, .acq_rel) == 1) {
                if (@typeInfo(WaitResult) != .error_union or !std.meta.isError(self.init_result)) {
                    self.init_futex.store(1, .release);
                    std.Io.futexWake(system.io, u32, &self.init_futex.raw, std.math.maxInt(u32));
                    if (self.init_promise) |promise| promise.resolve(self.init_result);
                } else {
                    // delay reporting error until threads have stopped
                    while (true) {
                        const cur = @atomicLoad(Status, &self.status, .acquire);
                        if (cur == .deinitializing) break;
                        if (@cmpxchgWeak(Status, &self.status, cur, .deinitializing, .acq_rel, .acquire) == null) break;
                    }
                    self.queue.stop();
                }
            }
            while (true) {
                switch (self.queue.pullOrSnapshot()) {
                    .item => |item| invokeFunction(item),
                    .empty => |seq| self.queue.waitFor(seq),
                    .stopped => break,
                }
            }
            if (@hasDecl(ns, "onThreadEnd")) {
                if (start_succeeded) _ = @call(.auto, ns.onThreadEnd, thread_end_params);
            }
            if (@atomicRmw(usize, &self.thread_count, .Sub, 1, .acq_rel) == 1) {
                self.queue.deinit();
                const init_result = self.init_result;
                const init_promise = self.init_promise;
                const deinit_promise = self.deinit_promise;
                if (@hasDecl(internal_ns, "onQueueDeinit")) {
                    _ = @call(.auto, internal_ns.onQueueDeinit, .{});
                }
                const has_init_err = @typeInfo(WaitResult) == .error_union and std.meta.isError(init_result);
                if (has_init_err) {
                    self.init_futex.store(1, .release);
                    std.Io.futexWake(system.io, u32, &self.init_futex.raw, std.math.maxInt(u32));
                }
                @atomicStore(Status, &self.status, .uninitialized, .release);
                if (has_init_err) {
                    if (init_promise) |promise| promise.resolve(init_result);
                }
                if (deinit_promise) |promise| promise.resolve({});
            }
        }

        fn invokeFunction(item: WorkItem) void {
            const un = @typeInfo(WorkItem).@"union";
            inline for (un.field_names) |field_name| {
                const key = @field(WorkItemEnum, field_name);
                if (item == key) {
                    const func = @field(ns, field_name);
                    const call = @field(item, field_name);
                    const result = @call(.auto, func, call.args);
                    switch (@hasField(@TypeOf(call), "generator")) {
                        true => if (call.generator) |g| g.pipe(result),
                        false => if (call.promise) |p| p.resolve(result),
                    }
                }
            }
        }
    };
}

test "WorkQueue.push()" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var thread_io = std.Io.Threaded.init_single_threaded;
    if (@TypeOf(&system.io) == *std.Io) {
        system.io = thread_io.io();
    } else {
        _ = &thread_io;
    }
    const test_ns = struct {
        var total: i32 = 0;

        pub fn hello(num: i32) void {
            total += num;
        }

        pub fn world() void {}

        pub fn shutdown(futex: *std.atomic.Value(u32), _: void) void {
            futex.store(1, .monotonic);
            std.Io.futexWake(system.io, u32, &futex.raw, 1);
        }
    };
    var gpa = std.heap.DebugAllocator(.{}).init;
    var queue: WorkQueue(test_ns, struct {}) = .{};
    try queue.init(.{ .allocator = gpa.allocator(), .n_jobs = 1 });
    try queue.push(test_ns.hello, .{123}, null);
    try queue.push(test_ns.hello, .{456}, null);
    try queue.push(test_ns.world, .{}, null);
    try std.Io.sleep(system.io, .fromMilliseconds(100), .real);
    try expectEqual(123 + 456, test_ns.total);
    var futex: std.atomic.Value(u32) = .init(0);
    queue.deinitAsync(.init(&futex, test_ns.shutdown));
    // wait for thread shutdown
    std.Io.futexWaitUncancelable(system.io, u32, &futex.raw, 0);
}

test "WorkQueue.promisify()" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var thread_io = std.Io.Threaded.init_single_threaded;
    if (@TypeOf(&system.io) == *std.Io) {
        system.io = thread_io.io();
    } else {
        _ = &thread_io;
    }
    const test_ns1 = struct {
        var total: i32 = 0;

        pub fn hello(num: i32) i32 {
            total += num;
            return num;
        }

        pub fn world() error{Doh}!bool {
            return error.Doh;
        }
    };
    const test_ns2 = struct {
        var hello_result: ?i32 = null;
        var world_result: ?bool = null;

        fn hello_callback(_: ?*anyopaque, result: i32) void {
            hello_result = result;
        }

        fn world_callback(_: ?*anyopaque, result: error{Doh}!bool) void {
            world_result = result catch false;
        }

        fn init(allocator: std.mem.Allocator) !void {
            try queue.init(.{ .allocator = allocator, .n_jobs = 1 });
        }

        fn deinit() void {
            var futex: std.atomic.Value(u32) = .init(0);
            queue.deinitAsync(.init(&futex, shutdown));
            // wait for thread shutdown
            std.Io.futexWait(system.io, u32, &futex.raw, 0) catch unreachable;
        }

        fn shutdown(futex: *std.atomic.Value(u32), _: void) void {
            futex.store(1, .monotonic);
            std.Io.futexWake(system.io, u32, &futex.raw, 1);
        }

        var queue: WorkQueue(test_ns1, struct {}) = .{};

        pub const hello = queue.promisify(test_ns1.hello);
        pub const world = queue.promisify(test_ns1.world);
    };
    var gpa = std.heap.DebugAllocator(.{}).init;
    try test_ns2.init(gpa.allocator());
    const promise1: PromiseOf(test_ns1.hello) = .init(null, test_ns2.hello_callback);
    try test_ns2.hello(1234, promise1);
    const promise2: PromiseOf(test_ns1.world) = .init(null, test_ns2.world_callback);
    try test_ns2.world(promise2);
    try std.Io.sleep(system.io, .fromMilliseconds(100), .real);
    try expectEqual(1234, test_ns1.total);
    try expectEqual(1234, test_ns2.hello_result);
    try expectEqual(false, test_ns2.world_result);
    test_ns2.deinit();
}

test "WorkQueue: multi-worker burst across ring resizes and re-init" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var thread_io = std.Io.Threaded.init_single_threaded;
    if (@TypeOf(&system.io) == *std.Io) {
        system.io = thread_io.io();
    } else {
        _ = &thread_io;
    }
    const item_count: usize = 500;
    const test_ns = struct {
        var sum: std.atomic.Value(usize) = .init(0);
        var done_count: std.atomic.Value(usize) = .init(0);
        var done_futex: std.atomic.Value(u32) = .init(0);

        pub fn add(num: usize) void {
            _ = sum.fetchAdd(num, .acq_rel);
            if (done_count.fetchAdd(1, .acq_rel) + 1 == item_count) {
                done_futex.store(1, .release);
                std.Io.futexWake(system.io, u32, &done_futex.raw, 1);
            }
        }

        fn onShutdown(futex: *std.atomic.Value(u32), _: void) void {
            futex.store(1, .release);
            std.Io.futexWake(system.io, u32, &futex.raw, 1);
        }
    };
    var wq: WorkQueue(test_ns, struct {}) = .{};
    for (0..2) |_| {
        test_ns.sum.store(0, .release);
        test_ns.done_count.store(0, .release);
        test_ns.done_futex.store(0, .release);

        try wq.init(.{ .allocator = std.testing.allocator, .n_jobs = 4 });
        wq.wait();

        for (1..item_count + 1) |i| {
            try wq.push(test_ns.add, .{i}, null);
        }
        while (test_ns.done_count.load(.acquire) < item_count) {
            std.Io.futexWaitUncancelable(system.io, u32, &test_ns.done_futex.raw, 0);
        }
        try expectEqual(item_count * (item_count + 1) / 2, test_ns.sum.load(.acquire));

        var shutdown_futex: std.atomic.Value(u32) = .init(0);
        wq.deinitAsync(.init(&shutdown_futex, test_ns.onShutdown));
        std.Io.futexWaitUncancelable(system.io, u32, &shutdown_futex.raw, 0);
        try expectEqual(.uninitialized, @atomicLoad(@TypeOf(wq.status), &wq.status, .acquire));
    }
}
