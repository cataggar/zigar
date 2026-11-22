const std = @import("std");
const pkg = @import("aws_lambda");
const js = pkg.zigar_js;
const lambda = pkg.aws_lambda_index;

test "@types/aws-lambda + @types/node@26 module graph compiles cleanly" {
    try std.testing.expect(@hasDecl(pkg, "aws_lambda_index"));
    try std.testing.expect(@hasDecl(pkg, "crypto"));
    try std.testing.expect(@hasDecl(pkg, "buffer"));
    try std.testing.expect(@hasDecl(pkg, "timers_promises"));
    try std.testing.expect(@hasDecl(pkg, "globals"));

    try std.testing.expect(@hasDecl(lambda, "Context"));
    try std.testing.expect(@hasDecl(lambda, "ApiGatewayProxyEventV2"));
    try std.testing.expect(@hasDecl(lambda, "ApiGatewayProxyStructuredResultV2"));
    try std.testing.expect(@hasDecl(lambda, "AttributeValue"));
    try std.testing.expect(@hasDecl(lambda, "DynamoDbStreamEvent"));
    try std.testing.expect(@hasDecl(lambda, "S3Event"));
    try std.testing.expect(@hasDecl(lambda, "SqsEvent"));
    try std.testing.expect(@hasDecl(lambda, "AlbEvent"));

    try std.testing.expect(@hasDecl(lambda.Context, "getRemainingTimeInMillis"));
    try std.testing.expect(@hasDecl(lambda.Context, "awsRequestIdAlloc"));
    try std.testing.expect(@hasDecl(lambda.ApiGatewayProxyEventV2, "fromJsRefAlloc"));
    try std.testing.expect(@hasDecl(lambda.ApiGatewayProxyStructuredResultV2, "toJsRef"));

    const result: lambda.ApiGatewayProxyStructuredResultV2 = .{
        .status_code = 200,
        .body = "{\"ok\":true}",
        .is_base64_encoded = false,
    };
    try std.testing.expectEqual(@as(?f64, 200), result.status_code);
    try std.testing.expectEqual(@as(usize, 0), js.activeHandleCount());
}
