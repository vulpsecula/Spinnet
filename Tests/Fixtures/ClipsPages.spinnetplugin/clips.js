// A clipboard-history-shaped Plugin using a Collection with multiple
// selection (ADR 0025): the user selects several snippets and acts on them
// at once. Each Item Action runs once for the whole selection: Open shows
// what was opened, Pin toggles a mark on every selected snippet unless all
// carry it, Remove takes them all out, and Rename acts on one snippet only.
// Copy and Insert are performed by the Host on the snippets' texts, one per
// line. A note field and a Remove Selected button report the selection as a
// list of IDs.
(() => {
  const ui = spinnet.ui, c = ui.components;
  const SNIPPETS = ["alpha", "bravo", "charlie", "delta", "echo"];

  function page(s, reset) {
    return ui.page({
      id: "clips", title: "Clips", reset,
      content: [
        c.textField({ id: "note", title: "Note", placeholder: "Press Return to tag the selection" }),
        c.list({ id: "clips", selection: "multiple", selected: s.preselected.filter((id) => s.snippets.includes(id)), emptyText: "No snippets",
                 items: s.snippets.map((id) => c.item({ id, title: id, text: id.toUpperCase(),
                                                        marks: s.pinned.includes(id) ? ["pinned"] : undefined })),
                 actions: [
                   c.itemAction({ id: "open", title: "Open", default: true }),
                   c.itemAction({ id: "pin", title: "Pin", toggle: "pinned" }),
                   c.itemAction({ id: "remove", title: "Remove" }),
                   c.itemAction({ id: "rename", title: "Rename", single: true }),
                   c.itemAction({ id: "copy", title: "Copy", perform: "clipboard.write", notify: true }),
                   c.itemAction({ id: "insert", title: "Insert", perform: "selection.replace" })
                 ] }),
        c.actions({ id: "buttons", actions: [c.button({ id: "remove-selected", title: "Remove Selected" })] }),
        c.text({ id: "last", text: s.last || "Nothing yet" })
      ]
    });
  }

  const kept = state || { snippets: SNIPPETS.slice(), pinned: [], preselected: ["bravo", "delta"], last: "" };
  const show = (next, reset) => ui.showPage(page(next, reset), { state: next });
  if (event === null) return show(kept);
  const ids = (items) => items.map((item) => item.id);
  switch (event.type) {
    case "item_action": {
      const chosen = ids(event.items);
      const said = event.action + " " + chosen.join(",") + " from " + event.item.id;
      if (event.action === "pin") {
        // Set the mark on all unless all already carry it, then clear it on all.
        const all = event.items.every((item) => (item.marks || []).includes("pinned"));
        const pinned = all ? kept.pinned.filter((id) => !chosen.includes(id))
          : kept.pinned.concat(chosen.filter((id) => !kept.pinned.includes(id)));
        return show(Object.assign({}, kept, { pinned, last: said }));
      }
      if (event.action === "remove") {
        return show(Object.assign({}, kept, { snippets: kept.snippets.filter((id) => !chosen.includes(id)), last: said }));
      }
      return show(Object.assign({}, kept, { last: said }));
    }
    case "operation_finished":
      return show(Object.assign({}, kept, {
        last: event.perform + " " + event.outcome + " " + ids(event.items || []).join(",") + " from " + event.item.id
      }));
    case "action_chosen":
      return show(Object.assign({}, kept, {
        snippets: kept.snippets.filter((id) => !event.selection.clips.includes(id)),
        last: "removed " + event.selection.clips.join(",")
      }));
    case "submitted":
      return show(Object.assign({}, kept, { last: event.values.note + " " + event.selection.clips.join(",") }));
    default:
      return null;
  }
})()
