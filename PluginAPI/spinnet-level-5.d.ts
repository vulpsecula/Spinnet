// SPDX-License-Identifier: MIT
export * from "./spinnet-level-4";
/** Arguments for apps.perform({bundle_id:"com.apple.Terminal", operation:"homebrew", arguments}). Requested operations only. */
export type TerminalHomebrewArguments = {
  command: "list" | "outdated" | "search" | "info" | "update" | "upgrade" | "install" | "uninstall" | "adopt" | "services" | "tap" | "untap" | "doctor" | "cleanup" | "autoremove" | "config" | "version";
  package?: string;
  kind?: "formula" | "cask";
  action?: "list" | "start" | "stop" | "restart" | "info";
}
