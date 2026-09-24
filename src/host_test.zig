// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const testing = std.testing;

const Vm = @import("vm/Vm.zig");
const Value = @import("vm/value.zig").Value;
const Tag = @import("vm/value.zig").Tag;
const object = @import("vm/object.zig");
const api = @import("api.zig");

const game =
    \\struct Actor {
    \\    /// Hit points.
    \\    var hp: int = 10;
    \\    var tags: [string] = ["actor"];
    \\    /// When the hit points run out.
    \\    signal died(by: string);
    \\
    \\    /// Called when it enters the world.
    \\    fn ready(self) { self.tags.append("ready"); }
    \\    fn hurt(self, n: int) {
    \\        self.hp -= n;
    \\        if (self.hp <= 0) self.died.emit("hurt");
    \\    }
    \\}
    \\
    \\struct Player extends Actor {
    \\    var score: int = 0;
    \\    signal scored(points: int, combo: int);
    \\
    \\    fn update(self, dt: float) { self.score += 1; }
    \\    /// Twice as hard as an actor's.
    \\    fn hurt(self, n: int) {
    \\        self.hp -= n * 2;
    \\        if (self.hp <= 0) self.died.emit("player");
    \\    }
    \\    fn add(self, points: int, combo: int) int {
    \\        self.score += points * combo;
    \\        self.scored.emit(points, combo);
    \\        return self.score;
    \\    }
    \\}
    \\
    \\var heard = "";
    \\fn listen(by: string) { heard = by; }
;

fn load(vm: *Vm) !*object.Module {
    return vm.load("game.flux", game) catch |err| {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try vm.writeDiagnostics(&buf.writer, .{});
        try vm.writePanic(&buf.writer, .{});
        std.debug.print("{s}\n", .{buf.written()});
        return err;
    };
}

fn field(v: Value, name: []const u8) Value {
    const inst = v.as(object.Instance);
    for (inst.class.fields, inst.fields()) |f, x| if (std.mem.eql(u8, f.name.bytes(), name)) return x;
    unreachable;
}

test "a task started for an owner the host holds waits while it is held, and so do the tasks it starts" {
    const vm = try Vm.create(testing.allocator, .{ .gc = .{ .stress = true, .verify = true } });
    defer vm.destroy();
    const m = try vm.load("bells.flux",
        \\var rang = 0;
        \\fn bell(by: int) { await wait(1.0); rang += by; }
        \\fn chime() { bell(100); await wait(0.0); }
    );
    const Paused = struct {
        fn held(_: ?*anyopaque, owner: u64) bool {
            return owner == 7;
        }
    };
    const paused: Vm.Held = .{ .held = Paused.held };

    const before = vm.setTaskOwner(7);
    _ = try vm.callName(m, "bell", &.{.int(1)});
    // Started by a task of the held owner: held along with it.
    _ = try vm.callName(m, "chime", &.{});
    try testing.expectEqual(@as(u64, 7), vm.setTaskOwner(before));
    _ = try vm.callName(m, "bell", &.{.int(10)});

    try vm.updateHolding(0.6, paused);
    try vm.updateHolding(0.6, paused);
    // The one nobody holds rang; the held ones have their whole second left.
    try testing.expectEqual(@as(i64, 10), vm.get(m, "rang").?.asInt());

    try vm.update(0.6);
    try testing.expectEqual(@as(i64, 10), vm.get(m, "rang").?.asInt());
    try vm.update(0.5);
    try testing.expectEqual(@as(i64, 111), vm.get(m, "rang").?.asInt());
}

test "a host makes an instance with its defaults, and calls what it declares" {
    const vm = try Vm.create(testing.allocator, .{ .gc = .{ .stress = true, .verify = true } });
    defer vm.destroy();
    const m = try load(vm);
    const player_class = vm.get(m, "Player").?;

    const player = try vm.instantiate(player_class, &.{});
    try vm.hold(player);
    defer vm.release(player);
    try testing.expectEqual(@as(i64, 10), field(player, "hp").asInt());
    try testing.expectEqual(player_class.as(object.Class), api.classOf(player).?.as(object.Class));
    // A list default is the instance's own, and its signals are made.
    try testing.expectEqual(Tag.list, field(player, "tags").tag);
    try testing.expectEqual(Tag.signal, field(player, "scored").tag);
    try testing.expectEqual(Tag.signal, field(player, "died").tag);

    // What an engine asks each frame, answered once and kept.
    try testing.expect(vm.hasMethod(player_class, "ready"));
    try testing.expect(vm.hasMethod(player_class, "update"));
    try testing.expect(!vm.hasMethod(player_class, "physics"));
    try testing.expect(!vm.hasMethod(player_class, "never_interned_anywhere"));
    const update = vm.methodNamed(player_class, "update").?;
    _ = try vm.call(update, &.{ player, .float(0.016) });
    _ = try vm.call(update, &.{ player, .float(0.016) });
    try testing.expectEqual(@as(i64, 2), field(player, "score").asInt());

    // By name, the override and not the method it overrides.
    _ = try vm.callMethod(player, "hurt", &.{.int(3)});
    try testing.expectEqual(@as(i64, 4), field(player, "hp").asInt());
    try testing.expectEqual(@as(i64, 2 + 5 * 2), (try vm.callMethod(player, "add", &.{ .int(5), .int(2) })).asInt());

    try testing.expectError(error.Panic, vm.callMethod(player, "fly", &.{}));
    try testing.expectEqualStrings("`Player` has no method `fly`", vm.panic.?.message);
    vm.clearPanic();
    try testing.expectError(error.Panic, vm.instantiate(.int(3), &.{}));
    vm.clearPanic();
}

test "a struct's methods and signals are listed its own first, in the order written" {
    const vm = try Vm.create(testing.allocator, .{});
    defer vm.destroy();
    const m = try load(vm);
    var buf: [8]api.Member = undefined;

    const methods = api.methodsOf(vm.get(m, "Player").?, &buf);
    try testing.expectEqual(@as(usize, 4), methods.len);
    const names = [_][]const u8{ "update", "hurt", "add", "ready" };
    const params = [_]u8{ 1, 1, 2, 0 };
    for (methods, names, params) |got, name, n| {
        try testing.expectEqualStrings(name, got.name);
        try testing.expectEqual(n, got.params);
    }
    const texts = [_][]const u8{ "dt: float", "n: int", "points: int, combo: int", "" };
    for (methods, texts) |got, text| try testing.expectEqualStrings(text, got.signature);
    try testing.expectEqualStrings("Twice as hard as an actor's.", methods[1].doc.?);
    try testing.expectEqualStrings("Called when it enters the world.", methods[3].doc.?);
    try testing.expectEqual(@as(?[]const u8, null), methods[0].doc);
    // What does not fit is left out, not written past the end.
    try testing.expectEqual(@as(usize, 2), api.methodsOf(vm.get(m, "Player").?, buf[0..2]).len);

    const signals = api.signalsOf(vm.get(m, "Player").?, &buf);
    try testing.expectEqual(@as(usize, 2), signals.len);
    try testing.expectEqualStrings("scored", signals[0].name);
    try testing.expectEqual(@as(u8, 2), signals[0].params);
    try testing.expectEqualStrings("died", signals[1].name);
    try testing.expectEqual(@as(u8, 1), signals[1].params);
    try testing.expectEqualStrings("When the hit points run out.", signals[1].doc.?);
    try testing.expectEqualStrings("points: int, combo: int", signals[0].signature);
    try testing.expectEqualStrings("by: string", signals[1].signature);

    try testing.expectEqual(@as(usize, 0), api.methodsOf(.int(1), &buf).len);
    try testing.expectEqual(@as(usize, 1), api.signalsOf(vm.get(m, "Actor").?, &buf).len);
}

const Heard = struct {
    calls: u32 = 0,
    last: i64 = 0,

    fn onScored(vm: *Vm, args: []Value) Vm.Error!Value {
        const self: *Heard = @ptrCast(@alignCast(vm.current_native.?.user.?));
        self.calls += 1;
        self.last = args[0].asInt() * args[1].asInt();
        return .null;
    }
};

test "a host connects to a script's signal, and emits one" {
    const vm = try Vm.create(testing.allocator, .{ .gc = .{ .stress = true, .verify = true } });
    defer vm.destroy();
    const m = try load(vm);
    const player = try vm.instantiate(vm.get(m, "Player").?, &.{});
    try vm.hold(player);
    defer vm.release(player);

    // The host hears the script emit.
    var heard: Heard = .{};
    const listener = try vm.native("on_scored", Heard.onScored, 2, 2, &heard);
    try vm.hold(listener);
    defer vm.release(listener);
    try vm.connectSignal(player, "scored", listener);
    _ = try vm.callMethod(player, "add", &.{ .int(3), .int(4) });
    try testing.expectEqual(@as(u32, 1), heard.calls);
    try testing.expectEqual(@as(i64, 12), heard.last);

    // And the host emits, to the script's own function and to itself.
    try vm.connectSignal(player, "died", vm.get(m, "listen").?);
    try vm.emitSignal(player, "died", &.{Value.fromObj(.string, &(try vm.newString("the host")).obj)});
    try testing.expectEqualStrings("the host", vm.get(m, "heard").?.as(object.String).bytes());
    try vm.emitSignal(player, "scored", &.{ .int(2), .int(5) });
    try testing.expectEqual(@as(i64, 10), heard.last);

    try testing.expect(try vm.disconnectSignal(player, "scored", listener));
    try testing.expect(!try vm.disconnectSignal(player, "scored", listener));
    try vm.emitSignal(player, "scored", &.{ .int(1), .int(1) });
    try testing.expectEqual(@as(u32, 2), heard.calls);

    try testing.expectError(error.Panic, vm.emitSignal(player, "scored", &.{.int(1)}));
    try testing.expectEqualStrings("signal `scored` takes 2 arguments, and was given 1", vm.panic.?.message);
    vm.clearPanic();
    try testing.expectError(error.Panic, vm.connectSignal(player, "won", listener));
    try testing.expectEqualStrings("`Player` has no signal `won`", vm.panic.?.message);
    vm.clearPanic();
    try testing.expectError(error.Panic, vm.connectSignal(player, "score", listener));
    vm.clearPanic();
}

const mover =
    \\struct Mover {
    \\    var speed: float = 2.0;
    \\    fn who(self) any { return self.entity; }
    \\}
    \\struct Fast extends Mover {
    \\    var boost: float = 1.5;
    \\}
    \\fn made() any {
    \\    const m = Mover{};
    \\    return m.entity;
    \\}
    \\fn game() any { return app; }
    \\fn show() { print(Mover{}); }
    \\fn hp(of: any) any { return of.hp; }
    \\
;

fn declareEngine(_: ?*anyopaque, vm: *Vm) anyerror!void {
    try vm.declareHostMember("entity", "The entity this script is on.");
    try vm.defineGlobal("app", .int(42), "The running game.");
}

test "the host gives every struct its members, and every module its globals" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const vm = try Vm.create(testing.allocator, .{ .out = &out.writer, .gc = .{ .stress = true, .verify = true } });
    defer vm.destroy();
    try declareEngine(null, vm);
    const m = try vm.load("mover.flux", mover);

    const class = vm.get(m, "Mover").?;
    const one = try vm.instantiate(class, &.{.{ .name = "entity", .value = .int(7) }});
    try vm.hold(one);
    defer vm.release(one);
    try testing.expectEqual(@as(i64, 7), (try vm.callMethod(one, "who", &.{})).asInt());
    const fast = try vm.instantiate(vm.get(m, "Fast").?, &.{.{ .name = "entity", .value = .int(9) }});
    try vm.hold(fast);
    defer vm.release(fast);
    try testing.expectEqual(@as(i64, 9), (try vm.callMethod(fast, "who", &.{})).asInt());
    // One a script makes has none, and printing leaves it out.
    try testing.expectEqual(Tag.null, (try vm.callName(m, "made", &.{})).tag);
    _ = try vm.callName(m, "show", &.{});
    try testing.expect(std.mem.indexOf(u8, out.written(), "speed") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "entity") == null);
    try testing.expectEqual(@as(i64, 42), (try vm.callName(m, "game", &.{})).asInt());

    try testing.expectError(error.Panic, vm.instantiate(class, &.{.{ .name = "speed", .value = .int(1) }}));
    try testing.expectEqualStrings("`speed` is not a member the host declared", vm.panic.?.message);
    vm.clearPanic();

    try testing.expectError(error.CompileFailed, vm.compile("a.flux", "struct A { fn f(self) { self.entity = 1; } }"));
    try testing.expectEqualStrings("`A.entity` cannot be assigned to", vm.diagnostics.items.items[0].message);
    try testing.expectError(error.CompileFailed, vm.compile("b.flux", "struct B { var entity: int = 0; }"));
    try testing.expectEqualStrings("`entity` is a member the host gives every struct; call the field something else", vm.diagnostics.items.items[0].message);
}

const Probe = struct { hp: i32 = 5 };

test "a handle on a value known only at run time" {
    const vm = try Vm.create(testing.allocator, .{});
    defer vm.destroy();
    try declareEngine(null, vm);
    const m = try vm.load("mover.flux", mover);
    var probe: Probe = .{};
    const h = try vm.handleOf(@import("fluxion_reflect").Value.of(&probe));
    try testing.expectEqual(@as(i64, 5), (try vm.callName(m, "hp", &.{h})).asInt());
}

test "instantiate keeps the host's values alive while it makes the instance" {
    const vm = try Vm.create(testing.allocator, .{ .gc = .{ .stress = true, .verify = true } });
    defer vm.destroy();
    try declareEngine(null, vm);
    const m = try vm.load("mover.flux", mover);
    var probe: Probe = .{ .hp = 9 };
    // Nothing but the call holds the handle, and making the instance collects.
    const one = try vm.instantiate(vm.get(m, "Mover").?, &.{.{ .name = "entity", .value = try vm.handle(&probe) }});
    try vm.hold(one);
    defer vm.release(one);
    const entity = try vm.callMethod(one, "who", &.{});
    try testing.expectEqual(@as(i64, 9), (try vm.callName(m, "hp", &.{entity})).asInt());
}

test "a handle on the host's memory is freed by the collector, once" {
    const vm = try Vm.create(testing.allocator, .{ .gc = .{ .stress = true, .verify = true } });
    defer vm.destroy();
    try declareEngine(null, vm);
    const m = try vm.load("mover.flux", mover);
    const probe = try vm.gpa.create(Probe);
    probe.* = .{ .hp = 4 };
    const h = try vm.adoptHandle(probe);
    try testing.expectEqual(@as(i64, 4), (try vm.callName(m, "hp", &.{h})).asInt());
    // Unreachable now: collected, and the testing allocator checks the
    // memory is given back, with the size and alignment it was made with.
    try @import("vm/gc.zig").collect(vm);
}

const Emits = struct {
    count: u32 = 0,
    signal: [16]u8 = undefined,
    signal_len: usize = 0,
    first_arg: i64 = 0,
    connection_ran: bool = false,
    connections_first: bool = false,

    fn onEmit(vm: *Vm, instance: Value, signal: []const u8, args: []const Value) Vm.Error!void {
        const self: *Emits = @ptrCast(@alignCast(vm.host.?));
        if (instance.tag != .instance) return vm.fail("an emit without its instance", .{});
        self.count += 1;
        @memcpy(self.signal[0..signal.len], signal);
        self.signal_len = signal.len;
        if (args.len > 0 and args[0].tag == .int) self.first_arg = args[0].asInt();
        if (std.mem.eql(u8, signal, "scored")) self.connections_first = self.connection_ran;
        if (std.mem.eql(u8, signal, "boom")) return vm.fail("the engine refused `{s}`", .{signal});
    }

    fn connected(vm: *Vm, _: []Value) Vm.Error!Value {
        const self: *Emits = @ptrCast(@alignCast(vm.current_native.?.user.?));
        self.connection_ran = true;
        return .null;
    }

    fn last(self: *const Emits) []const u8 {
        return self.signal[0..self.signal_len];
    }
};

test "the host hears every emit of an instance's signal, after its connections" {
    var emits: Emits = .{};
    const vm = try Vm.create(testing.allocator, .{ .on_emit = Emits.onEmit, .gc = .{ .stress = true, .verify = true } });
    defer vm.destroy();
    vm.host = &emits;
    const m = try load(vm);
    const player = try vm.instantiate(vm.get(m, "Player").?, &.{});
    try vm.hold(player);
    defer vm.release(player);
    const first = try vm.native("first", Emits.connected, 2, 2, &emits);
    try vm.hold(first);
    defer vm.release(first);
    try vm.connectSignal(player, "scored", first);

    // Emitted by the script: heard once, with its arguments, after the
    // signal's own connection ran.
    _ = try vm.callMethod(player, "add", &.{ .int(3), .int(4) });
    try testing.expectEqual(@as(u32, 1), emits.count);
    try testing.expectEqualStrings("scored", emits.last());
    try testing.expectEqual(@as(i64, 3), emits.first_arg);
    try testing.expect(emits.connections_first);

    // Emitted by the host: heard the same way.
    try vm.emitSignal(player, "died", &.{Value.fromObj(.string, &(try vm.newString("the host")).obj)});
    try testing.expectEqual(@as(u32, 2), emits.count);
    try testing.expectEqualStrings("died", emits.last());

    // A refusal stops the script that emitted.
    const b = try vm.load("bomb.flux", "struct Bomb { signal boom(); fn go(self) { self.boom.emit(); } }");
    const bomb = try vm.instantiate(vm.get(b, "Bomb").?, &.{});
    try vm.hold(bomb);
    defer vm.release(bomb);
    try testing.expectError(error.Panic, vm.callMethod(bomb, "go", &.{}));
    try testing.expectEqualStrings("the engine refused `boom`", vm.panic.?.message);
    vm.clearPanic();
}

test "a signal a reload adds is heard from the instances it moved" {
    var emits: Emits = .{};
    const vm = try Vm.create(testing.allocator, .{ .on_emit = Emits.onEmit, .gc = .{ .stress = true, .verify = true } });
    defer vm.destroy();
    vm.host = &emits;
    const m = try vm.load("pinger.flux", "struct Pinger { var n: int = 0; fn go(self) { self.n += 1; } }");
    const pinger = try vm.instantiate(vm.get(m, "Pinger").?, &.{});
    try vm.hold(pinger);
    defer vm.release(pinger);
    _ = try vm.reload(m, "struct Pinger { var n: int = 0; signal ping(times: int); fn go(self) { self.n += 1; self.ping.emit(self.n); } }");
    _ = try vm.callMethod(pinger, "go", &.{});
    try testing.expectEqual(@as(u32, 1), emits.count);
    try testing.expectEqualStrings("ping", emits.last());
    try testing.expectEqual(@as(i64, 1), emits.first_arg);
}

test "a file that failed to compile loads under the same name once it is mended" {
    const vm = try Vm.create(testing.allocator, .{});
    defer vm.destroy();
    try testing.expectError(error.CompileFailed, vm.load("level.flux", "fn start( { }"));
    const m = try vm.load("level.flux", "fn start() int { return 3; }");
    try testing.expectEqual(@as(i64, 3), (try vm.callName(m, "start", &.{})).asInt());
}

test "an editor's completions and hovers know what the host gives" {
    const service = @import("service.zig");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const options: service.Options = .{ .setup = .{ .run = declareEngine } };
    const source = mover ++ "fn use(x: Mover) {\n    x.\n}\n";
    const offset: u32 = @intCast(source.len - "\n}\n".len);

    const after_dot = try service.complete(testing.allocator, arena.allocator(), "mover.flux", source, offset, options);
    const entity = for (after_dot.items) |i| {
        if (std.mem.eql(u8, i.label, "entity")) break i;
    } else return error.EntityNotOffered;
    try testing.expectEqualStrings("The entity this script is on.", entity.doc.?);

    const named = try service.complete(testing.allocator, arena.allocator(), "mover.flux", mover ++ "fn g() {\n    ap\n}\n", @intCast(mover.len + "fn g() {\n    ap".len), options);
    const app = for (named.items) |i| {
        if (std.mem.eql(u8, i.label, "app")) break i;
    } else return error.AppNotOffered;
    try testing.expectEqualStrings("The running game.", app.doc.?);
    try testing.expectEqual(service.Kind.constant, app.kind);

    const a = try service.Analysis.init(testing.allocator, "mover.flux", mover, options);
    defer a.deinit();
    const on_entity = (try a.hover(arena.allocator(), @intCast(std.mem.indexOf(u8, mover, "entity; }").? + 1))).?;
    try testing.expectEqualStrings("entity: any", on_entity.code);
    try testing.expectEqualStrings("The entity this script is on.", on_entity.doc.?);
    const on_app = (try a.hover(arena.allocator(), @intCast(std.mem.indexOf(u8, mover, "app;").? + 1))).?;
    try testing.expectEqualStrings("The running game.", on_app.doc.?);
}

const guard_script =
    \\enum Mood { calm, angry }
    \\struct Guard {
    \\    /// How much it takes.
    \\    @export @range(0, 100) var hp: int = 10;
    \\    @export @multiline var motto: string = "halt";
    \\    @export var mood: Mood = .calm;
    \\    @export var path: [vec2];
    \\    @export var nick: ?string = null;
    \\    var heard = 0;
    \\
    \\    fn watch(self, bell: any) {
    \\        const rung = await bell;
    \\        self.heard = rung;
    \\    }
    \\}
;

test "a host lists a struct's fields with their annotations, sets them, and wakes a task with a signal of its own" {
    const vm = try Vm.create(testing.allocator, .{ .gc = .{ .stress = true, .verify = true } });
    defer vm.destroy();
    const m = try vm.load("guard.flux", guard_script);
    const class = vm.get(m, "Guard").?;
    var buffer: [8]api.FieldInfo = undefined;
    const fields = api.fieldsOf(vm, class, &buffer);
    try testing.expectEqual(@as(usize, 6), fields.len);

    const hp = fields[0];
    try testing.expectEqualStrings("hp", hp.name);
    try testing.expect(hp.exported);
    try testing.expectEqual(api.FieldKind.int, hp.kind);
    try testing.expectEqualStrings("How much it takes.", hp.doc.?);
    try testing.expectEqual(@as(i64, 10), hp.default.asInt());
    const range = api.annotationOf(hp, "range").?;
    try testing.expectEqual(@as(usize, 2), range.len);
    try testing.expectEqual(@as(i64, 100), range[1].asInt());
    try testing.expectEqual(@as(usize, 0), api.annotationOf(fields[1], "multiline").?.len);
    try testing.expect(api.annotationOf(fields[1], "range") == null);
    try testing.expectEqual(api.FieldKind.enum_member, fields[2].kind);
    try testing.expectEqualStrings("angry", fields[2].members[1].bytes());
    try testing.expectEqual(api.FieldKind.list, fields[3].kind);
    try testing.expectEqual(api.FieldKind.vec2, fields[3].element);
    try testing.expect(fields[4].nullable);
    try testing.expectEqual(api.FieldKind.string, fields[4].kind);
    try testing.expect(!fields[5].exported);

    const guard = try vm.instantiate(class, &.{});
    try vm.hold(guard);
    defer vm.release(guard);
    try vm.setField(guard, "hp", .int(50));
    try testing.expectEqual(@as(i64, 50), vm.getField(guard, "hp").?.asInt());
    try testing.expectError(error.WrongType, vm.setField(guard, "hp", .float(1.5)));
    try testing.expectError(error.NoSuchField, vm.setField(guard, "nope", .int(1)));

    // A signal of the host's own, awaited by a task and woken by its emit.
    const bell = try vm.newSignal("rung", 1);
    try vm.hold(bell);
    defer vm.release(bell);
    _ = try vm.callMethod(guard, "watch", &.{bell});
    try testing.expectEqual(@as(i64, 0), vm.getField(guard, "heard").?.asInt());
    try vm.emitSignalValue(bell, &.{.int(7)});
    try testing.expectEqual(@as(i64, 7), vm.getField(guard, "heard").?.asInt());
}

test "an annotation's arguments are literals" {
    const vm = try Vm.create(testing.allocator, .{});
    defer vm.destroy();
    try testing.expectError(error.CompileFailed, vm.load("bad.flux", "fn top() int { return 3; }\nstruct S { @range(0, top()) var x: int = 1; }"));
}

const Clock = struct {
    ticks: i64 = 0,

    var timeout: Value = .null;

    fn member(_: *Vm, _: Value, name: []const u8) Vm.Error!?Value {
        if (std.mem.eql(u8, name, "timeout")) return timeout;
        return null;
    }
};

test "a member the host gives a handle besides its fields: a signal a script awaits" {
    const vm = try Vm.create(testing.allocator, .{ .host_member = Clock.member });
    defer vm.destroy();
    var clock: Clock = .{};
    try vm.defineGlobal("clock", try vm.handle(&clock), null);
    Clock.timeout = try vm.newSignal("timeout", 0);
    try vm.hold(Clock.timeout);
    defer vm.release(Clock.timeout);
    const m = try vm.load("wait.flux",
        \\var rang = false;
        \\fn listen() {
        \\    await clock.timeout;
        \\    rang = true;
        \\}
        \\fn missing() any { return clock.nothing; }
    );
    _ = try vm.callName(m, "listen", &.{});
    try testing.expect(!vm.get(m, "rang").?.asBool());
    try vm.emitSignalValue(Clock.timeout, &.{});
    try testing.expect(vm.get(m, "rang").?.asBool());
    try testing.expectError(error.Panic, vm.callName(m, "missing", &.{}));
    try testing.expectEqualStrings("host_test.Clock has no field `nothing`", vm.panic.?.message);
    vm.clearPanic();
}

const Later = struct {
    kept: Value = .null,

    pub const reflect_methods = .{.keep};

    pub fn keep(self: *Later, f: Value) void {
        self.kept = f;
    }
};

test "a method of the host's is handed a script's value as it is" {
    const vm = try Vm.create(testing.allocator, .{});
    defer vm.destroy();
    var later: Later = .{};
    try vm.defineGlobal("later", try vm.handle(&later), null);
    const m = try vm.load("later.flux",
        \\var called = 0;
        \\fn bump() { called += 1; }
        \\fn give() { later.keep(bump); }
    );
    _ = try vm.callName(m, "give", &.{});
    try testing.expectEqual(Tag.function, later.kept.tag);
    _ = try vm.call(later.kept, &.{});
    try testing.expectEqual(@as(i64, 1), vm.get(m, "called").?.asInt());
}
