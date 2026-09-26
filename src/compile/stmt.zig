// SPDX-License-Identifier: BSD-2-Clause

//! Statements: declarations, assignments, blocks and loops.

const std = @import("std");

const diag = @import("../diag.zig");
const ast = @import("../syntax/ast.zig");
const types = @import("types.zig");
const Type = types.Type;
const Func = @import("Func.zig");
const Compiler = @import("Compiler.zig");
const Error = Compiler.Error;
const expr = @import("expr.zig");
const Operand = expr.Operand;
const binary = @import("binary.zig");
const names = @import("names.zig");
const member = @import("member.zig");
const control = @import("control.zig");
const decl = @import("decl.zig");
const body = @import("body.zig");

pub fn compile(f: *Func, s: *const ast.Stmt) Error!void {
    const c = f.comp;
    if (!f.reachable and s.kind != .invalid) {
        _ = try (try c.warn(s.span, "this code is never reached", .{})).text("nothing before it lets control get here", .{});
        f.reachable = true;
    }
    const saved = f.span;
    f.span = s.span;
    defer f.span = saved;
    switch (s.kind) {
        .@"var" => |v| return varDecl(f, v),
        .@"fn" => |fnode| return localFunction(f, fnode),
        else => {},
    }
    const mark = f.free;
    defer f.release(mark);
    switch (s.kind) {
        .expr => |e| {
            const v = try expr.compile(f, e, null, .unknown);
            if (c.pool.isErrorUnion(v.type) != null and try control.implicitTry(f, v, e.span) == null) {
                _ = try (try (try c.err(e.span, "the error this may give is ignored", .{}))
                    .text("this is {s}", .{c.typeName(v.type)}))
                    .help("pass it on with `try`, handle it with `catch`, or drop it with `_ = ...`", .{});
            }
        },
        .assign => |a| try assign(f, a.target, a.op, a.value),
        .block => |b| try block(f, b),
        .@"if" => |x| try ifStmt(f, x.cond, x.capture, x.then, x.else_capture, x.@"else"),
        .@"while" => |x| try whileStmt(f, x),
        .@"for" => |x| try forStmt(f, x),
        .@"switch" => |sw| try control.switchStmt(f, sw, s.span),
        .@"defer" => |d| try f.defers.append(c.gpa, .{ .depth = f.depth, .stmt = d.body, .on_error = d.on_error }),
        .@"struct", .@"enum", .@"test" => _ = try c.err(s.span, "this is declared at the top of a file", .{}),
        .invalid, .@"var", .@"fn" => {},
    }
}

/// A statement at the top of a file: variables there are the module's.
pub fn topLevel(f: *Func, s: *const ast.Stmt) Error!void {
    if (s.kind != .@"var") return compile(f, s);
    const v = s.kind.@"var";
    const c = f.comp;
    const g = c.global(v.name.text).?;
    if (g.kind == .import) return;
    f.span = s.span;
    const mark = f.free;
    defer f.release(mark);
    const init = v.value orelse {
        const zero = decl.zeroOf(c, g.type);
        if (zero.tag == .null and !c.pool.nullable(g.type) and c.pool.listOf(g.type) == null and c.pool.mapOf(g.type) == null and g.type != .unknown) {
            _ = try c.err(v.name.span, "`{s}` needs a starting value", .{v.name.text});
        }
        const r = try zeroValue(f, g.type, null);
        try f.abx(.setglobal, r.reg, @intCast(g.index));
        return;
    };
    // A type written down is the type, even one already reported as wrong:
    // only a variable with none takes its initializer's.
    const infer = g.type == .unknown and v.type == null;
    const value = if (infer) try expr.compile(f, init, null, .unknown) else try expr.typed(f, init, g.type, "the variable");
    if (infer) g.type = try inferred(f, value.type, v.name);
    try f.abx(.setglobal, value.reg, @intCast(g.index));
}

/// A module variable's initializer on a reload: run only when the variable
/// has no value kept from before, being new or declared differently.
pub fn reinit(f: *Func, s: *const ast.Stmt) Error!void {
    const g = f.comp.global(s.kind.@"var".name.text).?;
    if (g.kind == .import) return;
    f.span = s.span;
    const at = try f.emit(.abx(.jglobal, 0, @intCast(g.index)));
    try f.emitWord(0);
    try topLevel(f, s);
    try f.patchHere(.{ .at = at, .kind = .word });
}

fn inferred(f: *Func, t: Type, name: ast.Name) Error!Type {
    const c = f.comp;
    switch (t) {
        .null => {
            _ = try (try c.err(name.span, "what type is `{s}`? It starts as null", .{name.text}))
                .help("write the type: `var {s}: ?Enemy = null;`", .{name.text});
            return .unknown;
        },
        .void => {
            _ = try c.err(name.span, "`{s}` is given something that gives no value", .{name.text});
            return .unknown;
        },
        .never => return .unknown,
        else => return t,
    }
}

/// The zero of type `t` in a register: fresh for lists and maps.
fn zeroValue(f: *Func, t: Type, dst: ?u8) Error!Operand {
    const c = f.comp;
    if (c.pool.listOf(t)) |elem| {
        const r = try expr.target(f, dst);
        try f.abc(.newlist, r, 0, 0);
        try f.emitWord(@intFromEnum(try c.pool.check(&c.vm.checks, c.vm.gpa, elem)));
        return .{ .reg = r, .type = t, .temp = dst == null };
    }
    if (c.pool.mapOf(t)) |kv| {
        const r = try expr.target(f, dst);
        const k = try c.pool.check(&c.vm.checks, c.vm.gpa, kv.key);
        const v = try c.pool.check(&c.vm.checks, c.vm.gpa, kv.value);
        try f.abc(.newmap, r, @truncate(@intFromEnum(k)), @truncate(@intFromEnum(v)));
        return .{ .reg = r, .type = t, .temp = dst == null };
    }
    return expr.constant(f, dst, decl.zeroOf(c, t), t);
}

fn varDecl(f: *Func, v: *const ast.VarDecl) Error!void {
    const c = f.comp;
    const declared: ?Type = if (v.type) |t| try @import("resolve.zig").typeExpr(c, t) else null;
    const r = try f.alloc();
    var t: Type = .unknown;
    if (v.value) |init| {
        if (declared) |d| {
            t = (try expr.typedInto(f, init, r, d, "the variable")).type;
            t = d;
        } else {
            const value = try expr.into(f, init, r, .unknown);
            t = try inferred(f, value.type, v.name);
        }
    } else if (declared) |d| {
        const zero = decl.zeroOf(c, d);
        if (zero.tag == .null and !c.pool.nullable(d) and c.pool.listOf(d) == null and c.pool.mapOf(d) == null and d != .unknown) {
            _ = try (try c.err(v.name.span, "`{s}` needs a starting value", .{v.name.text}))
                .help("a {s} has no zero to start from", .{c.typeName(d)});
        }
        _ = try zeroValue(f, d, r);
        t = d;
    } else {
        _ = try c.err(v.name.span, "`{s}` needs a type or a value", .{v.name.text});
    }
    if (v.is_const and v.value == null) _ = try c.err(v.name.span, "a constant needs its value", .{});
    for (v.annotations) |a| _ = try c.err(a.name.span, "`@{s}` is for a struct's fields", .{a.name.text});
    f.release(r + 1);
    try f.declare(v.name.text, r, t, v.is_const, v.name.span);
}

fn localFunction(f: *Func, node: *const ast.Fn) Error!void {
    const r = try f.alloc();
    try f.declare(node.name.?.text, r, .unknown, true, node.name.?.span);
    const op = try body.lambda(f, node, r, .unknown);
    f.findLocal(node.name.?.text).?.type = op.type;
    if (f.comp.recording()) |rec| rec.retype(node.name.?.span, op.type);
    f.release(r + 1);
}

pub fn block(f: *Func, b: *const ast.Block) Error!void {
    f.enter();
    const defers = f.defers.items.len;
    for (b.stmts) |s| {
        if (f.comp.diags.full()) break;
        compile(f, s) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.CompileFailed => {},
        };
    }
    if (f.reachable) try control.runDefers(f, f.depth, false);
    f.defers.items.len = defers;
    try f.leave();
}

/// `old op value`, for `x op= value`.
pub fn combine(f: *Func, op: ast.BinaryOp, old: Operand, value: *const ast.Expr, span: diag.Span) Error!Operand {
    return binary.apply(f, op, old, value, span, null, f.free);
}

fn assign(f: *Func, target: *const ast.Expr, op: ast.AssignOp, value: *const ast.Expr) Error!void {
    const c = f.comp;
    const binop = ast.assignToBinary(op);
    switch (target.kind) {
        .ident => |name| {
            if (std.mem.eql(u8, name, "_")) {
                if (binop != null) _ = try c.err(target.span, "`_` only takes a value to drop", .{});
                _ = try expr.compile(f, value, null, .unknown);
                return;
            }
            const place = try names.lookup(f, name);
            if (c.recording()) |rec| try rec.place(f, name, target.span, place);
            switch (place) {
                .local => |r| {
                    const l = names.localByReg(f, r).?;
                    if (l.is_const) return constant(f, target, name, l.span);
                    if (binop) |o| {
                        const old: Operand = .{ .reg = r, .type = l.type, .temp = false };
                        const v = try binary.apply(f, o, old, value, target.span, r, f.free);
                        const w = try binary.coerce(f, v, l.type, value.span, "the variable");
                        if (w.reg != r) try f.abc(.move, r, w.reg, 0);
                    } else {
                        _ = try expr.typedInto(f, value, r, l.type, "the variable");
                    }
                },
                .none => return names.notDeclared(f, name, target.span),
                .builtin => _ = try c.err(target.span, "`{s}` is built in and cannot be assigned to", .{name}),
                else => {
                    const t = names.typeOf(f, place);
                    if (place == .upval and f.upvals.items[place.upval].is_const) return constant(f, target, name, null);
                    if (place == .global and place.global.kind != .variable) return constant(f, target, name, place.global.span);
                    const v = if (binop) |o| blk: {
                        const old = try names.read(f, name, target.span, null);
                        const combined = try combine(f, o, old, value, target.span);
                        break :blk try binary.coerce(f, combined, t, value.span, "the variable");
                    } else try expr.typed(f, value, t, "the variable");
                    try storeName(f, name, target.span, v.reg, t);
                },
            }
        },
        .field => try member.assignField(f, target, value, binop),
        .index => try member.assignIndex(f, target, value, binop),
        .self => _ = try c.err(target.span, "`self` cannot be assigned to; set its fields: `self.x = ...`", .{}),
        else => _ = try c.err(target.span, "this cannot be assigned to", .{}),
    }
}

fn constant(f: *Func, target: *const ast.Expr, name: []const u8, declared: ?diag.Span) Error!void {
    const c = f.comp;
    const h = try c.err(target.span, "`{s}` is a constant and cannot be changed", .{name});
    if (declared) |d| _ = try h.label(c.at(d), "declared here", .{});
    _ = try h.help("declare it with `var` to change it; parameters and loop captures are constants", .{});
}

/// R[reg] into the variable `name`.
pub fn storeName(f: *Func, name: []const u8, span: diag.Span, reg: u8, t: Type) Error!void {
    _ = t;
    switch (try names.lookup(f, name)) {
        .local => |r| if (r != reg) try f.abc(.move, r, reg, 0),
        .upval => |u| try f.abc(.setupval, reg, u, 0),
        .global => |g| try f.abx(.setglobal, reg, @intCast(g.index)),
        else => try names.notDeclared(f, name, span),
    }
}

fn ifStmt(f: *Func, cond: *const ast.Expr, capture: ?ast.Name, then: *const ast.Stmt, else_capture: ?ast.Name, otherwise: ?*const ast.Stmt) Error!void {
    const c = f.comp;
    var skip: control.Jumps = .empty;
    defer skip.deinit(c.gpa);
    const mark = f.free;
    var held: ?u8 = null;
    if (capture) |cap| {
        const v = try binary.owned(f, try expr.compile(f, cond, null, .unknown));
        held = v.reg;
        const opt = c.pool.isOptional(v.type);
        const err_union = c.pool.isErrorUnion(v.type);
        if (opt == null and err_union == null and !Compiler.dynamic(v.type)) {
            _ = try (try c.err(cond.span, "`if (x) |v|` unwraps an optional or an error union, and this is {s}", .{c.typeName(v.type)}))
                .text("never null", .{});
        }
        try skip.append(c.gpa, try f.jumpForward(if (err_union != null) .jerr else .jnull, v.reg, 0));
        f.enter();
        const r = try f.alloc();
        try f.abc(.move, r, v.reg, 0);
        try f.declare(cap.text, r, opt orelse err_union orelse v.type, true, cap.span);
        try compile(f, then);
        try f.leave();
        if (else_capture) |ec| {
            if (err_union == null) _ = try c.err(ec.span, "`else |err|` is for an error union", .{});
        }
    } else {
        try control.jumpIf(f, cond, false, &skip);
        f.release(mark);
        const narrowed = try control.narrow(f, cond, true);
        try scoped(f, then);
        f.unnarrow(narrowed);
    }
    const then_reachable = f.reachable;
    var else_reachable = true;
    if (otherwise) |o| {
        const end = try f.jumpForward(.jmp, 0, 0);
        try f.patchAll(skip.items, f.here());
        f.reachable = true;
        if (else_capture != null and held != null) {
            const ec = else_capture.?;
            f.enter();
            const r = try f.alloc();
            try f.abc(.move, r, held.?, 0);
            try f.declare(ec.text, r, .@"error", true, ec.span);
            try compile(f, o);
            try f.leave();
        } else {
            f.release(mark);
            const narrowed = if (capture == null) try control.narrow(f, cond, false) else f.narrowed.items.len;
            try scoped(f, o);
            f.unnarrow(narrowed);
        }
        else_reachable = f.reachable;
        f.reachable = f.reachable or then_reachable;
        try f.patchHere(end);
    } else {
        try f.patchAll(skip.items, f.here());
        f.reachable = true;
    }
    f.release(mark);
    // What follows is reached through one branch only: what that branch's
    // condition says holds to the end of the block.
    if (capture == null and then_reachable != else_reachable) _ = try control.narrow(f, cond, then_reachable);
}

/// A branch or a loop body in a scope of its own, so what it declares ends
/// with it.
fn scoped(f: *Func, s: *const ast.Stmt) Error!void {
    if (s.kind == .block) return compile(f, s);
    f.enter();
    const defers = f.defers.items.len;
    try compile(f, s);
    if (f.reachable) try control.runDefers(f, f.depth, false);
    f.defers.items.len = defers;
    try f.leave();
}

fn pushLoop(f: *Func, label: ?ast.Name) Error!void {
    try f.loops.append(f.comp.gpa, .{
        .label = if (label) |l| l.text else null,
        .depth = f.depth,
        .defers = f.defers.items.len,
        .locals = f.locals.items.len,
    });
}

fn popLoop(f: *Func, continue_at: usize, break_at: usize) Error!void {
    var loop = f.loops.pop().?;
    defer {
        loop.breaks.deinit(f.comp.gpa);
        loop.continues.deinit(f.comp.gpa);
    }
    try f.patchAll(loop.continues.items, continue_at);
    try f.patchAll(loop.breaks.items, break_at);
    if (loop.breaks.items.len > 0) f.reachable = true;
}

fn whileStmt(f: *Func, x: anytype) Error!void {
    const c = f.comp;
    const start = f.here();
    var exit: control.Jumps = .empty;
    defer exit.deinit(c.gpa);
    const mark = f.free;
    f.enter();
    if (x.capture) |cap| {
        const v = try expr.compile(f, x.cond, null, .unknown);
        const child = c.pool.isOptional(v.type) orelse v.type;
        try exit.append(c.gpa, try f.jumpForward(.jnull, v.reg, 0));
        const r = try f.alloc();
        try f.abc(.move, r, v.reg, 0);
        try f.declare(cap.text, r, child, true, cap.span);
    } else {
        const always = x.cond.kind == .bool and x.cond.kind.bool;
        try control.jumpIf(f, x.cond, false, &exit);
        if (always) f.reachable = true;
        _ = try control.narrow(f, x.cond, true);
    }
    try pushLoop(f, x.label);
    try scoped(f, x.body);
    const continue_at = f.here();
    f.reachable = true;
    if (x.next) |n| try scoped(f, n);
    try f.leave();
    f.release(mark);
    try f.jumpBack(.jmp, 0, start);
    const end = f.here();
    try f.patchAll(exit.items, end);
    const infinite = x.cond.kind == .bool and x.cond.kind.bool;
    f.reachable = !infinite;
    try popLoop(f, continue_at, end);
    if (!infinite) f.reachable = true;
}

fn forStmt(f: *Func, x: anytype) Error!void {
    const c = f.comp;
    const mark = f.free;
    if (x.iterable.kind == .range) {
        const r = x.iterable.kind.range;
        const regs = try f.allocN(3);
        _ = try expr.typedInto(f, r.start, regs, .int, "a range's start");
        _ = try expr.typedInto(f, r.end.?, regs + 1, .int, "a range's end");
        if (r.inclusive) try f.abc(.addi_i, regs + 1, regs + 1, 1);
        const prep = try f.jumpForward(.for_prep, regs, 0);
        const body_start = f.here();
        f.enter();
        try pushLoop(f, x.label);
        try f.declare(x.value.text, regs + 2, .int, true, x.value.span);
        if (x.index) |i| _ = try c.err(i.span, "a range gives one number each time; `|i|` alone", .{});
        try scoped(f, x.body);
        const continue_at = f.here();
        try closeCaptured(f);
        try f.leave();
        f.reachable = true;
        try f.jumpBack(.for_loop, regs, body_start);
        const end = f.here();
        try f.patch(prep, end);
        try popLoop(f, continue_at, end);
        f.reachable = true;
        f.release(mark);
        return;
    }
    const regs = try f.allocN(4);
    var it = try expr.into(f, x.iterable, regs, .unknown);
    if (c.pool.isErrorUnion(it.type) != null) if (try control.implicitTry(f, it, x.iterable.span)) |value| {
        if (value.reg != regs) try f.abc(.move, regs, value.reg, 0);
        it = .{ .reg = regs, .type = value.type, .temp = false };
    };
    var item: Type = .any;
    var second: Type = .int;
    if (c.pool.listOf(it.type)) |e| {
        item = e;
    } else if (c.pool.mapOf(it.type)) |kv| {
        item = kv.key;
        second = kv.value;
    } else if (it.type == .string) {
        item = .string;
    } else if (!Compiler.dynamic(it.type)) {
        _ = try (try c.err(x.iterable.span, "a `for` loop walks a list, a map, a string or a range, and this is {s}", .{c.typeName(it.type)}))
            .help("to count, write `for (0..n) |i|`", .{});
    } else {
        second = .any;
    }
    const prep = try f.jumpForward(.iter_prep, regs, 0);
    const body_start = f.here();
    f.enter();
    try pushLoop(f, x.label);
    try f.declare(x.value.text, regs + 2, item, true, x.value.span);
    if (x.index) |i| try f.declare(i.text, regs + 3, second, true, i.span);
    try scoped(f, x.body);
    const continue_at = f.here();
    try closeCaptured(f);
    try f.leave();
    f.reachable = true;
    try f.patchHere(prep);
    try f.jumpBack(.iter_next, regs, body_start);
    const end = f.here();
    try popLoop(f, continue_at, end);
    f.reachable = true;
    f.release(mark);
}

/// Each round of a loop gets its own captured variables: a closure made in
/// one round keeps that round's value.
fn closeCaptured(f: *Func) Error!void {
    var lowest: ?u8 = null;
    for (f.locals.items) |l| if (l.depth == f.depth and l.captured) {
        lowest = if (lowest) |x| @min(x, l.reg) else l.reg;
    };
    if (lowest) |r| try f.abc(.close, r, 0, 0);
}
