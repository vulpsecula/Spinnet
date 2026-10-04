// An Emoji-shaped Plugin written against Candidate Contract collections r2:
// 1,906 items in nine categories, the size and shape of the external Emoji
// probe's data, with generated names in place of Unicode's. A search row
// above a sectioned grid; Return or a double-click inserts through a
// Requested Host Operation and records the emoji as recent; Copy is a
// standard item action the Host performs. Answers to typing carry the first
// 200 results and the Host asks for more as the user nears the end. Calling
// Emoji again while it is open keeps the search as the user left it and
// reads Recent again.
(() => {
  const ui = spinnet.ui, c = ui.components;
  const PAGE_SIZE = 200;
  const RECENT_LIMIT = 16;
  const CATEGORIES = [
    ["smileys-emotion", "Smileys & Emotion", 168],
    ["people-body", "People & Body", 386],
    ["animals-nature", "Animals & Nature", 159],
    ["food-drink", "Food & Drink", 135],
    ["travel-places", "Travel & Places", 218],
    ["activities", "Activities", 85],
    ["objects", "Objects", 264],
    ["symbols", "Symbols", 224],
    ["flags", "Flags", 267]
  ];
  const WORDS = {
    "smileys-emotion": ["grinning", "smile", "joy", "wink", "heart eyes", "kiss", "tears", "angry", "sleepy", "cool"],
    "people-body": ["hand", "person", "woman", "man", "child", "wave", "thumbs", "runner", "dancer", "family"],
    "animals-nature": ["cat", "cat face", "dog", "rabbit", "tiger", "flower", "tree", "leaf", "bird", "fish"],
    "food-drink": ["apple", "bread", "cheese", "coffee", "tea", "noodles", "cake", "grapes", "rice", "soup"],
    "travel-places": ["car", "train", "plane", "ship", "mountain", "house", "bridge", "rocket", "tent", "city"],
    "activities": ["ball", "medal", "game", "kite", "guitar", "trophy", "skate", "chess", "dice", "target"],
    "objects": ["phone", "book", "lamp", "key", "lock", "camera", "watch", "pencil", "bell", "gift"],
    "symbols": ["heart", "star", "arrow", "check", "cross", "circle", "square", "sign", "note", "spark"],
    "flags": ["flag", "banner", "pennant", "chequered", "pirate", "rainbow", "white", "black", "triangle", "crossed"]
  };
  const FIRST_CODE_POINT = 0x1F300;

  const ALL = [];
  let n = 0;
  for (const [category, , count] of CATEGORIES) {
    const words = WORDS[category];
    for (let i = 0; i < count; i++, n++) {
      const word = words[i % words.length];
      const round = Math.floor(i / words.length);
      const codePoint = FIRST_CODE_POINT + n;
      ALL.push({
        hex: codePoint.toString(16).toUpperCase(),
        emoji: String.fromCodePoint(codePoint),
        name: round === 0 ? word : word + " " + (round + 1),
        category
      });
    }
  }
  const BY_HEX = {};
  for (const e of ALL) BY_HEX[e.hex] = e;

  function matches(query, category) {
    const q = query.trim().toLowerCase();
    const inCategory = category === "all" ? ALL : ALL.filter((e) => e.category === category);
    if (q === "") return inCategory;
    const exact = [], prefix = [], other = [];
    for (const e of inCategory) {
      if (e.name === q || e.emoji === q) exact.push(e);
      else if (e.name.startsWith(q)) prefix.push(e);
      else if (e.name.includes(q)) other.push(e);
    }
    return exact.concat(prefix, other);
  }

  const item = (e, prefix) => c.item({ id: (prefix || "") + e.hex, title: e.name, symbol: e.emoji });

  function results(query, category, loaded, recent) {
    const found = matches(query, category);
    const shown = found.slice(0, loaded);
    const hasMore = shown.length < found.length;
    if (query.trim() !== "") return { found, options: { items: shown.map((e) => item(e)), hasMore } };
    const sections = [];
    if (category === "all" && recent.length > 0) {
      sections.push(c.section({ id: "recent", title: "Recent", items: recent.map((hex) => item(BY_HEX[hex], "recent:")) }));
    }
    for (const [id, title] of CATEGORIES) {
      const items = shown.filter((e) => e.category === id).map((e) => item(e));
      if (items.length > 0) sections.push(c.section({ id, title, items }));
    }
    if (sections.length === 0) return { found, options: { items: [], hasMore } };
    return { found, options: { sections, hasMore } };
  }

  function page(s, reset) {
    const { found, options } = results(s.query, s.category, s.loaded, s.recent);
    return ui.page({
      id: "search",
      title: "Emoji",
      showsInsertionTarget: true,
      reset,
      content: [
        c.row({ id: "bar", content: [
          c.textField({ id: "query", title: "Search", placeholder: "smile, cat, heart or an emoji", value: s.query,
                        collection: "results", status: found.length + " emoji" }),
          c.choiceField({ id: "category", title: "Category", value: s.category,
                          choices: ["all"].concat(CATEGORIES.map((x) => x[0])),
                          choiceTitles: ["All Categories"].concat(CATEGORIES.map((x) => x[1])) })
        ] }),
        c.grid(Object.assign({
          id: "results", columns: 8, rows: 6, emptyText: "No emoji match",
          actions: [
            c.itemAction({ id: "insert", title: "Insert", default: true }),
            c.itemAction({ id: "copy", title: "Copy", perform: "clipboard.write" })
          ]
        }, options))
      ]
    });
  }

  const kept = state || { query: "", category: "all", loaded: PAGE_SIZE, recent: [] };
  if (event === null) {
    const recent = spinnet.storage.get("recent") || [];
    const opened = { query: "", category: "all", loaded: PAGE_SIZE, recent };
    return ui.showPage(page(opened), { state: opened });
  }
  switch (event.type) {
    case "field_changed": {
      const next = Object.assign({}, kept, { query: event.values.query, category: event.values.category });
      // A new search starts on its first result; the field keeps what the
      // user typed, so it is never reset here.
      const changed = next.query !== kept.query || next.category !== kept.category;
      if (changed) next.loaded = PAGE_SIZE;
      return ui.showPage(page(next, changed ? ["results"] : undefined), { state: next });
    }
    case "load_more": {
      const next = Object.assign({}, kept, { loaded: Math.min(event.loaded + PAGE_SIZE, ALL.length) });
      return ui.showPage(page(next), { state: next });
    }
    case "called": {
      // The same page with no reset: what was typed, the selection and the
      // scroll stay, and Recent shows what was inserted since.
      const next = Object.assign({}, kept, { recent: spinnet.storage.get("recent") || [] });
      return ui.showPage(page(next), { state: next });
    }
    case "item_action": {
      const hex = event.item.id.replace(/^recent:/, "");
      const text = event.item.text || (BY_HEX[hex] && BY_HEX[hex].emoji) || hex;
      const recent = [hex].concat(kept.recent.filter((h) => h !== hex)).slice(0, RECENT_LIMIT);
      spinnet.storage.set({ key: "recent", value: recent });
      return ui.request(spinnet.selection.replace.operation({ text }, { id: "insert", closesView: true }));
    }
    default:
      return null;
  }
})()
