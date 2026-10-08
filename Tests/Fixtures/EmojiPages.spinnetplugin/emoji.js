// An Emoji-shaped Plugin written against Candidate Contract collections r3:
// 1,906 items in nine categories, the size and shape of the external Emoji
// probe's data, with generated names in place of Unicode's. A search row
// above a sectioned grid that gives its total and one slice of its items:
// the Host keeps a window of them and asks for the rest with load_range.
// Return or a double-click inserts the emoji, Copy and ⌘C copy it, both
// performed by the Host with notify, and the emoji joins Recent only once
// its insertion or copy succeeded, even after the view closed. Favourites is
// a toggle item action, each favourite carrying the mark. Calling Emoji
// again while it is open keeps the search as the user left it and reads
// Recent and Favourites again.
(() => {
  const ui = spinnet.ui, c = ui.components;
  const SLICE = 200;
  const RECENT_LIMIT = 16;
  const FAVOURITE_LIMIT = 32;
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

  // Every position of the grid, in order: [emoji, ID prefix], and its
  // section headers with their counts.
  function layout(s) {
    const found = matches(s.query, s.category);
    if (s.query.trim() !== "") return { found, positions: found.map((e) => [e, ""]), sections: undefined };
    const positions = [], sections = [];
    function section(id, title, list, prefix) {
      if (list.length === 0) return;
      sections.push(c.section({ id, title, count: list.length }));
      for (const e of list) positions.push([e, prefix]);
    }
    if (s.category === "all") {
      section("favourites", "Favourites", s.favourites.map((hex) => BY_HEX[hex]), "fav:");
      section("recent", "Recent", s.recent.map((hex) => BY_HEX[hex]), "recent:");
    }
    for (const [id, title] of CATEGORIES) section(id, title, found.filter((e) => e.category === id), "");
    return { found, positions, sections };
  }

  function page(s, start, count, reset) {
    const { found, positions, sections } = layout(s);
    const first = Math.min(start, positions.length);
    const items = positions.slice(first, first + count).map(([e, prefix]) => c.item({
      id: prefix + e.hex, title: e.name, symbol: e.emoji,
      marks: s.favourites.includes(e.hex) ? ["favourite"] : undefined
    }));
    return ui.page({
      id: "search",
      title: "Emoji",
      showsInsertionTarget: true,
      resizable: true,
      reset,
      content: [
        c.row({ id: "bar", content: [
          c.textField({ id: "query", title: "Search", placeholder: "smile, cat, heart or an emoji", value: s.query,
                        collection: "results", status: found.length + " emoji" }),
          c.choiceField({ id: "category", title: "Category", value: s.category,
                          choices: ["all"].concat(CATEGORIES.map((x) => x[0])),
                          choiceTitles: ["All Categories"].concat(CATEGORIES.map((x) => x[1])) })
        ] }),
        c.grid({
          id: "results", columns: "auto", rows: 6, emptyText: "No emoji match",
          total: positions.length, start: first, items, sections,
          actions: [
            c.itemAction({ id: "insert", title: "Insert", default: true, perform: "selection.replace",
                           closesView: true, notify: true }),
            c.itemAction({ id: "copy", title: "Copy", perform: "clipboard.write", notify: true }),
            c.itemAction({ id: "favourite", title: "Favourite", toggle: "favourite" })
          ]
        })
      ]
    });
  }

  const hexOf = (id) => id.replace(/^(recent|fav):/, "");
  const stored = (key) => spinnet.storage.get(key) || [];
  const kept = state || { query: "", category: "all", recent: [], favourites: [] };
  const show = (s, start, count, reset, toast) => ui.showPage(page(s, start, count, reset), { state: s, toast });

  if (event === null) {
    const opened = { query: "", category: "all", recent: stored("recent"), favourites: stored("favourites") };
    return show(opened, 0, SLICE);
  }
  switch (event.type) {
    case "field_changed": {
      const next = Object.assign({}, kept, { query: event.values.query, category: event.values.category });
      // A new search starts on its first result; the field keeps what the
      // user typed, so it is never reset here.
      const changed = next.query !== kept.query || next.category !== kept.category;
      return show(next, 0, SLICE, changed ? ["results"] : undefined);
    }
    case "load_range":
      return show(kept, event.start, event.count);
    case "called": {
      // The same page with no reset: what was typed, the selection and the
      // scroll stay, and Recent and Favourites show what changed since.
      const next = Object.assign({}, kept, { recent: stored("recent"), favourites: stored("favourites") });
      return show(next, 0, SLICE);
    }
    case "operation_finished": {
      // Recent records what was inserted or copied, once that succeeded;
      // after the view closed there is no page to answer with.
      if (event.outcome !== "succeeded" || !event.item) return null;
      const hex = hexOf(event.item.id);
      const recent = [hex].concat(stored("recent").filter((h) => h !== hex)).slice(0, RECENT_LIMIT);
      spinnet.storage.set({ key: "recent", value: recent });
      if (event.view_closed) return null;
      return show(Object.assign({}, kept, { recent }), 0, SLICE);
    }
    case "item_action": {
      if (event.action !== "favourite") return null;
      const hex = hexOf(event.item.id);
      const favourites = stored("favourites");
      const marked = (event.item.marks || []).includes("favourite");
      if (!marked && favourites.length >= FAVOURITE_LIMIT) {
        return { toast: "Favourites holds " + FAVOURITE_LIMIT + " emoji" };
      }
      const next = marked ? favourites.filter((h) => h !== hex) : [hex].concat(favourites.filter((h) => h !== hex));
      spinnet.storage.set({ key: "favourites", value: next });
      return show(Object.assign({}, kept, { favourites: next }), 0, SLICE);
    }
    default:
      return null;
  }
})()
