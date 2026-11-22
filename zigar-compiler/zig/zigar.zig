pub const function = struct {
    pub const release = host.releaseFunction;

    pub const Promise = host.Promise;
    pub const PromiseArgOf = host.PromiseArgOf;
    pub const PromiseOf = host.PromiseOf;
    pub const Generator = host.Generator;
    pub const GeneratorArgOf = host.GeneratorArgOf;
    pub const GeneratorOf = host.GeneratorOf;
    pub const AbortSignal = host.AbortSignal;
};

pub const thread = struct {
    pub const use = host.startMultithread;
    pub const end = host.stopMultithread;

    pub const WorkQueue = host.WorkQueue;
};

pub const mem = struct {
    /// Default target-optimal Zigar allocator (`ShardedPool` / `wasm_allocator` on WebAssembly,
    /// `smp_allocator` / `c_allocator` / `page_allocator` on native targets).
    pub const allocator = host.default_allocator;

    /// Opt-in thread-safe wrapper tracking `activeCount()` and `activeBytes()` across all
    /// Zig-side and cross-boundary allocations without adding atomic contention to `allocator`
    /// or mixing user leak assertions with long-lived runtime internal slabs.
    pub const TrackingAllocator = @import("type/tracking-allocator.zig").TrackingAllocator;

    /// Convenience constructor for a `TrackingAllocator` backed by `zigar.mem.allocator`.
    pub fn initTrackingAllocator() TrackingAllocator {
        return .init(allocator);
    }
};

pub const io = struct {
    pub const redirect = host.redirectIO;
};

pub const image = struct {
    pub const formats = host.image.formats;

    pub const Access = host.image.Access;
    pub const Format = host.image.Format;

    pub const Any = host.image.AnyImage;
    pub const Gd = host.image.GdImage;
    pub const Web = host.image.WebImage;
};

pub const js = host.js;

const std = @import("std");
const host = @import("root").host;
