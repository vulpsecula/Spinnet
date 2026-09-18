(() => {
  // Speaks the DeepL API v2 shape (POST {endpoint}/v2/translate, JSON body,
  // "Authorization: DeepL-Auth-Key <key>"). The Host reads the text, sends the
  // request only to a consented host, adds the key itself, and delivers the
  // result; this script only shapes the request and reads the response.
  const config = input && typeof input === "object" ? input : {};
  const endpoint = String(config.endpoint || "").replace(/\/+$/, "");
  if (!/^https:\/\//.test(endpoint)) throw new Error("Configure an https endpoint for Translator");

  let text;
  switch (commandID) {
    case "translator.copy":
    case "translator.replace":
      text = requestHostService("read_selected_text");
      break;
    case "translator.clipboard": {
      const clipboard = requestHostService("read_current_clipboard");
      text = clipboard && typeof clipboard.text === "string" ? clipboard.text : "";
      break;
    }
    default:
      throw new Error("Unknown Translator Command " + commandID);
  }
  if (typeof text !== "string" || text.trim() === "") throw new Error("There is no text to translate");

  const body = { text: [text], target_lang: config.target_language };
  if (config.formality && config.formality !== "default") body.formality = config.formality;
  const response = requestHostService("https_request", {
    method: "POST",
    url: endpoint + "/v2/translate",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
    credential: { reference: config.credential, header: "Authorization", format: "DeepL-Auth-Key {credential}" }
  });

  switch (response.status) {
    case 200: break;
    case 401:
    case 403: throw new Error("The translation service rejected the API key");
    case 429: throw new Error("Too many translation requests; try again shortly");
    case 456: throw new Error("The translation quota is used up");
    default: throw new Error("The translation service answered " + response.status);
  }
  let translated;
  try {
    translated = JSON.parse(response.body).translations[0].text;
  } catch (error) {
    throw new Error("The translation service sent an unexpected response");
  }
  if (typeof translated !== "string") throw new Error("The translation service sent an unexpected response");

  if (commandID === "translator.replace") {
    requestHostService("insert_text", translated);
  } else {
    requestHostService("write_clipboard", translated);
  }
  return null;
})()
