// Quits the App in front without a view and without reading which App it
// is: the Host quits it gracefully without a Host Confirmation (#83).
spinnet.ui.request(spinnet.apps.quit.operation(null, { id: "front" }));
