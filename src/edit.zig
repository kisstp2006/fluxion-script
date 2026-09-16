// SPDX-License-Identifier: BSD-2-Clause

//! A code editor for Flux, without the drawing: the text and its undo, the
//! caret, the keys, and what the language service says as the text changes -
//! colours, mistakes, the outline, completions, signatures and hovers.
//!
//! An interface draws a `Code` and hands it keys, characters and the
//! pointer. It measures the text for it through `Metrics`, so any font does,
//! monospaced or not. `fluxion_script_ui` is that interface on fluxion-ui:
//! the mini IDE in `examples/ide` and the fluxion editor both draw with it.

pub const Buffer = @import("edit/Buffer.zig");
pub const Code = @import("edit/Code.zig");
pub const Metrics = Code.Metrics;
pub const Measure = Code.Measure;
pub const Problem = Code.Problem;
pub const Key = Code.Key;
pub const Mods = Code.Mods;

test {
    _ = Buffer;
    _ = Code;
}
