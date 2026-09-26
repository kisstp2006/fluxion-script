# Flux for Visual Studio Code

The [Flux](https://github.com/kisstp2006/fluxion-script#readme) scripting
language in VS Code: colours as you type, then everything its language
server knows about the file.

- **Completions** - what is in scope; after `x.` the fields and methods of
  `x`'s type; after `.` where an enum goes, its members; in `Enemy{ . }` the
  fields not given yet; the types where a type is written; after a lone `@`,
  the annotations.
- **Hovers** - the declaration, its types resolved, and its `///` doc.
- **Signature help** - the parameters of the call you are in, the current
  one marked.
- **Go to definition**, **find references**, **highlight** of every use.
- **Outline** of the file's structs, enums, functions and variables.
- **Diagnostics** as you type, with their notes and help.
- **Colouring by meaning** - a field, a parameter, a signal, an enum member
  - on top of the grammar's.

## A Fluxion project's scripts

A `.flux` file under a folder with a `project.fluxion` in it is a script of
that project, and the [Fluxion editor](https://github.com/kisstp2006/fluxion-editor-v2)
serves it - `fluxion-editor --lsp <the project's folder>`, with no window -
with what the engine gives its scripts: `app`, `self.entity`, the components
by their types (`self.entity.get(Sprite)`), an input event's kinds after
`is`, the enums, the methods the engine calls - offered whole where a
struct's member is written - and the `res://` files a script imports. It is
what the editor's Code panel checks the scripts with, so a mistake here is
one the game would refuse.

Any other `.flux` file is served by `flux lsp`, with the `os` module that
`flux run` gives a script.

## Install

The Fluxion editor's Project ▸ Open project in code editor writes
`flux.editorPath` into the project's `.vscode/settings.json` itself, so a
project opened from it needs nothing set. Otherwise each server is found on
the PATH, or where a setting says:

- `flux.editorPath` - the Fluxion editor, for a project's scripts
  (`fluxion-editor` by default);
- `flux.path` - the `flux` command, built with `zig build` in this
  repository as `zig-out/bin/flux` (`flux` by default).

One that is not there is said once, with a button to the setting.

```bash
cd editors/vscode
npm install
npm run package
code --install-extension flux-language-0.1.0.vsix
```

Or, to try it from the source: open `editors/vscode` in VS Code and press
F5.
