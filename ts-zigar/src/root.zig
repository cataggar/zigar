//! `ts-zigar`: TypeScript 7.1 (`zigar:typescript@7.1.0`) WebAssembly Component
//! bindings and Zig host integration layer.

pub const wit_zigar = @import("wit_zigar");
pub const typescript = @import("generated_ts_wasm32");
pub const typescript_wasm64 = @import("generated_ts_wasm64");
pub const host = @import("host.zig");
pub const cli = @import("cli.zig");
pub const naming = @import("naming.zig");
pub const lower_types = @import("lower_types.zig");
pub const lower_unions = @import("lower_unions.zig");
pub const classify_decls = @import("classify_decls.zig");
pub const lower_objects = @import("lower_objects.zig");
pub const lower_heritage = @import("lower_heritage.zig");
pub const merge_decls = @import("merge_decls.zig");
pub const ir = @import("ir.zig");
pub const emit = @import("emit.zig");
pub const driver = @import("driver.zig");

pub const types = typescript.types;
pub const compiler = typescript.compiler;
pub const extractor = typescript.extractor;
pub const TypeScriptHost = host.TypeScriptHost;
pub const ComponentHost = host.ComponentHost;
pub const ComponentPlan = host.ComponentPlan;
pub const defaultCompilerOptions = host.defaultCompilerOptions;
pub const defaultExtractConfig = host.defaultExtractConfig;

test {
    _ = host;
    _ = cli;
    _ = naming;
    _ = lower_types;
    _ = lower_unions;
    _ = classify_decls;
    _ = lower_objects;
    _ = lower_heritage;
    _ = merge_decls;
    _ = ir;
    _ = emit;
    _ = driver;
}
