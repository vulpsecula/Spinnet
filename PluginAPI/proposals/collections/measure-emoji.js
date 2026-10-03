// PROPOSAL ONLY (#74). SPDX-License-Identifier: MIT
//
// Measures what the external Emoji probe's realistic pages would cost in the
// draft `collections` shape: the UTF-8 size of each answer and the time
// JavaScriptCore takes to build and serialize it. It reuses the probe's own
// search code and data, so result counts are the Plugin's real ones. The
// helper runs every invocation in a fresh JSContext, so the figure that
// matters is the first run in a fresh process (`cold`); `warm` is the median
// of later runs in the same process, for comparison only.
//
//   JSC=/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc
//   $JSC measure-emoji.js -- <path to Emoji.spinnetplugin/emoji.js> [scenario]
//
// Without a scenario it prints the sizes of every scenario as JSON lines.
// With one it prints that scenario's cold and warm build times in ms.

const [path, only] = arguments;
const source = readFile(path);
const start = source.indexOf("const EMOJI_VERSION");
const end = source.indexOf("const current = state");
if (start < 0 || end < 0) throw new Error("not the generated Emoji script: " + path);
globalThis.spinnet = { ui: {} };
const plugin = new Function(source.slice(start, end) +
  "\nreturn { search, browse, entries, EMOJI_GROUPS, EMOJI_GROUP_COUNTS, CATEGORIES, ALL };")();

function utf8(text) {
  let bytes = 0;
  for (const ch of text) {
    const c = ch.codePointAt(0);
    bytes += c < 0x80 ? 1 : c < 0x800 ? 2 : c < 0x10000 ? 3 : 4;
  }
  return bytes;
}

const item = (e) => ({ id: e.hex, title: e.name, symbol: e.emoji });
const itemWithText = (e) => ({ id: e.hex, title: e.name, symbol: e.emoji, text: e.emoji });

// The draft Emoji search page (fixtures/answers/emoji-*.json): a search row and
// one sectioned or flat grid.
function answer(query, category, collection, shape) {
  return {
    page: {
      id: "search", title: "Emoji", shows_insertion_target: true,
      content: [
        { kind: "row", id: "bar", content: [
          { kind: "text_field", id: "query", title: "Search", placeholder: "smile, cat, heart or an emoji",
            value: query, collection: "results", status: `${collection.count} emoji` },
          { kind: "choice_field", id: "category", title: "Category", value: category,
            choices: [plugin.ALL].concat(plugin.CATEGORIES), choice_titles: ["All Categories"].concat(plugin.EMOJI_GROUPS) }
        ] },
        Object.assign({ kind: "grid", id: "results", columns: 8, rows: 6, empty_text: "No emoji match",
          actions: [{ id: "insert", title: "Insert", default: true }, { id: "copy", title: "Copy", perform: "copy_text" }] },
          collection.body)
      ]
    },
    state: { query, category, loaded: collection.loaded }
  };
}

// Every emoji, grouped as the category picker groups them, cut after `limit`.
function sectioned(limit, make) {
  const all = plugin.entries().filter((e) => e.group >= 0 && e.group < plugin.EMOJI_GROUPS.length);
  const sections = [];
  let loaded = 0;
  for (let g = 0; g < plugin.EMOJI_GROUPS.length && loaded < limit; g++) {
    const items = all.filter((e) => e.group === g).slice(0, limit - loaded).map(make);
    loaded += items.length;
    sections.push({ id: plugin.CATEGORIES[g], title: plugin.EMOJI_GROUPS[g], items });
  }
  const total = all.length;
  return { count: total, loaded, body: loaded < total ? { sections, has_more: true } : { sections } };
}

function flat(matches, limit, make) {
  const items = matches.slice(0, limit).map(make);
  return { count: matches.length, loaded: items.length,
           body: items.length < matches.length ? { items, has_more: true } : { items } };
}

const people = plugin.CATEGORIES[1];
const scenarios = {
  "browse-all-1906": () => answer("", "all", sectioned(Infinity, item)),
  "browse-all-1906-with-text": () => answer("", "all", sectioned(Infinity, itemWithText)),
  "browse-all-page-96": () => answer("", "all", sectioned(96, item)),
  "browse-all-page-200": () => answer("", "all", sectioned(200, item)),
  "browse-all-page-400": () => answer("", "all", sectioned(400, item)),
  "browse-all-page-1000": () => answer("", "all", sectioned(1000, item)),
  "browse-people-386": () => answer("", people, flat(plugin.entries().filter((e) => e.group === 1), Infinity, item)),
  "search-smile": () => answer("smile", "all", flat(plugin.search("smile", "all").matches, Infinity, item)),
  "search-cat": () => answer("cat", "all", flat(plugin.search("cat", "all").matches, Infinity, item)),
  "search-heart": () => answer("heart", "all", flat(plugin.search("heart", "all").matches, Infinity, item)),
  "search-flag": () => answer("flag", "all", flat(plugin.search("flag", "all").matches, Infinity, item)),
  "search-s": () => answer("s", "all", flat(plugin.search("s", "all").matches, Infinity, item)),
  "search-s-page-200": () => answer("s", "all", flat(plugin.search("s", "all").matches, 200, item)),
  "search-a": () => answer("a", "all", flat(plugin.search("a", "all").matches, Infinity, item)),
  "level1-six-results": () => answer("cat", "all", flat(plugin.search("cat", "all").matches, 6, item))
};

function build(name) { return JSON.stringify(scenarios[name]()); }

if (only === undefined) {
  for (const name of Object.keys(scenarios)) {
    const json = build(name);
    const parsed = JSON.parse(json);
    const grid = parsed.page.content[1];
    const items = grid.items ? grid.items.length : grid.sections.reduce((n, s) => n + s.items.length, 0);
    print(JSON.stringify({ scenario: name, items, count: parsed.state.loaded, bytes: utf8(json) }));
  }
} else {
  const t0 = preciseTime();
  build(only);
  const cold = (preciseTime() - t0) * 1000;
  const warm = [];
  for (let i = 0; i < 25; i++) {
    const t = preciseTime();
    build(only);
    warm.push((preciseTime() - t) * 1000);
  }
  warm.sort((a, b) => a - b);
  print(JSON.stringify({ scenario: only, cold_ms: +cold.toFixed(2), warm_median_ms: +warm[12].toFixed(2) }));
}
