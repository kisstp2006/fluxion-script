// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const diag = @import("../diag.zig");

pub const Span = diag.Span;

pub const Name = struct {
    text: []const u8,
    span: Span,
};

pub const TypeExpr = struct {
    span: Span,
    kind: Kind,

    pub const Kind = union(enum) {
        name: []const u8,
        member: struct { module: []const u8, name: []const u8 },
        optional: *TypeExpr,
        error_union: *TypeExpr,
        list: *TypeExpr,
        map: struct { key: *TypeExpr, value: *TypeExpr },
        func: struct { params: []const *TypeExpr, ret: ?*TypeExpr },
    };
};

pub const UnaryOp = enum { neg, not, bit_not };

pub const BinaryOp = enum {
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
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    @"and",
    @"or",
    in,

    pub fn symbol(op: BinaryOp) []const u8 {
        return switch (op) {
            .add => "+",
            .sub => "-",
            .mul => "*",
            .div => "/",
            .mod => "%",
            .add_wrap => "+%",
            .sub_wrap => "-%",
            .mul_wrap => "*%",
            .bit_and => "&",
            .bit_or => "|",
            .bit_xor => "^",
            .shl => "<<",
            .shr => ">>",
            .eq => "==",
            .ne => "!=",
            .lt => "<",
            .le => "<=",
            .gt => ">",
            .ge => ">=",
            .@"and" => "and",
            .@"or" => "or",
            .in => "in",
        };
    }

    pub fn isComparison(op: BinaryOp) bool {
        return switch (op) {
            .eq, .ne, .lt, .le, .gt, .ge => true,
            else => false,
        };
    }
};

pub const FPart = union(enum) {
    literal: []const u8,
    expr: struct { value: *Expr, spec: []const u8 },
};

pub const MapEntry = struct { key: *Expr, value: *Expr };

pub const FieldInit = struct { name: Name, value: *Expr };

pub const Capture = struct {
    name: Name,
};

pub const Expr = struct {
    span: Span,
    kind: Kind,

    pub const Kind = union(enum) {
        int: i64,
        float: f64,
        bool: bool,
        null,
        string: []const u8,
        fstring: []const FPart,
        enum_literal: Name,
        error_literal: struct { name: Name, message: ?*Expr },
        ident: []const u8,
        self,
        list: []const *Expr,
        map: []const MapEntry,
        struct_literal: struct { type: *Expr, fields: []const FieldInit },
        unary: struct { op: UnaryOp, operand: *Expr },
        binary: struct { op: BinaryOp, lhs: *Expr, rhs: *Expr },
        is_type: struct { value: *Expr, type: *TypeExpr },
        @"orelse": struct { lhs: *Expr, rhs: *Expr },
        @"catch": struct { lhs: *Expr, capture: ?Name, rhs: *Expr },
        @"try": *Expr,
        @"await": *Expr,
        call: struct { callee: *Expr, args: []const *Expr },
        index: struct { target: *Expr, index: *Expr },
        slice: struct { target: *Expr, start: ?*Expr, end: ?*Expr },
        field: struct { target: *Expr, name: Name },
        unwrap: *Expr,
        @"if": struct { cond: *Expr, capture: ?Name, then: *Expr, @"else": *Expr },
        @"switch": *Switch,
        lambda: *Fn,
        builtin: struct { name: Name, args: []const *Expr },
        range: struct { start: *Expr, end: ?*Expr, inclusive: bool },
        block: *Block,
        @"return": ?*Expr,
        @"break": ?Name,
        @"continue": ?Name,
        invalid,
    };
};

pub const SwitchProng = struct {
    span: Span,
    cases: []const Case,
    is_else: bool,
    capture: ?Name,
    body: *Expr,

    pub const Case = union(enum) {
        value: *Expr,
        range: struct { from: *Expr, to: *Expr },
    };
};

pub const Switch = struct {
    subject: *Expr,
    prongs: []const SwitchProng,
};

pub const Block = struct {
    span: Span,
    stmts: []const *Stmt,
};

pub const Annotation = struct {
    name: Name,
    args: []const *Expr,
};

pub const VarDecl = struct {
    span: Span,
    is_const: bool,
    name: Name,
    type: ?*TypeExpr,
    value: ?*Expr,
    annotations: []const Annotation,
    doc: ?[]const u8,
};

pub const Param = struct {
    name: Name,
    type: ?*TypeExpr,
    default: ?*Expr,
    is_self: bool,
};

pub const Fn = struct {
    span: Span,
    name: ?Name,
    params: []const Param,
    ret: ?*TypeExpr,
    body: Body,
    annotations: []const Annotation,
    doc: ?[]const u8,

    pub const Body = union(enum) {
        block: *Block,
        expr: *Expr,
    };

    pub fn hasSelf(f: *const Fn) bool {
        return f.params.len > 0 and f.params[0].is_self;
    }
};

pub const Signal = struct {
    span: Span,
    name: Name,
    params: []const Param,
    doc: ?[]const u8,
};

pub const Struct = struct {
    span: Span,
    name: Name,
    parent: ?*TypeExpr,
    fields: []const *VarDecl,
    consts: []const *VarDecl,
    methods: []const *Fn,
    signals: []const Signal,
    annotations: []const Annotation,
    doc: ?[]const u8,
};

pub const EnumMember = struct {
    name: Name,
    value: ?*Expr,
};

pub const Enum = struct {
    span: Span,
    name: Name,
    members: []const EnumMember,
    methods: []const *Fn,
    annotations: []const Annotation,
    doc: ?[]const u8,
};

pub const Test = struct {
    span: Span,
    name: []const u8,
    body: *Block,
};

pub const AssignOp = enum { set, add, sub, mul, div, mod, add_wrap, sub_wrap, mul_wrap, bit_and, bit_or, bit_xor, shl, shr };

pub const Stmt = struct {
    span: Span,
    kind: Kind,

    pub const Kind = union(enum) {
        expr: *Expr,
        @"var": *VarDecl,
        assign: struct { target: *Expr, op: AssignOp, value: *Expr },
        block: *Block,
        @"if": struct { cond: *Expr, capture: ?Name, then: *Stmt, else_capture: ?Name, @"else": ?*Stmt },
        @"while": struct { label: ?Name, cond: *Expr, capture: ?Name, next: ?*Stmt, body: *Stmt },
        @"for": struct { label: ?Name, iterable: *Expr, value: Name, index: ?Name, body: *Stmt },
        @"switch": *Switch,
        @"defer": struct { body: *Stmt, on_error: bool },
        @"fn": *Fn,
        @"struct": *Struct,
        @"enum": *Enum,
        @"test": *Test,
        invalid,
    };
};

pub const Module = struct {
    stmts: []const *Stmt,
};

pub fn assignToBinary(op: AssignOp) ?BinaryOp {
    return switch (op) {
        .set => null,
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .add_wrap => .add_wrap,
        .sub_wrap => .sub_wrap,
        .mul_wrap => .mul_wrap,
        .bit_and => .bit_and,
        .bit_or => .bit_or,
        .bit_xor => .bit_xor,
        .shl => .shl,
        .shr => .shr,
    };
}
