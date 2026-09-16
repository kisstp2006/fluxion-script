// SPDX-License-Identifier: BSD-2-Clause

//! The instruction set. One 32-bit word each - an opcode and three bytes of
//! operands, or an opcode, a byte and sixteen bits - and a second word for
//! the few that carry a jump or a cache. R is the frame's registers, K its
//! constants, U its closure's captured variables, G its module's variables.

const std = @import("std");

pub const Op = enum(u8) {
    nop,
    /// R[A] = R[B]
    move,
    /// R[A] = K[Bx]
    loadk,
    /// R[A] = int(sBx)
    loadi,
    /// R[A] = float(sBx)
    loadf,
    /// R[A..=A+B] = null
    loadnull,
    loadtrue,
    loadfalse,
    /// R[A] = U[B]
    getupval,
    /// U[B] = R[A]
    setupval,
    /// R[A] = G[Bx], refused while its initializer has not run
    getglobal,
    /// G[Bx] = R[A]
    setglobal,
    /// if G[Bx] has a value, jump by the next word: a reload skips the
    /// initializer of a variable whose value it kept
    jglobal,

    /// R[A] = R[B] op R[C], any operand types
    add,
    sub,
    mul,
    div,
    mod,
    add_wrap,
    sub_wrap,
    mul_wrap,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    /// R[A] = R[B] op K[C]
    addk,
    subk,
    mulk,
    divk,
    /// R[A] = R[B] + sC, any type
    addi,
    /// R[A] = op R[B]
    neg,
    not,
    bit_not,

    /// Typed: both operands known ints, overflow checked.
    add_ii,
    sub_ii,
    mul_ii,
    div_ii,
    mod_ii,
    /// R[A] = R[B] + sC, R[B] known int
    addi_i,
    neg_i,
    /// Typed: both known floats.
    add_ff,
    sub_ff,
    mul_ff,
    div_ff,
    neg_f,
    /// R[A] = float(R[B]), R[B] known int
    to_float,
    /// R[A] = R[B] * sC and R[B] % sC, R[B] known int
    muli_i,
    modi_i,
    /// Typed vectors: both operands known vec2, or vec2 and a float.
    add_v2,
    sub_v2,
    mul_v2,
    mul_v2f,
    div_v2f,
    add_v3,
    sub_v3,
    mul_v3,
    mul_v3f,
    div_v3f,

    /// R[A] = R[B] cmp R[C], a bool
    eq,
    ne,
    lt,
    le,
    lt_ii,
    le_ii,
    eq_ii,
    lt_ff,
    le_ff,
    /// R[A] = R[B] == K[C]
    eqk,
    nek,

    /// if (R[A] cmp R[B]) jump by the next word
    jeq,
    jne,
    jlt,
    jle,
    jlt_ii,
    jle_ii,
    jeq_ii,
    jne_ii,
    jlt_ff,
    jle_ff,
    /// if (R[A] cmp sB) jump, R[A] known int
    jlti,
    jlei,
    jgti,
    jgei,
    /// if (R[A] == K[B]) jump
    jeqk,
    jnek,

    /// jump by the signed 24 bits of A, B and C
    jmp,
    /// if R[A] is true (it must be a bool) jump by sBx
    jtrue,
    jfalse,
    jnull,
    jnotnull,
    jerr,
    jnoterr,

    /// R[A] = R[A](R[A+1] .. R[A+B]); C = 1 runs a coroutine in this task
    call,
    /// if the frame was given more than A arguments, jump by sBx
    jargs,
    /// return R[A]
    ret,
    retnull,
    /// R[A] = a closure of the prototype at Bx
    closure,
    /// close every captured variable at R[A] and above
    close,

    /// R[A] = a list with room for B, elements checked by the next word
    newlist,
    /// append R[B] .. R[B+C-1] to R[A]
    append,
    /// R[A] = a map with room for B
    newmap,
    /// R[A] = R[B][R[C]]
    getindex,
    /// R[A][R[B]] = R[C]
    setindex,
    /// Typed list with a known int index.
    getlist,
    setlist,
    /// R[A] = R[B][R[C] .. R[C+1]]
    slice,
    /// R[A] = R[B].len
    len,

    /// R[A] = R[B].fields[C]
    getfield,
    /// R[A].fields[B] = R[C]
    setfield,
    /// R[A] = R[B].K[w.name], through the cache w.cache
    getprop,
    /// R[A].K[w.name] = R[B]
    setprop,
    /// R[A] = method K[w.name] of R[B]; R[A+1] = R[B]
    getmethod,
    /// R[A] = a new instance of the class K[Bx]
    newinstance,
    /// R[A] = float(component C of the vector R[B])
    getcomp,
    /// component B of the vector R[A] = float(R[C])
    setcomp,

    /// R[A] = the text of R[B] .. R[B+C-1], each formatted by the spec in
    /// K[w.specs + i]
    format,
    /// panic unless R[A] passes check Bx; ints become floats where floats are wanted
    check,
    /// the same for parameter A, named in the message
    check_param,
    /// R[A] = R[B], or panic if it is null
    unwrap,
    /// R[A] = R[B] is check w
    is,
    /// R[A] = R[B] in R[C]
    in,
    /// R[A] = await R[B]
    @"await",
    /// R[A] = error K[next word] with the message R[B]
    make_error,

    /// Counting: R[A] from, R[A+1] to; R[A+2] = the loop's copy. Jump by sBx when empty.
    for_prep,
    /// R[A] += 1; if R[A] < R[A+1] { R[A+2] = R[A]; jump back by sBx }
    for_loop,
    /// Walking: R[A] the list, map or string, R[A+1] the position; jump by sBx when done.
    iter_prep,
    /// R[A+2] = next item, R[A+3] = its index or key; jump back by sBx while there is one
    iter_next,

    /// panic: this is code a reload replaced, and the new code changed
    /// what it relies on
    stale,

    _,
};

pub const Instr = packed struct(u32) {
    op: Op,
    a: u8,
    b: u8,
    c: u8,

    pub fn abc(op: Op, a: u8, b: u8, c: u8) Instr {
        return .{ .op = op, .a = a, .b = b, .c = c };
    }

    pub fn abx(op: Op, a: u8, wide: u16) Instr {
        return .{ .op = op, .a = a, .b = @truncate(wide), .c = @truncate(wide >> 8) };
    }

    pub fn asbx(op: Op, a: u8, signed: i16) Instr {
        return abx(op, a, @bitCast(signed));
    }

    pub fn sj(op: Op, offset: i24) Instr {
        const bits: u24 = @bitCast(offset);
        return .{ .op = op, .a = @truncate(bits), .b = @truncate(bits >> 8), .c = @truncate(bits >> 16) };
    }

    pub inline fn bx(i: Instr) u16 {
        return @as(u16, i.b) | (@as(u16, i.c) << 8);
    }

    pub inline fn sbx(i: Instr) i16 {
        return @bitCast(i.bx());
    }

    pub inline fn sc(i: Instr) i8 {
        return @bitCast(i.c);
    }

    pub inline fn sB(i: Instr) i8 {
        return @bitCast(i.b);
    }

    pub inline fn jump(i: Instr) i24 {
        const bits: u24 = @as(u24, i.a) | (@as(u24, i.b) << 8) | (@as(u24, i.c) << 16);
        return @bitCast(bits);
    }

    pub inline fn word(i: Instr) u32 {
        return @bitCast(i);
    }

    pub inline fn of(w: u32) Instr {
        return @bitCast(w);
    }
};

/// The second word of `getprop`, `setprop` and `getmethod`.
pub const Extra = packed struct(u32) {
    name: u16,
    cache: u16,
};

/// Which instructions take a second word.
pub fn width(op: Op) u8 {
    return switch (op) {
        .jeq, .jne, .jlt, .jle, .jlt_ii, .jle_ii, .jeq_ii, .jne_ii, .jlt_ff, .jle_ff, .jlti, .jlei, .jgti, .jgei, .jeqk, .jnek, .jglobal => 2,
        .getprop, .setprop, .getmethod, .format, .is, .newlist, .make_error => 2,
        else => 1,
    };
}

test "operands survive the round trip" {
    const i = Instr.abx(.loadk, 3, 0xBEEF);
    try std.testing.expectEqual(@as(u16, 0xBEEF), Instr.of(i.word()).bx());
    try std.testing.expectEqual(@as(i16, -5), Instr.asbx(.loadi, 0, -5).sbx());
    try std.testing.expectEqual(@as(i24, -1_000_000), Instr.sj(.jmp, -1_000_000).jump());
    try std.testing.expectEqual(Op.loadk, Instr.of(i.word()).op);
}
