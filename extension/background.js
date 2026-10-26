// Watches network responses for video streams and remembers them per tab.
//
// It sees only the URL, the initiator origin and response headers like
// Content-Type. It never asks for "extraHeaders", so Chrome never shows it
// Cookie or Set-Cookie headers. The only request it makes itself is a second,
// cookie-free read of each HLS playlist, to tell a master from its variants.
// It sends nothing to the downloader; the popup does that.

importScripts("hls.js");

const MANIFEST = /\.(m3u8|mpd)(\?|#|$)/i;
const MANIFEST_TYPE = /^(application\/(vnd\.apple\.mpegurl|x-mpegurl|dash\+xml)|audio\/(x-)?mpegurl)/i;
const VIDEO_FILE = /\.(mp4|m4v|webm|mov)(\?|#|$)/i;
// Stream segments, subtitles and audio-only files: never offered.
const SEGMENT = /\.(ts|m4s|m4a|aac|vtt|key)(\?|#|$)/i;
// Short segments of a stream are small; a whole video file is not.
const MIN_FILE_BYTES = 5 * 1024 * 1024;
const MAX_PER_TAB = 30;
// Playlists are small text files. Anything bigger is not one; do not read it.
const MAX_PLAYLIST_BYTES = 1024 * 1024;

function header(details, name) {
  const h = (details.responseHeaders || []).find((x) => x.name.toLowerCase() === name);
  return h ? h.value : "";
}

// Total size from "Content-Range: bytes 0-1023/123456", else Content-Length.
function totalBytes(details) {
  const range = header(details, "content-range").split("/")[1];
  return Number(range) || Number(header(details, "content-length")) || 0;
}

function classify(details) {
  const url = details.url;
  const type = header(details, "content-type").split(";")[0].trim();
  if (SEGMENT.test(url) || type === "video/mp2t") return null;
  if (MANIFEST.test(url) || MANIFEST_TYPE.test(type)) {
    return /mpd/i.test(url) || /dash/i.test(type) ? "DASH" : "HLS";
  }
  if (VIDEO_FILE.test(url) || type.startsWith("video/")) {
    const size = totalBytes(details);
    return size >= MIN_FILE_BYTES ? "File" : null;
  }
  return null;
}

async function load(tabId) {
  const key = "tab:" + tabId;
  return (await chrome.storage.session.get(key))[key] || [];
}

async function save(tabId, items) {
  await chrome.storage.session.set({ ["tab:" + tabId]: items });
  await chrome.action.setBadgeText({ tabId, text: items.length ? String(items.length) : "" });
}

// Run storage updates one at a time, so two responses that arrive together
// cannot overwrite each other's entry.
let chain = Promise.resolve();
function serial(fn) {
  chain = chain.then(fn).catch(() => {});
}

chrome.webRequest.onHeadersReceived.addListener(
  (details) => {
    if (details.tabId < 0 || details.statusCode >= 400) return;
    const kind = classify(details);
    if (!kind) return;
    serial(async () => {
      const items = await load(details.tabId);
      if (items.some((i) => i.url === details.url)) return;
      items.push({ url: details.url, kind, initiator: details.initiator || "", bytes: totalBytes(details), at: Date.now() });
      await save(details.tabId, items.slice(-MAX_PER_TAB));
      if (kind === "HLS") inspectHls(details.tabId, details.url);
    });
  },
  { urls: ["<all_urls>"], types: ["xmlhttprequest", "media", "other"] },
  ["responseHeaders"],
);

// Reads the playlist again, without cookies, and marks it as a master if it lists
// other playlists. The popup then hides those. If the read fails (the site wants
// cookies, or the URL already expired), nothing is hidden.
async function inspectHls(tabId, url) {
  let master = null;
  try {
    const res = await fetch(url, { credentials: "omit", cache: "force-cache" });
    if (!res.ok || Number(res.headers.get("content-length")) > MAX_PLAYLIST_BYTES) return;
    master = parseHlsMaster(await res.text(), url);
  } catch {
    return;
  }
  if (!master) return;
  serial(async () => {
    const items = await load(tabId);
    const item = items.find((i) => i.url === url);
    if (!item) return; // the tab moved to another page meanwhile
    Object.assign(item, master);
    await save(tabId, items);
  });
}

// A new page in the tab: forget what the old page loaded.
chrome.webRequest.onBeforeRequest.addListener(
  (details) => serial(() => save(details.tabId, [])),
  { urls: ["<all_urls>"], types: ["main_frame"] },
);

chrome.tabs.onRemoved.addListener((tabId) => chrome.storage.session.remove("tab:" + tabId));
