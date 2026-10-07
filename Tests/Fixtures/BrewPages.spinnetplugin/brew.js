// A Brew-shaped Plugin written against Candidate Contract collections r3: a
// searchable list of 800 generated formulae and casks with descriptions,
// versions and per-item actions (Upgrade only when outdated, Install only
// when not installed), which give the list's total and 150 at a time while
// the Host asks for the ranges the user scrolls to, and a detail page with its own
// ID from which Back returns to the list as the user left it. Install and
// Upgrade only say what a reviewed task would do (#88). Which packages the
// list shows first is the Plugin Setting `scope`, which a Menu Item may
// override, so "Outdated Packages" and "Installed Packages" can be two Menu
// Items of one Command; calling either while the list is open shows its
// scope in the same panel, keeping what was typed.
(() => {
  const ui = spinnet.ui, c = ui.components;
  const SLICE = 150;
  const STEMS = ["lib", "py", "node", "go", "rust", "open", "git", "zlib", "jpeg", "ffmpeg", "sqlite", "curl",
                 "wget", "pyenv", "pipx", "ruby", "lua", "perl", "qt", "gtk"];
  const TAILS = ["", "-utils", "-dev", "-cli", "@3.13", "@2", "-tools", "-core", "lite", "x", "-server", "-gui",
                 "-docs", "-extra", "-legacy", "-next", "fmt", "-ng", "-kit", "-plus", "-lab", "-shell", "-sync",
                 "-proxy", "-view", "-edit", "-mon", "-fs", "-net", "-db", "-ui", "-js", "-rs", "-go", "-py", "-ml",
                 "-io", "-gl", "-ssl", "-zip"];
  const PACKAGES = [];
  for (let t = 0; t < TAILS.length; t++) {
    for (let s = 0; s < STEMS.length; s++) {
      const index = PACKAGES.length;
      const name = STEMS[s] + TAILS[t];
      const installed = index % 4 === 0;
      PACKAGES.push({
        name,
        kind: index % 5 === 0 ? "cask" : "formula",
        description: "The " + STEMS[s] + " " + (TAILS[t] || "package").replace(/^[-@]/, "") + " for everyday work",
        version: (1 + (index % 7)) + "." + (index % 13) + "." + (index % 5),
        installed,
        outdated: installed && index % 3 === 0
      });
    }
  }
  const BY_NAME = {};
  for (const p of PACKAGES) BY_NAME[p.name] = p;

  function matching(query, scope) {
    const q = query.trim().toLowerCase();
    return PACKAGES.filter((p) =>
      (scope === "all" || (scope === "installed" && p.installed) || (scope === "outdated" && p.outdated))
      && (q === "" || p.name.includes(q)));
  }

  function item(p) {
    const actions = ["details"];
    if (!p.installed) actions.push("install");
    if (p.outdated) actions.push("upgrade");
    actions.push("copy");
    return c.item({ id: p.kind + ":" + p.name, title: p.name, subtitle: p.description,
                    accessory: p.outdated ? "Outdated" : p.version, text: p.name, actions,
                    icon: { symbol: p.kind === "cask" ? "macwindow" : "shippingbox" } });
  }

  function list(s, reset, start, count) {
    const found = matching(s.query, s.scope);
    const first = Math.min(start || 0, found.length);
    return ui.page({
      id: "packages", title: "Homebrew", reset,
      content: [
        c.row({ id: "bar", content: [
          c.textField({ id: "query", title: "Search", placeholder: "Search formulae and casks", value: s.query,
                        collection: "packages", status: found.length + " packages" }),
          c.choiceField({ id: "scope", title: "Show", value: s.scope, choices: ["installed", "outdated", "all"],
                          choiceTitles: ["Installed", "Outdated", "All"] })
        ] }),
        c.list({ id: "packages", rows: 8, emptyText: "No packages match", total: found.length, start: first,
                 items: found.slice(first, first + (count || SLICE)).map(item),
                 actions: [
                   c.itemAction({ id: "details", title: "Show Details", default: true }),
                   c.itemAction({ id: "install", title: "Install" }),
                   c.itemAction({ id: "upgrade", title: "Upgrade" }),
                   c.itemAction({ id: "copy", title: "Copy Name", perform: "clipboard.write" })
                 ] })
      ]
    });
  }

  function detail(p) {
    return ui.page({
      id: "package:" + p.name, title: p.name, subtitle: "Homebrew " + p.kind,
      content: [
        c.text({ id: "summary", text: "**" + p.description + "**\n\nVersion " + p.version
          + (p.installed ? (p.outdated ? ", installed and outdated." : ", installed.") : ", not installed.") }),
        c.actions({ id: "buttons", actions: [
          c.button({ id: "back", title: "Back" }),
          spinnet.open.url.action("https://formulae.brew.sh/" + p.kind + "/" + encodeURIComponent(p.name),
                                  { title: "Homepage" }),
          spinnet.clipboard.write.action(p.name, { title: "Copy Name" })
        ] })
      ]
    });
  }

  // A reviewed install or upgrade task (#88) as the Plugin would show it:
  // its stages and status, indeterminate because no package manager says
  // how far along a step is, and a cancel that asks to attempt
  // cancellation. Here the task never advances by itself; the state the
  // page is drawn from is the Plugin's.
  const STAGES = [
    { id: "download", title: "Download" }, { id: "pour", title: "Pour" },
    { id: "link", title: "Link" }, { id: "cleanup", title: "Clean Up" }
  ];

  function task(t) {
    return ui.page({
      id: "task:" + t.name, title: (t.verb === "install" ? "Install " : "Upgrade ") + t.name,
      content: [
        c.progress({ id: "task", title: (t.verb === "install" ? "Installing " : "Upgrading ") + t.name,
                     stages: STAGES, stage: t.stage, state: t.state,
                     status: t.state === "cancelling" ? "Attempting to stop; nothing is rolled back"
                       : t.state === "cancelled" ? "Stopped; what was done stays done" : "Waiting for a reviewed task",
                     cancel: { id: "cancel", title: "Cancel" } }),
        c.actions({ id: "buttons", actions: [c.button({ id: "back", title: "Back" })] })
      ]
    });
  }

  const called = (input && input.scope) || "installed";
  const kept = state || { query: "", scope: called };
  if (event === null) return ui.showPage(list(kept), { state: kept });
  switch (event.type) {
    case "called": {
      // Back to the list, from a detail page too. Another scope starts the
      // scope and the results again; the query stays as the user typed it.
      if (called === kept.scope) return ui.showPage(list(kept), { state: kept });
      const next = Object.assign({}, kept, { scope: called });
      return ui.showPage(list(next, ["scope", "packages"]), { state: next });
    }
    case "field_changed": {
      const next = Object.assign({}, kept, { query: event.values.query, scope: event.values.scope });
      return ui.showPage(list(next, ["packages"]), { state: next });
    }
    case "load_range":
      return ui.showPage(list(kept, undefined, event.start, event.count), { state: kept });
    case "item_action": {
      const p = BY_NAME[event.item.text];
      if (event.action === "details") return ui.showPage(detail(p), { state: kept });
      const next = Object.assign({}, kept, { task: { name: p.name, verb: event.action, stage: "download", state: "running" } });
      return ui.showPage(task(next.task), { state: next });
    }
    case "action_chosen":
      if (event.action === "back") return ui.showPage(list(kept), { state: kept });
      if (event.action === "cancel" && kept.task) {
        const next = Object.assign({}, kept, { task: Object.assign({}, kept.task, { state: "cancelling" }) });
        return ui.showPage(task(next.task), { state: next });
      }
      return null;
    default:
      return null;
  }
})()
