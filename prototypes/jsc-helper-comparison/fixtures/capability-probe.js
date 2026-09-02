(() => {
  requestHostService("selection.read");
  requestHostService("process.spawn");
  return { checksum: String(input.length + iteration), output_bytes: input.length };
})()
