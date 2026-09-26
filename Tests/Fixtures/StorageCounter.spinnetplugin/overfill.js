// Tries to keep a value over the 512 KiB limit. Plugin Storage stores nothing
// and throws an error the script can catch, so this carries on and shows what
// happened as a toast.
(() => {
  try {
    spinnet.storage.set({ key: "too-large", value: "x".repeat(600 * 1024) });
    return { toast: "Storage Counter stored a value over the limit" };
  } catch (error) {
    return { toast: `Storage Counter was refused (${error.code}): ${error.message}` };
  }
})()
