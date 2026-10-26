"""Guess whether a video is a movie, a TV episode or a clip, from its name.

Pure functions, no I/O, so they are easy to test. The guess only fills in the
starting values; the web form's Edit button fixes anything it gets wrong.
"""
import re

KINDS = ("movie", "episode", "clip")

# "Show.Name.S02E05...", "Show Name - s2e5", "Show_Name_S02_E05"
_SXXEYY = re.compile(r"^(?P<show>.*?)[\s._-]*\bS(?P<season>\d{1,2})[\s._-]*E(?P<episode>\d{1,3})\b(?P<rest>.*)$", re.I)
# "Show Name 2x05 ..."
_NXNN = re.compile(r"^(?P<show>.*?)[\s._-]+(?P<season>\d{1,2})x(?P<episode>\d{1,3})\b(?P<rest>.*)$", re.I)
# "Show Name Season 2 Episode 5 ..."
_WORDS = re.compile(r"^(?P<show>.*?)[\s._-]*\bseason[\s._-]*(?P<season>\d{1,2})[\s._-]*episode[\s._-]*(?P<episode>\d{1,3})\b(?P<rest>.*)$", re.I)
# "Movie Name (2019)", "Movie.Name.2019.1080p"
_YEAR = re.compile(r"^(?P<title>.+?)[\s._(\[-]+(?P<year>(?:19|20)\d{2})(?=$|[\s._)\]-])")
# Release tags. Everything from the first one on is noise, not part of the title.
_JUNK = re.compile(
    r"[\s._\[(-]*\b(2160p|1080p|720p|576p|480p|4k|uhd|hdr|x264|x265|h\.?264|h\.?265|hevc|avc|"
    r"web[\s._-]?dl|webrip|web|bluray|blu[\s._-]?ray|brrip|bdrip|hdrip|dvdrip|hdtv|remux|"
    r"aac\d?(\.\d)?|ac3|dts|ddp?\d?(\.\d)?|10bit|proper|repack|extended|unrated)\b.*$",
    re.I,
)


def tidy(text: str) -> str:
    """Dots and underscores become spaces; release tags and edge dashes go."""
    text = _JUNK.sub("", text)
    text = re.sub(r"[._]+", " ", text)
    text = re.sub(r"\s+", " ", text)
    return text.strip(" -[]()")


def guess(name: str, default_kind: str) -> dict:
    """Guess library fields from a file name or a video title.

    Returns kind, title, show, season, episode and year. default_kind is used
    when the name has neither an episode number nor a year: "movie" for files
    you import, "clip" for downloads.
    """
    for pattern in (_SXXEYY, _NXNN, _WORDS):
        m = pattern.match(name)
        if m and tidy(m["show"]):
            episode = int(m["episode"])
            return {
                "kind": "episode",
                "show": tidy(m["show"]),
                "season": int(m["season"]),
                "episode": episode,
                "title": tidy(m["rest"]) or f"Episode {episode}",
                "year": None,
            }
    m = _YEAR.match(name)
    if m and tidy(m["title"]):
        return {"kind": "movie", "title": tidy(m["title"]), "year": int(m["year"]),
                "show": None, "season": None, "episode": None}
    return {"kind": default_kind, "title": tidy(name) or name, "year": None,
            "show": None, "season": None, "episode": None}


def from_ytdlp(info: dict) -> dict:
    """Library fields for a download. Uses yt-dlp's series data when the site has it."""
    if info.get("series") and info.get("episode_number") is not None:
        episode = int(info["episode_number"])
        return {
            "kind": "episode",
            "show": info["series"],
            "season": int(info["season_number"]) if info.get("season_number") is not None else None,
            "episode": episode,
            "title": info.get("episode") or info.get("title") or f"Episode {episode}",
            "year": None,
        }
    fields = guess(info.get("title") or "", default_kind="clip")
    # A download keeps its real title unless it is an episode; tidy() is for file names.
    if fields["kind"] != "episode":
        fields["title"] = info.get("title") or fields["title"]
    if fields["kind"] != "episode":
        # A year in a video title is not proof of a movie. Leave it a clip.
        fields.update(kind="clip", year=None)
    return fields


def sort_key(video: dict) -> tuple:
    """Season, then episode, then title. Unknown numbers sort last."""
    big = 10_000
    return (
        video.get("season") if video.get("season") is not None else big,
        video.get("episode") if video.get("episode") is not None else big,
        (video.get("title") or "").lower(),
    )


def group(videos: list[dict]) -> dict:
    """Shape ready videos (newest first) into the Roku library layout."""
    movies = sorted((v for v in videos if v["kind"] == "movie"), key=lambda v: (v.get("title") or "").lower())
    # An episode with no show has nowhere to go on the Roku; show it as a clip.
    clips = [v for v in videos if v["kind"] == "clip" or (v["kind"] == "episode" and not v.get("show"))]
    shows: dict[str, list[dict]] = {}
    for v in videos:
        if v["kind"] == "episode" and v.get("show"):
            shows.setdefault(v["show"], []).append(v)

    show_list = []
    for name in sorted(shows, key=str.lower):
        episodes = sorted(shows[name], key=sort_key)
        seasons: dict = {}
        for e in episodes:
            seasons.setdefault(e.get("season"), []).append(e)
        show_list.append({
            "name": name,
            "thumbnail": next((e["thumbnail"] for e in episodes if e.get("thumbnail")), ""),
            "episode_count": len(episodes),
            "seasons": [{"season": s, "episodes": eps} for s, eps in seasons.items()],
        })
    return {"recent": videos[:12], "shows": show_list, "movies": movies, "clips": clips}
