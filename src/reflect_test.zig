// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const testing = std.testing;

const Vm = @import("vm/Vm.zig");
const Value = @import("vm/value.zig").Value;
const object = @import("vm/object.zig");

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

test "a handle the script owns is freed with it" {
    const vm = try Vm.create(testing.allocator, .{});
    defer vm.destroy();
    const h = try vm.newHandle(Player);
    try testing.expectEqual(@as(i32, 10), h.as(object.Handle).value.as(Player).?.hp);
    try @import("vm/gc.zig").collect(vm);
}
