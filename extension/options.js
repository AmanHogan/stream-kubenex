// Server address and API token, kept in this browser profile's extension storage only.

const $ = (id) => document.getElementById(id);

chrome.storage.local.get(["server", "token"]).then(({ server, token }) => {
  $("server").value = server || "http://192.168.4.247";
  $("token").value = token || "";
});

$("form").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  const server = $("server").value.trim().replace(/\/$/, "");
  if (!/^https?:\/\//.test(server)) {
    $("msg").className = "bad";
    $("msg").textContent = " Server must start with http:// or https://";
    return;
  }
  await chrome.storage.local.set({ server, token: $("token").value.trim() });
  $("msg").className = "ok";
  $("msg").textContent = " Saved.";
});
