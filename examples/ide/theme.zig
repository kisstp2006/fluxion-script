// SPDX-License-Identifier: BSD-2-Clause

//! The IDE's colours: a dark theme, its code coloured the way Godot's
//! script editor colours GDScript.

const ui = @import("fluxion_ui");
const service = @import("fluxion_script").service;

const Color = ui.Color;

pub const window: Color = .hex(0x15181D);
pub const panel: Color = .hex(0x1B1F25);
pub const toolbar: Color = .hex(0x23282F);
pub const border: Color = .hex(0x2E343D);
pub const button: Color = .hex(0x2E343D);
pub const button_hover: Color = .hex(0x3A4250);
pub const button_down: Color = .hex(0x4A5568);
pub const accent: Color = .hex(0x5AA9FF);
pub const run: Color = .hex(0x3FB950);
pub const stop: Color = .hex(0xE5534B);

pub const code: Color = .hex(0x1D2229);
pub const gutter: Color = .hex(0x1D2229);
pub const current_line: Color = .hex(0x252B34);
pub const selection: Color = .hexa(0x3E6CA870);
pub const caret: Color = .hex(0xE8E8EA);
pub const line_number: Color = .hex(0x5C6370);
pub const line_number_current: Color = .hex(0xABB2BF);

pub const ink: Color = .hex(0xCDCFD2);
pub const dim: Color = .hex(0x8A93A0);
pub const faint: Color = .hex(0x5C6370);

pub const error_ink: Color = .hex(0xFF6B6B);
pub const warning_ink: Color = .hex(0xFFC857);

pub const popup: Color = .hex(0x262C35);
pub const popup_selected: Color = .hex(0x33455F);
pub const tooltip: Color = .hex(0x2A303A);

/// The colour of a token of the kind the language service says it is.
pub fn token(t: service.TokenType, modifiers: service.Modifiers) Color {
    return switch (t) {
        .keyword => .hex(0xFF7085),
        .comment => if (modifiers.documentation) .hex(0x99B3CC) else .hex(0x6F7782),
        .string => .hex(0xFFEDA1),
        .number => .hex(0xA1FFE0),
        .operator => .hex(0xABC9FF),
        .decorator => .hex(0xFFB373),
        .type => .hex(0x8FFFDB),
        .@"struct", .@"enum" => .hex(0xC7FFED),
        .namespace => .hex(0x8FFFDB),
        .function, .method => if (modifiers.default_library) .hex(0x66E6FF) else .hex(0x57B3FF),
        .property => .hex(0xBCE0FF),
        .enum_member => .hex(0xA3D0FF),
        .event => .hex(0xE6A1FF),
        .parameter => .hex(0xF0C9A0),
        .variable => if (modifiers.readonly and !modifiers.declaration) .hex(0xD8DBE0) else ink,
    };
}

/// The letter and colour a completion shows its kind with.
pub fn kind(k: service.Kind) struct { []const u8, Color } {
    return switch (k) {
        .variable, .parameter => .{ "v", .hex(0xCDCFD2) },
        .constant => .{ "c", .hex(0xD8DBE0) },
        .function, .builtin_function, .@"test" => .{ "f", .hex(0x57B3FF) },
        .method, .builtin_method => .{ "m", .hex(0x57B3FF) },
        .field, .property => .{ "p", .hex(0xBCE0FF) },
        .signal => .{ "s", .hex(0xE6A1FF) },
        .@"struct" => .{ "S", .hex(0xC7FFED) },
        .@"enum" => .{ "E", .hex(0xC7FFED) },
        .enum_member => .{ "e", .hex(0xA3D0FF) },
        .module => .{ "M", .hex(0x8FFFDB) },
        .builtin_type => .{ "T", .hex(0x8FFFDB) },
        .keyword => .{ "k", .hex(0xFF7085) },
        .annotation => .{ "@", .hex(0xFFB373) },
    };
}
