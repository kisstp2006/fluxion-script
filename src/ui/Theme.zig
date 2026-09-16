// SPDX-License-Identifier: BSD-2-Clause

//! The colours a code view draws with. `dark` colours Flux the way Godot's
//! script editor colours GDScript; a program with colours of its own starts
//! from it and changes what it has - its popups', its selection's - and
//! keeps the code's.

const ui = @import("fluxion_ui");
const service = @import("fluxion_script").service;

const Color = ui.Color;
const Theme = @This();

/// Behind the code, and the line numbers beside it.
code: Color,
gutter: Color,
current_line: Color,
selection: Color,
caret: Color,
line_number: Color,
line_number_current: Color,

/// Text that is not a token of its own, and quieter text.
ink: Color,
dim: Color,
faint: Color,

error_ink: Color,
warning_ink: Color,

/// The lists and tooltips over the code.
popup: Color,
popup_selected: Color,
hover: Color,
tooltip: Color,
border: Color,
/// The argument of a call the caret is in, in the signature over it.
accent: Color,

/// Each kind of token.
keyword: Color,
comment: Color,
doc_comment: Color,
string: Color,
number: Color,
operator: Color,
annotation: Color,
type: Color,
declared_type: Color,
function: Color,
library_function: Color,
property: Color,
enum_member: Color,
signal: Color,
parameter: Color,
constant: Color,

pub const dark: Theme = .{
    .code = .hex(0x1D2229),
    .gutter = .hex(0x1D2229),
    .current_line = .hex(0x252B34),
    .selection = .hexa(0x3E6CA870),
    .caret = .hex(0xE8E8EA),
    .line_number = .hex(0x5C6370),
    .line_number_current = .hex(0xABB2BF),

    .ink = .hex(0xCDCFD2),
    .dim = .hex(0x8A93A0),
    .faint = .hex(0x5C6370),

    .error_ink = .hex(0xFF6B6B),
    .warning_ink = .hex(0xFFC857),

    .popup = .hex(0x262C35),
    .popup_selected = .hex(0x33455F),
    .hover = .hex(0x3A4250),
    .tooltip = .hex(0x2A303A),
    .border = .hex(0x2E343D),
    .accent = .hex(0x5AA9FF),

    .keyword = .hex(0xFF7085),
    .comment = .hex(0x6F7782),
    .doc_comment = .hex(0x99B3CC),
    .string = .hex(0xFFEDA1),
    .number = .hex(0xA1FFE0),
    .operator = .hex(0xABC9FF),
    .annotation = .hex(0xFFB373),
    .type = .hex(0x8FFFDB),
    .declared_type = .hex(0xC7FFED),
    .function = .hex(0x57B3FF),
    .library_function = .hex(0x66E6FF),
    .property = .hex(0xBCE0FF),
    .enum_member = .hex(0xA3D0FF),
    .signal = .hex(0xE6A1FF),
    .parameter = .hex(0xF0C9A0),
    .constant = .hex(0xD8DBE0),
};

/// The colour of a token of the kind the language service says it is.
pub fn token(t: *const Theme, kind_of: service.TokenType, modifiers: service.Modifiers) Color {
    return switch (kind_of) {
        .keyword => t.keyword,
        .comment => if (modifiers.documentation) t.doc_comment else t.comment,
        .string => t.string,
        .number => t.number,
        .operator => t.operator,
        .decorator => t.annotation,
        .type, .namespace => t.type,
        .@"struct", .@"enum" => t.declared_type,
        .function, .method => if (modifiers.default_library) t.library_function else t.function,
        .property => t.property,
        .enum_member => t.enum_member,
        .event => t.signal,
        .parameter => t.parameter,
        .variable => if (modifiers.readonly and !modifiers.declaration) t.constant else t.ink,
    };
}

/// The letter and colour a completion, an outline row or a symbol shows its
/// kind with.
pub fn kind(t: *const Theme, k: service.Kind) struct { []const u8, Color } {
    return switch (k) {
        .variable, .parameter => .{ "v", t.ink },
        .constant => .{ "c", t.constant },
        .function, .builtin_function, .@"test" => .{ "f", t.function },
        .method, .builtin_method => .{ "m", t.function },
        .field, .property => .{ "p", t.property },
        .signal => .{ "s", t.signal },
        .@"struct" => .{ "S", t.declared_type },
        .@"enum" => .{ "E", t.declared_type },
        .enum_member => .{ "e", t.enum_member },
        .module => .{ "M", t.type },
        .builtin_type => .{ "T", t.type },
        .keyword => .{ "k", t.keyword },
        .annotation => .{ "@", t.annotation },
    };
}
