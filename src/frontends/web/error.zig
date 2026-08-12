const std = @import("std");

pub const ErrorCode = enum {
    not_found,
    bad_request,
    session_not_found,
    message_not_found,
    agent_busy,
    internal_error,
};

pub fn codeString(c: ErrorCode) []const u8 {
    return switch (c) {
        .not_found => "not_found",
        .bad_request => "bad_request",
        .session_not_found => "session_not_found",
        .message_not_found => "message_not_found",
        .agent_busy => "agent_busy",
        .internal_error => "internal_error",
    };
}

pub fn statusCode(c: ErrorCode) std.http.Status {
    return switch (c) {
        .not_found => .not_found,
        .bad_request => .bad_request,
        .session_not_found => .not_found,
        .message_not_found => .not_found,
        .agent_busy => .service_unavailable,
        .internal_error => .internal_server_error,
    };
}

pub fn respondError(request: *std.http.Server.Request, code: ErrorCode, message: []const u8, allocator: std.mem.Allocator) !void {
    const body = try std.fmt.allocPrint(allocator, "{{\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}", .{ codeString(code), message });
    try request.respond(body, .{ .status = statusCode(code) });
}

test "error: codeString returns snake_case" {
    try std.testing.expectEqualStrings("not_found", codeString(.not_found));
    try std.testing.expectEqualStrings("session_not_found", codeString(.session_not_found));
    try std.testing.expectEqualStrings("agent_busy", codeString(.agent_busy));
}

test "error: statusCode maps correctly" {
    try std.testing.expectEqual(std.http.Status.not_found, statusCode(.not_found));
    try std.testing.expectEqual(std.http.Status.bad_request, statusCode(.bad_request));
    try std.testing.expectEqual(std.http.Status.service_unavailable, statusCode(.agent_busy));
    try std.testing.expectEqual(std.http.Status.internal_server_error, statusCode(.internal_error));
}

test "error: respondError formats JSON body" {
    var fba = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer fba.deinit();
    const allocator = fba.allocator();

    const body = try std.fmt.allocPrint(allocator, "{{\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}", .{ codeString(.not_found), "session z1 not found" });
    try std.testing.expectEqualStrings("{\"error\":{\"code\":\"not_found\",\"message\":\"session z1 not found\"}}", body);
}
