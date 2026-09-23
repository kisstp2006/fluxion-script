// SPDX-License-Identifier: BSD-2-Clause

//! The IDE's colours: a dark window around the code, whose own colours are
//! the language's view's `Theme.dark`.

const ui = @import("fluxion_ui");

const Color = ui.Color;

pub const code = &@import("fluxion_script_ui").Theme.dark;

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

pub const ink = code.ink;
pub const dim = code.dim;
pub const faint = code.faint;
pub const error_ink = code.error_ink;
pub const warning_ink = code.warning_ink;
