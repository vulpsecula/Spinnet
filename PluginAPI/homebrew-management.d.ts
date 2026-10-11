// MIT. Typed tools.read additions; every URL and executable route is Host-owned.
export type PackageKind = "formula" | "cask";
export type HomebrewManagementReadInput =
  | { tool: "homebrew"; operation: "version" | "doctor" | "adoptionCandidates" }
  | { tool: "homebrew"; operation: "services"; kind?: "formula" }
  | { tool: "homebrew"; operation: "taps"; tap?: string }
  | { tool: "homebrew"; operation: "previewInstall" | "packageAnalytics"; kind: PackageKind; names: string[] }
  | { tool: "homebrew"; operation: "previewUpgrade"; kind: PackageKind; names: string[]; greedy?: boolean }
  | { tool: "homebrew"; operation: "previewUpgradeAll"; kind?: PackageKind; greedy?: boolean }
  | { tool: "homebrew"; operation: "adoptionPreview"; target: string; name: string }
  | { tool: "homebrew"; operation: "vulnerabilityDetail"; id: string }
  | { tool: "homebrew"; operation: "vulnerabilities"; names?: string[]; offset?: number };
export interface Advisory {
  id: string; summary?: string; details?: string; severity: "UNKNOWN" | "LOW" | "MEDIUM" | "HIGH" | "CRITICAL";
  url: string; aliases?: string[]; status?: "open" | "patched" | "unknown"; fixed_versions?: string[]; references?: string[]; detail_available?: boolean;
}
export interface ManagementReadBase { tool: "homebrew"; operation: HomebrewManagementReadInput["operation"]; version: string; available?: boolean; reason?: "requires_homebrew_7" | "requires_reviewed_homebrew_version"; truncated?: boolean; }
export type HomebrewManagementReadResult = ManagementReadBase & {
  features?: { vulnerabilities: boolean; doctorJSON: boolean; trust: boolean };
  taps?: { name: string; official: boolean; trusted: boolean; remote?: string; formula_count: number; cask_count: number; packages?: {kind: PackageKind; name: string}[]; truncated?: boolean }[];
  services?: { name: string; status: "started" | "scheduled" | "stopped" | "none" | "error" | "unknown" | "other"; user_owned: true }[];
  findings?: ({ id: string; text: string; guidance?: string; links: string[]; commands: string[]; repairs: { target: string; title: string }[] }
    | { name: string; installed_version: string; advisories: Advisory[]; open_count?: number; patched_count?: number; unknown_count?: number; upgrade_available?: boolean })[];
  applications?: { identity?: string; target: string; name: string; bundle_id: string; version: string; candidates?: {name: string; confidence: "ready" | "likely" | "unlikely" | "cannot"; reason: string}[] }[];
  fix_all?: {target: string; title: string; count: number};
  target?: string; name?: string; kind?: PackageKind; summary?: string; estimated?: false; dry_run?: true; succeeded?: boolean; exit_status?: number; stdout?: string; stderr?: string;
  stages?: {title: string; lines: string[]}[]; warnings?: string[];
  packages?: { name: string; kind: PackageKind; version?: string; installed_version?: string; dependencies?: string[]; homepage?: string; download_url?: string;
    installed_path?: string; linked?: boolean; linkable?: boolean; keg_only?: boolean; languages?: string[]; selected_language?: string }[];
  checked?: number; total?: number; offset?: number; next_offset?: number;
  skipped?: { name: string; reason: string }[]; advisory?: Advisory;
  rankings?: {name: string; analytics: {install?: {"30d"?: number; "90d"?: number; "365d"?: number}}}[];
  analytics?: { install: { "30d"?: number; "90d"?: number; "365d"?: number } };
};
