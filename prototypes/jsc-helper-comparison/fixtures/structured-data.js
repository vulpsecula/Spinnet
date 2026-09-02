(() => {
  const document = JSON.parse(input);
  const enabled = document.items
    .filter((item) => item.enabled)
    .sort((left, right) => left.name.localeCompare(right.name))
    .map((item) => `${item.id}:${item.name}`);
  const output = JSON.stringify(enabled);
  let checksum = 2166136261;
  for (let index = 0; index < output.length; index += 1) {
    checksum = Math.imul(checksum ^ output.charCodeAt(index), 16777619) >>> 0;
  }
  return { checksum: String(checksum), output_bytes: output.length };
})()
