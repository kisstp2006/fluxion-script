// SPDX-License-Identifier: BSD-2-Clause

// Flux in VS Code. A .flux file in a Fluxion project - under a folder with a
// project.fluxion in it - is served by the Fluxion editor's `--lsp`, which
// knows what the engine gives its scripts; any other by `flux lsp`. Past the
// grammar's colours - completions, hovers, signatures, definitions,
// references, the outline, diagnostics and colouring by meaning - is theirs.

const vscode = require("vscode");
const fs = require("fs");
const path = require("path");
const { LanguageClient } = require("vscode-languageclient/node");

// The servers running, by the folder they serve: a project's, or for a
// file in no project, the folder it is in.
const clients = new Map();
// The commands not found, told once each.
const told = new Set();

function activate(context) {
  context.subscriptions.push(
    vscode.workspace.onDidOpenTextDocument(serve),
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration("flux")) restart();
    }),
    { dispose: stopAll },
  );
  vscode.workspace.textDocuments.forEach(serve);
}

function deactivate() {
  return stopAll();
}

// Starts the server `document` wants, unless it runs already.
function serve(document) {
  if (document.languageId !== "flux" || document.uri.scheme !== "file") return;
  const file = document.uri.fsPath;
  const project = projectOf(file);
  const folder = project || path.dirname(file);
  if (clients.has(folder)) return;
  const config = vscode.workspace.getConfiguration("flux");
  const server = project
    ? found(config.get("editorPath"), "fluxion-editor", "flux.editorPath", "The Fluxion editor serves the scripts of a Fluxion project")
    : found(config.get("path"), "flux", "flux.path", "`flux` serves Flux scripts");
  if (!server) return;
  const client = new LanguageClient(
    "flux",
    "Flux",
    { command: server, args: project ? ["--lsp", project] : ["lsp"] },
    // A project's files, however deep; a lone folder's, and none under it,
    // which may be a project's.
    { documentSelector: [{ scheme: "file", language: "flux", pattern: glob(folder) + (project ? "/**/*.flux" : "/*.flux") }] },
  );
  clients.set(folder, client);
  client.start().catch((err) => {
    clients.delete(folder);
    vscode.window.showErrorMessage(`Flux: ${server} did not start: ${err.message}`);
  });
}

// The folder with a project.fluxion that `file` is in, or null.
function projectOf(file) {
  let at = path.dirname(file);
  for (;;) {
    if (fs.existsSync(path.join(at, "project.fluxion"))) return at;
    const up = path.dirname(at);
    if (up === at) return null;
    at = up;
  }
}

// The program a setting names - a path to it, or its name on the PATH -
// or, with none set, `name` on the PATH. Null, said once, when it is not
// there.
function found(setting, name, key, what) {
  const wanted = setting || name;
  const command = wanted.includes("/") || wanted.includes("\\") ? (isFile(wanted) ? wanted : null) : onPath(wanted);
  if (command) return command;
  if (!told.has(key)) {
    told.add(key);
    vscode.window
      .showErrorMessage(`Flux: ${what}, and \`${wanted}\` is not there. Put it on the PATH, or set ${key} to where it is.`, "Open Settings")
      .then((picked) => {
        if (picked) vscode.commands.executeCommand("workbench.action.openSettings", key);
      });
  }
  return null;
}

function onPath(name) {
  const endings = process.platform === "win32" ? ["", ...(process.env.PATHEXT || ".EXE;.CMD;.BAT").split(";")] : [""];
  for (const dir of (process.env.PATH || "").split(path.delimiter)) {
    if (!dir) continue;
    for (const ending of endings) {
      const candidate = path.join(dir, name + ending);
      if (isFile(candidate)) return candidate;
    }
  }
  return null;
}

function isFile(at) {
  try {
    return fs.statSync(at).isFile();
  } catch {
    return false;
  }
}

// A folder as a glob matches it: forward slashes, and the characters a glob
// reads each in a class of its own.
function glob(folder) {
  return folder.replace(/\\/g, "/").replace(/[[\]{}*?]/g, (c) => `[${c}]`);
}

function stopAll() {
  const stopping = [...clients.values()].map((c) => c.stop().catch(() => {}));
  clients.clear();
  return Promise.all(stopping);
}

// Settings changed: every server again, as they now say.
async function restart() {
  await stopAll();
  told.clear();
  vscode.workspace.textDocuments.forEach(serve);
}

module.exports = { activate, deactivate };
