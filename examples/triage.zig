const std = @import("std");
const jevlin = @import("jevlin");
const Team = enum { billing, technical, sales };
pub fn main(init: std.process.Init) !void {
    const key = init.environ_map.get("TYPESAFE_API_KEY") orelse return error.MissingApiKey;
    var http = try jevlin.Http.init(init.gpa, init.io, key);
    defer http.deinit();
    var client = try jevlin.Client.init(http.transport(), .{});
    const request = try init.gpa.alloc(u8, 16 * 1024);
    defer init.gpa.free(request);
    const response = try init.gpa.alloc(u8, 32 * 1024);
    defer init.gpa.free(response);
    const scratch = try init.gpa.alloc(u8, 256 * 1024);
    defer init.gpa.free(scratch);
    const questions = .{
        .urgent = jevlin.noul("Does this customer need urgent help?"),
        .team = jevlin.choice(Team, "Which team should handle this?", .{ .billing = "Charges, invoices and refunds", .technical = "Bugs and outages", .sales = "Pricing and upgrades" }),
        .severity = jevlin.score("How severe is the problem?", [3][]const u8{ "Minor inconvenience", "Workaround required", "Unable to use the service" }),
    };
    var diagnostics: jevlin.engine.Diagnostics = .{};
    const result = try client.evaluate(.{ .ticket = "I was charged twice. Please refund the duplicate payment today." }, questions, "jev-latest", .{ .request = request, .response = response, .scratch = scratch }, &diagnostics);
    std.debug.print("model={s} team={t} urgent={d:.3} severity={d:.3} attempts={d}\n", .{ result.model, result.answers.team.choice, result.answers.urgent.probability, result.answers.severity.score, result.attempts });
}
