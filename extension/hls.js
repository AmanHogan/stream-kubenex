// HLS helpers, shared by background.js (importScripts) and popup.js (<script>).
//
// A site's player first loads a master playlist, which lists one playlist per
// quality (and separate audio or subtitle playlists). It then loads one or more
// of those. Only the master is worth downloading: yt-dlp picks the best quality.

// The same playlist can come back with different query tokens, so compare
// playlists by origin and path only.
function pathKey(url) {
  const u = new URL(url);
  return u.origin + u.pathname;
}

// Returns null when the text is not a master playlist. Otherwise returns the
// path keys of every playlist it lists, the number of qualities, and the
// tallest resolution.
function parseHlsMaster(text, baseUrl) {
  if (!text.startsWith("#EXTM3U") || !text.includes("#EXT-X-STREAM-INF")) return null;
  const children = new Set();
  let qualities = 0;
  let maxHeight = 0;
  let expectUri = false;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    if (line.startsWith("#EXT-X-STREAM-INF")) {
      qualities++;
      const res = /RESOLUTION=\d+x(\d+)/.exec(line);
      if (res) maxHeight = Math.max(maxHeight, Number(res[1]));
      expectUri = true; // the next URI line is this quality's playlist
    } else if (/^#EXT-X-(MEDIA|I-FRAME-STREAM-INF):/.test(line)) {
      const uri = /URI="([^"]+)"/.exec(line);
      if (uri) children.add(pathKey(new URL(uri[1], baseUrl).href));
    } else if (!line.startsWith("#") && expectUri) {
      children.add(pathKey(new URL(line, baseUrl).href));
      expectUri = false;
    }
  }
  return { children: [...children], qualities, maxHeight };
}

// Drops every playlist that a master in the same list already covers.
function visibleItems(items) {
  const covered = new Set(items.flatMap((i) => i.children || []));
  return items.filter((i) => !covered.has(pathKey(i.url)));
}

if (typeof module !== "undefined") module.exports = { pathKey, parseHlsMaster, visibleItems };
