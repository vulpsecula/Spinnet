// View Gallery: every Plugin View component and View Event, for tests and
// the manual check. It builds its views only with spinnet.ui and keeps what
// it needs between events in `state`, so the helper may retire in between.
(() => {
  const ui = spinnet.ui;
  const tone = input && input.tone === "warm" ? "Warm" : "Plain";
  const shout = Boolean(input && input.shout);
  const empty = { name: "", note: "", link: "", formal: false, size: "m" };

  function greeting(values) {
    const name = values.name.trim() || "there";
    const text = `${values.formal ? "Good day" : tone === "Warm" ? "Hi, lovely" : "Hello"}, ${name}`;
    return shout ? `${text.toUpperCase()}!` : `${text}.`;
  }

  function formView(values, subtitle) {
    return ui.view({
      title: "View Gallery",
      subtitle: subtitle || `Tone: ${tone}${shout ? ", shouting" : ""}`,
      // A swap button between the two choices exchanges their values.
      settings: [ui.setting("tone"), ui.setting("shout"), ui.setting("from", { swapWith: "into" }), ui.setting("into")],
      form: ui.form({
        submitTitle: "Greet",
        fields: [
          ui.textField({ key: "name", title: "Name", placeholder: "Who to greet", value: values.name }),
          ui.multilineTextField({ key: "note", title: "Note", placeholder: "Anything else", value: values.note }),
          ui.urlField({ key: "link", title: "Link", placeholder: "https://example.com", value: values.link }),
          ui.toggleField({ key: "formal", title: "Formal", value: values.formal }),
          ui.choiceField({ key: "size", title: "Size", choices: ["s", "m", "l"],
                           choiceTitles: ["Small", "Medium", "Large"], value: values.size })
        ]
      }),
      actions: [
        ui.action({ id: "detail", title: "Show Detail", shortcut: "cmd+d" }),
        ui.action({ id: "clear", title: "Clear", shortcut: "cmd+k" }),
        ui.action({ id: "close", title: "Close" }),
        ui.openPluginSettings()
      ]
    });
  }

  function detailView(values, count, delivered) {
    const text = greeting(values);
    const sections = [
      ui.section({ id: "greeting", title: "Greeting", text: `**${text}**` }),
      ui.section({
        id: "subset",
        title: "Markdown",
        text: "*Italic*, __bold__, `inline code` and a [link to Spinnet](https://github.com/vulpsecula/Spinnet).\n"
          + "```\nlet block = \"code\"\n```"
      }),
      ui.section({
        id: "outside",
        title: "Outside the Subset",
        text: "# Not a heading\n- not a list\n![not an image](https://example.com/a.png)\n<b>not HTML</b>"
      }),
      ui.section({ id: "count", title: "Count", text: `Counted ${count} ${count === 1 ? "time" : "times"}.` })
    ];
    if (values.link) sections.push(ui.section({ id: "link", title: "Your Link", text: `[${values.link}](${values.link})` }));
    if (delivered !== null) sections.push(ui.section({ id: "delivered", title: "Delivered", text: delivered }));
    const actions = [
      ui.copyText({ text: text, shortcut: "cmd+shift+c" }),
      ui.openURL({ title: "Open Spinnet", url: "https://github.com/vulpsecula/Spinnet" }),
      ui.insertText({ text: text, closesView: true }),
      ui.action({ id: "count", title: "Count", shortcut: "cmd+n" }),
      ui.action({ id: "fetched", title: "Fetch", shortcut: "cmd+f" }),
      ui.action({ id: "form", title: "Back to Form", shortcut: "cmd+b" }),
      ui.openPluginSettings()
    ];
    return ui.view({ title: "View Gallery", subtitle: `Tone: ${tone}`, settings: [ui.setting("tone"), ui.setting("shout")],
                     detail: ui.detail({ sections: sections }), actions: actions });
  }

  // Host-Fetched Sections: the Host sends both requests at once. It shows
  // the `show` answer itself; the `deliver` response comes back as a
  // `section_delivered` event, and the section shows the text answered.
  const profile = { method: "GET", url: "https://api.github.com/users/octocat",
                    headers: { Accept: "application/vnd.github+json" } };

  function fetchedView(delivered) {
    return ui.view({
      title: "View Gallery",
      subtitle: "Host-Fetched Sections",
      detail: ui.detail({ sections: [
        ui.section({ id: "name", title: "Shown by the Host",
                     fetch: { request: profile, mode: "show", pointer: "/name", error_pointer: "/message", cache: true } }),
        ui.section({ id: "repos", title: "Delivered to the Plugin", text: delivered === null ? undefined : delivered,
                     fetch: { request: profile, mode: "deliver" } })
      ] }),
      actions: [ui.action({ id: "detail", title: "Back to Detail", shortcut: "cmd+b" })]
    });
  }

  function delivery(response) {
    if (response.status < 200 || response.status >= 300) return `The service answered ${response.status}`;
    const profile = JSON.parse(response.body);
    return `**${profile.login}** has ${profile.public_repos} public repositories.`;
  }

  function show(next, toast) {
    const view = next.screen === "fetched"
      ? fetchedView(next.delivered)
      : next.screen === "detail"
        ? detailView(next.values, next.count, next.delivered)
        : formView(next.values, next.subtitle);
    return ui.show(view, { state: next, toast: toast });
  }

  if (event === null) {
    if (commandID === "gallery.toast") return ui.toast("View Gallery says hello");
    const screen = commandID === "gallery.detail" ? "detail" : "form";
    return show({ screen: screen, values: empty, count: 0, delivered: null, subtitle: null });
  }

  const current = state || { screen: "form", values: empty, count: 0, delivered: null, subtitle: null };
  switch (event.type) {
    case "field_changed": {
      const typed = String(event.values[event.field] ?? "");
      return show(Object.assign({}, current, {
        values: event.values,
        subtitle: `Editing ${event.field}: ${typed.length} ${typed.length === 1 ? "character" : "characters"}`
      }));
    }
    case "submitted":
      return show(Object.assign({}, current, { screen: "detail", values: event.values }), greeting(event.values));
    case "action_chosen":
      switch (event.action) {
        case "detail": return show(Object.assign({}, current, { screen: "detail", delivered: null }));
        case "fetched": return show(Object.assign({}, current, { screen: "fetched", delivered: null }));
        case "form": return show(Object.assign({}, current, { screen: "form", subtitle: null }));
        case "clear": return show(Object.assign({}, current, { values: empty, subtitle: "Cleared" }), "Cleared");
        case "count": return show(Object.assign({}, current, { count: current.count + 1 }));
        case "close": return ui.close({ toast: "View Gallery closed" });
        default: return null;
      }
    case "setting_changed":
      // The Host stored the setting already; `input` holds the new value.
      return show(current, `${event.key} is now ${JSON.stringify(event.value)}`);
    case "settings_swapped":
      return show(current, `Swapped ${event.keys.join(" and ")}`);
    case "section_delivered":
      return show(Object.assign({}, current, {
        delivered: current.screen === "fetched"
          ? delivery(event.response)
          : `Section ${event.section} delivered ${JSON.stringify(event.response)}`
      }));
    default:
      return null;
  }
})()
