"""Watch progress rules: when a video counts as watched, intro and credits markers,
episode order, and the Continue Watching list.

Pure functions, no I/O. Times are whole seconds. Markers come from the show
(set once on the web form) unless the episode overrides them.
"""
import time

from . import library

# With no credits marker, a video counts as watched when this much is left:
# 2 minutes, or 10% for short clips (a 5-minute clip: the last 30 seconds).
DEFAULT_CREDITS = 120
# Stopping in the first 30 seconds leaves nothing worth resuming.
MIN_RESUME = 30
MARKERS = ("intro_start", "intro_end", "credits_before_end")


def markers(video: dict, show_markers: dict | None) -> dict:
    """The episode's own markers where set, otherwise the show's."""
    show_markers = show_markers or {}
    own_intro = video.get("intro_start") is not None and video.get("intro_end") is not None
    src = video if own_intro else show_markers
    credits = video.get("credits_before_end")
    if credits is None:
        credits = show_markers.get("credits_before_end")
    return {"intro_start": src.get("intro_start"), "intro_end": src.get("intro_end"),
            "credits_before_end": credits}


def credits_at(duration: int | None, credits_before_end: int | None) -> int | None:
    """Second at which the video counts as watched and Up Next appears."""
    if not duration:
        return None
    left = credits_before_end if credits_before_end is not None else min(DEFAULT_CREDITS, duration * 0.1)
    return max(0, int(duration - left))


def progress_update(duration: int | None, credits_before_end: int | None, position: int) -> dict:
    """Database fields to set when the player reports a position."""
    now = time.time()
    at = credits_at(duration, credits_before_end)
    if at is not None and position >= at:
        # Finished. Reset the position so the next play starts at the top, not in the credits.
        return {"watched": 1, "position": 0, "last_watched_at": now}
    return {"position": position if position >= MIN_RESUME else 0, "last_watched_at": now}


def enrich(videos: list[dict], show_markers: dict[str, dict]) -> list[dict]:
    """Add markers, credits_at, remaining time and next/previous episode ids.

    videos: ready videos as dicts with at least id, kind, show, season, episode,
    title, duration, position, watched and the three marker columns.
    """
    out = []
    for v in videos:
        m = markers(v, show_markers.get(v.get("show") or ""))
        position = v.get("position") or 0
        duration = v.get("duration") or 0
        out.append({
            **v, **m,
            "watched": bool(v.get("watched")),
            "credits_at": credits_at(duration, m["credits_before_end"]),
            "remaining": max(0, duration - position) if position else None,
            "next_id": None, "prev_id": None,
        })
    # Episode order within each show, across seasons: S1E1 ... S1E22, S2E1 ...
    shows: dict[str, list[dict]] = {}
    for v in out:
        if v["kind"] == "episode" and v.get("show"):
            shows.setdefault(v["show"], []).append(v)
    for episodes in shows.values():
        episodes.sort(key=library.sort_key)
        for prev, nxt in zip(episodes, episodes[1:]):
            prev["next_id"], nxt["prev_id"] = nxt["id"], prev["id"]
    return out


def continue_watching(videos: list[dict], limit: int = 12) -> list[dict]:
    """What to watch next, most recent activity first.

    One entry per show: the episode you stopped in, or else the first unwatched
    episode after the one you finished last. Movies and clips appear while
    they are part-watched. videos must come from enrich().
    """
    by_id = {v["id"]: v for v in videos}
    latest: dict[str, dict] = {}
    picks: list[tuple[float, dict]] = []
    for v in videos:
        if not v.get("last_watched_at"):
            continue
        if v["kind"] == "episode" and v.get("show"):
            cur = latest.get(v["show"])
            if cur is None or v["last_watched_at"] > cur["last_watched_at"]:
                latest[v["show"]] = v
        elif v.get("position") and not v["watched"]:
            picks.append((v["last_watched_at"], v))
    for v in latest.values():
        if v.get("position"):
            picks.append((v["last_watched_at"], v))
            continue
        nid = v.get("next_id")
        while nid and by_id[nid]["watched"]:
            nid = by_id[nid].get("next_id")
        if nid:
            picks.append((v["last_watched_at"], by_id[nid]))
    picks.sort(key=lambda p: p[0], reverse=True)
    return [v for _, v in picks[:limit]]
