(() => {
  // Describes one request per translation source turned on in Plugin
  // Settings and asks the Host to present them. The Host reads nothing for
  // this script beyond the selection or clipboard, sends each request only to
  // a consented host, adds each key itself, and shows the answers in its own
  // popup; the script never sees a key or a translation.
  const config = input && typeof input === "object" ? input : {};

  // Plugin Settings use DeepL's codes; Google and the OpenAI prompt need
  // their own names for the same languages.
  const languages = {
    "EN-US": ["American English", "en"], "EN-GB": ["British English", "en"], "DE": ["German", "de"],
    "FR": ["French", "fr"], "ES": ["Spanish", "es"], "IT": ["Italian", "it"], "NL": ["Dutch", "nl"],
    "PL": ["Polish", "pl"], "PT-BR": ["Brazilian Portuguese", "pt"], "PT-PT": ["European Portuguese", "pt-PT"],
    "RU": ["Russian", "ru"], "SV": ["Swedish", "sv"], "DA": ["Danish", "da"], "FI": ["Finnish", "fi"],
    "CS": ["Czech", "cs"], "UK": ["Ukrainian", "uk"], "TR": ["Turkish", "tr"], "AR": ["Arabic", "ar"],
    "ID": ["Indonesian", "id"], "JA": ["Japanese", "ja"], "KO": ["Korean", "ko"],
    "ZH-HANS": ["Simplified Chinese", "zh-CN"], "ZH-HANT": ["Traditional Chinese", "zh-TW"]
  };
  const target = String(config.target_language || "EN-US");
  const [languageName, googleCode] = languages[target] || [target, target.toLowerCase()];

  function baseURL(value, name) {
    const url = String(value || "").trim().replace(/\/+$/, "");
    if (!/^https:\/\//.test(url)) throw new Error("Configure an https address for " + name + " in Translator's Plugin Settings");
    return url;
  }

  // Each adapter returns one present_results section. "{{text}}" marks where
  // the Host puts the text, as a JSON string.
  const adapters = {
    DeepL() {
      const body = { text: ["{{text}}"], target_lang: target };
      if (config.formality && config.formality !== "default") body.formality = config.formality;
      return {
        title: "DeepL",
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
    Google() {
      return {
        title: "Google",
        request: {
          method: "POST",
          url: "https://translation.googleapis.com/language/translate/v2",
          json_body: { q: ["{{text}}"], target: googleCode, format: "text" },
          credential: { reference: config.google_credential, header: "X-Goog-Api-Key", format: "{credential}" }
        },
        result_pointer: "/data/translations/0/translatedText",
        error_pointer: "/error/message",
        status_messages: { "429": "Too many requests to Google; try again shortly" }
      };
    },
    OpenAI() {
      const model = String(config.openai_model || "").trim();
      if (model === "") throw new Error("Choose an OpenAI model in Translator's Plugin Settings");
      const prompt = "You are a translation engine. Translate the text the user sends into " + languageName + ". " +
        "Reply with the translation only, without quotes, notes, or explanations, and keep its line breaks and formatting.";
      return {
        title: "OpenAI · " + model,
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
  const sections = sources.map((name) => {
    if (!Object.prototype.hasOwnProperty.call(adapters, name)) throw new Error("Unknown translation source " + name);
    return adapters[name]();
  });
  const title = "Translate into " + languageName;

  let text;
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
      requestHostService("present_results", { title, input: { placeholder: "Text to translate", submit_title: "Translate" }, sections });
      return null;
    default:
      throw new Error("Unknown Translator Command " + commandID);
  }
  if (typeof text !== "string" || text.trim() === "") throw new Error("There is no text to translate");

  requestHostService("present_results", { title, original: text, sections });
  return null;
})()
