const std = @import("std");
const pkg = @import("azure_functions");
const js = pkg.zigar_js;
const azure = pkg.azure_functions;

test "@azure/functions + @types/node@26 module graph compiles cleanly" {
    try std.testing.expect(@hasDecl(pkg, "azure_functions"));
    try std.testing.expect(@hasDecl(pkg, "crypto"));
    try std.testing.expect(@hasDecl(pkg, "buffer"));
    try std.testing.expect(@hasDecl(pkg, "timers_promises"));
    try std.testing.expect(@hasDecl(pkg, "url"));

    // Core @azure/functions v4 programming model namespaces & classes
    try std.testing.expect(@hasDecl(azure, "app"));
    try std.testing.expect(@hasDecl(azure, "trigger"));
    try std.testing.expect(@hasDecl(azure, "input"));
    try std.testing.expect(@hasDecl(azure, "output"));
    try std.testing.expect(@hasDecl(azure.app, "http"));
    try std.testing.expect(@hasDecl(azure.app, "getHttpMethodFunctionOptions"));
    try std.testing.expect(@hasDecl(azure.app, "timer"));
    try std.testing.expect(@hasDecl(azure.app, "storageBlob"));
    try std.testing.expect(@hasDecl(azure.app, "storageQueue"));
    try std.testing.expect(@hasDecl(azure.app, "serviceBusQueue"));
    try std.testing.expect(@hasDecl(azure.app, "cosmosDb"));
    try std.testing.expect(@hasDecl(azure.app, "eventGrid"));
    try std.testing.expect(@hasDecl(azure.app, "mcpTool"));

    try std.testing.expect(@hasDecl(azure, "HttpRequest"));
    try std.testing.expect(@hasDecl(azure, "HttpResponse"));
    try std.testing.expect(@hasDecl(azure, "HttpResponseInit"));
    try std.testing.expect(@hasDecl(azure, "Cookie"));
    try std.testing.expect(@hasDecl(azure, "InvocationContext"));
    try std.testing.expect(@hasDecl(azure, "TraceContext"));

    // Verify bundled package wire_specifier maps internal types/* submodules to "@azure/functions"
    try std.testing.expectEqualStrings("@azure/functions", azure.app.zigar_js.wire_specifier);
    try std.testing.expectEqualStrings("@azure/functions", azure.HttpRequest.zigar_js.ctor_target.module);
    try std.testing.expectEqualStrings("@azure/functions", azure.HttpResponse.zigar_js.ctor_target.module);
    try std.testing.expectEqualStrings("@azure/functions", azure.InvocationContext.zigar_js.ctor_target.module);

    const cookie: azure.Cookie = .{
        .name = "zigar-invocation",
        .value = "inv-001",
        .path = "/",
        .http_only = true,
        .same_site = .lax,
        .max_age = 3600,
    };
    try std.testing.expectEqualStrings("zigar-invocation", cookie.name);
    try std.testing.expectEqual(@as(usize, 0), js.activeHandleCount());
}
