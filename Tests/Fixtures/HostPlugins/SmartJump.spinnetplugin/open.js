(() => {
  // Smart Jump reads the selection and opens what it points to: the first
  // link, DOI, Bilibili video or local path in reading order, or else a
  // search with the first engine. Arithmetic, and a selection with nothing
  // in it, open a view whose field recognizes the text as it is typed.
  // Recognition runs here and fetches nothing; opening goes through
  // `open_url` and `open_local_path`, which the Host checks again, and a
  // download link goes to the browser, which downloads it. The view keeps
  // the field's text in its state, so each View Event describes it afresh.
  const ui = spinnet.ui;
  const config = input && typeof input === "object" ? input : {};

  // Text the user must change before Smart Jump can act on it, such as a
  // division by zero. It is shown in the view, not thrown to the Host.
  class Refusal extends Error {}

  const maximumTextBytes = 16 * 1024;
  // The Host opens no link longer than this, in characters.
  const maximumLinkLength = 2048;

  function utf8Length(text) {
    let bytes = 0;
    for (const character of text) {
      const code = character.codePointAt(0);
      bytes += code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4;
    }
    return bytes;
  }

  // Surrounding white space and line breaks, as Foundation trims them.
  function trimmed(text) {
    return text.replace(/^[\t-\r\u0085\p{Z}]+|[\t-\r\u0085\p{Z}]+$/gu, "");
  }

  // A bounded recursive-descent parser for decimal arithmetic, with no
  // variables, functions, exponentiation or evaluation of code. It answers
  // null for text that is not arithmetic at all, and refuses an expression
  // it cannot calculate.
  const invalidExpression = "Invalid arithmetic expression; use numbers, + − × ÷ and parentheses";

  function calculate(text) {
    const normalized = text.replace(/−/g, "-").replace(/×/g, "*").replace(/÷/g, "/");
    // A line break is allowed only as CR LF, which Swift took for one
    // character, and counts as one.
    if (!/^[0-9.+\-*/() \t]*$/.test(normalized.replace(/\r\n/g, "")) || !/[0-9]/.test(normalized)) return null;
    if (normalized.replace(/\r\n/g, "\n").length > 512) throw new Refusal(invalidExpression);
    let index = 0;
    const skipSpaces = () => {
      while (index < normalized.length && " \t\r\n".includes(normalized[index])) index += 1;
    };
    const take = (token) => {
      skipSpaces();
      if (normalized[index] !== token) return false;
      index += 1;
      return true;
    };
    const finite = (value) => {
      if (!Number.isFinite(value)) throw new Refusal(invalidExpression);
      return value;
    };
    function factor(depth) {
      if (depth >= 32) throw new Refusal(invalidExpression);
      if (take("+")) return factor(depth + 1);
      if (take("-")) return -factor(depth + 1);
      if (take("(")) {
        const value = expression(depth + 1);
        if (!take(")")) throw new Refusal(invalidExpression);
        return value;
      }
      skipSpaces();
      const start = index;
      while (index < normalized.length && "0123456789.".includes(normalized[index])) index += 1;
      const number = normalized.slice(start, index);
      if (!/^(?:[0-9]+\.?[0-9]*|\.[0-9]+)$/.test(number)) throw new Refusal(invalidExpression);
      return finite(Number(number));
    }
    function term(depth) {
      let value = factor(depth);
      for (;;) {
        if (take("*")) {
          value *= factor(depth);
        } else if (take("/")) {
          const divisor = factor(depth);
          if (divisor === 0) throw new Refusal("Cannot divide by zero");
          value /= divisor;
        } else {
          return finite(value);
        }
      }
    }
    function expression(depth) {
      let value = term(depth);
      for (;;) {
        if (take("+")) value += term(depth);
        else if (take("-")) value -= term(depth);
        else return finite(value);
      }
    }
    const value = expression(0);
    skipSpaces();
    if (index !== normalized.length) throw new Refusal(invalidExpression);
    return finite(value);
  }

  // The result as Foundation's %.15g writes it: 15 significant digits
  // without trailing zeros, in exponent form, with a capital E, below 1e-4
  // or from 1e15.
  function formatted(value) {
    if (value === 0) return "0";
    const [mantissa, power] = value.toExponential(14).split("e");
    const exponent = Number(power);
    const withoutZeros = (digits) => digits.includes(".") ? digits.replace(/\.?0+$/, "") : digits;
    if (exponent < -4 || exponent >= 15) {
      const size = String(Math.abs(exponent)).padStart(2, "0");
      return withoutZeros(mantissa) + "E" + (exponent < 0 ? "-" : "+") + size;
    }
    return withoutZeros(value.toFixed(14 - exponent));
  }

  // Whether the Host would open `text` as a link: http or https, a host, a
  // numeric port if any, no white space, control or format characters, and
  // at most 2048 characters. A host has none of " < > \ ^ ` { | } and no %
  // but before two hex digits; beyond ASCII it must be one the Host can
  // write in Punycode, whose labels are not empty and have no hyphen at
  // either end or as their third and fourth characters. The Host checks
  // again when it opens the link.
  function isOpenable(text) {
    if (Array.from(text).length > maximumLinkLength || /[\t-\r\u0085\p{Z}\p{Cc}\p{Cf}]/u.test(text)) return false;
    const parts = /^https?:\/\/([^/?#]*)/i.exec(text);
    if (parts === null) return false;
    const authority = parts[1].slice(parts[1].lastIndexOf("@") + 1);
    const hostAndPort = /^(\[[^\[\]]*\]|[^\[\]:]*)(?::[0-9]*)?$/.exec(authority);
    if (hostAndPort === null || hostAndPort[1] === "") return false;
    const host = hostAndPort[1];
    if (/["<>\\^`{|}]|%(?![0-9A-Fa-f]{2})/.test(host)) return false;
    if (/^[\u0000-\u007f]*$/.test(host)) return true;
    const labels = host.split(".");
    if (labels.length > 1 && labels[labels.length - 1] === "") labels.pop();
    return labels.every((label) => label !== "" && !label.startsWith("-") && !label.endsWith("-") &&
      Array.from(label).slice(2, 4).join("") !== "--");
  }

  // The extension of a link's last path component, lowercased.
  function pathExtension(url) {
    const path = url.replace(/^https?:\/\/[^/?#]*/i, "").replace(/[?#].*$/, "").replace(/\/+$/, "");
    const component = path.slice(path.lastIndexOf("/") + 1);
    const dot = component.lastIndexOf(".");
    return dot > 0 ? component.slice(dot + 1).toLowerCase() : "";
  }

  // By extension only: the browser downloads these, and nothing here
  // fetches a header or a body.
  const downloadExtensions = ["zip", "dmg", "pdf", "pkg", "tar", "gz", "bz2", "xz", "7z", "rar"];

  const google = { name: "Google", url: "https://www.google.com/search?q={query}" };

  // The `search_engines` rows Plugin Settings checked when they were saved;
  // the first is the default, and none means Google.
  function engines() {
    const rows = Array.isArray(config.search_engines) ? config.search_engines : [];
    const found = rows.filter((row) => row && typeof row.name === "string" && typeof row.url === "string")
      .map((row) => ({ name: row.name.trim(), url: row.url.trim() }));
    return found.length > 0 ? found : [google];
  }

  // Percent-encodes everything but RFC 3986's unreserved characters, so the
  // text cannot change the host or the query's structure.
  function queryValue(text) {
    try {
      return encodeURIComponent(text).replace(/[!'()*]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());
    } catch (error) {
      throw new Refusal("The search text cannot be encoded");
    }
  }

  // ICU's \w, which Smart Jump's patterns were first written for: it counts
  // letters of every script, marks and joiners.
  const word = "\\p{Alphabetic}\\p{M}\\p{Nd}\\p{Pc}\\u200c\\u200d";

  // What ends a target: ICU's white space, which unlike JavaScript's has
  // NEL and not the byte order mark, and the marks that close a sentence.
  const stop = "\\t-\\r \\u0085\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000<>\"“”，。；";

  // Each kind of target, and the characters it may not follow. At the same
  // position, a rule earlier in the list wins.
  const rules = [
    { kind: "doi", notAfter: word + "/", body: "10\\.[0-9]{4,9}/[^" + stop + "]+", flags: "giu" },
    { kind: "video", notAfter: "A-Za-z0-9", body: "(?:BV[1-9A-HJ-NP-Za-km-z]{10}|[aA][vV][0-9]+)(?![A-Za-z0-9])",
      flags: "gu" },
    { kind: "path", notAfter: word + ":/", body: "\"(?:~/|/)[^\"\\r\\n]+\"|(?:~/|/)[^" + stop + "]+", flags: "gu" },
    { kind: "web", notAfter: word + "@/:.\\-",
      body: "https?://[^" + stop + "]+|(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,63}(?::[0-9]+)?" +
            "(?:[/?#][^" + stop + "]*)?",
      flags: "giu" }
  ].map((rule) => Object.assign(rule, {
    // The character before is matched rather than looked behind at, which
    // the oldest supported macOS cannot do, so a pattern fails at once
    // inside a word instead of trying every position in it.
    pattern: new RegExp("(?:^|[^" + rule.notAfter + "])(" + rule.body + ")", rule.flags)
  }));

  // Trailing punctuation belongs to the sentence, and so does a closing
  // bracket that the text never opened.
  function withoutTrailingPunctuation(text) {
    const punctuation = ".,;:!?，。；！？”’";
    let start = 0;
    let end = text.length;
    while (start < end && punctuation.includes(text[start])) start += 1;
    while (end > start && punctuation.includes(text[end - 1])) end -= 1;
    let value = text.slice(start, end);
    // A bracket that a mark or joiner extends is another character.
    const count = (bracket) => (value.match(new RegExp("\\" + bracket + "(?![\\p{M}\\u200c\\u200d])", "gu")) || []).length;
    for (const [opening, closing] of [["(", ")"], ["[", "]"]]) {
      let excess = count(closing) - count(opening);
      while (value.endsWith(closing) && excess > 0) {
        value = value.slice(0, -1);
        excess -= 1;
      }
    }
    return value;
  }

  function link(url, kind) {
    return isOpenable(url) ? { kind: "link", url, linkKind: kind } : null;
  }

  // The target a match stands for, or null when it stands for none.
  function target(rule, raw, text, end) {
    const line = raw.split(/\r\n|[\n\v\f\r\u0085\u2028\u2029]/)[0];
    const value = withoutTrailingPunctuation(line);
    switch (rule.kind) {
      case "doi":
        return link("https://doi.org/" + value, "doi");
      case "video":
        return link("https://www.bilibili.com/video/" + (value.toLowerCase().startsWith("av") ? value.toLowerCase() : value),
                    "video");
      case "path":
        return { kind: "path", path: line.startsWith("\"") ? line.slice(1, -1) : value };
      default: {
        // A function-shaped token such as Math.random() is text, not a bare
        // domain to open.
        if (text.startsWith("(", end) && !value.includes("/")) return null;
        const address = /^https?:\/\//i.test(value) ? value : "https://" + value;
        if (!isOpenable(address)) return null;
        return { kind: "link", url: address,
                 linkKind: downloadExtensions.includes(pathExtension(address)) ? "download" : "web" };
      }
    }
  }

  // The first target each rule finds, with where it starts.
  function firstMatch(rule, text) {
    const pattern = new RegExp(rule.pattern.source, rule.pattern.flags);
    let match;
    while ((match = pattern.exec(text)) !== null) {
      const raw = match[1];
      const end = match.index + match[0].length;
      const found = target(rule, raw, text, end);
      if (found !== null) return { offset: end - raw.length, target: found };
      // The next may start right after this one, so the search goes on from
      // its last character, the one the next must not follow.
      const pair = end >= 2 && /[\ud800-\udbff][\udc00-\udfff]/.test(text.slice(end - 2, end));
      pattern.lastIndex = end - (pair ? 2 : 1);
    }
    return null;
  }

  // What Smart Jump does with `text`. The first target in reading order
  // wins, and at the same position a more specific one wins over a web
  // address. A DOI may look like a division, and a leading slash is a path,
  // not a division missing its numerator. Throws a Refusal for text Smart
  // Jump cannot act on.
  function recognize(original) {
    if (utf8Length(original) > maximumTextBytes) throw new Refusal("Smart Jump accepts up to 16 KiB of text");
    const text = trimmed(original);
    if (text === "") return { kind: "input" };
    if (text === "/" || text === "~/") return { kind: "path", path: text };
    let first = null;
    for (const rule of rules) {
      const found = firstMatch(rule, text);
      if (found !== null && (first === null || found.offset < first.offset)) first = found;
    }
    if (first !== null && first.target.linkKind === "doi") return first.target;
    if (!text.startsWith("/")) {
      const result = calculate(text);
      if (result !== null) return { kind: "calculation", result: formatted(result) };
    }
    if (first !== null) return first.target;
    const engine = engines()[0];
    const url = engine.url.split("{query}").join(queryValue(text));
    if (Array.from(url).length > maximumLinkLength) {
      throw new Refusal("The link is longer than " + maximumLinkLength + " characters");
    }
    if (!isOpenable(url)) throw new Refusal("The search engine " + engine.name + " has no address that can be opened");
    return { kind: "search", url, engine: engine.name };
  }

  // Opens the target, if it is one that opens.
  function jump(found) {
    switch (found.kind) {
      case "link":
      case "search":
        spinnet.open.url(found.url);
        return true;
      case "path":
        spinnet.open.path(found.path);
        return true;
      default:
        return false;
    }
  }

  function host(url) {
    return url.replace(/^https?:\/\//i, "").replace(/[/?#].*$/, "").replace(/^.*@/, "");
  }

  // The status the field shows under its text, "what · on what", the colour
  // it takes for that kind of target, and the button that does it. Waiting
  // for text has no colour.
  function status(found) {
    switch (found.kind) {
      case "refused":
        return { title: "Check this input", detail: found.message, accent: "red", verb: "Jump" };
      case "input":
        return { title: "Type to preview", detail: "Link, DOI, video, path, calculation or search", verb: "Jump" };
      case "search":
        return { title: "Search the web", detail: "Using " + found.engine + " · " + host(found.url), accent: "teal",
                 verb: "Search" };
      case "path":
        return { title: "Open local file", detail: found.path, accent: "orange", verb: "Open" };
      case "calculation":
        return { title: "Calculate", detail: "Result: " + found.result, accent: "green", verb: "Calculate" };
      default:
        return Object.assign({ detail: found.url }, linkStatus[found.linkKind]);
    }
  }

  const linkStatus = {
    web: { title: "Open web address", accent: "blue", verb: "Open" },
    doi: { title: "Open DOI", accent: "indigo", verb: "Open" },
    video: { title: "Open Bilibili video", accent: "pink", verb: "Watch" },
    download: { title: "Open download link in browser", accent: "purple", verb: "Download" }
  };

  // Recognizes without throwing: a Refusal becomes what the view shows.
  function preview(text) {
    try {
      return recognize(text);
    } catch (error) {
      if (!(error instanceof Refusal)) throw error;
      return { kind: "refused", message: error.message };
    }
  }

  // The Host takes a state of at most 64 KiB, so a text much longer than
  // Smart Jump accepts is left out of the field and the state, where it
  // would end the view, and only the status says it is too long.
  const maximumKeptBytes = 32 * 1024;

  function show(query, found, toast) {
    const line = status(found);
    const kept = utf8Length(JSON.stringify(query)) <= maximumKeptBytes ? query : "";
    const view = ui.view({
      title: "Smart Jump",
      form: ui.form({
        submitTitle: line.verb,
        fields: [ui.textField({ key: "query", title: "Text", placeholder: "Text, link, path or calculation", value: kept,
                                accent: line.accent, status: line.title + " · " + line.detail })]
      }),
      actions: found.kind === "calculation" ? [ui.action({ id: "copy_result", title: "Copy Result" })] : undefined
    });
    return ui.show(view, { state: { query: kept }, toast });
  }

  if (event === null) {
    // A selection the App keeps to itself is no selection: the view waits
    // for text instead of failing.
    const selected = spinnet.selection.readText({ best_effort: true });
    const text = typeof selected === "string" ? trimmed(selected) : "";
    if (utf8Length(text) > maximumTextBytes) return ui.toast("Smart Jump accepts up to 16 KiB of text");
    const found = preview(text);
    return jump(found) ? null : show(text, found);
  }

  const current = state && typeof state === "object" && typeof state.query === "string" ? state : { query: "" };
  switch (event.type) {
    case "field_changed": {
      const query = String(event.values.query ?? "");
      return show(query, preview(query));
    }
    case "submitted": {
      const query = String(event.values.query ?? "");
      const found = preview(query);
      if (jump(found)) return ui.close();
      return show(query, found, found.kind === "input" ? "Enter text to jump" : undefined);
    }
    case "action_chosen": {
      if (event.action !== "copy_result") return null;
      const found = preview(current.query);
      if (found.kind !== "calculation") return show(current.query, found, "There is no calculation result to copy");
      spinnet.clipboard.write(found.result);
      return show(current.query, found, "Copied");
    }
    default:
      return null;
  }
})()
