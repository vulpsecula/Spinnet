// Typing Probe: a Smart Jump-like form for measuring View Sessions (W13 #60).
// Each pause in typing delivers `field_changed`, and the answer recognizes the
// text as Smart Jump does, entirely in the script: a DOI, a sum, a local
// path, a web address, or else a search. It keeps what it needs in `state`,
// so the helper may retire between events.
(() => {
  const ui = spinnet.ui;

  // A small arithmetic parser: + - * / % ^, parentheses and decimals.
  // It answers null for anything that is not a whole expression.
  function calculate(text) {
    if (!/^[\d\s+\-*/%^().,]+$/.test(text) || !/[+\-*/%^]/.test(text.replace(/^\s*-/, ""))) return null;
    const tokens = text.replace(/,/g, "").match(/\d+(?:\.\d+)?|[+\-*/%^()]/g) || [];
    let index = 0;
    const peek = () => tokens[index];
    const take = () => tokens[index++];
    function primary() {
      const token = take();
      if (token === "(") {
        const value = sum();
        if (take() !== ")") throw new Error("unbalanced");
        return value;
      }
      if (token === "-") return -primary();
      if (token === undefined || !/^\d/.test(token)) throw new Error("unexpected");
      return Number(token);
    }
    function power() {
      const base = primary();
      if (peek() === "^") { take(); return Math.pow(base, power()); }
      return base;
    }
    function product() {
      let value = power();
      while (peek() === "*" || peek() === "/" || peek() === "%") {
        const operator = take();
        const right = power();
        value = operator === "*" ? value * right : operator === "/" ? value / right : value % right;
      }
      return value;
    }
    function sum() {
      let value = product();
      while (peek() === "+" || peek() === "-") {
        value = take() === "+" ? value + product() : value - product();
      }
      return value;
    }
    try {
      const value = sum();
      return index === tokens.length && Number.isFinite(value) ? value : null;
    } catch (error) {
      return null;
    }
  }

  // What the text would open, in code spans so the Markdown subset leaves
  // it as typed.
  function recognize(query) {
    const text = query.trim();
    if (text === "") return "Type a link, a sum or a search";
    const doi = text.match(/\b10\.\d{4,9}\/[^\s"<>`]+/);
    if (doi) return `DOI: \`https://doi.org/${doi[0]}\``;
    if (!text.startsWith("/")) {
      const result = calculate(text);
      if (result !== null) return `Calculation: \`${text} = ${Math.round(result * 1e10) / 1e10}\``;
    }
    if (/^~?\//.test(text)) return `Path: \`${text}\``;
    const web = text.match(/\b(?:https?:\/\/)?(?:[a-z0-9-]+\.)+[a-z]{2,}(?::\d+)?(?:\/[^\s`]*)?/i);
    if (web && !text.slice(web.index + web[0].length).startsWith("(")) {
      const address = /^https?:\/\//i.test(web[0]) ? web[0] : `https://${web[0]}`;
      return `Link: \`${address.replace(/[.,;:!?]+$/, "")}\``;
    }
    return `Search: \`https://www.google.com/search?q=${encodeURIComponent(text)}\``;
  }

  function show(next) {
    const view = ui.view({
      title: "Typing Probe",
      subtitle: `${next.query.length} ${next.query.length === 1 ? "character" : "characters"}`,
      form: ui.form({
        submitTitle: "Recognize",
        fields: [ui.textField({ key: "query", title: "Query", placeholder: "A link, a sum or a search", value: next.query })]
      }),
      detail: ui.detail({ sections: [ui.section({ id: "status", title: "Recognized", text: recognize(next.query) })] }),
      actions: [ui.action({ id: "again", title: "Recognize Again", shortcut: "cmd+r" })]
    });
    return ui.show(view, { state: next });
  }

  if (event === null) return show({ query: "", answered: 0 });
  const current = state || { query: "", answered: 0 };
  switch (event.type) {
    case "field_changed":
    case "submitted":
      return show({ query: String(event.values.query ?? ""), answered: current.answered + 1 });
    case "action_chosen":
      return event.action === "again" ? show(Object.assign({}, current, { answered: current.answered + 1 })) : null;
    default:
      return null;
  }
})()
