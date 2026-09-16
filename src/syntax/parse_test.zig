// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const testing = std.testing;

const diag = @import("../diag.zig");
const parse = @import("parse.zig");
const dump = @import("dump.zig");

const Result = struct {
    arena: std.heap.ArenaAllocator,
    diags: diag.Diagnostics,
    out: std.Io.Writer.Allocating,

    fn deinit(r: *Result) void {
        r.out.deinit();
        r.diags.deinit();
        r.arena.deinit();
    }
};

fn run(source: []const u8) !Result {
    var r: Result = .{ .arena = .init(testing.allocator), .diags = .init(testing.allocator), .out = .init(testing.allocator) };
    errdefer r.deinit();
    const m = try parse.parse(r.arena.allocator(), testing.allocator, source, @enumFromInt(0), &r.diags);
    try dump.module(&r.out.writer, m);
    return r;
}

fn expectTree(source: []const u8, expected: []const u8) !void {
    var r = try run(source);
    defer r.deinit();
    if (r.diags.failed()) {
        for (r.diags.items.items) |d| std.debug.print("unexpected: {s}\n", .{d.message});
        return error.TestUnexpectedError;
    }
    try testing.expectEqualStrings(expected, r.out.written());
}

fn expectErrors(source: []const u8, expected: []const []const u8) !void {
    var r = try run(source);
    defer r.deinit();
    const got = r.diags.items.items;
    if (got.len != expected.len) {
        for (got) |d| std.debug.print("got: {s}\n", .{d.message});
        return error.TestExpectedEqual;
    }
    for (expected, got) |want, d| try testing.expectEqualStrings(want, d.message);
}

test "precedence follows Zig: bit operators bind tighter than comparisons" {
    try expectTree("x = a + b * c;", "(= x (+ a (* b c)))");
    try expectTree("x = a & 1 == 0;", "(= x (== (& a 1) 0))");
    try expectTree("x = a or b and c;", "(= x (or a (and b c)))");
    try expectTree("x = -a.b(1)[2];", "(= x (- ([] (call (. a b) 1) 2)))");
    try expectTree("x = try f() + 1;", "(= x (+ (try (call f)) 1))");
    try expectTree("x = m.get(k) orelse 0 + 1;", "(= x (orelse (call (. m get) k) (+ 0 1)))");
}

test "declarations" {
    try expectTree("const x: int = 5;", "(const x:int 5)");
    try expectTree("var items: [Item] = [];", "(var items:[Item] (list))");
    try expectTree("var m: [string: ?int] = {};", "(var m:[string: ?int] (map))");
    try expectTree("fn add(a: int, b: int) int { return a + b; }", "(fn add (a:int b:int) int { (return (+ a b)) })");
    try expectTree("fn greet(name, greeting = \"hi\") { print(name); }", "(fn greet (name greeting=\"hi\") { (call print name) })");
    try expectTree("fn load(path: string) !Save { }", "(fn load (path:string) !Save { })");
}

test "structs, enums, signals and annotations" {
    try expectTree(
        \\struct Player extends Actor {
        \\    @export var speed: float = 300.0;
        \\    @export @range(0, 100) var health = 100;
        \\    const MAX = 3;
        \\    signal died(by: ?Actor);
        \\    fn damage(self, amount: int) { self.health -= amount; }
        \\}
    , "(struct Player extends Actor (@export var speed:float 300) (@export @range(0 100) var health 100) (const MAX 3) (signal died 1) (fn damage (self amount:int) { (-= (. self health) amount) }))");
    try expectTree("enum State { idle, run = 5, dead, fn moving(self) bool { return self == .run; } }", "(enum State idle run=5 dead (fn moving (self) bool { (return (== self .run)) }))");
}

test "control flow with Zig captures" {
    try expectTree("for (enemies) |e, i| { print(e); }", "(for enemies |e, i| { (call print e) })");
    try expectTree("for (0..10) |i| total += i;", "(for (.. 0 10) |i| (+= total i))");
    try expectTree("if (target) |t| print(t.name) else print(\"none\");", "(if target |t| (call print (. t name)) else (call print \"none\"))");
    try expectTree("while (i < n) : (i += 1) { }", "(while (< i n) : (+= i 1) { })");
    try expectTree("outer: while (true) { break :outer; }", "(while :outer true { (break :outer) })");
    try expectTree("if (a) { x(); } else if (b) { y(); } else { z(); }", "(if a { (call x) } else (if b { (call y) } else { (call z) }))");
}

test "switch as a statement and as a value" {
    try expectTree(
        \\const name = switch (state) {
        \\    .idle, .run => "moving",
        \\    1...5 => "low",
        \\    else => "dead",
        \\};
    , "(const name (switch state (.idle .run => \"moving\") ((... 1 5) => \"low\") (else => \"dead\")))");
    try expectTree("switch (x) { 1 => { a(); } else => b(), }", "(switch x (1 => { (call a) }) (else => (call b)))");
}

test "errors, optionals and their handling" {
    try expectTree("const t = try fs.read(path);", "(const t (try (call (. fs read) path)))");
    try expectTree("const v = parse(s) catch |err| return error.Bad(\"no\");", "(const v (catch (call parse s) |err| (return error.Bad(\"no\"))))");
    try expectTree("f() catch {};", "(catch (call f) |_| (map))");
    try expectTree("const n = x.? + (y orelse 1);", "(const n (+ (.? x) (orelse y 1)))");
    try expectTree("defer close(f);", "(defer (call close f))");
}

test "literals: lists, maps, strings, structs and lambdas" {
    try expectTree("x = [1, 2.5, \"a\\n\", 'c', true, null];", "(= x (list 1 2.5 \"a\\n\" 99 true null))");
    try expectTree("x = {\"hp\": 10, key: [1]};", "(= x (map (\"hp\" 10) (key (list 1))))");
    try expectTree("x = f\"hp {self.hp:.1} of {max}!\";", "(= x (f \"hp \" {(. self hp):.1} \" of \" {max} \"!\"))");
    try expectTree("p = Player{ .hp = 5, .name = \"x\" };", "(= p (new Player (.hp 5) (.name \"x\")))");
    try expectTree("p = Player{};", "(= p (new Player))");
    try expectTree("alive = enemies.filter(|e| e.health > 0);", "(= alive (call (. enemies filter) (lambda (e) (> (. e health) 0))))");
    try expectTree("f = fn (x: int) int { return x * 2; };", "(= f (lambda (x:int) int { (return (* x 2)) }))");
    try expectTree("s = xs[1..3] + xs[2..] + xs[..2];", "(= s (+ (+ ([..] xs 1 3) ([..] xs 2 _)) ([..] xs 0 2)))");
    try expectTree("const s =\n    \\\\one\n    \\\\two\n;", "(const s \"one\\ntwo\")");
}

test "imports, tests and await" {
    try expectTree("const math = @import(\"math\");", "(const math (@import \"math\"))");
    try expectTree("test \"damage\" { assert(true); }", "(test \"damage\" { (call assert true) })");
    try expectTree("fn intro() { await wait(1.5); }", "(fn intro () { (await (call wait 1.5)) })");
    try expectErrors("fn intro(self) {}", &.{"`self` can only be the first parameter of a method"});
}

test "a missing semicolon is reported after the statement, and parsing goes on" {
    try expectErrors("var a = 1\nvar b = 2;\nvar c = ;\nvar d = 4;", &.{ "expected `;` after the declaration", "expected an expression, found `;`" });
}

test "a declaration whose value does not parse is still declared" {
    var r = try run("var seen = (1 + ;\nvar next = [:];");
    defer r.deinit();
    try testing.expectEqualStrings("(var seen <invalid>)\n(var next <invalid>)", r.out.written());
    try expectErrors("var seen: [string: int] = [:];", &.{"`[:]` is not a map"});
}

test "one mistake in a block does not hide the next one" {
    try expectErrors(
        \\fn f() {
        \\    var x = (1 + ;
        \\    var y = 2
        \\    return x + y;
        \\}
        \\fn g() { h(; }
    , &.{ "expected an expression, found `;`", "expected `;` after the declaration", "expected an expression, found `;`" });
}

test "helpful messages for common slips" {
    try expectErrors("if (a = 1) {}", &.{"`=` sets a variable and cannot be a condition"});
    try expectErrors("x = a < b < c;", &.{"comparisons cannot be chained"});
    try expectErrors("var fn = 1;", &.{"`fn` is a keyword and cannot be a variable name"});
    try expectErrors("x = if (a) 1;", &.{"an `if` that gives a value needs an `else`"});
    try expectErrors("for (xs) { }", &.{"a `for` loop names each item"});
    try expectErrors("x = f\"{}\";", &.{"an empty `{}` in an f-string; write `{{}}` for the braces themselves"});
    try expectErrors("f(1) = 2;", &.{"this cannot be assigned to"});
    try expectErrors("fn f(a = 1, b) {}", &.{"`b` needs a default value, because a parameter before it has one"});
}

test "doc comments are kept on declarations" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diags: diag.Diagnostics = .init(testing.allocator);
    defer diags.deinit();
    const m = try parse.parse(arena.allocator(), testing.allocator, "var a = 1;\n/// How fast.\n/// In pixels.\n@export var speed = 3.0;", @enumFromInt(0), &diags);
    try testing.expectEqualStrings("How fast.\nIn pixels.", m.stmts[1].kind.@"var".doc.?);
    try testing.expect(m.stmts[0].kind.@"var".doc == null);
}
