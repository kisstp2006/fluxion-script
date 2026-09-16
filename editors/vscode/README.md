# Flux for Visual Studio Code

The [Flux](../../README.md) scripting language in VS Code: colours as you
type, then everything `flux lsp` knows about the file.

- **Completions** - what is in scope; after `x.` the fields and methods of
  `x`'s type; after `.` where an enum goes, its members; in `Enemy{ . }` the
  fields not given yet; the types where a type is written.
- **Hovers** - the declaration, its types resolved, and its `///` doc.
- **Signature help** - the parameters of the call you are in, the current
  one marked.
- **Go to definition**, **find references**, **highlight** of every use.
- **Outline** of the file's structs, enums, functions and variables.
- **Diagnostics** as you type, with their notes and help.
- **Colouring by meaning** - a field, a parameter, a signal, an enum member
  - on top of the grammar's.

## Install

It needs the `flux` command: build it with `zig build` in the repository
(it is `zig-out/bin/flux`), and put it on the PATH or set `flux.path`.

```bash
cd editors/vscode
npm install
npx @vscode/vsce package
code --install-extension flux-language-0.1.0.vsix
```

Or, to try it from the source: open `editors/vscode` in VS Code and press
F5.
