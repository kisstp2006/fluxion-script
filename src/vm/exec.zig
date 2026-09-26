// SPDX-License-Identifier: BSD-2-Clause

//! The instruction loop. Each handler ends by jumping straight to the next
//! instruction's handler - `continue :dispatch` on a labeled switch, which
//! Zig compiles to one indirect jump per handler rather than a return to a
//! shared one, so the branch predictor learns each instruction's successor.

const std = @import("std");

const Vm = @import("Vm.zig");
const code = @import("code.zig");
const Instr = code.Instr;
const Extra = code.Extra;
const Value = @import("value.zig").Value;
const object = @import("object.zig");
const fiber_mod = @import("fiber.zig");
const Fiber = fiber_mod.Fiber;
const Frame = fiber_mod.Frame;
const ops = @import("ops.zig");
const access = @import("access.zig");
const call = @import("call.zig");
const make = @import("make.zig");
const types = @import("types.zig");
const format = @import("format.zig");

pub const RunError = Vm.Error || error{Suspend};

inline fn at(ip: [*]const u32) Instr {
    return @bitCast(ip[0]);
}

inline fn jump(ip: [*]const u32, offset: anytype) [*]const u32 {
    const delta: isize = offset;
    return @ptrFromInt(@as(usize, @bitCast(@as(isize, @bitCast(@intFromPtr(ip))) + delta * 4)));
}

inline fn wordOffset(ip: [*]const u32) i32 {
    return @bitCast(ip[1]);
}

inline fn topFrame(f: *Fiber) *Frame {
    return &f.frames.items[f.frames.items.len - 1];
}

/// A module's variables never move while its code runs: they are all
/// declared before it starts.
inline fn globalsOf(p: *const object.Proto) [*]Value {
    return if (p.module) |m| m.globals.items.ptr else undefined;
}

inline fn arith(comptime op: ops.Arith, vm: *Vm, frame: *Frame, ip: [*]const u32, x: Value, y: Value) Vm.Error!Value {
    if (x.tag == .int and y.tag == .int) {
        const a = x.asInt();
        const b = y.asInt();
        const r = switch (op) {
            .add => @addWithOverflow(a, b),
            .sub => @subWithOverflow(a, b),
            .mul => @mulWithOverflow(a, b),
            else => {
                frame.ip = ip;
                return .int(try ops.ints(vm, op, a, b));
            },
        };
        if (r[1] != 0) {
            frame.ip = ip;
            return ops.overflow(vm, op, a, b);
        }
        return .int(r[0]);
    }
    if (x.tag == .float and y.tag == .float) {
        switch (op) {
            .add => return .float(x.asFloat() + y.asFloat()),
            .sub => return .float(x.asFloat() - y.asFloat()),
            .mul => return .float(x.asFloat() * y.asFloat()),
            .div => return .float(x.asFloat() / y.asFloat()),
            else => {},
        }
    }
    frame.ip = ip;
    return ops.arith(vm, op, x, y);
}

inline fn less(comptime order: ops.Order, vm: *Vm, frame: *Frame, ip: [*]const u32, x: Value, y: Value) Vm.Error!bool {
    if (x.tag == .int and y.tag == .int) return if (order == .lt) x.asInt() < y.asInt() else x.asInt() <= y.asInt();
    if (x.tag == .float and y.tag == .float) return if (order == .lt) x.asFloat() < y.asFloat() else x.asFloat() <= y.asFloat();
    frame.ip = ip;
    return ops.compare(vm, order, x, y);
}

inline fn equal(x: Value, y: Value) bool {
    if (x.tag == .int and y.tag == .int) return x.raw == y.raw;
    return ops.equal(x, y);
}

fn notBool(vm: *Vm, v: Value) Vm.Error {
    @branchHint(.cold);
    return vm.fail("a condition must be a bool, not {s}", .{types.typeName(v)});
}

fn uninitialised(vm: *Vm, m: *object.Module, index: usize) Vm.Error {
    @branchHint(.cold);
    const name = if (index < m.names.items.len) m.names.items[index].bytes() else "?";
    return vm.fail("`{s}` is used before its initializer has run", .{name});
}

/// A closure of `p`, capturing registers of the frame making it and
/// captured variables of its closure. Out of the loop, so the loop's own
/// frame stays small: every call from the host or a native starts one.
fn newClosure(vm: *Vm, f: *Fiber, base: [*]Value, parent: *object.Closure, p: *object.Proto) Vm.Error!*object.Closure {
    const depth: u32 = @intCast(f.frames.items.len - 1);
    var captured: [256]*object.Upvalue = undefined;
    for (p.upvals, 0..) |d, n| {
        captured[n] = if (d.from_parent_local)
            try call.capture(vm, f, depth, d.index, &base[d.index])
        else
            parent.upvals()[d.index];
    }
    const c = try make.closure(vm, p);
    @memcpy(c.upvals(), captured[0..p.upvals.len]);
    return c;
}

/// Room for more frames: rare, so kept out of the call's way.
fn growFrames(vm: *Vm, f: *Fiber) Vm.Error!void {
    @branchHint(.cold);
    try f.frames.ensureUnusedCapacity(vm.gpa, 1);
}

fn staleCode(vm: *Vm, p: *const object.Proto) Vm.Error {
    @branchHint(.cold);
    const file = if (p.module) |m| m.path else "?";
    return vm.fail("`{s}` is code from before a reload of `{s}` that changed what it relies on; make it again from the new code", .{ p.name.bytes(), file });
}

fn failedCheck(vm: *Vm, check: types.Check, v: Value) Vm.Error {
    @branchHint(.cold);
    return access.wrongType(vm, check, v, "this value");
}

/// Runs the top frame of `f` until the nearest boundary frame returns. On
/// a panic the frames are left as they were, for the caller to unwind.
pub fn run(vm: *Vm, f: *Fiber) RunError!Value {
    var frame = topFrame(f);
    var ip = frame.ip;
    var base = frame.base;
    var proto = frame.proto;
    var k = proto.constants.ptr;
    var closure = frame.closure;
    var globals = globalsOf(proto);

    dispatch: switch (at(ip).op) {
        .nop => {
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .move => {
            const i = at(ip);
            base[i.a] = base[i.b];
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .loadk => {
            const i = at(ip);
            base[i.a] = k[i.bx()];
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .loadi => {
            const i = at(ip);
            base[i.a] = .int(i.sbx());
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .loadf => {
            const i = at(ip);
            base[i.a] = .float(@floatFromInt(i.sbx()));
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .loadnull => {
            const i = at(ip);
            for (base[i.a .. @as(usize, i.a) + i.b + 1]) |*r| r.* = .null;
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .loadtrue => {
            base[at(ip).a] = .true;
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .loadfalse => {
            base[at(ip).a] = .false;
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .getupval => {
            const i = at(ip);
            base[i.a] = closure.upvals()[i.b].location.*;
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .setupval => {
            const i = at(ip);
            const u = closure.upvals()[i.b];
            u.location.* = base[i.a];
            if (u.location == &u.closed) vm.heap.barrier(&u.obj, base[i.a]);
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .getglobal => {
            const i = at(ip);
            const v = globals[i.bx()];
            if (v.tag == .undefined) {
                frame.ip = ip;
                return uninitialised(vm, proto.module.?, i.bx());
            }
            base[i.a] = v;
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .setglobal => {
            const i = at(ip);
            globals[i.bx()] = base[i.a];
            vm.heap.barrier(&proto.module.?.obj, base[i.a]);
            ip += 1;
            continue :dispatch at(ip).op;
        },

        inline .add, .sub, .mul, .div, .mod, .add_wrap, .sub_wrap, .mul_wrap, .bit_and, .bit_or, .bit_xor, .shl, .shr => |op| {
            const i = at(ip);
            base[i.a] = try arith(comptime arithOf(op), vm, frame, ip, base[i.b], base[i.c]);
            ip += 1;
            continue :dispatch at(ip).op;
        },
        inline .addk, .subk, .mulk, .divk => |op| {
            const i = at(ip);
            base[i.a] = try arith(comptime arithOf(op), vm, frame, ip, base[i.b], k[i.c]);
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .addi => {
            const i = at(ip);
            base[i.a] = try arith(.add, vm, frame, ip, base[i.b], .int(i.sc()));
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .neg => {
            const i = at(ip);
            const v = base[i.b];
            base[i.a] = switch (v.tag) {
                .float => .float(-v.asFloat()),
                else => blk: {
                    frame.ip = ip;
                    break :blk try ops.negate(vm, v);
                },
            };
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .not => {
            const i = at(ip);
            const v = base[i.b];
            if (v.tag != .bool) {
                frame.ip = ip;
                base[i.a] = try ops.not(vm, v);
            }
            base[i.a] = .boolean(!v.asBool());
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .bit_not => {
            const i = at(ip);
            frame.ip = ip;
            base[i.a] = try ops.bitNot(vm, base[i.b]);
            ip += 1;
            continue :dispatch at(ip).op;
        },

        inline .add_ii, .sub_ii, .mul_ii => |op| {
            const i = at(ip);
            const a = base[i.b].asInt();
            const b = base[i.c].asInt();
            const r = switch (op) {
                .add_ii => @addWithOverflow(a, b),
                .sub_ii => @subWithOverflow(a, b),
                else => @mulWithOverflow(a, b),
            };
            if (r[1] != 0) {
                frame.ip = ip;
                return ops.overflow(vm, switch (op) {
                    .add_ii => .add,
                    .sub_ii => .sub,
                    else => .mul,
                }, a, b);
            }
            base[i.a] = .int(r[0]);
            ip += 1;
            continue :dispatch at(ip).op;
        },
        inline .div_ii, .mod_ii => |op| {
            const i = at(ip);
            frame.ip = ip;
            base[i.a] = .int(try ops.ints(vm, if (op == .div_ii) .div else .mod, base[i.b].asInt(), base[i.c].asInt()));
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .addi_i => {
            const i = at(ip);
            const r = @addWithOverflow(base[i.b].asInt(), @as(i64, i.sc()));
            if (r[1] != 0) {
                frame.ip = ip;
                return ops.overflow(vm, .add, base[i.b].asInt(), i.sc());
            }
            base[i.a] = .int(r[0]);
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .neg_i => {
            const i = at(ip);
            const v = base[i.b].asInt();
            if (v == std.math.minInt(i64)) {
                frame.ip = ip;
                return ops.overflow(vm, .sub, 0, v);
            }
            base[i.a] = .int(-v);
            ip += 1;
            continue :dispatch at(ip).op;
        },
        inline .add_ff, .sub_ff, .mul_ff, .div_ff => |op| {
            const i = at(ip);
            const a = base[i.b].asFloat();
            const b = base[i.c].asFloat();
            base[i.a] = .float(switch (op) {
                .add_ff => a + b,
                .sub_ff => a - b,
                .mul_ff => a * b,
                else => a / b,
            });
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .neg_f => {
            const i = at(ip);
            base[i.a] = .float(-base[i.b].asFloat());
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .to_float => {
            const i = at(ip);
            base[i.a] = .float(@floatFromInt(base[i.b].asInt()));
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .muli_i => {
            const i = at(ip);
            const r = @mulWithOverflow(base[i.b].asInt(), @as(i64, i.sc()));
            if (r[1] != 0) {
                frame.ip = ip;
                return ops.overflow(vm, .mul, base[i.b].asInt(), i.sc());
            }
            base[i.a] = .int(r[0]);
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .modi_i => {
            const i = at(ip);
            const d: i64 = i.sc();
            base[i.a] = .int(if (d == -1) 0 else @rem(base[i.b].asInt(), d));
            ip += 1;
            continue :dispatch at(ip).op;
        },
        inline .add_v2, .sub_v2, .mul_v2 => |op| {
            const i = at(ip);
            const a: @Vector(2, f32) = base[i.b].asVec2();
            const b: @Vector(2, f32) = base[i.c].asVec2();
            const r: [2]f32 = switch (op) {
                .add_v2 => a + b,
                .sub_v2 => a - b,
                else => a * b,
            };
            base[i.a] = .vec2(r[0], r[1]);
            ip += 1;
            continue :dispatch at(ip).op;
        },
        inline .mul_v2f, .div_v2f => |op| {
            const i = at(ip);
            const a: @Vector(2, f32) = base[i.b].asVec2();
            const s: @Vector(2, f32) = @splat(@floatCast(base[i.c].asFloat()));
            const r: [2]f32 = if (op == .mul_v2f) a * s else a / s;
            base[i.a] = .vec2(r[0], r[1]);
            ip += 1;
            continue :dispatch at(ip).op;
        },
        inline .add_v3, .sub_v3, .mul_v3 => |op| {
            const i = at(ip);
            const a: @Vector(3, f32) = base[i.b].asVec3();
            const b: @Vector(3, f32) = base[i.c].asVec3();
            const r: [3]f32 = switch (op) {
                .add_v3 => a + b,
                .sub_v3 => a - b,
                else => a * b,
            };
            base[i.a] = .vec3(r[0], r[1], r[2]);
            ip += 1;
            continue :dispatch at(ip).op;
        },
        inline .mul_v3f, .div_v3f => |op| {
            const i = at(ip);
            const a: @Vector(3, f32) = base[i.b].asVec3();
            const s: @Vector(3, f32) = @splat(@floatCast(base[i.c].asFloat()));
            const r: [3]f32 = if (op == .mul_v3f) a * s else a / s;
            base[i.a] = .vec3(r[0], r[1], r[2]);
            ip += 1;
            continue :dispatch at(ip).op;
        },

        inline .eq, .ne => |op| {
            const i = at(ip);
            const same = equal(base[i.b], base[i.c]);
            base[i.a] = .boolean(if (op == .eq) same else !same);
            ip += 1;
            continue :dispatch at(ip).op;
        },
        inline .eqk, .nek => |op| {
            const i = at(ip);
            const same = equal(base[i.b], k[i.c]);
            base[i.a] = .boolean(if (op == .eqk) same else !same);
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .lt => {
            const i = at(ip);
            base[i.a] = .boolean(try less(.lt, vm, frame, ip, base[i.b], base[i.c]));
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .le => {
            const i = at(ip);
            base[i.a] = .boolean(try less(.le, vm, frame, ip, base[i.b], base[i.c]));
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .lt_ii, .le_ii, .eq_ii => |op| {
            const i = at(ip);
            const a = base[i.b].asInt();
            const b = base[i.c].asInt();
            base[i.a] = .boolean(switch (op) {
                .lt_ii => a < b,
                .le_ii => a <= b,
                else => a == b,
            });
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .lt_ff, .le_ff => |op| {
            const i = at(ip);
            const a = base[i.b].asFloat();
            const b = base[i.c].asFloat();
            base[i.a] = .boolean(if (op == .lt_ff) a < b else a <= b);
            ip += 1;
            continue :dispatch at(ip).op;
        },

        .jeq, .jne => |op| {
            const i = at(ip);
            const same = equal(base[i.a], base[i.b]);
            ip = if (same == (op == .jeq)) jump(ip + 2, wordOffset(ip)) else ip + 2;
            continue :dispatch at(ip).op;
        },
        .jlt => {
            const i = at(ip);
            const taken = try less(.lt, vm, frame, ip, base[i.a], base[i.b]);
            ip = if (taken) jump(ip + 2, wordOffset(ip)) else ip + 2;
            continue :dispatch at(ip).op;
        },
        .jle => {
            const i = at(ip);
            const taken = try less(.le, vm, frame, ip, base[i.a], base[i.b]);
            ip = if (taken) jump(ip + 2, wordOffset(ip)) else ip + 2;
            continue :dispatch at(ip).op;
        },
        .jlt_ii, .jle_ii, .jeq_ii, .jne_ii => |op| {
            const i = at(ip);
            const a = base[i.a].asInt();
            const b = base[i.b].asInt();
            const taken = switch (op) {
                .jlt_ii => a < b,
                .jle_ii => a <= b,
                .jeq_ii => a == b,
                else => a != b,
            };
            ip = if (taken) jump(ip + 2, wordOffset(ip)) else ip + 2;
            continue :dispatch at(ip).op;
        },
        .jlt_ff, .jle_ff => |op| {
            const i = at(ip);
            const a = base[i.a].asFloat();
            const b = base[i.b].asFloat();
            const taken = if (op == .jlt_ff) a < b else a <= b;
            ip = if (taken) jump(ip + 2, wordOffset(ip)) else ip + 2;
            continue :dispatch at(ip).op;
        },
        .jlti, .jlei, .jgti, .jgei => |op| {
            const i = at(ip);
            const a = base[i.a].asInt();
            const b: i64 = i.sB();
            const taken = switch (op) {
                .jlti => a < b,
                .jlei => a <= b,
                .jgti => a > b,
                else => a >= b,
            };
            ip = if (taken) jump(ip + 2, wordOffset(ip)) else ip + 2;
            continue :dispatch at(ip).op;
        },
        .jeqk, .jnek => |op| {
            const i = at(ip);
            const same = equal(base[i.a], k[i.b]);
            ip = if (same == (op == .jeqk)) jump(ip + 2, wordOffset(ip)) else ip + 2;
            continue :dispatch at(ip).op;
        },
        .jmp => {
            const offset = at(ip).jump();
            if (offset < 0 and vm.guarded.load(.monotonic)) {
                frame.ip = ip;
                try vm.tick();
            }
            ip = jump(ip + 1, offset);
            continue :dispatch at(ip).op;
        },
        .jtrue, .jfalse => |op| {
            const i = at(ip);
            const v = base[i.a];
            if (v.tag != .bool) {
                frame.ip = ip;
                return notBool(vm, v);
            }
            ip = if (v.asBool() == (op == .jtrue)) jump(ip + 1, i.sbx()) else ip + 1;
            continue :dispatch at(ip).op;
        },
        .jnull, .jnotnull => |op| {
            const i = at(ip);
            const is_null = base[i.a].tag == .null;
            ip = if (is_null == (op == .jnull)) jump(ip + 1, i.sbx()) else ip + 1;
            continue :dispatch at(ip).op;
        },
        .jerr, .jnoterr => |op| {
            const i = at(ip);
            const is_err = base[i.a].tag == .@"error";
            ip = if (is_err == (op == .jerr)) jump(ip + 1, i.sbx()) else ip + 1;
            continue :dispatch at(ip).op;
        },
        .jargs => {
            const i = at(ip);
            ip = if (frame.args > i.a) jump(ip + 1, i.sbx()) else ip + 1;
            continue :dispatch at(ip).op;
        },

        .call => {
            const i = at(ip);
            const slot = base + i.a;
            var nargs: usize = i.b;
            if (i.c & 2 != 0 and slot[1].tag == .undefined) {
                std.mem.copyForwards(Value, slot[1..nargs], slot[2 .. nargs + 1]);
                nargs -= 1;
            }
            frame.ip = ip + 1;
            while (true) {
                // Read in place: a copy of the callee costs a trip through the stack.
                switch (slot[0].tag) {
                    .function => {
                        const c = slot[0].as(object.Closure);
                        const p = c.proto;
                        if (p.coroutine and i.c & 1 == 0) {
                            frame.ip = ip;
                            slot[0] = try call.spawn(vm, c, slot[1 .. nargs + 1]);
                            ip += 1;
                            continue :dispatch at(ip).op;
                        }
                        if (nargs < p.required or nargs > p.params) {
                            frame.ip = ip;
                            return call.badArity(vm, p, nargs);
                        }
                        if (f.frames.items.len >= vm.options.max_frames) {
                            frame.ip = ip;
                            return call.stackOverflow(vm);
                        }
                        const new_base = try f.place(vm.gpa, slot + 1, nargs, p.regs);
                        if (f.frames.items.len == f.frames.capacity) try growFrames(vm, f);
                        const pushed = f.frames.addOneAssumeCapacity();
                        pushed.* = .{
                            .closure = c,
                            .proto = p,
                            .ip = p.code.ptr + (if (i.c & 4 != 0) p.fast_entry else 0),
                            .base = new_base,
                            .result = &slot[0],
                            .chunk = f.current,
                            .args = @intCast(nargs),
                            .boundary = false,
                        };
                        frame = pushed;
                        ip = frame.ip;
                        base = new_base;
                        proto = p;
                        k = p.constants.ptr;
                        closure = c;
                        globals = globalsOf(p);
                        continue :dispatch at(ip).op;
                    },
                    .native => {
                        const n = slot[0].as(object.Native);
                        if (nargs < n.min or (n.max != null and nargs > n.max.?)) {
                            frame.ip = ip;
                            return call.badNativeArity(vm, n, nargs);
                        }
                        frame.ip = ip + 1;
                        const saved = vm.current_native;
                        vm.current_native = n;
                        const result = n.func(vm, slot[1 .. nargs + 1]) catch |err| {
                            vm.current_native = saved;
                            return err;
                        };
                        vm.current_native = saved;
                        // It may have called back into the script on this
                        // line of execution, and the frames it pushed may
                        // have moved the list this frame is kept in.
                        frame = topFrame(f);
                        slot[0] = result;
                        ip += 1;
                        continue :dispatch at(ip).op;
                    },
                    .method => {
                        const m = slot[0].as(object.Method);
                        std.mem.copyBackwards(Value, slot[2 .. nargs + 2], slot[1 .. nargs + 1]);
                        slot[1] = m.receiver;
                        slot[0] = m.function;
                        nargs += 1;
                    },
                    else => {
                        frame.ip = ip;
                        return call.notCallable(vm, slot[0]);
                    },
                }
            }
        },
        .ret, .retnull => |op| {
            const v = if (op == .ret) base[at(ip).a] else Value.null;
            const depth: u32 = @intCast(f.frames.items.len - 1);
            if (f.open) |u| if (u.frame >= depth) call.close(vm, f, depth, 0);
            frame.result.* = v;
            const boundary = frame.boundary;
            f.frames.items.len -= 1;
            f.popped();
            if (boundary) return v;
            frame = topFrame(f);
            ip = frame.ip;
            base = frame.base;
            proto = frame.proto;
            k = proto.constants.ptr;
            closure = frame.closure;
            globals = globalsOf(proto);
            continue :dispatch at(ip).op;
        },
        .closure => {
            const i = at(ip);
            frame.ip = ip;
            const c = try @call(.never_inline, newClosure, .{ vm, f, base, closure, proto.protos[i.bx()] });
            base[i.a] = .fromObj(.function, &c.obj);
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .close => {
            const depth: u32 = @intCast(f.frames.items.len - 1);
            call.close(vm, f, depth, at(ip).a);
            ip += 1;
            continue :dispatch at(ip).op;
        },

        .newlist => {
            const i = at(ip);
            frame.ip = ip;
            const check: types.Check = @enumFromInt(ip[1]);
            base[i.a] = .fromObj(.list, &(try make.list(vm, i.b, check)).obj);
            ip += 2;
            continue :dispatch at(ip).op;
        },
        .append => {
            const i = at(ip);
            frame.ip = ip;
            const l = base[i.a].as(object.List);
            for (base[i.b .. @as(usize, i.b) + i.c]) |v| {
                const stored = vm.checks.coerce(l.elem, v) orelse return access.wrongType(vm, l.elem, v, "the list's element");
                try l.items.append(vm.gpa, stored);
                vm.heap.barrier(&l.obj, stored);
            }
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .newmap => {
            const i = at(ip);
            frame.ip = ip;
            const key: types.Check = @enumFromInt(i.b);
            const value: types.Check = @enumFromInt(i.c);
            base[i.a] = .fromObj(.map, &(try make.map(vm, key, value)).obj);
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .getindex => {
            const i = at(ip);
            const target = base[i.b];
            const index = base[i.c];
            if (target.tag == .list and index.tag == .int) {
                const items = target.as(object.List).items.items;
                const n = index.asInt();
                if (n >= 0 and n < items.len) {
                    base[i.a] = items[@intCast(n)];
                    ip += 1;
                    continue :dispatch at(ip).op;
                }
            }
            frame.ip = ip;
            base[i.a] = try access.getIndex(vm, target, index);
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .setindex => {
            const i = at(ip);
            frame.ip = ip;
            try access.setIndex(vm, base[i.a], base[i.b], base[i.c]);
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .getlist => {
            const i = at(ip);
            const items = base[i.b].as(object.List).items.items;
            const n = base[i.c].asInt();
            if (n < 0 or n >= items.len) {
                frame.ip = ip;
                base[i.a] = try access.getIndex(vm, base[i.b], base[i.c]);
            } else base[i.a] = items[@intCast(n)];
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .setlist => {
            const i = at(ip);
            const l = base[i.a].as(object.List);
            const n = base[i.b].asInt();
            if (n < 0 or n >= l.items.items.len) {
                frame.ip = ip;
                try access.setIndex(vm, base[i.a], base[i.b], base[i.c]);
            } else {
                l.items.items[@intCast(n)] = base[i.c];
                vm.heap.barrier(&l.obj, base[i.c]);
            }
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .slice => {
            const i = at(ip);
            frame.ip = ip;
            base[i.a] = try access.slice(vm, base[i.b], base[i.c], base[@as(usize, i.c) + 1]);
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .len => {
            const i = at(ip);
            const v = base[i.b];
            base[i.a] = switch (v.tag) {
                .list => .int(@intCast(v.as(object.List).items.items.len)),
                else => blk: {
                    frame.ip = ip;
                    break :blk try access.length(vm, v);
                },
            };
            ip += 1;
            continue :dispatch at(ip).op;
        },

        .getfield => {
            const i = at(ip);
            base[i.a] = base[i.b].as(object.Instance).fields()[i.c];
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .setfield => {
            const i = at(ip);
            const inst = base[i.a].as(object.Instance);
            inst.fields()[i.b] = base[i.c];
            vm.heap.barrier(&inst.obj, base[i.c]);
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .getprop => {
            const i = at(ip);
            const x: Extra = @bitCast(ip[1]);
            const target = base[i.b];
            const cache = &proto.caches[x.cache];
            if (target.tag == .instance) {
                const inst = target.as(object.Instance);
                if (cache.class == inst.class and cache.slot != std.math.maxInt(u32)) {
                    base[i.a] = inst.fields()[cache.slot];
                    ip += 2;
                    continue :dispatch at(ip).op;
                }
            }
            frame.ip = ip;
            base[i.a] = try access.getProperty(vm, target, k[x.name].as(object.String), cache);
            ip += 2;
            continue :dispatch at(ip).op;
        },
        .setprop => {
            const i = at(ip);
            const x: Extra = @bitCast(ip[1]);
            const target = &base[i.a];
            const cache = &proto.caches[x.cache];
            if (target.tag == .instance) {
                const inst = target.as(object.Instance);
                if (cache.class == inst.class and cache.check == .any and cache.slot != std.math.maxInt(u32)) {
                    inst.fields()[cache.slot] = base[i.b];
                    vm.heap.barrier(&inst.obj, base[i.b]);
                    ip += 2;
                    continue :dispatch at(ip).op;
                }
            }
            frame.ip = ip;
            try access.setProperty(vm, target, k[x.name].as(object.String), base[i.b], cache);
            ip += 2;
            continue :dispatch at(ip).op;
        },
        .getmethod => {
            const i = at(ip);
            const x: Extra = @bitCast(ip[1]);
            const target = base[i.b];
            const cache = &proto.caches[x.cache];
            if (target.tag == .instance and cache.class == target.as(object.Instance).class and cache.slot == std.math.maxInt(u32)) {
                base[i.a] = cache.method;
                base[@as(usize, i.a) + 1] = target;
                ip += 2;
                continue :dispatch at(ip).op;
            }
            frame.ip = ip;
            const found = try access.getMethod(vm, target, k[x.name].as(object.String), cache);
            base[i.a] = found.function;
            base[@as(usize, i.a) + 1] = if (found.with_self) target else Value.undef;
            ip += 2;
            continue :dispatch at(ip).op;
        },
        .getcomp => {
            const i = at(ip);
            const v = base[i.b];
            const xy: [2]f32 = @bitCast(v.raw);
            base[i.a] = .float(if (i.c < 2) xy[i.c] else @as(f32, @bitCast(v.extra)));
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .setcomp => {
            const i = at(ip);
            const v = &base[i.a];
            const x: f32 = @floatCast(base[i.c].asFloat());
            if (i.b < 2) {
                var xy: [2]f32 = @bitCast(v.raw);
                xy[i.b] = x;
                v.raw = @bitCast(xy);
            } else v.extra = @bitCast(x);
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .newinstance => {
            const i = at(ip);
            frame.ip = ip;
            const class = k[i.bx()].as(object.Class);
            const inst = try make.instance(vm, class);
            base[i.a] = .fromObj(.instance, &inst.obj);
            if (class.has_signals) try @call(.never_inline, @import("../lib/signal.zig").fill, .{ vm, inst });
            if (class.defaults != null or class.parent != null) {
                try @call(.never_inline, call.initDefaults, .{ vm, base[i.a] });
                frame = topFrame(f);
            }
            ip += 1;
            continue :dispatch at(ip).op;
        },

        .format => {
            const i = at(ip);
            frame.ip = ip;
            base[i.a] = try @call(.never_inline, format.parts, .{ vm, base[i.b .. @as(usize, i.b) + i.c], k + ip[1] });
            ip += 2;
            continue :dispatch at(ip).op;
        },
        .check => {
            const i = at(ip);
            const c: types.Check = @enumFromInt(i.bx());
            base[i.a] = vm.checks.coerce(c, base[i.a]) orelse {
                frame.ip = ip;
                return failedCheck(vm, c, base[i.a]);
            };
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .check_param => {
            const i = at(ip);
            const c: types.Check = @enumFromInt(i.bx());
            base[i.a] = vm.checks.coerce(c, base[i.a]) orelse {
                frame.ip = ip;
                const name = if (i.a < proto.param_names.len) proto.param_names[i.a].bytes() else "?";
                return access.wrongType(vm, c, base[i.a], name);
            };
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .unwrap => {
            const i = at(ip);
            // With `c` set, an error nothing handled: the compiler's, for
            // `Options.unhandled_errors`.
            if (i.c == 1) {
                if (base[i.b].tag == .@"error") {
                    frame.ip = ip;
                    const e = base[i.b].as(object.ErrorValue);
                    if (e.message) |m| return vm.fail("error.{s} was not handled: {s}", .{ e.name.bytes(), m.bytes() });
                    return vm.fail("error.{s} was not handled", .{e.name.bytes()});
                }
            } else if (base[i.b].tag == .null) {
                frame.ip = ip;
                return vm.fail("`.?` found null", .{});
            }
            base[i.a] = base[i.b];
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .is => {
            const i = at(ip);
            base[i.a] = .boolean(vm.checks.accepts(@enumFromInt(ip[1]), base[i.b]));
            ip += 2;
            continue :dispatch at(ip).op;
        },
        .in => {
            const i = at(ip);
            frame.ip = ip;
            base[i.a] = .boolean(try ops.contains(vm, base[i.b], base[i.c]));
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .@"await" => {
            const i = at(ip);
            frame.ip = ip;
            switch (try call.prepareAwait(vm, &base[i.a], base[i.b])) {
                .ready => |v| base[i.a] = v,
                .wait => {
                    frame.ip = ip + 1;
                    return error.Suspend;
                },
            }
            ip += 1;
            continue :dispatch at(ip).op;
        },
        .make_error => {
            const i = at(ip);
            frame.ip = ip;
            const name = k[ip[1]].as(object.String);
            const m = base[i.b];
            if (m.tag != .string) base[i.b] = try format.toString(vm, m);
            base[i.a] = try make.errorValue(vm, name, base[i.b].as(object.String));
            ip += 2;
            continue :dispatch at(ip).op;
        },

        .for_prep => {
            const i = at(ip);
            const from = base[i.a];
            const to = base[@as(usize, i.a) + 1];
            if (from.tag != .int or to.tag != .int) {
                frame.ip = ip;
                return vm.fail("a range counts in ints, not {s} to {s}", .{ types.typeName(from), types.typeName(to) });
            }
            if (from.asInt() >= to.asInt()) {
                ip = jump(ip + 1, i.sbx());
            } else {
                base[@as(usize, i.a) + 2] = from;
                ip += 1;
            }
            continue :dispatch at(ip).op;
        },
        .for_loop => {
            const i = at(ip);
            const n = base[i.a].asInt() + 1;
            if (n < base[@as(usize, i.a) + 1].asInt()) {
                if (vm.guarded.load(.monotonic)) {
                    frame.ip = ip;
                    try vm.tick();
                }
                base[i.a] = .int(n);
                base[@as(usize, i.a) + 2] = .int(n);
                ip = jump(ip + 1, i.sbx());
            } else ip += 1;
            continue :dispatch at(ip).op;
        },
        .iter_prep => {
            const i = at(ip);
            const it = base[i.a];
            switch (it.tag) {
                .list, .string => base[@as(usize, i.a) + 1] = .int(0),
                .map => base[@as(usize, i.a) + 1] = .{ .raw = 0, .extra = it.as(object.Map).table.version, .tag = .int },
                else => {
                    frame.ip = ip;
                    return vm.fail("a `for` loop walks a list, a map, a string or a range, not {s}", .{types.typeName(it)});
                },
            }
            ip = jump(ip + 1, i.sbx());
            continue :dispatch at(ip).op;
        },
        .iter_next => {
            const i = at(ip);
            const a: usize = i.a;
            const it = base[a];
            const pos: usize = @intCast(base[a + 1].asInt());
            var found = false;
            switch (it.tag) {
                .list => {
                    const items = it.as(object.List).items.items;
                    if (pos < items.len) {
                        base[a + 2] = items[pos];
                        base[a + 3] = .int(@intCast(pos));
                        base[a + 1] = .int(@intCast(pos + 1));
                        found = true;
                    }
                },
                .map => {
                    const t = &it.as(object.Map).table;
                    if (t.version != base[a + 1].extra) {
                        frame.ip = ip;
                        return vm.fail("the map was reorganised while a loop walked it; collect the changes and make them after the loop", .{});
                    }
                    var n = pos;
                    while (n < t.entries.items.len and t.entries.items[n].key.tag == .undefined) n += 1;
                    if (n < t.entries.items.len) {
                        base[a + 2] = t.entries.items[n].key;
                        base[a + 3] = t.entries.items[n].value;
                        base[a + 1] = .{ .raw = n + 1, .extra = t.version, .tag = .int };
                        found = true;
                    }
                },
                .string => {
                    const s = it.as(object.String);
                    if (pos < s.len) {
                        frame.ip = ip;
                        const len = std.unicode.utf8ByteSequenceLength(s.bytes()[pos]) catch 1;
                        const end = @min(s.len, pos + len);
                        base[a + 2] = try vm.string(s.bytes()[pos..end]);
                        base[a + 3] = .int(base[a + 1].extra);
                        base[a + 1] = .{ .raw = end, .extra = base[a + 1].extra + 1, .tag = .int };
                        found = true;
                    }
                },
                else => unreachable,
            }
            if (found and vm.guarded.load(.monotonic)) {
                frame.ip = ip;
                try vm.tick();
            }
            ip = if (found) jump(ip + 1, i.sbx()) else ip + 1;
            continue :dispatch at(ip).op;
        },
        .jglobal => {
            const i = at(ip);
            ip = if (globals[i.bx()].tag != .undefined) jump(ip + 2, wordOffset(ip)) else ip + 2;
            continue :dispatch at(ip).op;
        },
        .stale => {
            frame.ip = ip;
            return staleCode(vm, proto);
        },
        _ => {
            frame.ip = ip;
            return vm.fail("bad instruction {d}", .{@intFromEnum(at(ip).op)});
        },
    }
}

fn arithOf(comptime op: code.Op) ops.Arith {
    return switch (op) {
        .add, .addk => .add,
        .sub, .subk => .sub,
        .mul, .mulk => .mul,
        .div, .divk => .div,
        .mod => .mod,
        .add_wrap => .add_wrap,
        .sub_wrap => .sub_wrap,
        .mul_wrap => .mul_wrap,
        .bit_and => .bit_and,
        .bit_or => .bit_or,
        .bit_xor => .bit_xor,
        .shl => .shl,
        .shr => .shr,
        else => unreachable,
    };
}
