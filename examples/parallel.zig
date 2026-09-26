const std = @import("std");
const j = @import("jevlin");
const demo = @import("fixture.zig");
const worker_count = 4;
const ticket_count = 12;
fn worker(index: usize) anyerror!void {
    // Client, transport context and workspace belong exclusively to this worker.
    // With HTTP, create a separate Http here and defer its deinit after calls end.
    var fixture: demo.Fixture = .{};
    var client = try j.Client.init(fixture.transport(), .{ .max_retries = 0 });
    var buffers: demo.Buffers = .{};
    var diagnostics: j.Diagnostics = .{};
    for (0..ticket_count / worker_count) |batch| {
        const ticket_id = index + batch * worker_count;
        const result = try client.evaluate(.{ .ticket_id = ticket_id }, demo.questions, "jev-latest", buffers.workspace(), &diagnostics);
        try std.testing.expectEqual(demo.Team.billing, result.answers.team.choice);
    }
    try std.testing.expectEqual(@as(usize, ticket_count / worker_count), fixture.calls);
}
pub fn main(init: std.process.Init) !void {
    var workers: [worker_count]std.Io.Future(anyerror!void) = undefined;
    var started: usize = 0;
    // Join/cancel even if starting or awaiting a worker fails.
    defer for (workers[0..started]) |*future| {
        _ = future.cancel(init.io) catch {};
    };
    for (&workers, 0..) |*future, index| {
        future.* = try init.io.concurrent(worker, .{index});
        started += 1;
    }
    for (&workers) |*future| try future.await(init.io);
    std.debug.print("parallel: {d} tickets, at most {d} workers\n", .{ ticket_count, worker_count });
}
