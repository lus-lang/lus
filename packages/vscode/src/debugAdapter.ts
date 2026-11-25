import * as path from "node:path";
import * as vscode from "vscode";

/**
 * Registers the `lus` debug type. A debug session runs `lus debug`, which
 * speaks the Debug Adapter Protocol on its standard input and output and
 * takes the program, its arguments, and its working directory from the
 * launch request.
 */
export function registerDebugger(context: vscode.ExtensionContext): void {
  context.subscriptions.push(
    vscode.debug.registerDebugAdapterDescriptorFactory("lus", new AdapterFactory()),
    vscode.debug.registerDebugConfigurationProvider("lus", new ConfigurationProvider()),
  );
}

/** The `lus` command named by the `lus.executablePath` setting. */
export function lusExecutable(folder: vscode.WorkspaceFolder | undefined): string {
  const configured = vscode.workspace
    .getConfiguration("lus", folder)
    .get<string>("executablePath", "lus")
    .trim();
  const command = configured === "" ? "lus" : configured;
  // A relative path with a directory part is relative to the workspace.
  if (folder && !path.isAbsolute(command) && /[\\/]/.test(command)) {
    return path.join(folder.uri.fsPath, command);
  }
  return command;
}

class AdapterFactory implements vscode.DebugAdapterDescriptorFactory {
  createDebugAdapterDescriptor(
    session: vscode.DebugSession,
  ): vscode.ProviderResult<vscode.DebugAdapterDescriptor> {
    const folder = session.workspaceFolder;
    const cwd =
      typeof session.configuration.cwd === "string"
        ? session.configuration.cwd
        : folder?.uri.fsPath;
    return new vscode.DebugAdapterExecutable(
      lusExecutable(folder),
      ["debug"],
      cwd ? { cwd } : undefined,
    );
  }
}

class ConfigurationProvider implements vscode.DebugConfigurationProvider {
  resolveDebugConfiguration(
    _folder: vscode.WorkspaceFolder | undefined,
    config: vscode.DebugConfiguration,
  ): vscode.ProviderResult<vscode.DebugConfiguration> {
    // Starting a session with no launch.json debugs the active Lus file.
    if (!config.type && !config.request && !config.name) {
      const editor = vscode.window.activeTextEditor;
      if (editor?.document.languageId === "lus") {
        config.type = "lus";
        config.name = "Debug Lus File";
        config.request = "launch";
        config.program = "${file}";
      }
    }
    if (!config.program) {
      void vscode.window.showErrorMessage(
        "Set 'program' in the launch configuration to the Lus script to debug.",
      );
      return undefined;
    }
    return config;
  }
}
