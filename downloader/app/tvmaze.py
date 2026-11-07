"""TVmaze (https://www.tvmaze.com/api): show and episode data for the shows you have.

Free, no key. Rules from their API page: at least 20 calls per 10 s per IP (we make a
few per show), data under CC BY-SA (credit TVmaze with a link), images may be cached
forever. A matched show costs 3 calls: the show with all its episodes, its images,
and the poster or background picture we copy.
"""

import html
import json
import re
import time
import urllib.parse
import urllib.request
from urllib.error import HTTPError

API = "https://api.tvmaze.com"
# Pictures come only from TVmaze's own image server.
IMAGE_HOSTS = {"static.tvmaze.com"}
USER_AGENT = "stream-kubenex (home media server)"
TIMEOUT = 20


def _get(url: str, retries: int = 3) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    for attempt in range(retries + 1):
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                return resp.read()
        except HTTPError as e:
            # 429 = too many calls; TVmaze asks clients to wait and try again.
            if e.code == 429 and attempt < retries:
                time.sleep(2 * (attempt + 1))
                continue
            raise
    raise RuntimeError("unreachable")


def _json(path: str, **params) -> object:
    query = urllib.parse.urlencode(params, doseq=True)
    return json.loads(_get(f"{API}{path}" + (f"?{query}" if query else "")))


def plain(text: str | None) -> str:
    """TVmaze summaries are HTML ("<p>A <b>boy</b>...</p>"). Make them plain text."""
    if not text:
        return ""
    text = re.sub(r"<br\s*/?>|</p>\s*<p>", "\n", text)
    text = re.sub(r"<[^>]+>", "", text)
    return html.unescape(text).strip()


def search(query: str) -> list[dict]:
    """Up to 10 shows that match the name, best first."""
    out = []
    for hit in _json("/search/shows", q=query):
        s = hit["show"]
        network = (s.get("network") or s.get("webChannel") or {}).get("name") or ""
        out.append({
            "tvmaze_id": s["id"],
            "name": s["name"],
            "premiered": s.get("premiered") or "",
            "network": network,
            "language": s.get("language") or "",
            "image": (s.get("image") or {}).get("medium") or "",
            "summary": plain(s.get("summary"))[:300],
        })
    return out


def fetch_show(tvmaze_id: int) -> dict:
    """The show, every regular episode (no specials) and its best pictures."""
    s = _json(f"/shows/{int(tvmaze_id)}", embed="episodes")
    episodes = []
    for e in s.get("_embedded", {}).get("episodes", []):
        if e.get("season") is None or e.get("number") is None:
            continue
        episodes.append({
            "season": e["season"],
            "number": e["number"],
            "name": e.get("name") or "",
            "summary": plain(e.get("summary")),
            "airdate": e.get("airdate") or "",
            "runtime": e.get("runtime"),
        })
    episodes.sort(key=lambda e: (e["season"], e["number"]))
    for i, e in enumerate(episodes, start=1):
        e["absolute"] = i  # for files numbered straight through (S01E37 of a 4-season show)

    poster = ((s.get("image") or {}).get("original")) or ""
    background = ""
    try:
        images = _json(f"/shows/{int(tvmaze_id)}/images")
        backgrounds = [i for i in images if i.get("type") == "background"]
        # TVmaze marks one picture of each type as the main one.
        backgrounds.sort(key=lambda i: not i.get("main"))
        if backgrounds:
            background = backgrounds[0]["resolutions"]["original"]["url"]
    except (HTTPError, OSError, ValueError, KeyError):
        pass  # pictures are a bonus; the text still counts
    return {
        "tvmaze_id": s["id"],
        "name": s["name"],
        "premiered": s.get("premiered") or "",
        "summary": plain(s.get("summary")),
        "genres": s.get("genres") or [],
        "poster": poster,
        "background": background,
        "episodes": episodes,
    }


def fetch_image(url: str) -> bytes:
    host = urllib.parse.urlsplit(url).hostname or ""
    if urllib.parse.urlsplit(url).scheme != "https" or host not in IMAGE_HOSTS:
        raise ValueError(f"not a TVmaze image URL: {url}")
    return _get(url)
