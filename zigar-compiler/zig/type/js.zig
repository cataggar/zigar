const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const util = @import("util.zig");
const module = @This();

pub const JsType = enum(u8) {
    @"undefined" = 0,
    object = 1,
    boolean = 2,
    number = 3,
    bigint = 4,
    string = 5,
    symbol = 6,
    function = 7,
};

pub const Any = opaque {};
pub const Unknown = opaque {};
pub const Object = opaque {};
pub const Symbol = opaque {};
pub const Function = opaque {};

pub const reserved_undefined_handle: u32 = 0;
pub const reserved_null_handle: u32 = 1;
pub const reserved_false_handle: u32 = 2;
pub const reserved_true_handle: u32 = 3;
pub const reserved_global_this_handle: u32 = 4;
pub const first_dynamic_slot: u32 = 8;

fn extractHandle(value: anytype) u32 {
    const V = @TypeOf(value);
    if (V == @TypeOf(null)) return reserved_null_handle;
    if (V == @TypeOf(undefined)) return reserved_undefined_handle;
    if (V == bool) return if (value) reserved_true_handle else reserved_false_handle;
    if (comptime util.getInternalType(V) == .js_value) {
        return value.handle;
    }
    switch (@typeInfo(V)) {
        .pointer => |pt| {
            if (pt.size == .one and comptime util.getInternalType(pt.child) == .js_value) {
                return value.*.handle;
            }
        },
        else => {},
    }
    @compileError("Expected zigar.js.Ref(T), received " ++ @typeName(V));
}

pub fn Js(comptime host: type) type {
    return struct {
        pub const JsType = module.JsType;
        pub const Any = module.Any;
        pub const Unknown = module.Unknown;
        pub const Object = module.Object;
        pub const Symbol = module.Symbol;
        pub const Function = module.Function;

        pub const reserved_undefined_handle = module.reserved_undefined_handle;
        pub const reserved_null_handle = module.reserved_null_handle;
        pub const reserved_false_handle = module.reserved_false_handle;
        pub const reserved_true_handle = module.reserved_true_handle;
        pub const reserved_global_this_handle = module.reserved_global_this_handle;
        pub const first_dynamic_slot = module.first_dynamic_slot;

        pub fn activeHandleCount() u32 {
            return host.getJsValueCount();
        }

        pub fn Ref(comptime T: type) type {
            return extern struct {
                const Self = @This();
                pub const Target = T;
                pub const internal_type: util.InternalType = .js_value;

                handle: u32,

                pub const @"undefined": Self = .{ .handle = module.reserved_undefined_handle };
                pub const @"null": Self = .{ .handle = module.reserved_null_handle };
                pub const @"false": Self = .{ .handle = module.reserved_false_handle };
                pub const @"true": Self = .{ .handle = module.reserved_true_handle };
                pub const globalThis: Self = .{ .handle = module.reserved_global_this_handle };
                pub const global_this: Self = .{ .handle = module.reserved_global_this_handle };

                pub inline fn fromBool(value: bool) Self {
                    return .{ .handle = if (value) module.reserved_true_handle else module.reserved_false_handle };
                }

                pub inline fn isUndefined(self: Self) bool {
                    return self.handle == module.reserved_undefined_handle;
                }

                pub inline fn isNull(self: Self) bool {
                    return self.handle == module.reserved_null_handle;
                }

                pub inline fn isNullOrUndefined(self: Self) bool {
                    return self.handle <= module.reserved_null_handle;
                }

                pub inline fn isReserved(self: Self) bool {
                    return self.handle < module.first_dynamic_slot;
                }

                pub fn clone(self: Self) Self {
                    if (self.handle <= module.reserved_global_this_handle) return self;
                    return .{ .handle = host.cloneJsValue(self.handle) };
                }

                pub fn deinit(self: Self) void {
                    if (self.handle <= module.reserved_global_this_handle) return;
                    host.releaseJsValue(self.handle);
                }

                pub fn typeof(self: Self) module.JsType {
                    return switch (self.handle) {
                        module.reserved_undefined_handle => .@"undefined",
                        module.reserved_null_handle, module.reserved_global_this_handle => .object,
                        module.reserved_false_handle, module.reserved_true_handle => .boolean,
                        else => host.typeofJsValue(self.handle),
                    };
                }

                pub fn instanceof(self: Self, ctor: anytype) bool {
                    return host.instanceofJsValue(self.handle, extractHandle(ctor));
                }

                pub fn eql(self: Self, other: anytype) bool {
                    const rhs_handle = extractHandle(other);
                    if (self.handle <= module.reserved_global_this_handle and rhs_handle <= module.reserved_global_this_handle) {
                        return self.handle == rhs_handle;
                    }
                    return host.equalJsValue(self.handle, rhs_handle);
                }

                pub inline fn cast(self: Self, comptime U: type) Ref(U) {
                    return .{ .handle = self.handle };
                }
            };
        }
    };
}

test "Js.Ref layout, reserved handles, and host dispatch" {
    const MockHost = struct {
        var active: u32 = 0;
        var next_slot: u32 = 9;

        pub fn cloneJsValue(handle: u32) u32 {
            std.debug.assert(handle >= 8);
            active += 1;
            defer next_slot += 1;
            return (1 << 20) | next_slot;
        }

        pub fn releaseJsValue(handle: u32) void {
            std.debug.assert(handle >= 8);
            active -= 1;
        }

        pub fn typeofJsValue(handle: u32) JsType {
            return if ((handle & 0xFFFFF) == 8) .function else .symbol;
        }

        pub fn instanceofJsValue(handle: u32, ctor_handle: u32) bool {
            return (handle & 0xFFFFF) == 9 and (ctor_handle & 0xFFFFF) == 8;
        }

        pub fn equalJsValue(lhs: u32, rhs: u32) bool {
            return (lhs & 0xFFFFF) == (rhs & 0xFFFFF) or ((lhs & 0xFFFFF) == 8 and (rhs & 0xFFFFF) == 9);
        }

        pub fn getJsValueCount() u32 {
            return active;
        }
    };

    const js = Js(MockHost);
    const ObjRef = js.Ref(js.Object);
    const AnyRef = js.Ref(js.Any);

    try expectEqual(4, @sizeOf(ObjRef));
    try expectEqual(4, @alignOf(ObjRef));
    try expectEqual(.js_value, util.getInternalType(ObjRef));

    try expect(ObjRef.@"undefined".isUndefined());
    try expect(!ObjRef.@"undefined".isNull());
    try expect(ObjRef.@"undefined".isNullOrUndefined());
    try expect(ObjRef.@"null".isNull());
    try expect(ObjRef.@"null".isNullOrUndefined());
    try expect(!ObjRef.globalThis.isNullOrUndefined());
    try expectEqual(@as(u32, 2), AnyRef.fromBool(false).handle);
    try expectEqual(@as(u32, 3), AnyRef.fromBool(true).handle);

    try expectEqual(JsType.@"undefined", AnyRef.@"undefined".typeof());
    try expectEqual(JsType.object, ObjRef.@"null".typeof());
    try expectEqual(JsType.boolean, AnyRef.fromBool(true).typeof());
    try expectEqual(JsType.object, ObjRef.globalThis.typeof());

    ObjRef.@"undefined".deinit();
    ObjRef.@"null".deinit();
    ObjRef.globalThis.deinit();
    try expectEqual(@as(u32, 4), ObjRef.globalThis.clone().handle);
    try expect(ObjRef.@"null".eql(null));
    try expect(AnyRef.fromBool(true).eql(true));
    try expect(!AnyRef.fromBool(true).eql(false));
    try expectEqual(@as(u32, 0), js.activeHandleCount());

    MockHost.active = 1;
    const dyn: ObjRef = .{ .handle = (1 << 20) | 8 };
    const cloned = dyn.clone();
    try expectEqual(@as(u32, 2), js.activeHandleCount());
    try expectEqual(JsType.function, dyn.typeof());
    try expect(cloned.instanceof(dyn));
    try expect(dyn.eql(cloned));
    const casted = cloned.cast(js.Symbol);
    try expectEqual(cloned.handle, casted.handle);
    casted.deinit();
    dyn.deinit();
    try expectEqual(@as(u32, 0), js.activeHandleCount());
}
