// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const testing = std.testing;

const Vm = @import("vm/Vm.zig");
const Value = @import("vm/value.zig").Value;
const object = @import("vm/object.zig");
const reflect = @import("fluxion_reflect");

const Vec2 = struct { x: f32 = 0, y: f32 = 0 };
const Mode = enum { idle, run, dead };
const Stats = struct { level: u8 = 1, xp: u32 = 0 };

const Player = struct {
    name: []const u8 = "ada",
    hp: i32 = 10,
    speed: f64 = 1.5,
    pos: Vec2 = .{},
    mode: Mode = .idle,
    target: ?u32 = null,
    stats: Stats = .{},

    pub const reflect_methods = .{ .heal, .moveBy, .ratio };

    pub fn heal(self: *Player, amount: i32) i32 {
        self.hp += amount;
        return self.hp;
    }

    pub fn moveBy(self: *Player, delta: Vec2) void {
        self.pos.x += delta.x;
        self.pos.y += delta.y;
    }

    pub fn ratio(self: *Player, over: i32) !f64 {
        if (over == 0) return error.DivideByZero;
        return @as(f64, @floatFromInt(self.hp)) / @as(f64, @floatFromInt(over));
    }
};

const script =
    \\fn update(p) {
    \\    print(p.name, p.hp, p.speed, p.pos, p.mode, p.target, p.stats.level);
    \\    p.hp -= 3;
    \\    p.pos = vec2(1, 2);
    \\    p.pos.x += 10;
    \\    p.mode = "run";
    \\    p.target = 7;
    \\    p.stats.xp = 250;
    \\    print(p.heal(5), p.ratio(4), p.ratio(0));
    \\    p.moveBy(vec2(0.5, 0.5));
    \\}
    \\fn bad(p) { p.hp = "full"; }
    \\fn typo(p) { return p.hpp; }
;

fn load(vm: *Vm) !*object.Module {
    return vm.load("test.flux", script) catch |err| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        try vm.writeDiagnostics(&out.writer, .{});
        try vm.writePanic(&out.writer, .{});
        std.debug.print("{s}\n", .{out.written()});
        return err;
    };
}

test "a Zig struct read, written and called from a script" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const vm = try Vm.create(testing.allocator, .{ .out = &out.writer });
    defer vm.destroy();
    const m = try load(vm);
    var player: Player = .{};
    const h = try vm.handle(&player);
    _ = try vm.callName(m, "update", &.{h});
    try testing.expectEqualStrings(
        \\ada 10 1.5 (0.0, 0.0) idle null 1
        \\12 3.0 error.DivideByZero
        \\
    , out.written());
    try testing.expectEqual(@as(i32, 12), player.hp);
    try testing.expectEqual(Vec2{ .x = 11.5, .y = 2.5 }, player.pos);
    try testing.expectEqual(Mode.run, player.mode);
    try testing.expectEqual(@as(?u32, 7), player.target);
    try testing.expectEqual(@as(u32, 250), player.stats.xp);

    try testing.expectError(error.Panic, vm.callName(m, "bad", &.{h}));
    try testing.expectEqualStrings("a i32 cannot be set from string", vm.panic.?.message);
    vm.clearPanic();
    try testing.expectError(error.Panic, vm.callName(m, "typo", &.{h}));
    try testing.expectEqualStrings("reflect_test.Player has no field `hpp`; did you mean `hp`?", vm.panic.?.message);
}

/// A tagged union whose arms mostly hold nothing: a window's fullscreen.
const Fill = union(enum) { windowed, borderless, exclusive: u32 };

const Screen = struct {
    fill: Fill = .windowed,

    pub const reflect_methods = .{ .setFill, .filled };

    pub fn setFill(self: *Screen, fill: Fill) void {
        self.fill = fill;
    }

    pub fn filled(self: *const Screen) Fill {
        return self.fill;
    }
};

test "a tagged union's empty arm goes and comes by its name" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const vm = try Vm.create(testing.allocator, .{ .out = &out.writer });
    defer vm.destroy();
    const m = try vm.load("fill.flux",
        \\fn go(s) {
        \\    print(s.fill, s.filled());
        \\    s.setFill("borderless");
        \\    print(s.filled());
        \\    s.fill = "windowed";
        \\}
        \\fn full(s) { s.setFill("exclusive"); }
        \\fn wrong(s) { s.setFill("sideways"); }
    );
    var screen: Screen = .{};
    const h = try vm.handle(&screen);
    _ = try vm.callName(m, "go", &.{h});
    try testing.expectEqualStrings("windowed windowed\nborderless\n", out.written());
    try testing.expectEqual(Fill.windowed, screen.fill);

    try testing.expectError(error.Panic, vm.callName(m, "full", &.{h}));
    try testing.expect(std.mem.indexOf(u8, vm.panic.?.message, "exclusive holds a u32") != null);
    vm.clearPanic();
    try testing.expectError(error.Panic, vm.callName(m, "wrong", &.{h}));
    try testing.expect(std.mem.indexOf(u8, vm.panic.?.message, "has no arm \"sideways\"") != null);
}

test "a handle the script owns is freed with it" {
    const vm = try Vm.create(testing.allocator, .{});
    defer vm.destroy();
    const h = try vm.newHandle(Player);
    try testing.expectEqual(@as(i32, 10), h.as(object.Handle).value.as(Player).?.hp);
    try @import("vm/gc.zig").collect(vm);
}

/// What an engine's entity looks like to a script: it finds things by name,
/// so it needs the VM to make a handle, and hands the handle back as it is.
const Finder = struct {
    calls: i32 = 0,

    pub const reflect_methods = .{ .find, .count };

    pub fn find(self: *Finder, vm: *Vm, name: []const u8) Vm.Error!Value {
        self.calls += 1;
        if (std.mem.eql(u8, name, "me")) return vm.handle(self);
        if (std.mem.eql(u8, name, "bad")) return vm.fail("nothing called `{s}` can be found", .{name});
        return .null;
    }

    pub fn count(self: *Finder, vm: *Vm) Value {
        _ = vm;
        return .int(self.calls);
    }
};

const Shield = struct { strength: i32 = 3 };

const Health = struct {
    value: i32 = 10,
    max: i32 = 10,
    shield: Shield = .{},

    pub const reflect_methods = .{.heal};

    pub fn heal(self: *Health, amount: i32) i32 {
        self.value = @min(self.max, self.value + amount);
        return self.value;
    }
};

/// Rows that move, as an ECS's do: a component changes place when its
/// storage does, and what it leaves behind reads as garbage.
const Rows = struct {
    items: [4]Health = @splat(.{}),
    slot_of: [2]?usize = .{ 0, null },

    fn resolve(context: ?*anyopaque, key: u64, t: *const reflect.Type) ?reflect.Value {
        const self: *Rows = @ptrCast(@alignCast(context.?));
        if (!t.is(Health) or key >= self.slot_of.len) return null;
        const slot = self.slot_of[key] orelse return null;
        return .of(&self.items[slot]);
    }

    fn move(self: *Rows, key: usize, to: usize) void {
        const from = self.slot_of[key].?;
        self.items[to] = self.items[from];
        self.items[from] = .{ .value = -999, .max = -999, .shield = .{ .strength = -999 } };
        self.slot_of[key] = to;
    }
};

test "a live handle, and what is reached through it, follow a value that moves" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const vm = try Vm.create(testing.allocator, .{ .out = &out.writer, .gc = .{ .stress = true, .verify = true } });
    defer vm.destroy();
    const m = try vm.load("rows.flux",
        \\var hp: any = null;
        \\var shield: any = null;
        \\fn keep(h) { hp = h; shield = h.shield; }
        \\fn hit() { hp.value -= 3; }
        \\fn read() { return hp.value; }
        \\fn strength() { return shield.strength; }
        \\fn heal() { return hp.heal(1); }
        \\fn show() { print(hp); }
    );
    var rows: Rows = .{};
    const resolver: object.Resolver = .{ .context = &rows, .resolve = Rows.resolve, .why = "its entity was despawned, or the component taken off" };
    const h = try vm.liveHandle(&resolver, 0, reflect.typeOf(Health));
    _ = try vm.callName(m, "keep", &.{h});
    _ = try vm.callName(m, "hit", &.{});
    try testing.expectEqual(@as(i32, 7), rows.items[0].value);

    // The row moves: what the script kept goes with it, nested fields too.
    rows.move(0, 2);
    try testing.expectEqual(@as(i64, 7), (try vm.callName(m, "read", &.{})).asInt());
    _ = try vm.callName(m, "hit", &.{});
    try testing.expectEqual(@as(i32, 4), rows.items[2].value);
    try testing.expectEqual(@as(i32, -999), rows.items[0].value);
    try testing.expectEqual(@as(i64, 3), (try vm.callName(m, "strength", &.{})).asInt());
    try testing.expectEqual(@as(i64, 5), (try vm.callName(m, "heal", &.{})).asInt());
    try testing.expectEqual(@as(i32, 5), rows.items[2].value);

    // The host reads what the handles stand for now, not where they were.
    try testing.expectEqual(@as(i32, 5), vm.reflectOf(h).?.as(Health).?.value);
    try testing.expectEqual(&rows.items[2].shield, vm.reflectOf(vm.get(m, "shield").?).?.as(Shield).?);
    try testing.expectEqual(@as(?reflect.Value, null), vm.reflectOf(.int(1)));

    // Gone: a panic that says so, never a read of what was left behind.
    rows.slot_of[0] = null;
    try testing.expect(vm.reflectOf(h) == null);
    try testing.expectError(error.Panic, vm.callName(m, "read", &.{}));
    try testing.expectEqualStrings("this reflect_test.Health is gone: its entity was despawned, or the component taken off", vm.panic.?.message);
    vm.clearPanic();
    try testing.expectError(error.Panic, vm.callName(m, "strength", &.{}));
    try testing.expectEqualStrings("this reflect_test.Shield is gone: its entity was despawned, or the component taken off", vm.panic.?.message);
    vm.clearPanic();
    _ = try vm.callName(m, "show", &.{});
    try testing.expectEqualStrings("<reflect_test.Health, gone>\n", out.written());
}

/// An engine signal's argument: no defaults, so it cannot be made fresh.
const Hit = struct { damage: f32, at: Vec2, mode: Mode };

test "a host's value handed to a script as the script's own" {
    const vm = try Vm.create(testing.allocator, .{ .gc = .{ .stress = true, .verify = true } });
    defer vm.destroy();
    const m = try vm.load("hits.flux",
        \\fn damage(h) { return h.damage; }
        \\fn at(h) { return h.at; }
        \\fn mode(h) { return h.mode; }
        \\fn total(xs) {
        \\    var t = 0;
        \\    for (xs) |x| t += x;
        \\    return t;
        \\}
    );
    var n: i32 = 7;
    try testing.expectEqual(@as(i64, 7), (try vm.valueOf(.of(&n))).asInt());
    var mode: Mode = .run;
    try testing.expectEqualStrings("run", (try vm.valueOf(.of(&mode))).as(object.String).bytes());
    var name: []const u8 = "ada";
    try testing.expectEqualStrings("ada", (try vm.valueOf(.of(&name))).as(object.String).bytes());
    var maybe: ?i32 = null;
    try testing.expect((try vm.valueOf(.of(&maybe))).tag == .null);
    const where: Vec2 = .{ .x = 1, .y = 2 };
    try testing.expectEqual([2]f32{ 1, 2 }, (try vm.valueOf(.of(&where))).asVec2());

    // A struct is copied: the host's memory can go right after.
    const hit = try testing.allocator.create(Hit);
    hit.* = .{ .damage = 12.5, .at = .{ .x = 3, .y = 4 }, .mode = .dead };
    const h = try vm.valueOf(.of(hit));
    try vm.hold(h);
    defer vm.release(h);
    hit.* = .{ .damage = -1, .at = .{ .x = -1, .y = -1 }, .mode = .idle };
    testing.allocator.destroy(hit);
    try testing.expectEqual(@as(f64, 12.5), (try vm.callName(m, "damage", &.{h})).asFloat());
    try testing.expectEqual([2]f32{ 3, 4 }, (try vm.callName(m, "at", &.{h})).asVec2());
    try testing.expectEqualStrings("dead", (try vm.callName(m, "mode", &.{h})).as(object.String).bytes());

    // A slice is a list of its elements.
    const numbers = [_]i32{ 1, 2, 3 };
    const slice: []const i32 = &numbers;
    const list = try vm.valueOf(.of(&slice));
    try vm.hold(list);
    defer vm.release(list);
    try testing.expectEqual(@as(i64, 6), (try vm.callName(m, "total", &.{list})).asInt());
}

test "a reflected method is given the calling VM, and hands back a value as it is" {
    const vm = try Vm.create(testing.allocator, .{ .gc = .{ .stress = true, .verify = true } });
    defer vm.destroy();
    const m = try vm.load("finder.flux",
        \\fn mine(f) { return f.find("me").calls; }
        \\fn none(f) { return f.find("nobody") == null; }
        \\fn calls(f) { return f.count(); }
        \\fn bad(f) { return f.find("bad"); }
        \\fn wrong(f) { return f.find(); }
    );
    var finder: Finder = .{};
    const h = try vm.handle(&finder);
    try vm.hold(h);
    defer vm.release(h);
    try testing.expectEqual(@as(i64, 1), (try vm.callName(m, "mine", &.{h})).asInt());
    try testing.expect((try vm.callName(m, "none", &.{h})).asBool());
    try testing.expectEqual(@as(i64, 2), (try vm.callName(m, "calls", &.{h})).asInt());

    // A panic the method raises stops the script; the VM is not an argument.
    try testing.expectError(error.Panic, vm.callName(m, "bad", &.{h}));
    try testing.expectEqualStrings("nothing called `bad` can be found", vm.panic.?.message);
    vm.clearPanic();
    try testing.expectError(error.Panic, vm.callName(m, "wrong", &.{h}));
    try testing.expectEqualStrings("`find` takes 1 argument, and was given 0", vm.panic.?.message);
    vm.clearPanic();
}

/// Results a method hands back: by value, in the call's own storage, which
/// a script's value must not point into; or by pointer, into the host's.
const Walker = struct {
    stats: Stats = .{ .level = 3, .xp = 40 },
    steps: [3]i32 = .{ 1, 2, 3 },

    pub const reflect_methods = .{ .now, .later, .maybe, .kept, .walked };

    pub fn now(self: *Walker) Stats {
        return self.stats;
    }

    pub fn later(self: *Walker, xp: u32) error{NoXp}!Stats {
        if (xp == 0) return error.NoXp;
        return .{ .level = self.stats.level + 1, .xp = xp };
    }

    pub fn maybe(self: *Walker, has: bool) ?Stats {
        _ = self;
        return if (has) .{ .level = 9, .xp = 900 } else null;
    }

    pub fn kept(self: *Walker, has: bool) ?*Stats {
        return if (has) &self.stats else null;
    }

    pub fn walked(self: *Walker) []const i32 {
        return &self.steps;
    }
};

test "what a method hands back outlives the call" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const vm = try Vm.create(testing.allocator, .{ .out = &out.writer, .gc = .{ .stress = true, .verify = true } });
    defer vm.destroy();
    const m = try vm.load("walker.flux",
        \\fn results(w) {
        \\    var a = w.now();
        \\    var b = w.later(99);
        \\    var c = w.maybe(true);
        \\    print(a.level, a.xp, b.level, b.xp, c.level, c.xp, w.maybe(false));
        \\    a.xp = 1;
        \\    return w.now().xp;
        \\}
        \\fn kept(w) {
        \\    w.kept(true).xp += 2;
        \\    return w.kept(false);
        \\}
        \\var steps: any = null;
        \\fn walked(w) { steps = w.walked(); }
        \\fn total() {
        \\    var t = 0;
        \\    for (steps) |x| t += x;
        \\    return t;
        \\}
    );
    var walker: Walker = .{};
    const h = try vm.handle(&walker);
    try vm.hold(h);
    defer vm.release(h);

    // A struct handed back by value is the script's own copy, which the
    // calls after it do not write over.
    try testing.expectEqual(@as(i64, 40), (try vm.callName(m, "results", &.{h})).asInt());
    try testing.expectEqualStrings("3 40 4 99 9 900 null\n", out.written());

    // One handed back by pointer is the host's, written where it lives.
    try testing.expect((try vm.callName(m, "kept", &.{h})).tag == .null);
    try testing.expectEqual(@as(u32, 42), walker.stats.xp);

    // A slice is a list of what it held when the method returned.
    _ = try vm.callName(m, "walked", &.{h});
    walker.steps[0] = 100;
    try testing.expectEqual(@as(i64, 6), (try vm.callName(m, "total", &.{})).asInt());
}

/// An id a host knows its things by, which its scripts see as a number:
/// how a script sees a type is the host's to say, whatever the type is made
/// of.
const Id = struct {
    index: u32,

    fn toScript(vm: *Vm, value: reflect.Value) Vm.Error!Value {
        _ = vm;
        return .int(value.asConst(Id).?.index);
    }

    fn fromScript(vm: *Vm, into: reflect.Value, value: Value) Vm.Error!void {
        if (value.tag != .int) return vm.fail("an id is a number", .{});
        const id = into.as(Id) orelse return vm.fail("this id can only be read", .{});
        id.index = @intCast(value.asInt());
    }
};

const Crowd = struct {
    leader: Id = .{ .index = 1 },
    second: ?Id = null,
    ids: [2]Id = .{ .{ .index = 5 }, .{ .index = 6 } },
    followed: u32 = 0,

    pub const reflect_methods = .{ .follow, .nearest, .nobody, .all };

    pub fn follow(self: *Crowd, who: Id) void {
        self.followed = who.index;
    }

    pub fn nearest(self: *Crowd) error{Alone}!Id {
        return self.ids[1];
    }

    pub fn nobody(self: *Crowd) ?Id {
        _ = self;
        return null;
    }

    pub fn all(self: *Crowd) []const Id {
        return &self.ids;
    }
};

test "a host's own type is seen as the host says" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const vm = try Vm.create(testing.allocator, .{
        .out = &out.writer,
        .gc = .{ .stress = true, .verify = true },
        .host_types = &.{.{ .type = reflect.typeOf(Id), .to_script = Id.toScript, .from_script = Id.fromScript }},
    });
    defer vm.destroy();
    const m = try vm.load("crowd.flux",
        \\fn read(c) { print(c.leader, c.nearest(), c.nobody(), c.all(), c.ids[1], c.second); }
        \\fn write(c) {
        \\    c.leader = 4;
        \\    c.second = 9;
        \\    c.follow(c.leader + 3);
        \\}
        \\fn word(c) { c.follow("seven"); }
        \\fn handle(c) { c.follow(c); }
        \\fn float(c) { c.leader = 1.5; }
    );
    var crowd: Crowd = .{};
    const h = try vm.handle(&crowd);
    try vm.hold(h);
    defer vm.release(h);

    // Read through a handle, handed back by a method, in a list, or given
    // to the host's own `valueOf`: a number each time.
    _ = try vm.callName(m, "read", &.{h});
    try testing.expectEqualStrings("1 6 null [5, 6] 6 null\n", out.written());
    var id: Id = .{ .index = 8 };
    try testing.expectEqual(@as(i64, 8), (try vm.valueOf(.of(&id))).asInt());

    // Written into a field, an optional or an argument.
    _ = try vm.callName(m, "write", &.{h});
    try testing.expectEqual(@as(u32, 4), crowd.leader.index);
    try testing.expectEqual(@as(u32, 9), crowd.second.?.index);
    try testing.expectEqual(@as(u32, 7), crowd.followed);

    // Anything else is the host's to refuse, a handle too: it is not taken
    // for the struct it points at.
    for ([_][]const u8{ "word", "handle", "float" }) |name| {
        try testing.expectError(error.Panic, vm.callName(m, name, &.{h}));
        try testing.expectEqualStrings("an id is a number", vm.panic.?.message);
        vm.clearPanic();
    }
    try testing.expectEqual(@as(u32, 7), crowd.followed);
    try testing.expectEqual(@as(u32, 4), crowd.leader.index);
}
