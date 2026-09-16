// SPDX-License-Identifier: BSD-2-Clause

//! A game embedding Flux, in one file: a module of its own functions for
//! scripts to import, its player seen by scripts through reflection, the
//! script's `update` called every frame, the script reloaded while the game
//! runs, and a script that never ends stopped without stopping the game.
//!
//!     zig build example-embed

const std = @import("std");
const flux = @import("fluxion_script");

const Vec2 = struct { x: f32 = 0, y: f32 = 0 };

const Player = struct {
    name: []const u8 = "Ada",
    hp: i32 = 100,
    pos: Vec2 = .{},

    /// Which methods scripts may call; fields are all visible.
    pub const reflect_methods = .{.heal};

    pub fn heal(self: *Player, amount: i32) i32 {
        self.hp = @min(self.hp + amount, 100);
        return self.hp;
    }
};

/// A function of the game's, for scripts: its Zig signature says what it
/// takes and gives, and a Zig error reaches the script as `error.NoSides`.
fn roll(sides: i64, turn: i64) !i64 {
    if (sides < 1) return error.NoSides;
    return @mod(turn * 7 + 3, sides) + 1;
}

const first_version =
    \\const game = @import("game");
    \\
    \\var frames = 0;
    \\
    \\fn update(player, dt: float) {
    \\    frames += 1;
    \\    player.pos.x += 60 * dt;
    \\    if (frames % 30 == 0) {
    \\        player.hp -= game.rol(12, frames) catch 0;
    \\        print(f"frame {frames}: {player.name} at x {player.pos.x:.1}, {player.hp} hp");
    \\    }
    \\}
    \\
    \\fn runaway() {
    \\    var n = 0;
    \\    while (true) n += 1;
    \\}
;

/// The same file after an edit: the player heals when low, and a new
/// variable counts it. `frames` is declared as before, so it keeps its value.
const second_version =
    \\const game = @import("game");
    \\
    \\var frames = 0;
    \\var heals = 0;
    \\
    \\fn update(player, dt: float) {
    \\    frames += 1;
    \\    player.pos.x += 60 * dt;
    \\    if (frames % 30 == 0) {
    \\        player.hp -= game.roll(12, frames) catch 0;
    \\        if (player.hp < 90) {
    \\            heals += 1;
    \\            print(f"frame {frames}: healed to {player.heal(15)} ({heals} so far)");
    \\        }
    \\    }
    \\}
    \\
    \\fn runaway() {
    \\    var n = 0;
    \\    while (true) n += 1;
    \\}
;

pub fn main(init: std.process.Init) !u8 {
    var out_buf: [4096]u8 = undefined;
    // Streaming, so output sent to a file lands after what is there.
    var out_file: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &out_buf);
    const out = &out_file.interface;
    defer out.flush() catch {};

    const vm = try flux.Vm.create(init.gpa, .{ .out = out });
    defer vm.destroy();

    // `@import("game")` in a script gets these: functions converted by
    // their signatures, and values.
    _ = try vm.defineModule("game", .{ .roll = roll, .version = 3 });

    // The player itself, not a copy: scripts read and write its fields and
    // call its methods through fluxion-reflect.
    var player: Player = .{};
    const handle = try vm.handle(&player);
    try vm.hold(handle);
    defer vm.release(handle);

    // The first version has a typo, as a first version will: the compiler
    // says where, and what was meant.
    if (vm.load("logic.flux", first_version)) |_| {
        try out.writeAll("the first version loaded, which it should not\n");
    } else |_| {
        try out.writeAll("the first version does not compile:\n");
        try vm.writeDiagnostics(out, .{});
    }

    const fixed = try std.mem.replaceOwned(u8, init.gpa, first_version, "game.rol(", "game.roll(");
    defer init.gpa.free(fixed);
    const module = vm.load("logic.flux", fixed) catch {
        try vm.writeDiagnostics(out, .{});
        return 1;
    };
    const update = vm.get(module, "update").?;

    for (0..90) |_| try frame(vm, update, handle, out);

    // An editor saved the file: the new code goes in, the game goes on.
    const report = vm.reload(module, second_version) catch {
        try vm.writeDiagnostics(out, .{});
        return 1;
    };
    try out.print("reloaded {d} module; frames kept at {d}\n", .{ report.modules, (vm.get(module, "frames").?).asInt() });
    for (0..90) |_| try frame(vm, update, handle, out);

    // A script that never ends meets the budget and stops with a panic,
    // stack trace and all; the host goes on.
    vm.setBudget(1_000_000);
    if (vm.callName(module, "runaway", &.{})) |_| {} else |_| {
        try out.writeAll("runaway stopped:\n");
        try vm.writePanic(out, .{});
        vm.clearPanic();
    }
    vm.setBudget(null);

    try out.print("{s} ends at x {d:.1} with {d} hp\n", .{ player.name, player.pos.x, player.hp });
    return 0;
}

fn frame(vm: *flux.Vm, update: flux.Value, handle: flux.Value, out: *std.Io.Writer) !void {
    _ = vm.call(update, &.{ handle, .float(1.0 / 60.0) }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.Panic => {
            try vm.writePanic(out, .{});
            vm.clearPanic();
        },
    };
    try vm.update(1.0 / 60.0);
}
