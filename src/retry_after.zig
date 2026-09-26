const std = @import("std");
const ns_per_s = std.time.ns_per_s;
pub const max_delay_ns: u64 = 300 * ns_per_s;

/// Values are parsed once at header receipt. Monotonic time still controls the
/// overall request budget. Invalid fields do not erase an earlier valid value.
pub const Headers = struct {
    milliseconds: ?u64 = null,
    standard: ?u64 = null,
    pub fn add(self: *Headers, name: []const u8, value: []const u8, wall_ns: i96) void {
        if (std.ascii.eqlIgnoreCase(name, "retry-after-ms")) {
            if (numeric(value, std.time.ns_per_ms)) |parsed| self.milliseconds = parsed;
        } else if (std.ascii.eqlIgnoreCase(name, "retry-after")) {
            if (parse(value, wall_ns)) |parsed| self.standard = parsed;
        }
    }
    pub fn delay(self: Headers) ?u64 {
        return self.milliseconds orelse self.standard;
    }
};
pub fn parse(raw: []const u8, wall_ns: i96) ?u64 {
    const text = std.mem.trim(u8, raw, " \t");
    if (numeric(text, ns_per_s)) |delay| return delay;
    const wall_seconds = std.math.cast(i64, @divFloor(wall_ns, ns_per_s)) orelse return null;
    const seconds = date(text, wall_seconds) orelse return null;
    const delta = @as(i96, seconds) * ns_per_s - wall_ns;
    return @intCast(@min(@max(delta, 0), max_delay_ns));
}
fn numeric(raw: []const u8, multiplier: u64) ?u64 {
    const text = std.mem.trim(u8, raw, " \t");
    // Preserve fractional numeric delays accepted by earlier releases.
    const number = std.fmt.parseFloat(f64, text) catch return null;
    if (!std.math.isFinite(number) or number < 0) return null;
    const ns = number * @as(f64, @floatFromInt(multiplier));
    return @intFromFloat(@min(ns, max_delay_ns));
}
fn digits(text: []const u8) ?u16 {
    if (text.len == 0) return null;
    for (text) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(u16, text, 10) catch null;
}
fn index(text: []const u8, comptime names: []const []const u8) ?u16 {
    inline for (names, 0..) |name, i| if (std.mem.eql(u8, text, name)) return i;
    return null;
}
const months = &[_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const weekdays = &[_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const weekdays_long = &[_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
fn daysBeforeYear(year: u16) i64 {
    const y: i64 = @as(i64, year) - 1;
    return 365 * y + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400);
}
fn timestamp(year: u16, month: u16, day: u16, hour: u16, minute: u16, second: u16) ?i64 {
    if (year < 1601 or month < 1 or month > 12 or day == 0 or hour > 23 or minute > 59 or second > 60) return null;
    if (day > std.time.epoch.getDaysInMonth(year, @enumFromInt(month))) return null;
    var days = daysBeforeYear(year) - daysBeforeYear(1970);
    for (1..month) |m| days += std.time.epoch.getDaysInMonth(year, @enumFromInt(m));
    days += day - 1;
    return days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;
}
/// IMF-fixdate plus RFC 850 and asctime legacy HTTP-date forms.
fn date(text: []const u8, now_seconds: i64) ?i64 {
    var year: u16 = undefined;
    var month_text: []const u8 = undefined;
    var day_text: []const u8 = undefined;
    var time: []const u8 = undefined;
    var weekday: u16 = undefined;
    var short_year = false;
    if (text.len == 29 and std.mem.eql(u8, text[3..5], ", ")) {
        if (text[7] != ' ' or text[11] != ' ' or text[16] != ' ' or !std.mem.eql(u8, text[25..], " GMT")) return null;
        weekday = index(text[0..3], weekdays) orelse return null;
        day_text = text[5..7];
        month_text = text[8..11];
        year = digits(text[12..16]) orelse return null;
        time = text[17..25];
    } else if (text.len == 24 and text[3] == ' ') {
        if (text[7] != ' ' or text[10] != ' ' or text[19] != ' ') return null;
        weekday = index(text[0..3], weekdays) orelse return null;
        month_text = text[4..7];
        day_text = if (text[8] == ' ') text[9..10] else text[8..10];
        time = text[11..19];
        year = digits(text[20..24]) orelse return null;
    } else {
        const comma = std.mem.indexOfScalar(u8, text, ',') orelse return null;
        weekday = index(text[0..comma], weekdays_long) orelse return null;
        const rest = text[comma + 1 ..];
        if (rest.len != 23 or rest[0] != ' ' or rest[3] != '-' or rest[7] != '-' or rest[10] != ' ' or !std.mem.eql(u8, rest[19..], " GMT")) return null;
        day_text = rest[1..3];
        month_text = rest[4..7];
        year = digits(rest[8..10]) orelse return null;
        time = rest[11..19];
        short_year = true;
    }
    const month = (index(month_text, months) orelse return null) + 1;
    const day = digits(day_text) orelse return null;
    if (time[2] != ':' or time[5] != ':') return null;
    const hour = digits(time[0..2]) orelse return null;
    const minute = digits(time[3..5]) orelse return null;
    const second = digits(time[6..8]) orelse return null;
    if (short_year) {
        // Bound the standard library's year conversion even for an injected clock.
        if (now_seconds < 0 or now_seconds > 253402300799) return null;
        const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(now_seconds) };
        const today = epoch.getEpochDay().calculateYearDay();
        const md = today.calculateMonthDay();
        const future_year = today.year + 50;
        const future_day = @min(@as(u16, md.day_index) + 1, std.time.epoch.getDaysInMonth(future_year, md.month));
        const cutoff = (timestamp(future_year, @intFromEnum(md.month), future_day, 0, 0, 0) orelse return null) + @mod(now_seconds, 86400);
        year += (today.year / 100) * 100;
        // Start from the next matching year, including across a century boundary.
        if (year < today.year) year += 100;
        const candidate = (timestamp(year, month, 1, hour, minute, second) orelse return null) + (@as(i64, day) - 1) * 86400;
        if (candidate > cutoff) year -= 100;
    }
    const result = timestamp(year, month, day, hour, minute, second) orelse return null;
    // Validate weekday before leap-second normalization crosses midnight.
    const midnight = timestamp(year, month, day, 0, 0, 0).?;
    if (@mod(@divFloor(midnight, 86400) + 4, 7) != weekday) return null;
    return result;
}

test "HTTP dates three formats past future fractions and invalid values" {
    const t = std.testing;
    const target: i96 = 784111777 * @as(i96, ns_per_s);
    for ([_][]const u8{ "Sun, 06 Nov 1994 08:49:37 GMT", "Sunday, 06-Nov-94 08:49:37 GMT", "Sun Nov  6 08:49:37 1994" }) |text| {
        try t.expectEqual(@as(?u64, 2 * ns_per_s), parse(text, target - 2 * ns_per_s));
        try t.expectEqual(@as(?u64, 500_000_000), parse(text, target - 500_000_000));
        try t.expectEqual(@as(?u64, 0), parse(text, target));
        try t.expectEqual(@as(?u64, 0), parse(text, target + ns_per_s));
    }
    try t.expectEqual(@as(?u64, max_delay_ns), parse("Fri, 31 Dec 9999 23:59:59 GMT", target));
    try t.expectEqual(@as(?u64, 0), parse("Thu, 01 Jan 1970 00:00:00 GMT", target));
    try t.expectEqual(@as(?u64, 1500000000), parse("1.5", target));
    try t.expectEqual(@as(?u64, max_delay_ns), parse("1e300", target));
    for ([_][]const u8{ "", "NaN", "inf", "-1", "Sun, 31 Feb 1994 08:49:37 GMT", "Sun, 06 Nov 1994 25:49:37 GMT", "Sun, 06 Nov 1994 08:60:37 GMT", "Sun, 06 Nov 1994 08:49:61 GMT", "Sun, 06 Nov 1994 08:49:37 UTC", "Mon, 06 Nov 1994 08:49:37 GMT", "Sunday, 06-Nov-94 08:49:37", "Sun Nov  6 08:49:37 1994 trailing" }) |text| try t.expectEqual(@as(?u64, null), parse(text, target));
}
test "retry header precedence is independent of order and invalid milliseconds" {
    const t = std.testing;
    for ([_]bool{ false, true }) |reverse| {
        var headers: Headers = .{};
        if (reverse) headers.add("Retry-After", "3", 0);
        headers.add("Retry-After-Ms", "250", 0);
        headers.add("Retry-After-Ms", "invalid", 0);
        if (!reverse) headers.add("Retry-After", "3", 0);
        try t.expectEqual(@as(?u64, 250000000), headers.delay());
    }
    var headers: Headers = .{};
    headers.add("Retry-After", "3", 0);
    headers.add("Retry-After-Ms", "invalid", 0);
    try t.expectEqual(@as(?u64, 3 * ns_per_s), headers.delay());
}

test "calendar leap years leap second and RFC850 rolling century" {
    const t = std.testing;
    const clock = 1790424000; // 2026-09-26T12:00:00Z
    try t.expectEqual(@as(?i64, 3368347200), date("Saturday, 26-Sep-76 12:00:00 GMT", clock));
    try t.expectEqual(@as(?i64, 212587201), date("Sunday, 26-Sep-76 12:00:01 GMT", clock));
    try t.expectEqual(@as(?i64, 951825600), date("Tuesday, 29-Feb-00 12:00:00 GMT", clock));
    try t.expectEqual(@as(?i64, 4102444800), date("Friday, 01-Jan-00 00:00:00 GMT", 3786912000));
    try t.expectEqual(@as(?i64, 1709208000), date("Thu, 29 Feb 2024 12:00:00 GMT", clock));
    try t.expectEqual(@as(?i64, 1483228800), date("Sat, 31 Dec 2016 23:59:60 GMT", clock));
    for ([_][]const u8{ "Mon, 29 Feb 2100 12:00:00 GMT", "Thu, 29 Feb 2023 12:00:00 GMT", "Fri, 00 Jan 2021 00:00:00 GMT", "Fri, 01 Xxx 2021 00:00:00 GMT" }) |text|
        try t.expectEqual(@as(?i64, null), date(text, clock));
    try t.expectEqual(@as(?u64, null), parse("Sunday, 06-Nov-94 08:49:37 GMT", std.math.maxInt(i96)));
}
test "bounded date mutation campaign and truncated inputs" {
    const seed = "Sat, 26 Sep 2026 12:00:00 GMT";
    for (0..seed.len) |len| try std.testing.expectEqual(@as(?u64, null), parse(seed[0..len], 0));
    var rng = std.Random.DefaultPrng.init(0x7265747279);
    const random = rng.random();
    var bytes: [64]u8 = undefined;
    for (0..10000) |i| {
        const len = if (i % 2 == 0) seed.len else random.intRangeAtMost(usize, 0, bytes.len);
        random.bytes(bytes[0..len]);
        if (i % 2 == 0) {
            @memcpy(bytes[0..len], seed);
            bytes[random.uintLessThan(usize, len)] = random.int(u8);
        }
        if (parse(bytes[0..len], 1790424000 * @as(i96, ns_per_s))) |delay|
            try std.testing.expect(delay <= max_delay_ns);
    }
}
