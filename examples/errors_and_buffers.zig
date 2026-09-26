const std = @import("std");
const j = @import("jevlin");
const demo = @import("fixture.zig");
pub fn main() !void {
    var fixture: demo.Fixture = .{};
    var client = try j.Client.init(fixture.transport(), .{ .max_retries = 0 });
    var buffers: demo.Buffers = .{};
    var diagnostics: j.Diagnostics = .{};
    var small: [1]u8 = undefined;
    var workspace = buffers.workspace();
    workspace.request = &small;
    // Encoding failed before any exchange: enlarging this request buffer is safe.
    try std.testing.expectError(error.RequestTooLarge, client.evaluate("Ticket", demo.questions, "jev-latest", workspace, &diagnostics));
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    workspace = buffers.workspace();
    _ = try client.evaluate("Ticket", demo.questions, "jev-latest", workspace, &diagnostics);
    // Scratch exhaustion may happen AFTER an exchange. Do not blindly replay:
    // production calls may already have incurred a charge or other effects.
    workspace.scratch = &small;
    try std.testing.expectError(error.WorkspaceTooSmall, client.evaluate("Ticket", demo.questions, "jev-latest", workspace, &diagnostics));
    workspace = buffers.workspace();
    workspace.response = &small;
    const calls_before = fixture.calls;
    try std.testing.expectError(error.ResponseTooLarge, client.evaluate("Ticket", demo.questions, "jev-latest", workspace, &diagnostics));
    try std.testing.expectEqual(calls_before + 1, fixture.calls);
    // Further calls here are safe only because this is an offline fixture.
    workspace = buffers.workspace();
    fixture.status = 422;
    if (client.evaluate("Ticket", demo.questions, "jev-latest", workspace, &diagnostics)) |_| {
        return error.ExpectedFailure;
    } else |err| switch (err) {
        error.BadRequest => {
            try std.testing.expectEqual(@as(?u16, 422), diagnostics.status);
            try std.testing.expect(diagnostics.error_json != null);
            // Log metadata by default; upstream bodies can contain sensitive data.
            std.debug.print("rejected: status={?d}, attempts={d}\n", .{ diagnostics.status, diagnostics.attempts });
        },
        else => return err,
    }
    fixture.status = 200;
    _ = try client.evaluate("Corrected ticket", demo.questions, "jev-latest", workspace, &diagnostics);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.error_body.len);
    try std.testing.expect(diagnostics.error_json == null);
}
