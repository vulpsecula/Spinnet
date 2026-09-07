(() => {
  const selectedText = String(requestHostService("read_selected_text"));
  const output = selectedText
    .trim()
    .split(/\s+/)
    .map((word, index) => index % 2 === 0 ? word.toUpperCase() : word.toLowerCase())
    .join("-");
  requestHostService("write_clipboard", output);
  let checksum = 2166136261;
  for (let index = 0; index < output.length; index += 1) {
    checksum = Math.imul(checksum ^ output.charCodeAt(index), 16777619) >>> 0;
  }
  return { checksum: String(checksum), output_bytes: output.length };
})()
