// SPDX-License-Identifier: BSD-2-Clause

//! `flux run --watch`: the script keeps running, and each file it loaded is
//! reloaded when it is saved. A panic or a reload that does not compile is
//! reported and the program goes on, so the next save can mend it.

const std = @import("std");
const flux = @import("fluxion_script");

pub const Output = struct {
    err: *std.Io.Writer,
    color: bool,
};

const tick = 0.25;

pub fn run(vm: *flux.Vm, module: *flux.object.Module, host: *flux.os.Host, io: std.Io, o: Output) !u8 {
    var seen: std.StringArrayHashMapUnmanaged(i96) = .empty;
    defer seen.deinit(vm.gpa);
    try note(vm, io, &seen);
    try o.err.print("watching {d} file{s}; save one to reload it, ctrl+c to stop\n", .{ seen.count(), if (seen.count() == 1) "" else "s" });
    try o.err.flush();
    vm.run(module) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.Panic => try panicked(vm, host, o),
    };
    var last = std.Io.Timestamp.now(io, .awake);
    while (host.exit_code == null) {
        var wait: f64 = tick;
        if (vm.scheduler.timers.items.len > 0) wait = @min(wait, vm.scheduler.timers.items[0].wake_at - vm.scheduler.time);
        try vm.options.out.?.flush();
        if (wait > 0) io.sleep(.fromNanoseconds(@intFromFloat(wait * std.time.ns_per_s)), .awake) catch {};
        const now = std.Io.Timestamp.now(io, .awake);
        const dt = @as(f64, @floatFromInt(last.durationTo(now).nanoseconds)) / std.time.ns_per_s;
        last = now;
        vm.update(dt) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.Panic => try panicked(vm, host, o),
        };
        try reloadSaved(vm, io, &seen, host, o);
    }
    return host.exit_code.?;
}

/// Every script file loaded so far, with when it was last changed.
fn note(vm: *flux.Vm, io: std.Io, seen: *std.StringArrayHashMapUnmanaged(i96)) !void {
    var it = vm.modules.iterator();
    while (it.next()) |e| {
        const gop = try seen.getOrPut(vm.gpa, e.key_ptr.*);
        if (!gop.found_existing) gop.value_ptr.* = changedAt(io, e.key_ptr.*) orelse 0;
    }
}

fn changedAt(io: std.Io, path: []const u8) ?i96 {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return stat.mtime.nanoseconds;
}

fn reloadSaved(vm: *flux.Vm, io: std.Io, seen: *std.StringArrayHashMapUnmanaged(i96), host: *flux.os.Host, o: Output) !void {
    for (seen.keys(), seen.values()) |path, *when| {
        const now = changedAt(io, path) orelse continue;
        if (now == when.*) continue;
        when.* = now;
        const module = vm.moduleNamed(path) orelse continue;
        if (vm.options.out) |w| try w.flush();
        const source = std.Io.Dir.cwd().readFileAlloc(io, path, vm.gpa, .limited(64 << 20)) catch |err| {
            try o.err.print("cannot read `{s}`: {s}\n", .{ path, @errorName(err) });
            continue;
        };
        defer vm.gpa.free(source);
        const report = vm.reload(module, source) catch |err| {
            switch (err) {
                error.OutOfMemory => return err,
                error.CompileFailed => {
                    try vm.writeDiagnostics(o.err, .{ .color = o.color });
                    try o.err.print("`{s}` was not reloaded: the code from before goes on running\n", .{path});
                },
                error.Panic => try panicked(vm, host, o),
                error.Busy => {},
            }
            try o.err.flush();
            continue;
        };
        try vm.writeDiagnostics(o.err, .{ .color = o.color });
        try o.err.print("reloaded `{s}`", .{path});
        if (report.modules > 1) try o.err.print(" and {d} file{s} importing it", .{ report.modules - 1, if (report.modules == 2) "" else "s" });
        if (report.changed) |name| try o.err.print("; `{s}` changed shape: {d} instance{s} moved, {d} task{s} stopped", .{ name, report.instances, plural(report.instances), report.stopped, plural(report.stopped) });
        try o.err.writeAll("\n");
        try o.err.flush();
        break;
    }
    try note(vm, io, seen);
}

fn plural(n: u32) []const u8 {
    return if (n == 1) "" else "s";
}

/// A panic is shown and the program goes on; `os.exit` is one too, and
/// ends it quietly.
fn panicked(vm: *flux.Vm, host: *flux.os.Host, o: Output) !void {
    if (vm.options.out) |w| try w.flush();
    if (host.exit_code == null) try vm.writePanic(o.err, .{ .color = o.color });
    vm.clearPanic();
    try o.err.flush();
}
