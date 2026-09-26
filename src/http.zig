const std = @import("std");
const engine = @import("engine.zig");
const Http = @This();
/// Only the official HTTPS endpoint is supported in this first release.
/// std HTTP/TLS allocates using gpa. No allocation-free transport claim.
gpa: std.mem.Allocator,
io: std.Io,
authorization: [1024]u8 = undefined,
authorization_len: usize,

pub fn init(gpa: std.mem.Allocator, io: std.Io, key: []const u8) engine.Error!Http {
    if (key.len == 0 or key.len > 1017) return error.InvalidConfig;
    for (key) |c| if (c < 0x21 or c > 0x7e) return error.InvalidConfig;
    var self: Http = .{ .gpa = gpa, .io = io, .authorization_len = key.len + 7 };
    @memcpy(self.authorization[0..7], "Bearer ");
    @memcpy(self.authorization[7..][0..key.len], key);
    return self;
}
pub fn deinit(self: *Http) void {
    std.crypto.secureZero(u8, &self.authorization);
}
pub fn transport(self: *Http) engine.Transport {
    return .{ .context = self, .now = now, .sleep = sleep, .exchange = exchange };
}
fn cast(context: *anyopaque) *Http {
    return @ptrCast(@alignCast(context));
}
fn now(context: *anyopaque) i96 {
    return std.Io.Clock.awake.now(cast(context).io).nanoseconds;
}
fn sleep(context: *anyopaque, ns: u64) engine.Error!void {
    try cast(context).io.sleep(.{ .nanoseconds = ns }, .awake);
}
fn exchange(context: *anyopaque, body: []const u8, response: []u8, end: i96) engine.Error!engine.Reply {
    return exchangeAt(cast(context), body, response, end, "https://api.typesafe.ai/v1/systemone");
}
fn exchangeAt(self: *Http, body: []const u8, response: []u8, end: i96, endpoint: []const u8) engine.Error!engine.Reply {
    if (now(self) >= end) return error.DeadlineExceeded;
    const Event = union(enum) { response: engine.Error!engine.Reply, timer: std.Io.Cancelable!void };
    var events: [2]Event = undefined;
    var race: std.Io.Select(Event) = .init(self.io, &events);
    // Cancellation joins both tasks before caller-owned buffers can be reused.
    defer while (race.cancel()) |_| {};
    race.concurrent(.response, perform, .{ self, body, response, endpoint }) catch return error.ConcurrencyUnavailable;
    race.concurrent(.timer, waitUntil, .{ self, end }) catch return error.ConcurrencyUnavailable;
    return switch (try race.await()) {
        .response => |result| result,
        .timer => |result| blk: {
            try result;
            break :blk error.DeadlineExceeded;
        },
    };
}
fn waitUntil(self: *Http, end: i96) std.Io.Cancelable!void {
    const remaining = end - now(self);
    if (remaining > 0) try self.io.sleep(.{ .nanoseconds = remaining }, .awake);
}
fn perform(self: *Http, body: []const u8, response: []u8, endpoint: []const u8) engine.Error!engine.Reply {
    return performInner(self, body, response, endpoint) catch |err| switch (err) {
        error.Canceled => error.Canceled,
        error.OutOfMemory => error.OutOfMemory,
        error.ResponseTooLarge => error.ResponseTooLarge,
        error.InvalidResponse, error.HttpContentEncodingUnsupported => error.InvalidResponse,
        else => if (std.mem.startsWith(u8, @errorName(err), "Tls") or std.mem.startsWith(u8, @errorName(err), "Certificate")) error.TlsFailure else error.TransportFailure,
    };
}
fn performInner(self: *Http, body: []const u8, output: []u8, endpoint: []const u8) !engine.Reply {
    // A fresh std client per attempt avoids cached TLS clock/roots and keeps
    // cancellation cleanup local. Connection pooling is deliberately deferred.
    var client: std.http.Client = .{ .allocator = self.gpa, .io = self.io };
    defer client.deinit();
    var request = try client.request(.POST, try std.Uri.parse(endpoint), .{
        .redirect_behavior = .unhandled,
        .keep_alive = false,
        .headers = .{
            .authorization = .{ .override = self.authorization[0..self.authorization_len] },
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .{ .override = "identity" },
            .user_agent = .{ .override = "jevlin/0.1.0-dev" },
        },
    });
    defer request.deinit();
    request.transfer_encoding = .{ .content_length = body.len };
    var upload_buffer: [4096]u8 = undefined;
    var upload = try request.sendBody(&upload_buffer);
    try upload.writer.writeAll(body);
    try upload.end();
    try request.connection.?.flush();
    var response = try request.receiveHead(&.{});
    if (response.head.content_encoding != .identity) return error.InvalidResponse;
    if (response.head.content_length) |n| if (n > output.len) return error.ResponseTooLarge;
    var reply: engine.Reply = .{ .status = @intFromEnum(response.head.status), .len = 0 };
    var headers = response.head.iterateHeaders();
    while (headers.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "retry-after-ms")) {
            reply.retry_after_ns = retryDelay(header.value, std.time.ns_per_ms);
        } else if (reply.retry_after_ns == null and std.ascii.eqlIgnoreCase(header.name, "retry-after")) {
            reply.retry_after_ns = retryDelay(header.value, std.time.ns_per_s);
        }
    }
    var transfer: [256]u8 = undefined;
    const reader = response.reader(&transfer);
    reply.len = try reader.readSliceShort(output);
    var extra: [1]u8 = undefined;
    if (try reader.readSliceShort(&extra) != 0) return error.ResponseTooLarge;
    if (response.head.content_length) |n| if (reply.len != n) return error.TransportFailure;
    return reply;
}
fn retryDelay(text: []const u8, multiplier: u64) ?u64 {
    const number = std.fmt.parseFloat(f64, text) catch return null;
    if (!std.math.isFinite(number) or number < 0) return null;
    const ns = number * @as(f64, @floatFromInt(multiplier));
    return @intFromFloat(@min(ns, 300 * std.time.ns_per_s));
}

fn serveTest(listener: *std.Io.net.Server, bytes: []const u8, delay: std.Io.Duration) !void {
    const io = std.testing.io;
    const stream = try listener.accept(io);
    defer stream.close(io);
    var rb: [8192]u8 = undefined;
    var wb: [8192]u8 = undefined;
    var reader = stream.reader(io, &rb);
    var writer = stream.writer(io, &wb);
    var server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = try server.receiveHead();
    var transfer: [256]u8 = undefined;
    const body = request.readerExpectNone(&transfer);
    _ = try body.discardRemaining();
    try io.sleep(delay, .awake);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}
test "HTTP exact bounds chunked overflow truncation and real deadline" {
    const cases = [_]struct { bytes: []const u8, delay: std.Io.Duration = .zero, expected: ?engine.Error = null }{
        .{ .bytes = "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nokay" },
        .{ .bytes = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nextra", .expected = error.ResponseTooLarge },
        .{ .bytes = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nextra\r\n0\r\n\r\n", .expected = error.ResponseTooLarge },
        .{ .bytes = "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nx", .expected = error.TransportFailure },
        .{ .bytes = "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nokay", .delay = .fromSeconds(5), .expected = error.DeadlineExceeded },
    };
    const io = std.testing.io;
    for (cases) |case| {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var listener = try address.listen(io, .{ .reuse_address = true });
        defer listener.deinit(io);
        var server = try io.concurrent(serveTest, .{ &listener, case.bytes, case.delay });
        // The timeout/overflow cases intentionally abort the server task.
        defer _ = server.cancel(io) catch {};
        var url_buffer: [128]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/v1/systemone", .{listener.socket.address.getPort()});
        var http = try Http.init(std.testing.allocator, io, "test-only-key");
        defer http.deinit();
        var output: [4]u8 = undefined;
        const end = now(&http) + 100 * std.time.ns_per_ms;
        const result = exchangeAt(&http, "{}", &output, end, url);
        if (case.expected) |err| {
            try std.testing.expectError(err, result);
        } else {
            try std.testing.expectEqual(4, (try result).len);
            try std.testing.expectEqualStrings("okay", &output);
        }
        try std.testing.expect(now(&http) < end + std.time.ns_per_s);
    }
}

fn allocationAttempt(http: *Http) !void {
    const io = std.testing.io;
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    var server = try io.concurrent(serveTest, .{ &listener, "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nokay", std.Io.Duration.zero });
    defer _ = server.cancel(io) catch {};
    var url_buffer: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/v1/systemone", .{listener.socket.address.getPort()});
    var output: [4]u8 = undefined;
    const reply = try exchangeAt(http, "{}", &output, now(http) + 5 * std.time.ns_per_s, url);
    try std.testing.expectEqual(@as(u16, 200), reply.status);
    try std.testing.expectEqualStrings("okay", &output);
}
fn allocationFailures(allocator: std.mem.Allocator) !void {
    var http = try Http.init(allocator, std.testing.io, "test-only-key");
    defer http.deinit();
    allocationAttempt(&http) catch |err| {
        // Same adapter remains usable once memory becomes available again.
        http.gpa = std.testing.allocator;
        try allocationAttempt(&http);
        return err;
    };
}
test "HTTP allocation failures release memory and permit recovery" {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    try allocationFailures(counting.allocator());
    try std.testing.expect(counting.alloc_index > 0);
    try std.testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailures, .{});
}

const Lifecycle = struct {
    const Mode = enum { disconnect_upload, disconnect_headers, disconnect_body, stall_headers, stall_body, race, healthy };
    const head = "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n";
    mode: Mode,
    reached: std.atomic.Value(bool) = .init(false),
    active: std.atomic.Value(u32) = .init(0),
    fn serve(self: *@This(), listener: *std.Io.net.Server) !void {
        const io = std.testing.io;
        _ = self.active.fetchAdd(1, .seq_cst);
        defer _ = self.active.fetchSub(1, .seq_cst);
        const stream = try listener.accept(io);
        defer stream.close(io);
        var rb: [4096]u8 = undefined;
        var wb: [4096]u8 = undefined;
        var reader = stream.reader(io, &rb);
        var writer = stream.writer(io, &wb);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = try server.receiveHead();
        self.reached.store(true, .release);
        if (self.mode == .disconnect_upload) return;
        var transfer: [256]u8 = undefined;
        _ = try request.readerExpectNone(&transfer).discardRemaining();
        switch (self.mode) {
            .disconnect_upload => unreachable,
            .disconnect_headers => {
                try writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Len");
                try writer.interface.flush();
            },
            .disconnect_body => {
                try writer.interface.writeAll(head ++ "o");
                try writer.interface.flush();
            },
            .stall_headers => try io.sleep(.fromSeconds(30), .awake),
            .stall_body => {
                try writer.interface.writeAll(head ++ "o");
                try writer.interface.flush();
                try io.sleep(.fromSeconds(30), .awake);
            },
            .race, .healthy => {
                if (self.mode == .race) try io.sleep(.fromMilliseconds(5), .awake);
                try writer.interface.writeAll(head ++ "okay");
                try writer.interface.flush();
            },
        }
    }
    fn scenario(http: *Http, mode: Mode, cancel_caller: bool) !void {
        const io = http.io;
        var state: Lifecycle = .{ .mode = mode };
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var listener = try address.listen(io, .{ .reuse_address = true });
        defer listener.deinit(io);
        var server = try io.concurrent(serve, .{ &state, &listener });
        defer _ = server.cancel(io) catch {};
        var url_buffer: [128]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/v1/systemone", .{listener.socket.address.getPort()});
        var output: [4]u8 = undefined;
        // Large enough that a peer closing immediately after headers interrupts upload.
        const upload = if (mode == .disconnect_upload) try std.testing.allocator.alloc(u8, 16 * 1024 * 1024) else null;
        defer if (upload) |bytes| std.testing.allocator.free(bytes);
        if (upload) |bytes| @memset(bytes, 'x');
        const budget: i96 = if (cancel_caller or mode == .healthy or mode == .disconnect_upload or mode == .disconnect_headers or mode == .disconnect_body) 5 * std.time.ns_per_s else if (mode == .race) 5 * std.time.ns_per_ms else 25 * std.time.ns_per_ms;
        const end = now(http) + budget;
        const result = if (cancel_caller) blk: {
            var call = try io.concurrent(exchangeAt, .{ http, "{}", &output, end, url });
            defer _ = call.cancel(io) catch {};
            // Cancel only after the peer has accepted and parsed the request.
            while (!state.reached.load(.acquire)) {
                if (now(http) >= end) return error.TestUnexpectedResult;
                try io.sleep(.fromMilliseconds(1), .awake);
            }
            break :blk call.cancel(io);
        } else exchangeAt(http, if (upload) |bytes| bytes else "{}", &output, end, url);
        if (cancel_caller) {
            try std.testing.expectError(error.Canceled, result);
        } else switch (mode) {
            .healthy => {
                try std.testing.expectEqual(@as(usize, 4), (try result).len);
                try std.testing.expectEqualStrings("okay", &output);
            },
            .disconnect_upload, .disconnect_headers, .disconnect_body => try std.testing.expectError(error.TransportFailure, result),
            .stall_headers, .stall_body => try std.testing.expectError(error.DeadlineExceeded, result),
            .race => if (result) |reply| {
                try std.testing.expectEqual(@as(usize, 4), reply.len);
                try std.testing.expectEqualStrings("okay", &output);
            } else |err| try std.testing.expectEqual(error.DeadlineExceeded, err),
        }
        try std.testing.expect(now(http) < end + std.time.ns_per_s);
        // Reuse the response storage while the delayed peer can still act.
        @memset(&output, 0xa5);
        try io.sleep(.fromMilliseconds(8), .awake);
        for (output) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
        _ = server.cancel(io) catch {};
        try std.testing.expectEqual(@as(u32, 0), state.active.load(.seq_cst));
    }
    fn worker() anyerror!void {
        var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var http = try Http.init(counting.allocator(), std.testing.io, "test-only-key");
        defer http.deinit();
        const modes = [_]Mode{ .disconnect_upload, .disconnect_headers, .disconnect_body, .stall_headers, .stall_body, .race };
        for (0..6) |_| {
            for (modes) |mode| {
                try scenario(&http, mode, false);
                try std.testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);
                try scenario(&http, .healthy, false);
            }
            try scenario(&http, .stall_body, true);
            try scenario(&http, .healthy, false);
            try std.testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);
        }
    }
};
fn descriptorCount() !usize {
    var dir = try std.Io.Dir.openDirAbsolute(std.testing.io, "/proc/self/fd", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var iterator = dir.iterate();
    var count: usize = 0;
    while (try iterator.next(std.testing.io)) |_| count += 1;
    return count;
}
test "HTTP lifecycle faults cancellation races and resource recovery" {
    // Warm up the I/O runtime before measuring persistent descriptors.
    var http = try Http.init(std.testing.allocator, std.testing.io, "test-only-key");
    defer http.deinit();
    try Lifecycle.scenario(&http, .healthy, false);
    const linux = @import("builtin").os.tag == .linux;
    const before = if (linux) try descriptorCount() else 0;
    try Lifecycle.worker();
    if (linux) try std.testing.expectEqual(before, try descriptorCount());
}
test "HTTP four independent concurrent adapters recover from faults" {
    const io = std.testing.io;
    var workers: [4]std.Io.Future(anyerror!void) = undefined;
    var started: usize = 0;
    defer for (workers[0..started]) |*worker| {
        _ = worker.cancel(io) catch {};
    };
    for (&workers) |*worker| {
        worker.* = try io.concurrent(Lifecycle.worker, .{});
        started += 1;
    }
    for (&workers) |*worker| try worker.await(io);
}

const RetryLoopback = struct {
    http: *Http,
    url: []const u8,
    fn clock(p: *anyopaque) i96 {
        const self: *@This() = @ptrCast(@alignCast(p));
        return now(self.http);
    }
    fn pause(p: *anyopaque, ns: u64) engine.Error!void {
        const self: *@This() = @ptrCast(@alignCast(p));
        return sleep(self.http, ns);
    }
    fn exchange(p: *anyopaque, body: []const u8, response: []u8, end: i96) engine.Error!engine.Reply {
        const self: *@This() = @ptrCast(@alignCast(p));
        return exchangeAt(self.http, body, response, end, self.url);
    }
    fn serve(listener: *std.Io.net.Server, recover: bool) !void {
        for (0..3) |attempt| {
            const bytes = if (recover and attempt == 2) Lifecycle.head ++ "okay" else "HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\nRetry-After-Ms: 1\r\n\r\n";
            try serveTest(listener, bytes, .zero);
        }
    }
};
test "HTTP retries recover or exhaust exactly the configured attempt limit" {
    const io = std.testing.io;
    var http = try Http.init(std.testing.allocator, io, "test-only-key");
    defer http.deinit();
    for ([_]bool{ false, true }) |recover| {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var listener = try address.listen(io, .{ .reuse_address = true });
        defer listener.deinit(io);
        var server = try io.concurrent(RetryLoopback.serve, .{ &listener, recover });
        defer _ = server.cancel(io) catch {};
        var url_buffer: [128]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/v1/systemone", .{listener.socket.address.getPort()});
        var context: RetryLoopback = .{ .http = &http, .url = url };
        const injected: engine.Transport = .{ .context = &context, .now = RetryLoopback.clock, .sleep = RetryLoopback.pause, .exchange = RetryLoopback.exchange };
        var d: engine.Diagnostics = .{};
        var output: [4]u8 = undefined;
        const config: engine.Config = .{ .max_retries = 2, .timeout_ms = 5000 };
        const result = engine.send(injected, config, engine.deadline(injected, config), "{}", &output, &d);
        if (recover) {
            try std.testing.expectEqual(@as(u16, 200), (try result).status);
            try std.testing.expectEqualStrings("okay", &output);
        } else try std.testing.expectError(error.ServerError, result);
        try std.testing.expectEqual(@as(u8, 3), d.attempts);
        try server.await(io);
    }
}

fn tlsFaultServer(listener: *std.Io.net.Server, mode: u8) !void {
    const io = std.testing.io;
    const stream = try listener.accept(io);
    defer stream.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &buffer);
    _ = try reader.interface.takeByte(); // ClientHello has begun.
    if (mode == 0) return;
    if (mode == 1) {
        var wb: [128]u8 = undefined;
        var writer = stream.writer(io, &wb);
        try writer.interface.writeAll("HTTP/1.1 200 OK\r\n\r\n");
        try writer.interface.flush();
        return;
    }
    try io.sleep(.fromSeconds(30), .awake);
}
test "TLS interrupted malformed and stalled handshakes recover" {
    const io = std.testing.io;
    var http = try Http.init(std.testing.allocator, io, "test-only-key");
    defer http.deinit();
    for (0..3) |mode| {
        const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var listener = try address.listen(io, .{ .reuse_address = true });
        defer listener.deinit(io);
        var server = try io.concurrent(tlsFaultServer, .{ &listener, @as(u8, @intCast(mode)) });
        defer _ = server.cancel(io) catch {};
        var url_buffer: [128]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "https://127.0.0.1:{d}/", .{listener.socket.address.getPort()});
        var output: [4]u8 = undefined;
        const result = exchangeAt(&http, "{}", &output, now(&http) + 200 * std.time.ns_per_ms, url);
        if (mode == 2) {
            try std.testing.expectError(error.DeadlineExceeded, result);
        } else if (result) |_| return error.TestUnexpectedResult else |err| {
            try std.testing.expect(err == error.TlsFailure or err == error.TransportFailure);
        }
        try Lifecycle.scenario(&http, .healthy, false);
    }
}
test "opt-in untrusted TLS certificate" {
    const url = std.testing.environ.getAlloc(std.testing.allocator, "JEVLIN_TEST_TLS_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(url);
    var http = try Http.init(std.testing.allocator, std.testing.io, "test-only-key");
    defer http.deinit();
    var output: [4]u8 = undefined;
    try std.testing.expectError(error.TlsFailure, exchangeAt(&http, "{}", &output, now(&http) + 5 * std.time.ns_per_s, url));
    try Lifecycle.scenario(&http, .healthy, false);
}
test "opt-in sustained lifecycle soak" {
    const value = std.testing.environ.getAlloc(std.testing.allocator, "JEVLIN_SOAK_SECONDS") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(value);
    const seconds = try std.fmt.parseInt(u32, value, 10);
    if (seconds == 0 or seconds > 86400) return error.InvalidConfig;
    var http = try Http.init(std.testing.allocator, std.testing.io, "test-only-key");
    defer http.deinit();
    try Lifecycle.worker();
    const before = try descriptorCount();
    const end = now(&http) + @as(i96, seconds) * std.time.ns_per_s;
    var rounds: usize = 0;
    while (now(&http) < end) {
        try Lifecycle.worker();
        try std.testing.expectEqual(before, try descriptorCount());
        rounds += 1;
    }
    std.debug.print("soak rounds={d} exchanges={d} descriptors={d}\n", .{ rounds, rounds * 84, before });
}
