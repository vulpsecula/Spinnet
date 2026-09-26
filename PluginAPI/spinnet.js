// The spinnet SDK object, Plugin API Level 1.
// SPDX-License-Identifier: MIT
//
// The helper evaluates this file before every script and calls the function
// it evaluates to with the raw `requestHostService` call and the invocation's
// environment. What the function returns becomes the script's `spinnet`
// global. `spinnet.d.ts` describes it.
//
// Each wrapper requests exactly one Host Service, with its argument as the
// service's input, unchanged, and returns the service's answer. It therefore
// fails exactly as `requestHostService` does: a refused Capability or System
// Permission ends the whole invocation, even if the script catches the error.
// Only a Plugin Storage write over a limit throws an error the script may
// catch, with `code` "storage_limit_exceeded".
//
// To add a wrapper, give it a camelCase name in the area it belongs to, name
// its service with `service(...)`, and declare it in `spinnet.d.ts` with an
// `@service` tag.
(function (requestHostService, environment) {
  "use strict";

  function service(name) {
    return function (input) {
      return requestHostService(name, input === undefined ? null : input);
    };
  }

  function area(wrappers) {
    return Object.freeze(wrappers);
  }

  return Object.freeze({
    selection: area({
      readText: service("read_selected_text"),
      replace: service("insert_text")
    }),
    clipboard: area({
      read: service("read_current_clipboard"),
      write: service("write_clipboard"),
      history: service("read_clipboard_history"),
      historyContent: service("read_clipboard_history_content"),
      // Opens the Clipboard History window, a Host Surface.
      showHistory: service("present_clipboard_history")
    }),
    window: area({
      read: service("read_focused_window"),
      setFrame: service("set_focused_window_frame"),
      toggleFullScreen: service("toggle_focused_window_full_screen"),
      restore: service("restore_focused_window_frame")
    }),
    open: area({
      url: service("open_url"),
      path: service("open_local_path")
    }),
    http: area({
      request: service("https_request")
    }),
    // Reviewed App Interface operations and Deep Link Templates.
    apps: area({
      perform: service("perform_app_operation"),
      openDeepLink: service("open_deep_link")
    }),
    text: area({
      detectLanguage: service("detect_language")
    }),
    screen: area({
      capture: service("capture_screen")
    }),
    // Plugin Storage: the Plugin's own JSON values, kept between invocations.
    storage: area({
      get: service("get_storage_value"),
      set: service("set_storage_value"),
      remove: service("remove_storage_value"),
      keys: service("list_storage_keys"),
      clear: service("clear_storage")
    }),
    // Pure builders for Plugin Views and standard actions; no Host call (W11 #58).
    ui: area({}),
    environment: area({
      apiLevel: environment.apiLevel,
      hostVersion: environment.hostVersion,
      preferredLanguage: environment.preferredLanguage,
      pluginID: environment.pluginID,
      commandID: environment.commandID,
      actionID: environment.actionID,
      invocationID: environment.invocationID
    })
  });
})
