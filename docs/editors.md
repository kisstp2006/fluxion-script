# Flux in an editor

Flux knows what each name in a file is while the file is being written:
what it names, its type, where it is declared, what could come next. Two
ways in:

- **`flux lsp`** answers the Language Server Protocol on standard input and
  output, for VS Code, Neovim, Helix, Sublime Text, Emacs, Zed and the rest.
- **`flux.service`** answers the same questions as function calls, for an
  editor built into a program - an engine's script editor.
  [`fluxion_script_code`](#the-editor-in-a-program) puts it in
  fluxion-code's editor, ready made, and [the IDE](#the-ide) in
  `examples/ide` is a window around that.

What either gives:

| | |
| --- | --- |
| Completions | what is in scope, innermost first; after `x.` the members of `x`'s type; after `Type.` or `module.` what they declare; after `.` where an enum goes, its members; in `Enemy{ . }` the fields not given yet; types where a type goes; `@import` and `@export` after `@` |
| Hover | the declaration with its types resolved - `fn Enemy.hit(self, amount: int) bool` - and its `///` doc; for what is built in, its signature and what it does |
| Signature help | the parameters of the call the cursor is in, the current one marked |
| Definition, references, highlights | through modules too: `enemies.spawn` leads into `enemies.flux` |
| Outline | structs and enums with their members, functions, variables, tests |
| Diagnostics | every error and warning the compiler has, with its notes and help, as you type |
| Semantic colours | each name by what it is: a field, a parameter, a signal, an enum member, a module |

It all comes from the compiler itself, run over the file with a listener
(`src/compile/Recorder.zig`) in a VM of its own that runs nothing, so what
the editor says is what `flux run` would. A file that does not parse yet is
still answered: a statement missing its `;` at the end of a line is kept,
and the line being typed has its open brackets closed before the compiler
sees it. A 130-line file is compiled and coloured in about a millisecond
and a 2,000-line one in about 12; a completion takes under half a
millisecond in the first and under 5 in the second.

## The IDE

```bash
zig build ide                     # an untitled script to try it in
zig build ide -- game.flux        # a file
```

[`examples/ide`](../examples/ide) is a small editor on
[fluxion-ui](https://github.com/kisstp2006/fluxion-ui), with the service
under it:

- completions as you type, locals first, each with how it is declared and its doc beside the list;
- the parameters of the call you are in, the one you are on lit; what a name is, when the mouse rests on it;
- mistakes underlined as they are made, and listed under the code - a click goes to one;
- the script's members down the left, a click away;
- F12, or ctrl and a click, to where a name is declared, in another file too;
- F5 to run the script, its output under the code, and Ctrl+S while it runs to put the new code in while it goes on.

| Key | What it does |
| --- | --- |
| Ctrl+Space | complete here |
| Enter, Tab | take the completion; Up and Down choose, Escape closes |
| F12, ctrl+click | go to the declaration |
| F5, Ctrl+S, Ctrl+O | run, save (and reload a running script), open |
| Ctrl+Z, Ctrl+Y | undo, redo |
| Ctrl+/ | comment the lines out, or back in |
| Tab, Shift+Tab | indent the selected lines, or take it away |

It reads a monospaced font of the system's - Consolas, DejaVu Sans Mono -
or the one `--font file.ttf` names. `--demo complete` (and `signature`,
`hover`, `problems`, `run`) has it show one of its tricks by itself.

## VS Code

`editors/vscode` is the extension: a TextMate grammar for colours at once,
and a language server for the rest - `flux lsp`, or for a script of a
Fluxion project (a `project.fluxion` in a folder above it) the Fluxion
editor's `--lsp`, which knows what the engine gives its scripts.

```bash
cd editors/vscode
npm install
npm run package
code --install-extension flux-language-0.1.0.vsix
```

It runs each from the PATH; the `flux.path` and `flux.editorPath` settings
point it elsewhere.

## Neovim (0.11 and later)

```lua
vim.filetype.add({ extension = { flux = "flux" } })
vim.lsp.config("flux", {
  cmd = { "flux", "lsp" },
  filetypes = { "flux" },
  root_markers = { ".git" },
})
vim.lsp.enable("flux")
```

Semantic colours come on by themselves; `:help lsp-semantic-highlight`
says how to theme them.

## Helix

In `languages.toml`:

```toml
[language-server.flux]
command = "flux"
args = ["lsp"]

[[language]]
name = "flux"
scope = "source.flux"
file-types = ["flux"]
comment-token = "//"
indent = { tab-width = 4, unit = "    " }
language-servers = ["flux"]
```

Helix colours with tree-sitter grammars, and Flux has none yet; the rest
works.

## Sublime Text

With the LSP package, in its settings:

```json
{
  "clients": {
    "flux": {
      "enabled": true,
      "command": ["flux", "lsp"],
      "selector": "source.flux"
    }
  }
}
```

## Emacs

With eglot:

```elisp
(define-derived-mode flux-mode prog-mode "Flux")
(add-to-list 'auto-mode-alist '("\\.flux\\'" . flux-mode))
(add-to-list 'eglot-server-programs '(flux-mode . ("flux" "lsp")))
```

## What `flux lsp` does

It keeps each file the editor has open and compiles it again at each
change, sending its diagnostics then. An import is read from the editor
when the imported file is open there - so what is typed in `enemies.flux`
is seen in `main.flux` before it is saved - and from disk otherwise. When a
file is saved, every open file is compiled again, since it may import it.
Scripts get the `os` module, as `flux run` gives it. Columns are counted
the way the client asks: UTF-8 if it offers it, else UTF-16.

## The service, in a program

```zig
const flux = @import("fluxion_script");
const service = flux.service;

// Compile a file to ask about it; keep it until the text changes.
const a = try service.Analysis.init(gpa, "player.flux", text, .{ .setup = .{ .run = giveGameModule } });
defer a.deinit();

for (a.diagnostics.items.items) |d| ...            // what is wrong
const tokens = try service.highlight.tokens(a, arena);   // how to colour it
const hover = try a.hover(arena, cursor);           // what is here
const decl = a.definition(cursor);                  // where it is declared
const uses = try a.references(arena, cursor);       // where else it is used
const outline = try a.symbols(arena);

// These compile a copy of the text with the cursor marked, so they take
// the text rather than an analysis.
const items = try service.complete(gpa, arena, "player.flux", text, cursor, options);
const sig = try service.signatureHelp(gpa, arena, "player.flux", text, cursor, options);
```

Offsets are bytes into the text. `options.setup` gives each VM the service
makes what the host gives its scripts - its natives and modules - so that
`@import("game")` completes; `options.loader` says where imports come from.

A program serves its own scripts to the editors above as `flux lsp` serves
any: a `flux.lsp.Server` with its options as `given`, run on its standard
input and output. The text of a file open in the editor is imported as it
is there; the rest comes through the program's loader.

```zig
var server: flux.lsp.Server = .init(gpa, io, stdout);
defer server.deinit();
server.given = .{ .setup = .{ .run = giveGameModule }, .loader = game_files };
return server.run(stdin);
```

## The editor, in a program

[fluxion-code](https://github.com/kisstp2006/fluxion-code) is a code editor
on fluxion-ui for any language: the text and its undo, the caret, the keys,
the view - rows, line numbers, selection, underlines, the completion list,
signatures, hovers, the find bar - measuring the text through the interface,
so a proportional font does as well as a monospaced one. A language tells it
what it knows as a `code.Language`. `fluxion_script_code`'s `Flux` is Flux's:
its words and rules, and the service asked as the text changes, with the
`options` a host gives its scripts.

```zig
// build.zig: made only for a dependant that asks for it.
const script = b.dependency("fluxion_script", .{ .target = target, .optimize = optimize, .code = true });
exe.root_module.addImport("fluxion_script", script.module("fluxion_script"));
exe.root_module.addImport("fluxion_script_code", script.module("fluxion_script_code"));
exe.root_module.addImport("fluxion_code", script.builder.dependency("fluxion_code", .{}).module("fluxion_code"));
```

```zig
const code = @import("fluxion_code");
const Flux = @import("fluxion_script_code").Flux;

// Where it will not move: the language points at it.
var flux_lang: Flux = .{ .options = options };
var ruler: code.Ruler = .{ .ui = &ui, .style = .{ .font_size = 15 } };
var doc: code.Document = try .init(gpa, "player.flux", text, flux_lang.language(), .{
    .font_size = 15,
    .line_height = 20,
    .measure = ruler.measure(),
});
var colours = code.Theme.dark;                 // or change some first
colours.popup = my_menu_colour;
// `font` is the code's face in the interface's font table - a monospaced
// one - and `prose_font` the docs'; give the ruler's style the same `font`.
const view: code.View = .{ .ids = .{ .code = "script-code" }, .theme = &colours, .font = mono };

// Each frame: time, keys, the pointer, then the view, then where it went.
doc.now = seconds;
_ = try doc.key(.enter, .{});                    // and doc.typeChar(c)
view.pointer(&doc, &ui, .{ .x = x, .y = y, .down = down, .pressed = pressed, .mods = .{} });
doc.refresh();
view.draw(&doc, &ui, focused);                 // inside your layout
_ = try ui.end();
view.measure(&doc, &ui, 1);
```

The ids name the view's elements, so two views - or a view among other
panels - do not clash.

A program that draws with a fluxion-ui of its own - an engine's, pinned
where the engine pins it - builds fluxion-code and Flux in it over that one
instead, so that its `Ui` and the view's are one type whatever either
package pins:

```zig
const script = b.dependency("fluxion_script", .{ .target = target, .optimize = optimize });
const code_dep = b.dependency("fluxion_code", .{ .target = target, .optimize = optimize });
const code = b.createModule(.{
    .root_source_file = code_dep.path("src/root.zig"),
    .imports = &.{
        // The engine's own: a module's imports are in its import table.
        .{ .name = "fluxion_ui", .module = engine.module("fluxion_engine").import_table.get("fluxion_ui").? },
        .{ .name = "fluxion_text", .module = script.module("fluxion_script").import_table.get("fluxion_text").? },
    },
});
const flux_code = b.createModule(.{
    .root_source_file = script.path("src/code.zig"),
    .imports = &.{
        .{ .name = "fluxion_script", .module = script.module("fluxion_script") },
        .{ .name = "fluxion_code", .module = code },
    },
});
```

The Fluxion editor builds it this way.
