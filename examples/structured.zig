const std = @import("std");
const j = @import("jevlin");
const demo = @import("fixture.zig");
pub fn main() !void {
    var fixture: demo.Fixture = .{};
    var client = try j.Client.init(fixture.transport(), .{ .max_retries = 0 });
    var buffers: demo.Buffers = .{};
    var diagnostics: j.Diagnostics = .{};
    const result = try client.evaluate(.{ .ticket = "Charged twice", .tags = .{ "billing", "refund" } }, demo.questions, "jev-latest", buffers.workspace(), &diagnostics);
    // Numeric values and enums can be retained by value.
    const team: demo.Team = result.answers.team.choice;
    try std.testing.expectEqual(demo.Team.billing, team);
    try std.testing.expectEqual(@as(u64, 12), result.usage.?.input_tokens);
    // Copy borrowed text before ANY reuse of the workspace, even a failing call.
    var saved_model: [64]u8 = undefined;
    if (result.model.len > saved_model.len) return error.ModelTooLong;
    const model_len = result.model.len;
    @memcpy(saved_model[0..model_len], result.model);
    _ = try client.evaluate("Another ticket", demo.questions, "jev-latest", buffers.workspace(), &diagnostics);
    try std.testing.expectEqualStrings("offline", saved_model[0..model_len]);
    std.debug.print("structured: team={t}, copied model={s}\n", .{ team, saved_model[0..model_len] });
}
