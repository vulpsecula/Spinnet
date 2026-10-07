// Quits the App in front without a view and without reading which App it
// is: the Host names it in its Host Confirmation (#83).
spinnet.ui.request(spinnet.apps.quit.operation(null, { id: "front" }));
