//! `ts-zigar`: TypeScript 7.1 (`zigar:typescript@7.1.0`) WebAssembly Component
//! bindings and Zig host integration layer.

pub const wit_zigar = @import("wit_zigar");
pub const typescript = @import("generated_ts_wasm32");
pub const typescript_wasm64 = @import("generated_ts_wasm64");
pub const host = @import("host.zig");

pub const types = typescript.types;
pub const compiler = typescript.compiler;
pub const extractor = typescript.extractor;
pub const TypeScriptHost = host.TypeScriptHost;
pub const ComponentHost = host.ComponentHost;
pub const ComponentPlan = host.ComponentPlan;
pub const defaultCompilerOptions = host.defaultCompilerOptions;
pub const defaultExtractConfig = host.defaultExtractConfig;

