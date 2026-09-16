// SPDX-License-Identifier: BSD-2-Clause

//! Bytecode as text, for `flux disasm`: to see what the compiler made of a
//! function, and whether the typed instructions it hoped for are there.

const std = @import("std");
const Writer = std.Io.Writer;

const Vm = @import("vm/Vm.zig");
const code = @import("vm/code.zig");
const Instr = code.Instr;
const object = @import("vm/object.zig");
const format = @import("vm/format.zig");

pub fn module(w: *Writer, vm: *Vm, m: *object.Module) Writer.Error!void {
    if (m.main) |p| try proto(w, vm, p, 0);
    for (m.globals.items) |g| switch (g.tag) {
        .function => try proto(w, vm, g.as(object.Closure).proto, 0),
        .class => {
            const c = g.as(object.Class);
            var it = c.methods.valueIterator();
            while (it.next()) |v| try proto(w, vm, v.as(object.Closure).proto, 0);
            var statics = c.statics.valueIterator();
            while (statics.next()) |v| if (v.tag == .function) try proto(w, vm, v.as(object.Closure).proto, 0);
            if (c.defaults) |d| try proto(w, vm, d.proto, 0);
        },
        .enum_type => {
            var it = g.as(object.EnumType).methods.valueIterator();
            while (it.next()) |v| try proto(w, vm, v.as(object.Closure).proto, 0);
        },
        else => {},
    };
}

fn constant(w: *Writer, v: @import("vm/value.zig").Value) Writer.Error!void {
    format.value(w, v, true, 8) catch return error.WriteFailed;
}

pub fn proto(w: *Writer, vm: *Vm, p: *object.Proto, depth: usize) Writer.Error!void {
    try w.splatByteAll(' ', depth * 2);
    try w.writeAll("fn ");
    if (p.class) |c| try w.print("{s}.", .{c.name.bytes()});
    try w.print("{s}: {d} params ({d} required), {d} registers, {d} constants, {d} caches{s}\n", .{
        p.name.bytes(), p.params, p.required, p.regs, p.constants.len, p.caches.len, if (p.coroutine) ", coroutine" else "",
    });
    var i: usize = 0;
    var last_line: u32 = 0;
    while (i < p.code.len) {
        const ins = Instr.of(p.code[i]);
        const pos = vm.sources.position(p.file, if (i < p.spans.len) p.spans[i].start else 0);
        try w.splatByteAll(' ', depth * 2);
        if (pos.line != last_line) {
            try w.print("{d:>5} ", .{pos.line});
            last_line = pos.line;
        } else try w.writeAll("      ");
        try w.print("{d:>4}  {s:<12}", .{ i, @tagName(ins.op) });
        const width = code.width(ins.op);
        switch (ins.op) {
            .loadk, .getglobal, .setglobal, .jglobal, .closure, .newinstance, .check, .check_param => {
                try w.print(" {d} {d}", .{ ins.a, ins.bx() });
                if (ins.op == .loadk or ins.op == .newinstance) {
                    try w.writeAll("    ; ");
                    try constant(w, p.constants[ins.bx()]);
                }
                if (ins.op == .getglobal or ins.op == .setglobal or ins.op == .jglobal) if (p.module) |m| if (ins.bx() < m.names.items.len) try w.print("    ; {s}", .{m.names.items[ins.bx()].bytes()});
                if (ins.op == .jglobal) try w.print(", if set to {d}", .{@as(isize, @intCast(i + 2)) + @as(i32, @bitCast(p.code[i + 1]))});
            },
            .loadi, .loadf, .jtrue, .jfalse, .jnull, .jnotnull, .jerr, .jnoterr, .for_prep, .for_loop, .iter_prep, .iter_next, .jargs => {
                try w.print(" {d} {d}", .{ ins.a, ins.sbx() });
                if (ins.op != .loadi and ins.op != .loadf) try w.print("    ; to {d}", .{@as(isize, @intCast(i + 1)) + ins.sbx()});
            },
            .jmp => try w.print(" {d}    ; to {d}", .{ ins.jump(), @as(isize, @intCast(i + 1)) + ins.jump() }),
            else => {
                try w.print(" {d} {d} {d}", .{ ins.a, ins.b, ins.c });
                if (width == 2) {
                    const extra = p.code[i + 1];
                    switch (ins.op) {
                        .getprop, .setprop, .getmethod => {
                            const x: code.Extra = @bitCast(extra);
                            try w.print("    ; .{s}", .{p.constants[x.name].as(object.String).bytes()});
                        },
                        .newlist, .is, .format, .make_error => try w.print("    ; {d}", .{extra}),
                        else => try w.print("    ; to {d}", .{@as(isize, @intCast(i + 2)) + @as(i32, @bitCast(extra))}),
                    }
                }
            },
        }
        try w.writeByte('\n');
        i += width;
    }
    for (p.protos) |child| try proto(w, vm, child, depth + 1);
}
