(function () {
  "use strict";

  var entry = document.querySelector(".landing-entry");
  if (!entry) return;

  // Links activate on Enter, but Space is not a native link key. Keep both keys
  // useful for keyboard users without changing the server-owned destination.
  entry.addEventListener("keydown", function (event) {
    if (event.key === " " || event.key === "Spacebar" || event.code === "Space") {
      event.preventDefault();
      event.stopPropagation();
      entry.click();
    }
  });

  // Keep the single-task landing page keyboard-complete even before the link
  // receives focus. Enter remains native on the link; this covers body focus.
  document.addEventListener("keydown", function (event) {
    if (event.target === entry) return;
    if (event.key !== "Enter" && event.key !== " " && event.key !== "Spacebar" && event.code !== "Space") return;
    if (event.target && /^(INPUT|TEXTAREA|SELECT|BUTTON|A)$/.test(event.target.tagName)) return;
    event.preventDefault();
    entry.click();
  });
})();
