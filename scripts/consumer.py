#!/usr/bin/env python3
"""Fetch a local Jevlin archive and run a separate application using its public API."""
import argparse
import json
import pathlib
import platform
import re
import subprocess
import tarfile
import tempfile

BUILD = '''const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dependency = b.dependency("jevlin", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{ .name = "consumer", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize,
        .imports = &.{.{ .name = "jevlin", .module = dependency.module("jevlin") }},
    }) });
    b.step("run", "Verify the packaged SDK from a separate application").dependOn(&b.addRunArtifact(exe).step);
}
'''
MAIN = r'''const std = @import("std");
const j = @import("jevlin");
const Fake = struct {
    status: u16 = 200,
    const response =
        \\{"model":"consumer-fixture","usage":{"input_tokens":42,"output_tokens":7},"answers":{"urgent":{"type":"noul","noul":0.8},"team":{"type":"choice","choice":"billing","confidence":0.5,"probabilities":{"billing":0.8,"support":0.2}},"risk":{"type":"score","score":0.25,"confidence":0.5,"probabilities":{"0":0.75,"1":0.25},"legend":{"0":"Low","1":"High"}}}}
    ;
    fn now(_: *anyopaque) i96 { return 0; }
    fn sleep(_: *anyopaque, _: u64) j.engine.Error!void {}
    fn exchange(p: *anyopaque, body: []const u8, out: []u8, _: i96) j.engine.Error!j.engine.Reply {
        const self: *@This() = @ptrCast(@alignCast(p));
        if (std.mem.indexOf(u8, body, "\"criteria\":{\"true\":") == null) return error.InvalidResponse;
        const bytes = if (self.status == 200) response else "{\"detail\":\"invalid\"}";
        if (bytes.len > out.len) return error.ResponseTooLarge;
        @memcpy(out[0..bytes.len], bytes);
        return .{ .status = self.status, .len = bytes.len };
    }
};
pub fn main(init: std.process.Init) !void {
    try @import("api_contract.zig").main();
    var http = try j.Http.init(init.gpa, init.io, "local-test-key");
    defer http.deinit();
    _ = http.transport(); // Compile production Http, without sending any request.
    var fake: Fake = .{};
    var client = try j.Client.init(.{ .context = &fake, .now = Fake.now, .sleep = Fake.sleep, .exchange = Fake.exchange }, .{ .max_retries = 0 });
    const Team = enum { billing, support };
    const questions = .{
        .urgent = j.noulWithCriteria(.{ .question = "Urgent?" }, .{ .@"true" = "Urgent", .@"false" = "Routine" }),
        .team = j.choiceStructured(Team, "Route?", .{ .billing = .{ .meaning = "Payments" }, .support = null }),
        .risk = j.scoreStructured("Risk?", .{ "Low", "High" }),
    };
    var request: [4096]u8 = undefined;
    var response: [4096]u8 = undefined;
    var scratch: [65536]u8 = undefined;
    const workspace: j.Workspace = .{ .request = &request, .response = &response, .scratch = &scratch };
    var d: j.engine.Diagnostics = .{};
    const result = try client.evaluate(.{ .ticket = "Help" }, questions, "jev-latest", workspace, &d);
    if (result.answers.team.choice != Team.billing or result.answers.risk.score != 0.25 or result.usage.?.input_tokens != 42) return error.ConsumerAssertionFailed;
    fake.status = 422;
    if (client.evaluate("state", questions, "jev-latest", workspace, &d)) |_| return error.ConsumerAssertionFailed else |err| {
        if (err != error.BadRequest or d.status.? != 422 or d.error_json == null) return error.ConsumerAssertionFailed;
    }
    fake.status = 200;
    _ = try client.evaluate("state", questions, "jev-latest", workspace, &d);
    std.debug.print("consumer: typed answers, usage, structured input, errors and recovery passed\n", .{});
}
'''


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--zig', default='zig')
    p.add_argument('--optimize', choices=['Debug','ReleaseSafe'], default='Debug')
    p.add_argument('--report', type=pathlib.Path, default=pathlib.Path('consumer-report.json'))
    a = p.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='jevlin-consumer-') as directory:
        temp = pathlib.Path(directory)
        archive = temp/'jevlin.tar.gz'
        # Archive working copies of tracked files; Zig applies build.zig.zon's
        # package paths filter when fetching. No access to checkout paths in app.
        files = subprocess.run(['git','ls-files','-z'], cwd=root, capture_output=True, check=True).stdout.decode().split('\0')
        with tarfile.open(archive, 'w:gz') as tar:
            for name in files:
                if name:
                    tar.add(root/name, arcname='jevlin/'+name)
        consumer = temp/'app'
        consumer.mkdir()
        def run(*args):
            return subprocess.run([a.zig,*args], cwd=consumer, capture_output=True, text=True, timeout=180)
        initialized = run('init', '--minimal')
        if initialized.returncode:
            raise RuntimeError(initialized.stdout + initialized.stderr)
        (consumer/'build.zig').write_text(BUILD, newline='\n')
        (consumer/'src').mkdir(exist_ok=True)
        (consumer/'src/main.zig').write_text(MAIN, newline='\n')
        (consumer/'src/api_contract.zig').write_text((root/'examples/api_contract.zig').read_text(), newline='\n')
        fetched = run('fetch', '--save=jevlin', str(archive), '--global-cache-dir', str(temp/'cache'))
        if fetched.returncode:
            raise RuntimeError(fetched.stdout+fetched.stderr)
        manifest = (consumer/'build.zig.zon').read_text()
        package_hash = re.search(r'\.hash\s*=\s*"([^"]+)"', manifest)
        if package_hash is None or '.path =' in manifest:
            raise RuntimeError('Expected a hashed archive dependency: '+manifest)
        archive.unlink()  # The build must use the fetched package, not the archive.
        built = run('build','run','-Doptimize='+a.optimize, '--global-cache-dir', str(temp/'cache'), '--summary','all')
        output = built.stdout+built.stderr
        report = {'passed': built.returncode==0, 'platform': platform.platform(), 'machine': platform.machine(),
                  'optimize': a.optimize, 'package_hash': package_hash.group(1), 'exit_code': built.returncode, 'output':output}
        a.report.write_text(json.dumps(report,indent=2)+'\n')
        print(output,end='')
        print('report='+str(a.report),flush=True)
        return built.returncode


if __name__ == '__main__':
    raise SystemExit(main())
