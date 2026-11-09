// A compose page (#127): a multi-line body and an urgent toggle. Each change
// updates the status under the body with its line count and the toggle;
// Copy copies the note, prefixed when urgent. Clear resets the body.
(() => {
  const ui = spinnet.ui, c = ui.components;

  function page(s, reset) {
    return ui.page({
      id: "compose", title: "Compose", reset: reset,
      content: [
        c.multilineTextField({ id: "body", title: "Note", placeholder: "Write a note…", value: "Dear team,\n",
                               status: s.status, accent: s.urgent ? "red" : undefined }),
        c.toggleField({ id: "urgent", title: "Urgent", value: false }),
        c.actions({ id: "buttons", actions: [c.button({ id: "copy", title: "Copy" }),
                                              c.button({ id: "clear", title: "Clear" })] })
      ]
    });
  }

  const kept = state || { status: "1 line", urgent: false };
  const show = (next, extra) => ui.showPage(page(next, extra && extra.reset), Object.assign({ state: next }, extra));
  if (event === null) return show(kept);
  const lines = (text) => text.split("\n").filter((line) => line.length > 0).length;
  switch (event.type) {
    case "field_changed": {
      const body = event.values.body, urgent = event.values.urgent === true;
      return show({ status: lines(body) + (lines(body) === 1 ? " line" : " lines") + (urgent ? ", urgent" : ""),
                    urgent: urgent });
    }
    case "action_chosen":
      if (event.action === "clear") return show({ status: "Cleared", urgent: kept.urgent }, { reset: ["body"] });
      return show(kept, { operation: { perform: "clipboard.write",
                                       input: { text: (event.values.urgent ? "URGENT\n" : "") + event.values.body } } });
    default:
      return null;
  }
})()
