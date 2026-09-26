const std = @import("std");
const t = std.testing;
const sdk = @import("root.zig");
const codec = @import("codec.zig");
const engine = @import("engine.zig");
const Team = enum { billing, technical };
const questions = .{
    .urgent = sdk.noul("Urgent?"),
    .team = sdk.choice(Team, "Route?", .{}),
    .severity = sdk.score("Severity?", [2][]const u8{ "Low", "High" }),
};
const good =
    \\{"model":"jev-test","answers":{"urgent":{"type":"noul","noul":0.8},"team":{"type":"choice","choice":"billing","probabilities":{"billing":0.9,"technical":0.1},"confidence":0.6},"severity":{"type":"score","score":0.25,"probabilities":{"0":0.75,"1":0.25},"confidence":0.2,"legend":{"0":"Low","1":"High"}}}}
;
const Fake = struct {
    time: i96 = 0,
    latency: u64 = 1_000_000,
    failures: usize = 0,
    calls: usize = 0,
    body: []const u8 = good,
    retry_after: ?u64 = null,
    fn cast(p: *anyopaque) *Fake {
        return @ptrCast(@alignCast(p));
    }
    fn now(p: *anyopaque) i96 {
        return cast(p).time;
    }
    fn sleep(p: *anyopaque, ns: u64) engine.Error!void {
        cast(p).time += ns;
    }
    fn exchange(p: *anyopaque, _: []const u8, output: []u8, end: i96) engine.Error!engine.Reply {
        const self = cast(p);
        self.calls += 1;
        self.time += self.latency;
        if (self.time >= end) return error.DeadlineExceeded;
        if (self.calls <= self.failures) return .{ .status = 429, .len = 0, .retry_after_ns = self.retry_after };
        if (self.body.len > output.len) return error.ResponseTooLarge;
        @memcpy(output[0..self.body.len], self.body);
        return .{ .status = 200, .len = self.body.len };
    }
    fn transport(self: *Fake) engine.Transport {
        return .{ .context = self, .now = now, .sleep = sleep, .exchange = exchange };
    }
};
const Buffers = struct {
    request: [4096]u8 = undefined,
    response: [4096]u8 = undefined,
    scratch: [65536]u8 = undefined,
    fn workspace(self: *Buffers) sdk.Workspace {
        return .{ .request = &self.request, .response = &self.response, .scratch = &self.scratch };
    }
};
test "typed batch encodes structured state and decodes all primitives" {
    var buffers: Buffers = .{};
    var fake: Fake = .{};
    var client = try sdk.Client.init(fake.transport(), .{});
    var diagnostics: engine.Diagnostics = .{};
    const result = try client.evaluate(.{ .ticket = "Help" }, questions, "jev-latest", buffers.workspace(), &diagnostics);
    try t.expectEqual(Team.billing, result.answers.team.choice);
    try t.expectEqual(0.25, result.answers.severity.score);
    try t.expectEqualStrings("Low", result.answers.severity.legend[0].string);
    try t.expectEqual(1, diagnostics.attempts);
    try t.expect(std.mem.indexOf(u8, &buffers.request, "\"state\":{\"ticket\":\"Help\"}") != null);
}
test "malformed and duplicate responses are rejected" {
    var memory: [65536]u8 = undefined;
    try t.expectError(error.InvalidResponse, codec.parse("{\"a\":1,\"a\":2}", &memory));
    try t.expectError(error.InvalidResponse, codec.parse("{} {}", &memory));
    const mutations = [_]struct { old: []const u8, new: []const u8 }{
        .{ .old = "\"score\":0.25", .new = "\"score\":99" },
        .{ .old = "\"score\":0.25", .new = "\"score\":0.9" },
        .{ .old = "\"noul\":0.8", .new = "\"noul\":-0.1" },
        .{ .old = "\"choice\":\"billing\"", .new = "\"choice\":\"INVALID\"" },
        .{ .old = "\"billing\":0.9", .new = "\"billing\":0.2" },
        .{ .old = "\"confidence\":0.6", .new = "\"confidence\":1.1" },
    };
    for (mutations) |m| {
        const body = try std.mem.replaceOwned(u8, t.allocator, good, m.old, m.new);
        defer t.allocator.free(body);
        const tree = try codec.parse(body, &memory);
        try t.expectError(error.InvalidResponse, codec.decode(@TypeOf(questions), tree));
    }
}
test "bounded retry engine is reproducible across 1000 seeds" {
    for (0..1000) |seed| {
        var a: Fake = .{ .failures = seed % 4 };
        var b: Fake = a;
        var output: [4096]u8 = undefined;
        var da: engine.Diagnostics = .{};
        var db: engine.Diagnostics = .{};
        const config: engine.Config = .{ .seed = seed };
        const ra = engine.send(a.transport(), config, engine.deadline(a.transport(), config), "{}", &output, &da);
        const rb = engine.send(b.transport(), config, engine.deadline(b.transport(), config), "{}", &output, &db);
        if (ra) |_| {
            _ = try rb;
        } else |err| {
            try t.expectError(err, rb);
        }
        try t.expectEqual(a.time, b.time);
        try t.expectEqual(a.calls, b.calls);
        try t.expect(a.calls <= 3);
    }
}
test "one deadline covers initial attempt retries and backoff" {
    var fake: Fake = .{ .failures = 1, .latency = 40 * std.time.ns_per_ms, .retry_after = 20 * std.time.ns_per_ms };
    const config: engine.Config = .{ .timeout_ms = 70 };
    var output: [4096]u8 = undefined;
    var d: engine.Diagnostics = .{};
    try t.expectError(error.DeadlineExceeded, engine.send(fake.transport(), config, engine.deadline(fake.transport(), config), "{}", &output, &d));
    try t.expectEqual(2, fake.calls);
    fake = .{ .failures = 1, .retry_after = std.time.ns_per_s };
    try t.expectError(error.DeadlineExceeded, engine.send(fake.transport(), config, engine.deadline(fake.transport(), config), "{}", &output, &d));
    try t.expectEqual(1, fake.calls);
}
test "capacities fail explicitly and client recovers" {
    var buffers: Buffers = .{};
    var fake: Fake = .{};
    var client = try sdk.Client.init(fake.transport(), .{});
    var d: engine.Diagnostics = .{};
    var workspace = buffers.workspace();
    workspace.request = buffers.request[0..2];
    try t.expectError(error.RequestTooLarge, client.evaluate("state", questions, "jev-latest", workspace, &d));
    try t.expectEqual(0, fake.calls);
    workspace = buffers.workspace();
    workspace.response = buffers.response[0..2];
    try t.expectError(error.ResponseTooLarge, client.evaluate("state", questions, "jev-latest", workspace, &d));
    _ = try client.evaluate("state", questions, "jev-latest", buffers.workspace(), &d);
    workspace = buffers.workspace();
    workspace.scratch = buffers.scratch[0..1];
    try t.expectError(error.WorkspaceTooSmall, client.evaluate("state", questions, "jev-latest", workspace, &d));
}
test "busy is explicit backpressure" {
    var fake: Fake = .{};
    var client = try sdk.Client.init(fake.transport(), .{});
    client.busy.store(true, .release);
    var b: Buffers = .{};
    var d: engine.Diagnostics = .{};
    try t.expectError(error.Busy, client.evaluate("state", questions, "jev-latest", b.workspace(), &d));
    try t.expectEqual(0, fake.calls);
}

test "depth and syntax limits reject malformed JSON" {
    var scratch: [65536]u8 = undefined;
    const deep = "[" ** 33 ++ "0" ++ "]" ** 33;
    try t.expectError(error.InvalidResponse, codec.parse(deep, &scratch));
    const cases = [_][]const u8{ "{", "null trailing", "{\"x\":NaN}", "{\"x\":\"\xff\"}", "[1,]" };
    for (cases) |input| try t.expectError(error.InvalidResponse, codec.parse(input, &scratch));
}
test "response mutation corpus never silently accepts duplicate choice" {
    var scratch: [65536]u8 = undefined;
    const body = try std.mem.replaceOwned(u8, t.allocator, good, "\"choice\":\"billing\"", "\"choice\":\"billing\",\"choice\":\"INVALID\"");
    defer t.allocator.free(body);
    try t.expectError(error.InvalidResponse, codec.parse(body, &scratch));
    // Every truncated prefix must be rejected. No network or heap growth in codec.
    for (0..good.len) |i| try t.expectError(error.InvalidResponse, codec.parse(good[0..i], &scratch));
}
test "maximum legal score and choice schemas compile" {
    const q = sdk.score("Rate", [_][]const u8{"level"} ** 10);
    try t.expectEqual(10, @TypeOf(q).count);
    try t.expectError(error.InvalidConfig, (engine.Config{ .max_retries = 9 }).validate());
    try t.expectError(error.InvalidConfig, (engine.Config{ .timeout_ms = 0 }).validate());
}
test "nonretryable statuses and transport cancellation do not retry" {
    const Fault = struct {
        code: u16,
        calls: usize = 0,
        fn exchange(p: *anyopaque, _: []const u8, _: []u8, _: i96) engine.Error!engine.Reply {
            const self: *@This() = @ptrCast(@alignCast(p));
            self.calls += 1;
            if (self.code == 0) return error.Canceled;
            return .{ .status = self.code, .len = 0 };
        }
        fn now(_: *anyopaque) i96 {
            return 0;
        }
        fn sleep(_: *anyopaque, _: u64) engine.Error!void {
            return error.Canceled;
        }
    };
    for ([_]u16{ 0, 400, 401, 302, 422 }) |status| {
        var fault: Fault = .{ .code = status };
        const transport: engine.Transport = .{ .context = &fault, .now = Fault.now, .sleep = Fault.sleep, .exchange = Fault.exchange };
        var output: [1]u8 = undefined;
        var diagnostics: engine.Diagnostics = .{};
        const result = engine.send(transport, .{}, engine.deadline(transport, .{}), "{}", &output, &diagnostics);
        if (result) |_| return error.TestUnexpectedResult else |_| {}
        try t.expectEqual(1, fault.calls);
    }
}

test "contract response fixtures through public client" {
    const Fixture = struct { name: []const u8, response: []const u8, valid: bool };
    const corpus = try std.json.parseFromSlice([]Fixture, t.allocator, @embedFile("fixtures/responses.json"), .{});
    defer corpus.deinit();
    var buffers: Buffers = .{};
    for (corpus.value) |case| {
        var fake: Fake = .{ .body = case.response };
        var client = try sdk.Client.init(fake.transport(), .{});
        var diagnostics: engine.Diagnostics = .{};
        const result = client.evaluate("state", questions, "jev-latest", buffers.workspace(), &diagnostics);
        if (case.valid) {
            _ = result catch |err| {
                std.debug.print("contract fixture {s}: {t}\n", .{ case.name, err });
                return err;
            };
        } else {
            t.expectError(error.InvalidResponse, result) catch |err| {
                std.debug.print("contract fixture {s}\n", .{case.name});
                return err;
            };
        }
        try t.expectEqual(1, fake.calls);
    }
}

test "contract request fixture and state variants" {
    var b: Buffers = .{};
    const encoded = try codec.encode(.{ .ticket = "Help" }, questions, "jev-latest", &b.request, &b.scratch);
    try t.expectEqualStrings(std.mem.trim(u8, @embedFile("fixtures/request.json"), "\n"), encoded);
    inline for (.{ "text", [_][]const u8{ "one", "two" } }) |state| {
        _ = try codec.encode(state, questions, "jev-latest", &b.request, &b.scratch);
    }
    inline for (.{ true, 42, null }) |state| {
        try t.expectError(error.InvalidRequest, codec.encode(state, questions, "jev-latest", &b.request, &b.scratch));
    }
}

test "contract status classification and retry counts" {
    const Fault = struct {
        status: u16,
        calls: usize = 0,
        fn now(_: *anyopaque) i96 {
            return 0;
        }
        fn sleep(_: *anyopaque, _: u64) engine.Error!void {}
        fn exchange(p: *anyopaque, _: []const u8, _: []u8, _: i96) engine.Error!engine.Reply {
            const self: *@This() = @ptrCast(@alignCast(p));
            self.calls += 1;
            return .{ .status = self.status, .len = 0 };
        }
    };
    const Case = struct { status: u16, err: engine.Error, calls: usize };
    const cases = [_]Case{
        .{ .status = 401, .err = error.Unauthorized, .calls = 1 },
        .{ .status = 403, .err = error.Unauthorized, .calls = 1 },
        .{ .status = 400, .err = error.BadRequest, .calls = 1 },
        .{ .status = 422, .err = error.BadRequest, .calls = 1 },
        .{ .status = 429, .err = error.RateLimited, .calls = 3 },
        .{ .status = 529, .err = error.ServerError, .calls = 3 },
        .{ .status = 503, .err = error.ServerError, .calls = 3 },
        .{ .status = 408, .err = error.UnexpectedStatus, .calls = 3 },
        .{ .status = 302, .err = error.UnexpectedStatus, .calls = 1 },
    };
    for (cases) |case| {
        var fault: Fault = .{ .status = case.status };
        const transport: engine.Transport = .{ .context = &fault, .now = Fault.now, .sleep = Fault.sleep, .exchange = Fault.exchange };
        var output: [1]u8 = undefined;
        var d: engine.Diagnostics = .{};
        try t.expectError(case.err, engine.send(transport, .{}, engine.deadline(transport, .{}), "{}", &output, &d));
        try t.expectEqual(case.calls, fault.calls);
        try t.expectEqual(case.status, d.status.?);
    }
}

test "workspace overlaps fail before transport and client recovers" {
    var b: Buffers = .{};
    var fake: Fake = .{};
    var client = try sdk.Client.init(fake.transport(), .{});
    var d: engine.Diagnostics = .{};
    for (0..6) |case| {
        var w = b.workspace();
        switch (case) {
            0 => w.response = w.request,
            1 => w.scratch = w.request[1..],
            2 => w.scratch = w.response,
            3 => w.request = w.scratch[1..],
            4 => w.response = w.scratch[1..],
            else => w.request = w.response[1..],
        }
        const before = fake.calls;
        try t.expectError(error.InvalidConfig, client.evaluate("state", questions, "jev-latest", w, &d));
        try t.expectEqual(before, fake.calls);
        _ = try client.evaluate("state", questions, "jev-latest", b.workspace(), &d);
    }
}

test "exact request response and scratch boundaries recover" {
    var b: Buffers = .{};
    const encoded = try codec.encode("state", questions, "jev-latest", &b.request, &b.scratch);
    const size = encoded.len;
    var fake: Fake = .{};
    var client = try sdk.Client.init(fake.transport(), .{});
    var d: engine.Diagnostics = .{};
    var w = b.workspace();
    w.request = b.request[0 .. size - 1];
    try t.expectError(error.RequestTooLarge, client.evaluate("state", questions, "jev-latest", w, &d));
    w.request = b.request[0..size];
    w.response = b.response[0..good.len];
    _ = try client.evaluate("state", questions, "jev-latest", w, &d);
    w.response = b.response[0 .. good.len - 1];
    try t.expectError(error.ResponseTooLarge, client.evaluate("state", questions, "jev-latest", w, &d));
    // Sweep every small scratch capacity, not only a single OOM example.
    for (1..4096) |capacity| {
        w = b.workspace();
        w.scratch = b.scratch[0..capacity];
        if (client.evaluate("state", questions, "jev-latest", w, &d)) |_| {} else |err| try t.expectEqual(error.WorkspaceTooSmall, err);
        _ = try client.evaluate("state", questions, "jev-latest", b.workspace(), &d);
    }
}

test "nesting boundary and malformed response recovery" {
    var b: Buffers = .{};
    _ = try codec.parse("[" ** 32 ++ "0" ++ "]" ** 32, &b.scratch);
    try t.expectError(error.InvalidResponse, codec.parse("[" ** 33 ++ "0" ++ "]" ** 33, &b.scratch));
    var fake: Fake = .{};
    var client = try sdk.Client.init(fake.transport(), .{});
    var d: engine.Diagnostics = .{};
    const invalid = [_][]const u8{
        "{",                            "{}",            "{\"x\":\"\xc0\xaf\"}",              "{\"x\":\"\xed\xa0\x80\"}",
        "{\"x\":\"\xf4\x90\x80\x80\"}", "{\"x\":1e999}", "{\"model\":\"a\",\"model\":\"b\"}",
    };
    for (0..100) |_| for (invalid) |body| {
        fake.body = body;
        try t.expectError(error.InvalidResponse, client.evaluate("state", questions, "jev-latest", b.workspace(), &d));
        fake.body = good;
        const result = try client.evaluate("state", questions, "jev-latest", b.workspace(), &d);
        try t.expectEqual(Team.billing, result.answers.team.choice);
    };
}

test "structured questions and noul criteria serialize and preserve typed answers" {
    const structured = .{
        .urgent = sdk.noulWithCriteria(.{ .question = "Urgent?", .context = "support" }, .{ .true = .{ .meaning = "Immediate" }, .false = [_][]const u8{"Routine"} }),
        .team = sdk.choiceStructured(Team, [_][]const u8{"Route?"}, .{ .billing = .{ .meaning = "Payments" }, .technical = null }),
        .severity = sdk.scoreStructured(.{ .question = "Severity?" }, .{ .{ .label = "Low" }, [_][]const u8{"High"} }),
    };
    var b: Buffers = .{};
    const wire = try codec.encode("state", structured, "jev-latest", &b.request, &b.scratch);
    const tree = try codec.parse(wire, &b.scratch);
    const qs = tree.object.get("questions").?.object;
    try t.expectEqualStrings("Immediate", qs.get("urgent").?.object.get("criteria").?.object.get("true").?.object.get("meaning").?.string);
    try t.expect(qs.get("team").?.object.get("instructions").? == .array);
    try t.expect(qs.get("severity").?.object.get("criteria").?.array.items[0] == .object);
    var fake: Fake = .{};
    var client = try sdk.Client.init(fake.transport(), .{});
    var d: engine.Diagnostics = .{};
    const result = try client.evaluate("state", structured, "jev-latest", b.workspace(), &d);
    try t.expectEqual(Team.billing, result.answers.team.choice);
    try t.expectEqual(0.25, result.answers.severity.score);
    inline for (.{
        .{ .q = sdk.noulWithCriteria("Question", .{ .invalid = "value" }) },
        .{ .q = sdk.noulWithCriteria(42, null) },
        .{ .q = sdk.choiceStructured(Team, "Question", .{ .billing = null }) },
        .{ .q = sdk.scoreStructured("Question", .{ "okay", false }) },
    }) |invalid| try t.expectError(error.InvalidRequest, codec.encode("state", invalid, "jev-latest", &b.request, &b.scratch));
    _ = try codec.encode("state", .{ .q = sdk.noulWithCriteria(.{ .question = "Q" }, null) }, "jev-latest", &b.request, &b.scratch);
}

test "usage is typed and optional for older responses" {
    var scratch: [65536]u8 = undefined;
    try t.expectEqual(@as(?codec.Usage, null), try codec.decodeUsage(try codec.parse("{}", &scratch)));
    const usage = (try codec.decodeUsage(try codec.parse("{\"usage\":{\"input_tokens\":42,\"output_tokens\":7}}", &scratch))).?;
    try t.expectEqual(@as(u64, 42), usage.input_tokens);
    try t.expectEqual(@as(u64, 7), usage.output_tokens);
}

test "upstream error details preserve status raw body and structured JSON" {
    const Fault = struct {
        body: []const u8,
        status: u16 = 422,
        fn clock(_: *anyopaque) i96 {
            return 0;
        }
        fn pause(_: *anyopaque, _: u64) engine.Error!void {}
        fn exchange(p: *anyopaque, _: []const u8, output: []u8, _: i96) engine.Error!engine.Reply {
            const self: *@This() = @ptrCast(@alignCast(p));
            @memcpy(output[0..self.body.len], self.body);
            return .{ .status = self.status, .len = self.body.len };
        }
    };
    var b: Buffers = .{};
    var fault: Fault = .{ .body = "{\"detail\":[{\"field\":\"questions\",\"message\":\"invalid\"}]}" };
    var client = try sdk.Client.init(.{ .context = &fault, .now = Fault.clock, .sleep = Fault.pause, .exchange = Fault.exchange }, .{});
    var d: engine.Diagnostics = .{};
    try t.expectError(error.BadRequest, client.evaluate("state", questions, "jev-latest", b.workspace(), &d));
    try t.expectEqual(@as(u16, 422), d.status.?);
    try t.expectEqual(@as(u8, 1), d.attempts);
    try t.expectEqualStrings(fault.body, d.error_body);
    try t.expectEqualStrings("questions", d.error_json.?.object.get("detail").?.array.items[0].object.get("field").?.string);
    fault.body = "not JSON";
    try t.expectError(error.BadRequest, client.evaluate("state", questions, "jev-latest", b.workspace(), &d));
    try t.expect(d.error_json == null);
    try t.expectEqualStrings(fault.body, d.error_body);
    fault.body = good;
    fault.status = 200;
    _ = try client.evaluate("state", questions, "jev-latest", b.workspace(), &d);
    try t.expectEqual(@as(usize, 0), d.error_body.len);
    try t.expect(d.error_json == null);
}
