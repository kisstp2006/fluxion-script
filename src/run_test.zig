// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const testing = std.testing;

const diag = @import("diag.zig");
const Vm = @import("vm/Vm.zig");
const Compiler = @import("compile/Compiler.zig");
const call = @import("vm/call.zig");
const panic = @import("vm/panic.zig");

fn runSource(source: []const u8, out: *std.Io.Writer.Allocating) !void {
    const vm = try Vm.create(testing.allocator, .{ .out = &out.writer });
    defer vm.destroy();
    var diags: diag.Diagnostics = .init(testing.allocator);
    defer diags.deinit();
    const module = Compiler.compileModule(vm, "test.flux", source, &diags) catch |err| {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try diag.render.all(&buf.writer, &vm.sources, &diags, .{});
        std.debug.print("{s}\n", .{buf.written()});
        return err;
    };
    call.runModule(vm, module) catch |err| {
        if (vm.panic) |*p| {
            var buf: std.Io.Writer.Allocating = .init(testing.allocator);
            defer buf.deinit();
            try panic.render(&buf.writer, vm, p, .{});
            std.debug.print("{s}\n", .{buf.written()});
        }
        return err;
    };
}

fn expectOutput(source: []const u8, expected: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try runSource(source, &out);
    try testing.expectEqualStrings(expected, out.written());
}

test "hello" {
    try expectOutput("print(\"hello\", 1 + 2);", "hello 3\n");
}

test "a budget stops a runaway loop with a panic, and the VM goes on" {
    const vm = try Vm.create(testing.allocator, .{});
    defer vm.destroy();
    const m = try vm.compile("loop.flux", "fn spin() { var n = 0; while (true) { n += 1; } }\nfn fine() int { var t = 0; for (0..10) |i| t += i; return t; }");
    try vm.run(m);
    vm.setBudget(1000);
    try testing.expectError(error.Panic, vm.callName(m, "spin", &.{}));
    try testing.expectEqualStrings("the script ran past its budget of 1000 loop rounds", vm.panic.?.message);
    try testing.expectEqualStrings("spin", vm.panic.?.trace[0].function);
    vm.clearPanic();
    try testing.expectEqual(@as(i64, 45), (try vm.callName(m, "fine", &.{})).asInt());
    vm.setBudget(null);
    vm.interrupt();
    try testing.expectError(error.Panic, vm.callName(m, "spin", &.{}));
    try testing.expectEqualStrings("the host stopped the script", vm.panic.?.message);
    vm.clearPanic();
    try testing.expectEqual(@as(i64, 45), (try vm.callName(m, "fine", &.{})).asInt());
}

test "a heap limit refuses what would pass it" {
    const vm = try Vm.create(testing.allocator, .{ .max_bytes = 256 * 1024 });
    defer vm.destroy();
    const m = try vm.compile("grow.flux", "fn grow() { var all: [string] = []; for (0..100000) |i| all.push(f\"item number {i}\"); }");
    try vm.run(m);
    try testing.expectError(error.OutOfMemory, vm.callName(m, "grow", &.{}));
}

test "a panic inside a native points at the call" {
    const vm = try Vm.create(testing.allocator, .{});
    defer vm.destroy();
    const source = "fn f() {\n    assert(1 > 2, \"no\");\n}";
    const m = try vm.compile("n.flux", source);
    try vm.run(m);
    try testing.expectError(error.Panic, vm.callName(m, "f", &.{}));
    const p = vm.panic.?;
    try testing.expectEqualStrings("assert", p.trace[0].function);
    const span = p.trace[1].span;
    try testing.expectEqualStrings("assert(1 > 2, \"no\")", source[span.start..span.end]);
}

test "a function value gives back what its type says, or panics" {
    const vm = try Vm.create(testing.allocator, .{});
    defer vm.destroy();
    const m = try vm.compile("f.flux",
        \\fn pass(x: any) any { return x; }
        \\var f: fn() int = pass(|| "text");
        \\fn call_it() int { return f() + 1; }
    );
    try vm.run(m);
    try testing.expectError(error.Panic, vm.callName(m, "call_it", &.{}));
    try testing.expect(std.mem.indexOf(u8, vm.panic.?.message, "int") != null);
    vm.clearPanic();
}

test "names longer than any interned string still find their functions and fields" {
    const vm = try Vm.create(testing.allocator, .{});
    defer vm.destroy();
    const m = try vm.compile("long.flux",
        \\struct Settings { var the_rather_long_name_of_a_setting_that_matters: int = 7; }
        \\fn a_function_whose_name_is_longer_than_forty_characters(s: any) int {
        \\    return s.the_rather_long_name_of_a_setting_that_matters;
        \\}
        \\fn run_it() int { return a_function_whose_name_is_longer_than_forty_characters(Settings{}); }
    );
    try vm.run(m);
    try testing.expectEqual(@as(i64, 7), (try vm.callName(m, "run_it", &.{})).asInt());
    try testing.expect(vm.get(m, "a_function_whose_name_is_longer_than_forty_characters") != null);
}

/// What `source` compiles to at `strictness`, and how many errors and
/// warnings it was told.
fn compileAt(vm: *Vm, strictness: Vm.Unhandled, source: []const u8, errors: *u32, warnings: *u32) !?*@import("vm/object.zig").Module {
    vm.options.unhandled_errors = strictness;
    var diags: diag.Diagnostics = .init(testing.allocator);
    defer diags.deinit();
    const module = Compiler.compileModule(vm, "lenient.flux", source, &diags) catch null;
    errors.* = diags.errors;
    warnings.* = diags.warnings;
    return module;
}

test "an error nothing handles is refused when strict, and handled when not: passed on where it can be, the script stopped where it cannot" {
    const source =
        \\fn plus_one(t: string) int { return int(t) + 1; }
        \\fn doubled(t: string) !int { const n = int(t) * 2; return n; }
        \\fn dropped(t: string) { int(t); }
        \\fn tried(t: string) int { return try int(t); }
        \\fn length(t: string) int { var total = 0; for (0..int(t)) |i| total += i; return total; }
        \\fn shown(t: string) string { return str(int(t)); }
    ;
    var errors: u32 = 0;
    var warnings: u32 = 0;
    {
        const vm = try Vm.create(testing.allocator, .{});
        defer vm.destroy();
        try testing.expect(try compileAt(vm, .strict, source, &errors, &warnings) == null);
        try testing.expectEqual(@as(u32, 5), errors);
    }
    const vm = try Vm.create(testing.allocator, .{});
    defer vm.destroy();
    const m = (try compileAt(vm, .warn, source, &errors, &warnings)).?;
    try testing.expectEqual(@as(u32, 0), errors);
    try testing.expectEqual(@as(u32, 5), warnings);
    try vm.run(m);

    const good = [_]@import("vm/value.zig").Value{try vm.string("41")};
    const bad = [_]@import("vm/value.zig").Value{try vm.string("x")};
    try testing.expectEqual(@as(i64, 42), (try vm.callName(m, "plus_one", &good)).asInt());
    try testing.expectEqual(@as(i64, 82), (try vm.callName(m, "doubled", &good)).asInt());
    // Where the function returns errors, the error is passed on.
    try testing.expect((try vm.callName(m, "doubled", &bad)).tag == .@"error");
    // Where it does not, the script stops, naming the error.
    for ([_][]const u8{ "plus_one", "dropped", "tried", "length" }) |name| {
        try testing.expectError(error.Panic, vm.callName(m, name, &bad));
        try testing.expect(std.mem.startsWith(u8, vm.panic.?.message, "error.InvalidInt was not handled"));
        vm.clearPanic();
    }
    // What strict takes stays as it was: the error, printed.
    const printed = try vm.callName(m, "shown", &bad);
    try testing.expect(std.mem.indexOf(u8, printed.as(@import("vm/object.zig").String).bytes(), "InvalidInt") != null);

    // Quiet: the same, and nothing said.
    const quiet = try Vm.create(testing.allocator, .{});
    defer quiet.destroy();
    _ = (try compileAt(quiet, .quiet, source, &errors, &warnings)).?;
    try testing.expectEqual(@as(u32, 0), errors + warnings);
}
