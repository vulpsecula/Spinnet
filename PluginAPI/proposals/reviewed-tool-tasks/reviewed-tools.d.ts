// PROPOSAL ONLY (#72). SPDX-License-Identifier: MIT
//
// Draft types for the Level 2 additions under the reserved catalogue IDs
// tools.read, tools.startTask, activities.list and activities.stop, as #87
// and #88 would add them to spinnet-level-2.d.ts. Nothing here exists in
// spinnet-level-2.js; the shapes are reviewed-tools.schema.json's.

declare namespace SpinnetReviewedTools {
  type Tool = "homebrew";
  type PackageKind = "formula" | "cask";
  /** A bare official-tap name: /^[a-z0-9][a-z0-9+_.@-]*$/, at most 64 characters. */
  type PackageName = string;
  /** Opaque, never a process: /^task-[A-Za-z0-9]{8,32}$/. */
  type TaskHandle = string;

  type ReadInput =
    | { tool: Tool; operation: "installed"; kind?: PackageKind }
    | { tool: Tool; operation: "outdated"; kind?: PackageKind; greedy?: boolean }
    | { tool: Tool; operation: "search"; query: string; kind?: PackageKind }
    | { tool: Tool; operation: "info"; kind: PackageKind; names: PackageName[] };

  interface Package {
    kind: PackageKind;
    /** Bare for an official tap, user/repository/name otherwise. */
    name: string;
    tap?: string;
    official?: true;
    title?: string;
    description?: string;
    version?: string;
    installed_version?: string;
    outdated?: true;
    pinned?: true;
    auto_updates?: true;
    deprecated?: true;
    disabled?: true;
    needs_privileges?: true;
    quits_app?: true;
  }

  interface ReadResult {
    tool: Tool;
    operation: ReadInput["operation"];
    /** At most 2,000; search gives kind and name only. */
    packages: Package[];
    not_found?: PackageName[];
    truncated?: true;
  }

  interface StartTaskInput {
    tool: Tool;
    operation: "install" | "upgrade";
    kind: PackageKind;
    name: PackageName;
  }

  type Stage = "starting" | "fetching" | "installing" | "linking" | "finishing" | "stopping";

  interface TaskResult {
    outcome: "completed" | "failed" | "stopped" | "interrupted" | "unknown";
    reason?: Reason;
    /** stopped only: which signal ended it. Nothing is ever rolled back. */
    stop?: "interrupted" | "terminated" | "killed";
  }

  interface Activity {
    task: TaskHandle;
    tool: Tool;
    operation: "install" | "upgrade";
    kind: PackageKind;
    name: PackageName;
    state: "running" | "stopping" | "ended";
    stage?: Stage;
    elapsed_seconds?: number;
    /** At most 20 redacted lines of at most 200 characters. */
    log?: string[];
    result?: TaskResult;
  }

  type Reason =
    | "capability_denied" | "command_unavailable" | "host_service_failed"
    | "tool_missing" | "tool_busy" | "tool_timed_out" | "tool_failed" | "output_too_large"
    | "package_not_found" | "source_not_allowed" | "needs_privileges" | "already_installed" | "not_outdated"
    | "task_not_found" | "task_finished";

  interface StartTaskFinished {
    type: "operation_finished";
    operation?: string;
    perform: "tools.startTask";
    outcome: "succeeded" | "refused" | "declined" | "expired" | "cancelled" | "failed";
    reason?: Reason;
    /** succeeded only: the task started; its end is reported by its Activity. */
    task?: TaskHandle;
    view_closed?: true;
  }

  /** Waits on #71: the latest state of one of the Plugin's tasks, while its view is visible. */
  interface ActivityChanged {
    type: "activity_changed";
    activity: Activity;
  }

  interface OperationOptions {
    id?: string;
    closesView?: boolean;
    notify?: boolean;
  }
}

/** Proposed members of the Level 2 `spinnet` object. */
interface SpinnetLevelTwoReviewedTools {
  tools: {
    /** A call inside the invocation; fails with tool_timed_out after 3 s. */
    read(input: SpinnetReviewedTools.ReadInput): SpinnetReviewedTools.ReadResult;
    startTask: {
      /** Only as a Requested Host Operation or page action: it always asks a Host Confirmation. */
      operation(input: SpinnetReviewedTools.StartTaskInput, options?: SpinnetReviewedTools.OperationOptions): object;
      action(input: SpinnetReviewedTools.StartTaskInput, options?: SpinnetReviewedTools.OperationOptions): object;
    };
  };
  activities: {
    /** The Plugin's own tasks, running first, at most 8. */
    list(): { activities: SpinnetReviewedTools.Activity[] };
    stop: {
      operation(input: { task: SpinnetReviewedTools.TaskHandle }, options?: Omit<SpinnetReviewedTools.OperationOptions, "closesView">): object;
      action(input: { task: SpinnetReviewedTools.TaskHandle }, options?: Omit<SpinnetReviewedTools.OperationOptions, "closesView">): object;
    };
  };
}
