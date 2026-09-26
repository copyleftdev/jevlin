const std = @import("std");
pub const Error = error{ OutOfMemory, Busy, InvalidConfig, DeadlineExceeded, Canceled, TransportFailure, TlsFailure, ConcurrencyUnavailable, ResponseTooLarge, Unauthorized, RateLimited, BadRequest, ServerError, UnexpectedStatus, InvalidResponse };
pub const Reply = struct { status: u16, len: usize, retry_after_ns: ?u64 = null };
/// Injectable boundary. Implementations must honor deadline_ns and buffer capacity.
pub const Transport = struct {
    context: *anyopaque,
    now: *const fn (*anyopaque) i96,
    sleep: *const fn (*anyopaque, u64) Error!void,
    exchange: *const fn (*anyopaque, []const u8, []u8, i96) Error!Reply,
};
pub const Config = struct {
    timeout_ms: u32 = 10_000,
    max_retries: u8 = 2,
    backoff_ms: u32 = 100,
    seed: u64 = 1,
    pub fn validate(c: Config) Error!void {
        if (c.timeout_ms == 0 or c.timeout_ms > 300_000 or c.max_retries > 8 or c.backoff_ms > 5_000) return error.InvalidConfig;
    }
};
/// Body and parsed details borrow the response/scratch workspace until reuse.
pub const Diagnostics = struct {
    status: ?u16 = null,
    attempts: u8 = 0,
    error_body: []const u8 = &.{},
    error_json: ?std.json.Value = null,
};
pub fn deadline(t: Transport, config: Config) i96 {
    return t.now(t.context) + @as(i96, config.timeout_ms) * std.time.ns_per_ms;
}
pub fn checkDeadline(t: Transport, end: i96) Error!void {
    if (t.now(t.context) >= end) return error.DeadlineExceeded;
}
pub fn send(t: Transport, config: Config, end: i96, body: []const u8, response: []u8, diagnostics: *Diagnostics) Error!Reply {
    try config.validate();
    diagnostics.* = .{};
    var rng = std.Random.DefaultPrng.init(config.seed);
    for (0..@as(usize, config.max_retries) + 1) |attempt| {
        try checkDeadline(t, end);
        diagnostics.attempts += 1;
        diagnostics.status = null;
        diagnostics.error_body = &.{};
        diagnostics.error_json = null;
        const reply = t.exchange(t.context, body, response, end) catch |err| {
            if (err != error.TransportFailure or attempt == config.max_retries) return err;
            try pause(t, config, end, attempt, null, rng.random());
            continue;
        };
        try checkDeadline(t, end);
        if (reply.len > response.len) return error.ResponseTooLarge;
        diagnostics.status = reply.status;
        if (reply.status >= 200 and reply.status < 300) return reply;
        diagnostics.error_body = response[0..reply.len];
        const err = statusError(reply.status);
        const retryable = reply.status == 408 or reply.status == 429 or (reply.status >= 500 and reply.status < 600);
        if (!retryable or attempt == config.max_retries) return err;
        try pause(t, config, end, attempt, reply.retry_after_ns, rng.random());
    }
    unreachable; // Every bounded final attempt returns success or an error.
}
fn pause(t: Transport, c: Config, end: i96, attempt: usize, server: ?u64, random: std.Random) Error!void {
    const scale = @as(u64, 1) << @as(u6, @intCast(attempt));
    const cap = @as(u64, @min(@as(u64, c.backoff_ms) * scale, 5_000)) * std.time.ns_per_ms;
    const delay = server orelse random.intRangeAtMost(u64, cap / 2, cap);
    if (t.now(t.context) + @as(i96, delay) >= end) return error.DeadlineExceeded;
    try t.sleep(t.context, delay);
    try checkDeadline(t, end);
}
fn statusError(status: u16) Error {
    return switch (status) {
        400, 422 => error.BadRequest,
        401, 403 => error.Unauthorized,
        429 => error.RateLimited,
        500...599 => error.ServerError,
        else => error.UnexpectedStatus,
    };
}
