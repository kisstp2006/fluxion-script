// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Vm = @import("vm/Vm.zig");
const Value = @import("vm/value.zig").Value;
const object = @import("vm/object.zig");

/// Modules a test imports, by name, from memory.
const Files = struct {
    list: []const [2][]const u8,

    fn loader(self: *Files) Vm.Loader {
        return .{ .context = self, .load = load };
    }

    fn load(context: ?*anyopaque, gpa: Allocator, from: []const u8, path: []const u8) anyerror!Vm.Loader.Loaded {
        const self: *Files = @ptrCast(@alignCast(context.?));
        _ = from;
        for (self.list) |f| if (std.mem.eql(u8, f[0], path)) return .{ .name = try gpa.dupe(u8, path), .source = try gpa.dupe(u8, f[1]) };
        return error.FileNotFound;
    }
};

fn int(vm: *Vm, m: *object.Module, name: []const u8) !i64 {
    return (try vm.callName(m, name, &.{})).asInt();
}

fn warnings(vm: *Vm) usize {
    return vm.diagnostics.warnings;
}

test "a reload of a body keeps state, identity, and what the host holds" {
    const vm = try Vm.create(testing.allocator, .{});
    defer vm.destroy();
    const m = try vm.compile("game.flux",
        \\var hits = 0;
        \\struct Enemy {
        \\    var hp: int = 10;
        \\    fn hit(self, n: int) { self.hp -= n; hits += 1; }
        \\}
        \\const e = Enemy{};
        \\fn damage() int { e.hit(2); return e.hp; }
        \\fn count() int { return hits; }
    );
    try vm.run(m);
    const damage = vm.get(m, "damage").?;
    const enemy = vm.get(m, "e").?;
    try testing.expectEqual(@as(i64, 8), (try vm.call(damage, &.{})).asInt());

    const report = try vm.reload(m,
        \\var hits = 0;
        \\struct Enemy {
        \\    var hp: int = 10;
        \\    fn hit(self, n: int) { self.hp -= n * 2; hits += 1; }
        \\}
        \\const e = Enemy{};
        \\fn damage() int { e.hit(2); return e.hp; }
        \\fn count() int { return hits; }
    );
    try testing.expect(report.changed == null);
    try testing.expectEqual(@as(u32, 1), report.modules);
    try testing.expectEqual(@as(i64, 4), (try vm.call(damage, &.{})).asInt());
    try testing.expectEqual(@as(i64, 2), try int(vm, m, "count"));
    try testing.expectEqual(enemy.raw, vm.get(m, "e").?.raw);
}

test "a new field moves instances to the new layout, by name" {
    const vm = try Vm.create(testing.allocator, .{ .gc = .{ .stress = true, .verify = true } });
    defer vm.destroy();
    const m = try vm.compile("p.flux",
        \\struct P {
        \\    var x: int = 1;
        \\    var hp: int = 3;
        \\}
        \\const p = P{ .x = 5, .hp = 9 };
        \\fn get() int { return p.x; }
    );
    try vm.run(m);
    const held = vm.get(m, "p").?;
    try vm.hold(held);
    defer vm.release(held);

    const report = try vm.reload(m,
        \\struct P {
        \\    var name: string = "anon";
        \\    var x: int = 1;
        \\    var hp: string = "full";
        \\    var tags: [string] = [];
        \\    var scale = vec2(2, 2);
        \\}
        \\const p = P{ .x = 5 };
        \\fn get() int { return p.x; }
        \\fn name() string { return p.name; }
        \\fn hp() string { return p.hp; }
        \\fn tags() int { p.tags.push("new"); return p.tags.len; }
        \\fn scale() float { return p.scale.x; }
    );
    try testing.expectEqualStrings("P", report.changed.?);
    try testing.expectEqual(@as(u32, 1), report.instances);
    try testing.expectEqual(@as(i64, 5), try int(vm, m, "get"));
    try testing.expectEqualStrings("anon", (try vm.callName(m, "name", &.{})).as(object.String).bytes());
    try testing.expectEqualStrings("full", (try vm.callName(m, "hp", &.{})).as(object.String).bytes());
    try testing.expectEqual(@as(i64, 1), try int(vm, m, "tags"));
    try testing.expectEqual(@as(f64, 2), (try vm.callName(m, "scale", &.{})).asFloat());
    try testing.expectEqual(@as(usize, 5), held.as(object.Instance).fields().len);
    try testing.expectEqual(@as(usize, 1), warnings(vm));
    try testing.expect(std.mem.indexOf(u8, vm.diagnostics.items.items[0].message, "`P.hp` is declared as another type now") != null);
}

test "code that does not compile changes nothing" {
    const vm = try Vm.create(testing.allocator, .{});
    defer vm.destroy();
    const m = try vm.compile("a.flux",
        \\struct S { var n: int = 1; }
        \\const s = S{};
        \\fn get() int { return s.n; }
    );
    try vm.run(m);
    try testing.expectError(error.CompileFailed, vm.reload(m,
        \\struct S { var n: int = 1; var extra: int = 2; }
        \\const s = S{};
        \\fn get() int { return s.nope; }
    ));
    try testing.expect(vm.diagnostics.failed());
    try testing.expectEqual(@as(i64, 1), try int(vm, m, "get"));
    try testing.expectEqual(@as(usize, 1), vm.get(m, "s").?.as(object.Instance).fields().len);
    _ = try vm.reload(m,
        \\struct S { var n: int = 1; var extra: int = 2; }
        \\const s = S{};
        \\fn get() int { return s.n + s.extra; }
    );
    try testing.expectEqual(@as(i64, 3), try int(vm, m, "get"));
}

test "stored enum members follow their names" {
    const vm = try Vm.create(testing.allocator, .{});
    defer vm.destroy();
    const m = try vm.compile("e.flux",
        \\enum State { idle, run, jump }
        \\var s = State.jump;
        \\var t = State.idle;
        \\var seen: [State: int] = {};
        \\fn start() { seen[State.idle] = 1; seen[State.run] = 2; }
    );
    try vm.run(m);
    _ = try vm.callName(m, "start", &.{});
    const report = try vm.reload(m,
        \\enum State { run, idle }
        \\var s = State.idle;
        \\var t = State.idle;
        \\var seen: [State: int] = {};
        \\fn start() {}
        \\fn check() bool { return s == State.run and t == State.idle and seen[State.idle] == 1 and seen[State.run] == 2; }
    );
    try testing.expectEqualStrings("State", report.changed.?);
    try testing.expect((try vm.callName(m, "check", &.{})).asBool());
    try testing.expectEqual(@as(usize, 1), warnings(vm));
    try testing.expect(std.mem.indexOf(u8, vm.diagnostics.items.items[0].message, "now holds `.run`") != null);
}

test "a changed signature stops tasks in old code, and old lambdas refuse to run" {
    const vm = try Vm.create(testing.allocator, .{});
    defer vm.destroy();
    const before =
        \\var ticks = 0;
        \\fn step(n: int) { ticks += n; }
        \\fn looping() { while (true) { await wait(1.0); step(1); } }
        \\var later = |x: int| step(x);
        \\const t = looping();
        \\fn count() int { return ticks; }
    ;
    const m = try vm.compile("t.flux", before);
    try vm.run(m);
    try vm.update(1.0);
    try testing.expectEqual(@as(i64, 1), try int(vm, m, "count"));
    const report = try vm.reload(m,
        \\var ticks = 0;
        \\fn step(n: int, times: int = 1) { ticks += n * times; }
        \\fn looping() { while (true) { await wait(1.0); step(1); } }
        \\var later = |x: int| step(x);
        \\const t = looping();
        \\fn count() int { return ticks; }
    );
    try testing.expectEqualStrings("step", report.changed.?);
    try testing.expectEqual(@as(u32, 1), report.stopped);
    try vm.update(3.0);
    try testing.expectEqual(@as(i64, 1), try int(vm, m, "count"));
    try testing.expectError(error.Panic, vm.call(vm.get(m, "later").?, &.{.int(1)}));
    try testing.expect(std.mem.indexOf(u8, vm.panic.?.message, "from before a reload") != null);
    vm.clearPanic();
}

test "a reload that keeps every shape lets running tasks go on" {
    const vm = try Vm.create(testing.allocator, .{});
    defer vm.destroy();
    const m = try vm.compile("k.flux",
        \\var ticks = 0;
        \\fn step() { ticks += 1; }
        \\fn looping() { while (true) { await wait(1.0); step(); } }
        \\const t = looping();
        \\fn count() int { return ticks; }
    );
    try vm.run(m);
    try vm.update(1.0);
    const report = try vm.reload(m,
        \\var ticks = 0;
        \\fn step() { ticks += 10; }
        \\fn looping() { while (true) { await wait(1.0); step(); } }
        \\const t = looping();
        \\fn count() int { return ticks; }
        \\fn extra() int { return 7; }
    );
    try testing.expect(report.changed == null);
    try testing.expectEqual(@as(u32, 0), report.stopped);
    try vm.update(1.0);
    try testing.expectEqual(@as(i64, 11), try int(vm, m, "count"));
    try testing.expectEqual(@as(i64, 7), try int(vm, m, "extra"));
}

test "modules importing the reloaded one compile again, or the reload is refused" {
    var files: Files = .{ .list = &.{.{ "lib.flux", "fn value() int { return 1; }" }} };
    const vm = try Vm.create(testing.allocator, .{ .loader = files.loader() });
    defer vm.destroy();
    const main = try vm.compile("main.flux",
        \\const lib = @import("lib.flux");
        \\fn get() int { return lib.value() + 10; }
    );
    try vm.run(main);
    try testing.expectEqual(@as(i64, 11), try int(vm, main, "get"));
    const lib = vm.moduleNamed("lib.flux").?;
    const report = try vm.reload(lib, "fn value() int { return 2; }");
    try testing.expectEqual(@as(u32, 2), report.modules);
    try testing.expectEqual(@as(i64, 12), try int(vm, main, "get"));
    try testing.expectError(error.CompileFailed, vm.reload(lib, "fn value() string { return \"two\"; }"));
    try testing.expectEqualStrings("main.flux", vm.sources.name(vm.diagnostics.items.items[0].labels.items[0].at.file));
    try testing.expectEqual(@as(i64, 12), try int(vm, main, "get"));
}

test "a reload waits for the host's turn" {
    const vm = try Vm.create(testing.allocator, .{});
    defer vm.destroy();
    const m = try vm.compile("b.flux", "fn f() int { return 1; }");
    try vm.run(m);
    vm.host = m;
    try vm.define("reload_now", struct {
        fn f(v: *Vm, _: []Value) Vm.Error!Value {
            const module: *object.Module = @ptrCast(@alignCast(v.host.?));
            _ = v.reload(module, "fn f() int { return 2; }") catch |err| return .boolean(err == error.Busy);
            return .false;
        }
    }.f, 0, 0);
    const probe = try vm.compile("c.flux", "fn busy() bool { return reload_now(); }");
    try vm.run(probe);
    try testing.expect((try vm.callName(probe, "busy", &.{})).asBool());
    try testing.expectEqual(@as(i64, 1), try int(vm, m, "f"));
}

test "reloading again moves already moved instances, under a collector that never rests" {
    var files: Files = .{ .list = &.{.{ "base.flux", "struct Unit { var hp: int = 5; }" }} };
    const vm = try Vm.create(testing.allocator, .{ .loader = files.loader(), .gc = .{ .stress = true, .verify = true } });
    defer vm.destroy();
    const game = try vm.compile("game.flux",
        \\const base = @import("base.flux");
        \\struct Boss extends base.Unit { var rage: int = 1; }
        \\var units: [base.Unit] = [];
        \\var bosses: [Boss] = [];
        \\fn start() { for (0..10) |i| { bosses.push(Boss{ .rage = i }); units.push(base.Unit{ .hp = i }); } }
        \\fn total() int { var t = 0; for (units) |u| t += u.hp; for (bosses) |x| t += x.hp; return t; }
        \\fn rage() int { var t = 0; for (bosses) |x| t += x.rage; return t; }
    );
    try vm.run(game);
    _ = try vm.callName(game, "start", &.{});
    const hp = try int(vm, game, "total");
    const rage = try int(vm, game, "rage");
    const base = vm.moduleNamed("base.flux").?;
    const first = try vm.reload(base, "struct Unit { var name: string = \"unit\"; var hp: int = 5; }");
    try testing.expectEqual(@as(u32, 2), first.modules);
    try testing.expectEqual(@as(u32, 20), first.instances);
    try testing.expectEqual(hp, try int(vm, game, "total"));
    try testing.expectEqual(rage, try int(vm, game, "rage"));
    const second = try vm.reload(base, "struct Unit { var hp: int = 5; var speed: float = 1.5; var name: string = \"unit\"; }");
    try testing.expectEqual(@as(u32, 20), second.instances);
    try testing.expectEqual(hp, try int(vm, game, "total"));
    try testing.expectEqual(rage, try int(vm, game, "rage"));
}

test "signals keep their connections; methods connected go on, old lambdas are let go" {
    const vm = try Vm.create(testing.allocator, .{});
    defer vm.destroy();
    const m = try vm.compile("s.flux",
        \\struct Door {
        \\    signal opened(by: string);
        \\    var count: int = 0;
        \\    fn on_open(self, by: string) { self.count += 1; }
        \\}
        \\const door = Door{};
        \\var lambda_calls = 0;
        \\fn start() {
        \\    door.opened.connect(door.on_open);
        \\    door.opened.connect(|by| { lambda_calls += 1; });
        \\}
        \\fn open() { door.opened.emit("me"); }
        \\fn count() int { return door.count; }
    );
    try vm.run(m);
    _ = try vm.callName(m, "start", &.{});
    _ = try vm.callName(m, "open", &.{});
    try testing.expectEqual(@as(i64, 1), try int(vm, m, "count"));
    _ = try vm.reload(m,
        \\struct Door {
        \\    signal opened(by: string);
        \\    var count: int = 0;
        \\    var last: string = "";
        \\    fn on_open(self, by: string) { self.count += 10; self.last = by; }
        \\}
        \\const door = Door{};
        \\var lambda_calls = 0;
        \\fn start() {}
        \\fn open() { door.opened.emit("me"); }
        \\fn count() int { return door.count; }
    );
    try testing.expectEqual(@as(usize, 1), warnings(vm));
    try testing.expect(std.mem.indexOf(u8, vm.diagnostics.items.items[0].message, "connection is dropped") != null);
    _ = try vm.callName(m, "open", &.{});
    try testing.expectEqual(@as(i64, 11), try int(vm, m, "count"));
}
