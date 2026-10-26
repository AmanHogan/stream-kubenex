// Lists the streams the background worker found in this tab and sends one to the
// downloader. A request carries the URL plus Referer, Origin and User-Agent. No cookies.

const $ = (id) => document.getElementById(id);

function el(tag, props = {}, ...kids) {
  const e = Object.assign(document.createElement(tag), props);
  e.append(...kids);
  return e;
}

function fmtBytes(n) {
  return n ? (n / 1e6).toFixed(0) + " MB" : "";
}

// "5 qualities, up to 1080p" for a master playlist; nothing for anything else.
function fmtQualities(item) {
  if (!item.qualities) return "";
  const n = item.qualities + (item.qualities === 1 ? " quality" : " qualities");
  return item.maxHeight ? `${n}, up to ${item.maxHeight}p` : n;
}

function say(text, cls = "") {
  $("msg").className = cls;
  $("msg").textContent = text;
}

// The page that played the video, or the frame inside it that requested the stream
// (embedded players often live on another domain). CDNs check these two headers.
function headersFor(tab, initiator) {
  const pageOrigin = new URL(tab.url).origin;
  if (initiator && initiator !== pageOrigin) return { referer: initiator + "/", origin: initiator };
  return { referer: tab.url, origin: pageOrigin };
}

async function send(button, tab, url, sniffed, initiator) {
  const { server, token } = await chrome.storage.local.get(["server", "token"]);
  if (!server || !token) {
    say("Set the server and API token in Settings first.", "bad");
    return;
  }
  button.disabled = true;
  try {
    const res = await fetch(server.replace(/\/$/, "") + "/api/downloads", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Api-Token": token },
      body: JSON.stringify({ url, sniffed, user_agent: navigator.userAgent, ...headersFor(tab, initiator) }),
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(typeof body.detail === "string" ? body.detail : res.status + " " + res.statusText);
    say(sniffed ? "Sent. Downloading now." : "Sent. Queued.", "ok");
    button.textContent = "Sent";
  } catch (e) {
    say("Failed: " + e.message, "bad");
    button.disabled = false;
  }
}

async function main() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab || !tab.url || !/^https?:/.test(tab.url)) {
    $("found").append(el("li", { className: "empty", textContent: "Open a video page first." }));
    return;
  }

  // For sites yt-dlp knows (YouTube and many more), the page URL is enough.
  const pageBtn = el("button", { textContent: "Send page" });
  pageBtn.onclick = () => send(pageBtn, tab, tab.url, false, "");
  $("page").append(el("li", {},
    el("span", { className: "tag", textContent: "Page" }),
    el("div", { className: "info" },
      el("div", { className: "url", textContent: tab.title || tab.url, title: tab.url }),
      el("div", { className: "muted", textContent: "For sites yt-dlp supports. Waits in the queue." })),
    pageBtn));

  const key = "tab:" + tab.id;
  // Variant playlists are hidden when their master is in the list (see hls.js).
  const items = visibleItems((await chrome.storage.session.get(key))[key] || []);
  // Masters first, then other stream manifests: they are usually the whole video in
  // the best quality.
  const order = { HLS: 0, DASH: 1, File: 2 };
  items.sort((a, b) => !!b.qualities - !!a.qualities || order[a.kind] - order[b.kind] || b.at - a.at);

  if (!items.length) {
    $("found").append(el("li", { className: "empty", textContent: "No streams yet. Press play, then open this again." }));
    return;
  }
  for (const item of items) {
    const u = new URL(item.url);
    const btn = el("button", { textContent: "Download" });
    btn.onclick = () => send(btn, tab, item.url, true, item.initiator);
    $("found").append(el("li", {},
      el("span", { className: "tag", textContent: item.kind }),
      el("div", { className: "info" },
        el("div", { className: "url", textContent: u.pathname.split("/").pop() || u.host, title: item.url }),
        el("div", { className: "muted", textContent: [u.host, fmtBytes(item.bytes), fmtQualities(item)].filter(Boolean).join(" · ") })),
      btn));
  }
}

main();
