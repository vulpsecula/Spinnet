(() => {
  // Shows the text to translate in a field the user can change, and one
  // Host-Fetched Section per translation source turned on in Plugin
  // Settings, with the languages as setting controls; without any text the
  // field waits for some. The Host sends each request only to a consented
  // host, adds each key itself, and shows the answers; the script never sees
  // a key or a translation. It keeps the text in the view's state, so each
  // View Event describes the view afresh.
  const ui = spinnet.ui;
  const config = input && typeof input === "object" ? input : {};

  // Plugin Settings use DeepL's codes, so a key is also the code DeepL takes.
  // Google, the OpenAI prompt and language detection each need their own
  // name for the same language.
  const languages = {
    "EN-US": { name: "English (American)", google: "en", detected: "en" },
    "EN-GB": { name: "English (British)", google: "en", detected: "en" },
    "DE": { name: "German", google: "de", detected: "de" },
    "FR": { name: "French", google: "fr", detected: "fr" },
    "ES": { name: "Spanish", google: "es", detected: "es" },
    "IT": { name: "Italian", google: "it", detected: "it" },
    "NL": { name: "Dutch", google: "nl", detected: "nl" },
    "PL": { name: "Polish", google: "pl", detected: "pl" },
    "PT-BR": { name: "Brazilian Portuguese", google: "pt", detected: "pt" },
    "PT-PT": { name: "European Portuguese", google: "pt-PT", detected: "pt" },
    "RU": { name: "Russian", google: "ru", detected: "ru" },
    "SV": { name: "Swedish", google: "sv", detected: "sv" },
    "DA": { name: "Danish", google: "da", detected: "da" },
    "FI": { name: "Finnish", google: "fi", detected: "fi" },
    "CS": { name: "Czech", google: "cs", detected: "cs" },
    "UK": { name: "Ukrainian", google: "uk", detected: "uk" },
    "TR": { name: "Turkish", google: "tr", detected: "tr" },
    "AR": { name: "Arabic", google: "ar", detected: "ar" },
    "ID": { name: "Indonesian", google: "id", detected: "id" },
    "JA": { name: "Japanese", google: "ja", detected: "ja" },
    "KO": { name: "Korean", google: "ko", detected: "ko" },
    "ZH-HANS": { name: "Simplified Chinese", google: "zh-CN", detected: "zh" },
    "ZH-HANT": { name: "Traditional Chinese", google: "zh-TW", detected: "zh" }
  };

  function language(code, fallback) {
    const id = String(code || fallback);
    const known = languages[id] || { name: id, google: id.toLowerCase(), detected: id.toLowerCase() };
    return { id, deepl: id, name: known.name, google: known.google, detected: known.detected };
  }

  const target = language(config.target_language, "EN-US");
  const source = language(config.source_language, "EN-US");
  const autoDetect = config.auto_detect === true;

  // Google turns away requests that look automated, so its own web client's
  // User-Agent is sent instead of Spinnet's.
  const browser = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) " +
    "Chrome/120.0.0.0 Safari/537.36";

  // A setting a source cannot work without fails that source's section alone.
  class SourceSetup extends Error {}

  function baseURL(value, name) {
    const url = String(value || "").trim().replace(/\/+$/, "");
    if (!/^https:\/\//.test(url)) throw new SourceSetup("Configure an https address for " + name + " in Translator's Plugin Settings");
    return url;
  }

  // Percent-encodes everything but RFC 3986's unreserved characters, so the
  // text stays one query value.
  function queryValue(text) {
    return encodeURIComponent(text).replace(/[!'()*]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());
  }

  // Each adapter describes the `fetch` of one section translating `text`
  // from `from` into `into`, with its members in sorted order so the same
  // request is always the same bytes, and the Host's cache knows it again.
  // `from` is null unless the text's language is known, from detection or
  // from the user's own choice; otherwise it is left to the service, since
  // guessing it wrongly spoils a translation.
  const adapters = {
    // DeepL judges mixed text by itself and may hand Chinese prose that
    // quotes English back unchanged, so it is told the language when known
    // and different from the target.
    DeepL(text, from, into) {
      const body = { target_lang: into.deepl, text: [text] };
      if (config.formality && config.formality !== "default") body.formality = config.formality;
      const fromCode = from === null ? null : from.deepl.split("-")[0];
      if (fromCode !== null && fromCode !== into.deepl.split("-")[0]) body.source_lang = fromCode;
      const sorted = {};
      for (const key of Object.keys(body).sort()) sorted[key] = body[key];
      return {
        title: "DeepL",
        fetch: {
          request: {
            method: "POST",
            url: baseURL(config.deepl_endpoint, "DeepL") + "/v2/translate",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(sorted),
            credential_uses: [{ reference: config.deepl_credential, header: "Authorization", template: "DeepL-Auth-Key {credential}" }]
          },
          mode: "show",
          pointer: "/translations/0/text",
          error_pointer: "/message",
          status_messages: {
            "401": "DeepL rejected the API key", "403": "DeepL rejected the API key",
            "429": "Too many requests to DeepL; try again shortly", "456": "The DeepL quota is used up"
          },
          cache: true
        }
      };
    },
    // Google Translate's own endpoint, the one its Chrome dictionary uses:
    // no API key, and the whole translation comes back as one string. The
    // address is a setting because Google refuses some networks, and a
    // reverse proxy speaking the same shape then takes its place.
    Google(text, from, into) {
      return {
        title: "Google",
        fetch: {
          request: {
            method: "GET",
            url: baseURL(config.google_endpoint, "Google") + "/translate_a/t?client=dict-chrome-ex&sl=auto&tl=" +
              into.google + "&q=" + queryValue(text),
            headers: { "User-Agent": browser }
          },
          mode: "show",
          pointer: "/0/0",
          status_messages: {
            "429": "Google is refusing requests from this network for now; try again later",
            "403": "Google refused the request",
            "413": "The text is too long for Google"
          },
          cache: true
        }
      };
    },
    OpenAI(text, from, into) {
      const model = String(config.openai_model || "").trim();
      if (model === "") throw new SourceSetup("Choose an OpenAI model in Translator's Plugin Settings");
      // Text mixing languages is translated whole, quoted terms included,
      // rather than handed back because most of it is already in `into`.
      const prompt = "You are a translation engine. Translate the text the user sends into " + into.name + ", " +
        "including every word or phrase in another language, such as quoted terms. " +
        "Reply with the translation only, without quotes, notes, or explanations, and keep its line breaks and formatting.";
      return {
        title: "OpenAI · " + model,
        fetch: {
          request: {
            method: "POST",
            url: baseURL(config.openai_endpoint, "OpenAI") + "/chat/completions",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              messages: [{ content: prompt, role: "system" }, { content: text, role: "user" }],
              model
            }),
            credential_uses: [{ reference: config.openai_credential, header: "Authorization", template: "Bearer {credential}" }]
          },
          mode: "show",
          pointer: "/choices/0/message/content",
          error_pointer: "/error/message",
          status_messages: { "401": "The service rejected the OpenAI API key" },
          cache: true
        }
      };
    }
  };

  const sources = Array.isArray(config.sources) ? config.sources : [];
  if (sources.length === 0) throw new Error("Turn on a translation source in Translator's Plugin Settings");
  for (const name of sources) {
    if (!Object.prototype.hasOwnProperty.call(adapters, name)) throw new Error("Unknown translation source " + name);
  }

  // Text the user reads as it is: every marker of the Markdown subset is
  // escaped, so an asterisk stays an asterisk.
  function literal(text) {
    return text.replace(/[\\`*_[\]]/g, "\\$&");
  }

  // One section per source, in the order Plugin Settings put them. A
  // section keeps its answer while its request is unchanged, so only a
  // source whose request a new setting changes is asked again.
  function sourceSections(text, from, into) {
    return sources.map((name) => {
      const id = name.toLowerCase();
      try {
        const described = adapters[name](text, from, into);
        return ui.section({ id, title: described.title, fetch: described.fetch });
      } catch (error) {
        if (!(error instanceof SourceSetup)) throw error;
        return ui.section({ id, title: name, text: literal(error.message) });
      }
    });
  }

  // The language the text is in, and what the subtitle says of it. The
  // translation always goes into Target, as the controls show. With
  // detection on, the text's language is detected here on the Mac; with it
  // off, the text is taken to be in Input. `from` is null when unknown.
  function origin(text) {
    if (!autoDetect) return { from: source, subtitle: undefined };
    const detected = spinnet.text.detectLanguage(text);
    const primary = detected === null ? null : detected.toLowerCase().split("-")[0];
    const id = Object.keys(languages).find((code) => languages[code].detected === primary);
    if (id === undefined) return { from: null, subtitle: undefined };
    const from = language(id);
    return { from, subtitle: "Detected " + (from.detected === source.detected ? source : from).name };
  }

  // The field holds the text, whether it was selected, copied or typed, so
  // it can always be changed; Return translates it again. `next.text` is
  // what is translated, or null before there is any; `next.draft` what the
  // field holds when that differs; `next.tooLong` that the last text did
  // not fit.
  function translation(next) {
    const text = next.text;
    const found = text === null ? null : origin(text);
    const sections = next.tooLong
      ? [ui.section({ id: "too_long", text: tooLongMessage })]
      : found === null ? [] : sourceSections(text, found.from, target);
    const view = ui.view({
      title: "Translate",
      subtitle: found === null ? undefined : found.subtitle,
      // The languages are changed where the translation is read.
      settings: [ui.setting("source_language", { swapWith: "target_language" }), ui.setting("target_language"),
                 ui.setting("auto_detect")],
      form: ui.form({
        submitOnReturn: true,
        fields: [ui.multilineTextField({ key: "text", title: "Text", placeholder: "Text to translate",
                                         value: next.draft !== undefined ? next.draft : text || "" })]
      }),
      detail: sections.length > 0 ? ui.detail({ sections }) : undefined
    });
    const kept = { text };
    if (next.draft !== undefined && next.draft !== text) kept.draft = next.draft;
    if (next.tooLong) kept.tooLong = true;
    return { view, state: kept };
  }

  // The Host takes a view of at most 256 KiB and a state of at most 64 KiB.
  // The text is in the state and the field, and in the view once per
  // source, three times over in Google's percent-encoded address, so a long
  // one may not fit; the view then says so rather than ending.
  const maximumViewBytes = 256 * 1024;
  const maximumStateBytes = 64 * 1024;
  const tooLongMessage = "The text is too long to translate at once. Select a shorter part.";

  function utf8Length(json) {
    let bytes = 0;
    for (const character of json) {
      const code = character.codePointAt(0);
      bytes += code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4;
    }
    return bytes;
  }

  function show(next) {
    const built = translation(next);
    if (utf8Length(JSON.stringify(built.view)) <= maximumViewBytes &&
        utf8Length(JSON.stringify(built.state)) <= maximumStateBytes) {
      return ui.show(built.view, { state: built.state });
    }
    const refused = translation({ text: null, tooLong: true });
    return ui.show(refused.view, { state: refused.state });
  }

  if (event === null) {
    let text = "";
    switch (commandID) {
      case "translator.selection":
        text = spinnet.selection.readText();
        break;
      case "translator.clipboard": {
        const clipboard = spinnet.clipboard.read();
        text = clipboard && typeof clipboard.text === "string" ? clipboard.text : "";
        break;
      }
      case "translator.input":
        break;
      default:
        throw new Error("Unknown Translator Command " + commandID);
    }
    // Nothing to work on, whether the Command asks for typing or the App kept
    // its selection to itself: the field waits for the text instead of failing.
    const found = typeof text === "string" && text.trim() !== "";
    return show({ text: found ? text : null });
  }

  const current = state && typeof state === "object" ? state : { text: null };
  // What the field holds now: an edit not yet sent is translated by the
  // next change of language, as it is by Return.
  const fieldText = current.draft !== undefined ? current.draft : current.text;
  const worded = (text) => typeof text === "string" && text.trim() !== "" ? text : null;
  switch (event.type) {
    case "field_changed":
      // Kept so a change of language translates what the field holds.
      return show(Object.assign({}, current, { draft: String(event.values.text || "") }));
    case "submitted": {
      const typed = worded(String(event.values.text || ""));
      return typed === null ? null : show({ text: typed });
    }
    case "setting_changed":
    case "settings_swapped":
      // The Host stored the settings already, and `input` holds them.
      return show({ text: worded(fieldText) });
    default:
      return null;
  }
})()
