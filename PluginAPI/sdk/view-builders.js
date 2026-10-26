// SPDX-License-Identifier: MIT
// Pure form/detail View builders and invocation environment. No Host Service calls.
(function (requestHostService, environment) {
  "use strict";

  function area(wrappers) {
    return Object.freeze(wrappers);
  }

  // The view builders are pure: each returns a new plain object in the
  // shape PluginAPI/schemas/plugin-view.schema.json describes, leaving out
  // members that are undefined, and asks the Host for nothing. The Host
  // checks the view when the script answers with it.
  function compact(members) {
    const result = {};
    for (const key of Object.keys(members)) {
      if (members[key] !== undefined) result[key] = members[key];
    }
    return result;
  }

  function options(value) {
    return value === undefined || value === null ? {} : value;
  }

  function field(kind) {
    return function (value) {
      const o = options(value);
      return compact({ key: o.key, kind: kind, title: o.title, placeholder: o.placeholder, value: o.value,
                       accent: o.accent, status: o.status });
    };
  }

  function standardAction(perform, defaultTitle, member) {
    return function (value) {
      const o = options(value);
      const action = compact({
        title: o.title === undefined ? defaultTitle : o.title,
        perform: perform,
        shortcut: o.shortcut,
        closes_view: o.closesView
      });
      if (member) action[member] = o[member];
      return action;
    };
  }

  return Object.freeze({
    ui: area({
      view: function (value) {
        const o = options(value);
        return compact({ title: o.title, subtitle: o.subtitle, settings: o.settings, form: o.form,
                         detail: o.detail, actions: o.actions });
      },
      setting: function (key, value) {
        const o = options(value);
        return compact({ key: key, swap_with: o.swapWith });
      },
      form: function (value) {
        const o = options(value);
        return compact({ fields: o.fields, submit_title: o.submitTitle, submit_on_return: o.submitOnReturn });
      },
      textField: field("text"),
      multilineTextField: field("multiline_text"),
      urlField: field("url"),
      toggleField: field("toggle"),
      choiceField: function (value) {
        const o = options(value);
        return compact({ key: o.key, kind: "choice", title: o.title, choices: o.choices,
                         choice_titles: o.choiceTitles, value: o.value });
      },
      detail: function (value) {
        const o = options(value);
        return compact({ sections: o.sections });
      },
      section: function (value) {
        const o = options(value);
        return compact({ id: o.id, title: o.title, text: o.text, fetch: o.fetch });
      },
      action: function (value) {
        const o = options(value);
        return compact({ id: o.id, title: o.title, shortcut: o.shortcut });
      },
      copyText: standardAction("clipboard.write", "Copy", "text"),
      openURL: standardAction("open.url", "Open in Browser", "url"),
      insertText: standardAction("selection.replace", "Insert", "text"),
      openPluginSettings: standardAction("host.showPluginSettings", "Plugin Settings", null),
      show: function (view, value) {
        const o = options(value);
        return compact({ view: view, state: o.state, toast: o.toast });
      },
      toast: function (text) {
        return { toast: text };
      },
      close: function (value) {
        const o = options(value);
        return compact({ close: true, toast: o.toast });
      }
    }),
    environment: area({
      hostVersion: environment.hostVersion,
      preferredLanguage: environment.preferredLanguage
    })
  });
})
