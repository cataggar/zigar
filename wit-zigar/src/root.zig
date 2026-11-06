const std = @import("std");

pub const component = @import("component/root.zig");

pub const wit = struct {
    pub const ast = @import("component/wit/ast.zig");
    pub const lexer = @import("component/wit/lexer.zig");
    pub const parser = @import("component/wit/parser.zig");
    pub const resolver = @import("component/wit/resolver.zig");
    pub const lift_types = @import("component/wit/lift_types.zig");
    pub const metadata_encode = @import("component/wit/metadata_encode.zig");
    pub const metadata_decode = @import("component/wit/metadata_decode.zig");
    pub const wasi_canon = @import("component/wit/wasi_canon.zig");
    pub const embed = @import("component/wit/embed.zig");
};

pub const abi = @import("component/adapter/abi.zig");
pub const types = @import("component/types.zig");
pub const core_types = @import("component/core_types.zig");
pub const canon = @import("canon.zig");
pub const bindgen = @import("bindgen.zig");
pub const cli = @import("main.zig");
pub const integration_test = @import("integration_test.zig");

test {
    _ = component;
    _ = wit.parser;
    _ = wit.resolver;
    _ = wit.lift_types;
    _ = wit.metadata_encode;
    _ = wit.metadata_decode;
    _ = abi;
    _ = canon;
    _ = bindgen;
    _ = cli;
    _ = integration_test;
}
