(() => {
  // Describes one request per translation source turned on in Plugin
  // Settings, in both directions, and asks the Host to present them. The Host
  // reads the text, decides the direction from the text itself, sends each
  // request only to a consented host, adds each key itself, and shows the
  // answers in its own popup; the script never sees a key or a translation.
  const config = input && typeof input === "object" ? input : {};

  // Plugin Settings use DeepL's codes, so a key is also the code DeepL takes.
  // Google, the OpenAI prompt and the Host's language detection each need
  // their own name for the same language.
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
  // With both languages the same there is no other direction to turn to.
  const autoDetect = config.auto_detect === true && source.id !== target.id;

  // Google turns away requests that look automated, so its own web client's
  // User-Agent is sent instead of Spinnet's.
  const browser = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) " +
    "Chrome/120.0.0.0 Safari/537.36";

  function baseURL(value, name) {
    const url = String(value || "").trim().replace(/\/+$/, "");
    if (!/^https:\/\//.test(url)) throw new Error("Configure an https address for " + name + " in Translator's Plugin Settings");
    return url;
  }

  // Each adapter returns one present_results section translating into `into`.
  // The source language is left to the service: the Host has already chosen
  // the direction, and guessing a source wrongly spoils a translation.
  // "{{text}}" marks where the Host puts the text.
  const adapters = {
    DeepL(into) {
      const body = { text: ["{{text}}"], target_lang: into.deepl };
      if (config.formality && config.formality !== "default") body.formality = config.formality;
      return {
        title: "DeepL",
        cache: true,
        request: {
          method: "POST",
          url: baseURL(config.deepl_endpoint, "DeepL") + "/v2/translate",
          json_body: body,
          credential: { reference: config.deepl_credential, header: "Authorization", format: "DeepL-Auth-Key {credential}" }
        },
        result_pointer: "/translations/0/text",
        error_pointer: "/message",
        status_messages: {
          "401": "DeepL rejected the API key", "403": "DeepL rejected the API key",
          "429": "Too many requests to DeepL; try again shortly", "456": "The DeepL quota is used up"
        }
      };
    },
    // Google Translate's own endpoint, the one its Chrome dictionary uses:
    // no API key, and the whole translation comes back as one string. The
    // address is a setting because Google refuses some networks, and a
    // reverse proxy speaking the same shape then takes its place.
    Google(into) {
      return {
        title: "Google",
        cache: true,
        request: {
          method: "GET",
          url: baseURL(config.google_endpoint, "Google") + "/translate_a/t?client=dict-chrome-ex&sl=auto&tl=" +
            into.google + "&q={{text}}",
          headers: { "User-Agent": browser }
        },
        result_pointer: "/0/0",
        status_messages: {
          "429": "Google is refusing requests from this network for now; try again later",
          "403": "Google refused the request",
          "413": "The text is too long for Google"
        }
      };
    },
    OpenAI(into) {
      const model = String(config.openai_model || "").trim();
      if (model === "") throw new Error("Choose an OpenAI model in Translator's Plugin Settings");
      const prompt = "You are a translation engine. Translate the text the user sends into " + into.name + ". " +
        "Reply with the translation only, without quotes, notes, or explanations, and keep its line breaks and formatting.";
      return {
        title: "OpenAI · " + model,
        cache: true,
        request: {
          method: "POST",
          url: baseURL(config.openai_endpoint, "OpenAI") + "/chat/completions",
          json_body: { model, messages: [{ role: "system", content: prompt }, { role: "user", content: "{{text}}" }] },
          credential: { reference: config.openai_credential, header: "Authorization", format: "Bearer {credential}" }
        },
        result_pointer: "/choices/0/message/content",
        error_pointer: "/error/message",
        status_messages: { "401": "The service rejected the OpenAI API key" }
      };
    }
  };

  const sources = Array.isArray(config.sources) ? config.sources : [];
  if (sources.length === 0) throw new Error("Turn on a translation source in Translator's Plugin Settings");
  function sections(into) {
    return sources.map((name) => {
      if (!Object.prototype.hasOwnProperty.call(adapters, name)) throw new Error("Unknown translation source " + name);
      return adapters[name](into);
    });
  }

  // The popup says which way it is translating and what the three language
  // settings are, so the direction is never a guess.
  const payload = {
    title: "Translate",
    // The popup shows these three as controls, so the languages can be
    // changed where the translation is read rather than in Settings.
    settings: {
      keys: ["source_language", "target_language", "auto_detect"],
      swap: ["source_language", "target_language"]
    },
    sections: sections(target)
  };
  if (autoDetect) {
    // Text already in the target language goes back the other way, so the two
    // languages never have to be swapped by hand.
    payload.alternate = {
      when_language: target.detected,
      // The controls show the settings; this says what they cannot, which is
      // which way this particular text actually went.
      subtitle: "Detected " + target.name + ", translating into " + source.name,
      sections: sections(source)
    };
  }

  let text = "";
  switch (commandID) {
    case "translator.selection":
      text = requestHostService("read_selected_text");
      break;
    case "translator.clipboard": {
      const clipboard = requestHostService("read_current_clipboard");
      text = clipboard && typeof clipboard.text === "string" ? clipboard.text : "";
      break;
    }
    case "translator.input":
      break;
    default:
      throw new Error("Unknown Translator Command " + commandID);
  }

  if (typeof text === "string" && text.trim() !== "") {
    payload.original = text;
  } else {
    // Nothing to work on, whether the Command asks for typing or the App kept
    // its selection to itself: the popup asks for the text instead of failing.
    payload.input = { placeholder: "Text to translate", submit_title: "Translate" };
  }
  requestHostService("present_results", payload);
  return null;
})()
