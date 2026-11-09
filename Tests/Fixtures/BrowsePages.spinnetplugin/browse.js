// A list-and-detail Plugin: its Collection opts into selection_changed
// (ADR 0025), and the detail text follows the item the user moves to. With
// input {multiple: true} the Collection selects several items, and the
// detail shows every selected item's text. Drop First removes the first
// snippet, so an answer moves the selection. Settling on "danger" answers
// with an operation, which is refused: selection_changed is not a gesture.
(() => {
  const ui = spinnet.ui, c = ui.components;
  const multiple = !!(input && input.multiple);
  const SNIPPETS = ["alpha", "bravo", "charlie", "delta", "danger"];

  function page(s) {
    return ui.page({
      id: "browse", title: "Browse",
      content: [
        c.textField({ id: "note", title: "Note" }),
        c.list({ id: "snippets", selection: multiple ? "multiple" : undefined, selectionEvents: true,
                 items: s.snippets.map((id) => c.item({ id, title: id, text: id.toUpperCase() })),
                 actions: [c.itemAction({ id: "open", title: "Open", default: true })] }),
        c.actions({ id: "buttons", actions: [c.button({ id: "drop-first", title: "Drop First" })] }),
        c.text({ id: "detail", text: s.detail || "Nothing yet" })
      ]
    });
  }

  const kept = state || { snippets: SNIPPETS.slice(), detail: "" };
  const show = (next, extra) => ui.showPage(page(next), Object.assign({ state: next }, extra));
  if (event === null) return show(kept);
  switch (event.type) {
    case "selection_changed": {
      const ids = event.items.map((item) => item.id);
      if (ids.includes("danger")) {
        return show(kept, { operation: { perform: "clipboard.write", input: { text: "danger" } } });
      }
      return show(Object.assign({}, kept, { detail: event.items.map((item) => item.text).join(",") + " " + event.values.note }));
    }
    case "item_action":
      return show(Object.assign({}, kept, { detail: "opened " + event.item.id }));
    case "action_chosen":
      return show(Object.assign({}, kept, { snippets: kept.snippets.slice(1) }));
    default:
      return null;
  }
})()
