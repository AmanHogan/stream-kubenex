"""Tenrai (https://tenrai.org): MyAnimeList data for anime, as a backup to TVmaze.

TVmaze has titles but few synopses for some anime (13 of original Naruto's 220
episodes); MyAnimeList has most of them. Tenrai is the successor to the Jikan API
(whose public service closed on 1 Oct 2026) and keeps Jikan's response shapes. Its
free tier needs no key: 120 calls per minute per IP. The episode list carries the
synopses, 100 episodes per page, so a 220-episode show costs 3 calls.
"""

import json
import time
import urllib.parse
import urllib.request
from urllib.error import HTTPError

API = "https://api.tenrai.org/v1"
USER_AGENT = "stream-kubenex (home media server)"
TIMEOUT = 20
PAGE_PAUSE = 0.6  # seconds between pages, well under the per-minute limit
MAX_PAGES = 30    # 3,000 episodes; One Piece-sized shows stop here


def _json(path: str, retries: int = 3, **params) -> dict:
    query = urllib.parse.urlencode(params)
    req = urllib.request.Request(f"{API}{path}" + (f"?{query}" if query else ""),
                                 headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
    for attempt in range(retries + 1):
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                return json.loads(resp.read())
        except HTTPError as e:
            if e.code == 429 and attempt < retries:
                time.sleep(2 * (attempt + 1))
                continue
            raise
    raise RuntimeError("unreachable")


def search(query: str) -> list[dict]:
    """Up to 10 anime that match the name, as MyAnimeList ranks them."""
    out = []
    for a in _json("/anime", q=query, limit=10).get("data", []):
        image = ((a.get("images") or {}).get("jpg") or {}).get("image_url") or ""
        out.append({
            "mal_id": a["mal_id"],
            "title": a.get("title") or "",
            "title_english": a.get("title_english") or "",
            "type": a.get("type") or "",
            "year": a.get("year") or ((a.get("aired") or {}).get("prop", {}).get("from", {}) or {}).get("year"),
            "episodes": a.get("episodes"),
            "image": image,
            "synopsis": (a.get("synopsis") or "")[:300],
        })
    return out


def fetch(mal_id: int) -> dict:
    """The anime's title and every episode: number, title and synopsis."""
    info = _json(f"/anime/{int(mal_id)}").get("data", {})
    episodes = []
    for page in range(1, MAX_PAGES + 1):
        if page > 1:
            time.sleep(PAGE_PAUSE)
        d = _json(f"/anime/{int(mal_id)}/episodes", page=page)
        for e in d.get("data", []):
            episodes.append({
                "number": e["mal_id"],  # the episode's number within this anime, 1, 2, 3...
                "title": e.get("title") or "",
                "synopsis": (e.get("synopsis") or "").strip(),
            })
        if not (d.get("pagination") or {}).get("has_next_page"):
            break
    return {"mal_id": int(mal_id), "title": info.get("title_english") or info.get("title") or "",
            "episodes": episodes}
