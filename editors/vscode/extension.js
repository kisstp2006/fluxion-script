// SPDX-License-Identifier: BSD-2-Clause

// Starts `flux lsp` for the .flux files VS Code opens: everything past the
// grammar's colours - completions, hovers, signatures, definitions,
// references, the outline, diagnostics and colouring by meaning - is its.

const vscode = require("vscode");
const { LanguageClient } = require("vscode-languageclient/node");

let client;

function activate(context) {
  const command = vscode.workspace.getConfiguration("flux").get("path") || "flux";
  client = new LanguageClient(
    "flux",
    "Flux",
    { command, args: ["lsp"] },
    { documentSelector: [{ scheme: "file", language: "flux" }] },
  );
  client.start();
  context.subscriptions.push(client);
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };
