"""stream-kubenex downloader.

Takes a video URL, downloads it with yt-dlp as H.264/AAC MP4 (so the Roku plays it
without transcoding), and publishes a JSON feed for the Roku channel. If a site has no
H.264 format, it downloads the best format and converts it once with ffmpeg.
It also imports video files you upload, and converts them the same way when needed.

nginx runs next to this app in the same pod. It serves /media/ straight from disk
(with HTTP range requests, so seeking works) and proxies everything else here.

Security (see README "Security"):
- Writes and the video list need the API token. The Roku feed and /media/ stay open.
- A request carries a URL plus Referer, User-Agent and Origin. Never cookies.
- URLs that resolve to private, LAN, cluster or Tailscale addresses are refused.
  The NetworkPolicy in deploy/k8s enforces the same rule at the network level.
"""
import hashlib
import hmac
import ipaddress
import json
import os
import shutil
import socket
import sqlite3
import subprocess
import threading
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Literal
from urllib.parse import urlsplit

import anyio
import yt_dlp
from yt_dlp.networking.impersonate import ImpersonateTarget
from yt_dlp.utils import DownloadError
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, Response
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, ConfigDict, Field

from . import library, playback, subtitles

DATA_DIR = Path(os.environ.get("DATA_DIR", "/data"))
MEDIA_DIR = DATA_DIR / "media"
DB_PATH = DATA_DIR / "stream.db"
# The Roku cannot use Tailscale, so feed URLs must be a LAN address.
PUBLIC_BASE_URL = os.environ.get("PUBLIC_BASE_URL", "http://192.168.4.247").rstrip("/")
# Refuse new downloads below this much free disk, so videos never fill the node.
MIN_FREE_GB = float(os.environ.get("MIN_FREE_GB", "15"))
# Browser to impersonate for sites that block yt-dlp via TLS fingerprinting.
# Empty means no impersonation. Examples: "chrome", "safari", "chrome-110".
# Needs the curl-cffi extra (see requirements.txt).
IMPERSONATE = os.environ.get("IMPERSONATE", "").strip()
# Shared secret for writes and the video list (from the stream-api Secret).
# Empty means those requests are refused: the API fails closed.
API_TOKEN = os.environ.get("API_TOKEN", "").strip()

# H.264 video + AAC audio, capped at 1080p. Falls back to a single progressive MP4.
FORMAT = "bv*[vcodec^=avc1][height<=1080]+ba[ext=m4a]/b[ext=mp4][height<=1080]/b[ext=mp4]"
# Used only when FORMAT matches nothing: best video + audio of any codec, then
# convert() makes it H.264/AAC.
FALLBACK_FORMAT = "bv*[height<=1080]+ba/b[height<=1080]/bv*+ba/b"
# File types the import accepts. ffmpeg reads them all; convert_to_mp4() fixes the codecs.
IMPORT_EXTS = {".mp4", ".m4v", ".mov", ".mkv", ".webm", ".avi", ".ts", ".mts", ".wmv", ".flv", ".mpg", ".mpeg"}

SCHEMA = """
CREATE TABLE IF NOT EXISTS videos (
    id          TEXT PRIMARY KEY,
    url         TEXT NOT NULL,
    status      TEXT NOT NULL,              -- queued | downloading | converting | ready | failed
    progress    REAL NOT NULL DEFAULT 0,    -- 0..1
    title       TEXT,
    uploader    TEXT,
    duration    INTEGER,
    description TEXT,
    error       TEXT,
    size_bytes  INTEGER,
    created_at  REAL NOT NULL,
    referer     TEXT,
    user_agent  TEXT,
    origin      TEXT,
    sniffed     INTEGER NOT NULL DEFAULT 0, -- 1 = media URL caught by the browser extension
    source      TEXT NOT NULL DEFAULT 'url', -- url | upload
    kind        TEXT NOT NULL DEFAULT 'clip', -- movie | episode | clip
    show        TEXT,                       -- episodes only
    season      INTEGER,
    episode     INTEGER,
    year        INTEGER,
    position    INTEGER NOT NULL DEFAULT 0, -- seconds; 0 = nothing to resume
    watched     INTEGER NOT NULL DEFAULT 0,
    last_watched_at REAL,
    -- Per-episode overrides of the show's markers (seconds; NULL = use the show's).
    intro_start INTEGER,
    intro_end   INTEGER,
    credits_before_end INTEGER
)
"""
# Per-show settings from the web form: intro/credits markers and optional artwork.
SHOWS_SCHEMA = """
CREATE TABLE IF NOT EXISTS shows (
    name        TEXT PRIMARY KEY,
    intro_start INTEGER,
    intro_end   INTEGER,
    credits_before_end INTEGER,
    art         TEXT,                       -- old single picture; moved to artwork at startup
    art_version INTEGER,
    -- Details screen. Typed on the web form today; a metadata import can fill the same columns later.
    year        INTEGER,                    -- first aired
    description TEXT
)
"""
# Columns added after the first release. Older databases get them at startup.
ADDED_COLUMNS = {
    "referer": "TEXT",
    "user_agent": "TEXT",
    "origin": "TEXT",
    "sniffed": "INTEGER NOT NULL DEFAULT 0",
    "source": "TEXT NOT NULL DEFAULT 'url'",
    "kind": "TEXT NOT NULL DEFAULT 'clip'",
    "show": "TEXT",
    "season": "INTEGER",
    "episode": "INTEGER",
    "year": "INTEGER",
    "position": "INTEGER NOT NULL DEFAULT 0",
    "watched": "INTEGER NOT NULL DEFAULT 0",
    "last_watched_at": "REAL",
    "intro_start": "INTEGER",
    "intro_end": "INTEGER",
    "credits_before_end": "INTEGER",
}

SHOWS_ADDED_COLUMNS = {"art": "TEXT", "art_version": "INTEGER", "year": "INTEGER", "description": "TEXT"}

# Subtitle tracks, one row per WebVTT file <video id>.sub<n>.vtt next to the video.
SUBTITLES_SCHEMA = """
CREATE TABLE IF NOT EXISTS subtitles (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    video_id    TEXT NOT NULL,
    file        TEXT NOT NULL,
    language    TEXT NOT NULL,              -- ISO 639-2, e.g. eng; und = unknown
    forced      INTEGER NOT NULL DEFAULT 0, -- only the foreign-language lines
    sdh         INTEGER NOT NULL DEFAULT 0, -- includes sound descriptions
    source      TEXT NOT NULL,              -- embedded | upload | download
    created_at  REAL NOT NULL
)
"""
# Languages yt-dlp fetches a site's subtitles in (its --sub-langs syntax).
# Auto-generated captions are never fetched.
SUB_LANGS = [s.strip() for s in os.environ.get("SUB_LANGS", "en.*,eng.*").split(",") if s.strip()]

# Artwork for a show ("show:<name>") or a video ("video:<id>", used for movies), one
# file per slot in media/art/, served by nginx. version changes on every upload, so
# the Roku (which caches pictures by URL) fetches the new one.
ARTWORK_SCHEMA = """
CREATE TABLE IF NOT EXISTS artwork (
    owner   TEXT NOT NULL,
    slot    TEXT NOT NULL,                  -- background | boxart | logo
    file    TEXT NOT NULL,
    version INTEGER NOT NULL,
    PRIMARY KEY (owner, slot)
)
"""
ART_DIR = MEDIA_DIR / "art"
MAX_ART_BYTES = 15 * 1024 * 1024
# Each slot is cropped or fitted to the shape the Roku shows, so any picture works.
#   background: 16:9, cropped to fill.  boxart: 2:3 (a DVD cover), cropped to fill.
#   logo: fitted inside 1000x400, transparency kept (upload a PNG).
ART_SLOTS = {
    "background": ("jpg", "scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,format=yuvj420p"),
    "boxart": ("jpg", "scale=600:900:force_original_aspect_ratio=increase,crop=600:900,format=yuvj420p"),
    "logo": ("png", "scale=w='min(1000,iw)':h='min(400,ih)':force_original_aspect_ratio=decrease,format=rgba"),
}

app = FastAPI(title="stream-kubenex")
# One worker per lane. Page URLs ("queue") wait their turn. Media URLs from the
# extension ("fast") are often signed and expire in minutes, so they start at once.
# Uploaded files ("upload") need no network, so they never wait behind a download.
LANES = {
    "queue": "source = 'url' AND sniffed = 0",
    "fast": "source = 'url' AND sniffed = 1",
    "upload": "source = 'upload'",
}
WAKE = {lane: threading.Event() for lane in LANES}
# ffmpeg uses every CPU core while it encodes; never run two encodes at once.
_convert_lock = threading.Lock()


@contextmanager
def db():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def set_fields(vid: str, **fields) -> None:
    cols = ", ".join(f"{k} = ?" for k in fields)
    with db() as conn:
        conn.execute(f"UPDATE videos SET {cols} WHERE id = ?", (*fields.values(), vid))


def free_gb() -> float:
    return shutil.disk_usage(MEDIA_DIR).free / 1e9


def remove_files(vid: str) -> None:
    # Covers the final .mp4/.jpg, yt-dlp leftovers like .f137.mp4 and .part, the
    # .src.* / .conv.mp4 files of a conversion, and the .sub<n>.vtt subtitles.
    for f in MEDIA_DIR.glob(f"{vid}.*"):
        f.unlink(missing_ok=True)
    with db() as conn:
        conn.execute("DELETE FROM subtitles WHERE video_id = ?", (vid,))


# --- subtitles ------------------------------------------------------------------

def next_subtitle_path(vid: str) -> Path:
    n = 1
    while (MEDIA_DIR / f"{vid}.sub{n}.vtt").exists():
        n += 1
    return MEDIA_DIR / f"{vid}.sub{n}.vtt"


def add_subtitle(vid: str, path: Path, language: str, forced: bool, sdh: bool, source: str) -> int:
    with db() as conn:
        cur = conn.execute(
            "INSERT INTO subtitles (video_id, file, language, forced, sdh, source, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (vid, path.name, language, int(forced), int(sdh), source, time.time()),
        )
        return cur.lastrowid


def extract_embedded_subtitles(vid: str, src: Path) -> None:
    """Keep every text subtitle track of an imported or converted file. Best effort:
    a file whose subtitles cannot be read still imports."""
    try:
        tracks = subtitles.text_tracks(src)
        outs = []
        for _ in tracks:
            out = next_subtitle_path(vid)
            out.touch()  # reserve the name before picking the next one
            outs.append(out)
        for t, out, ok in zip(tracks, outs, subtitles.extract(src, tracks, outs)):
            if ok:
                add_subtitle(vid, out, t["language"], t["forced"], t["sdh"], "embedded")
            else:
                out.unlink(missing_ok=True)
    except Exception:  # noqa: BLE001 - subtitles are optional
        pass


class _SilentLogger:
    """yt-dlp logger that drops everything; subtitle fetching is best effort."""

    def debug(self, msg: str) -> None:
        pass

    info = warning = error = debug


def fetch_site_subtitles(vid: str, url: str, headers: dict) -> None:
    """Ask yt-dlp for the site's own subtitles (no video). Best effort, so a site
    that fails here does not fail a download that already worked."""
    opts = {
        "skip_download": True,
        "writesubtitles": True,
        "writeautomaticsub": False,
        "subtitleslangs": SUB_LANGS,
        "subtitlesformat": "vtt/srt/ass/best",
        "outtmpl": {"subtitle": str(MEDIA_DIR / f"{vid}.ytsub.%(ext)s")},
        "noplaylist": True,
        "quiet": True,
        "no_warnings": True,
        "noprogress": True,
        # Segmented (HLS) subtitles print fragment progress even with noprogress.
        "logger": _SilentLogger(),
    }
    if headers:
        opts["http_headers"] = headers
    if IMPERSONATE:
        opts["impersonate"] = ImpersonateTarget.from_str(IMPERSONATE)
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            ydl.extract_info(url, download=True)
    except Exception:  # noqa: BLE001 - subtitles are optional
        pass
    # yt-dlp names them <vid>.ytsub.<lang>.<ext>.
    for f in sorted(MEDIA_DIR.glob(f"{vid}.ytsub.*")):
        lang_code = f.name[len(f"{vid}.ytsub."):].rsplit(".", 1)[0]
        out = next_subtitle_path(vid)
        # WebVTT from yt-dlp is already clean, and it merges segmented (HLS)
        # subtitles itself; a second pass through ffmpeg garbles the first cue of
        # every segment. Only other formats (SRT, ASS) go through ffmpeg.
        if f.suffix == ".vtt" and subtitles.usable(f):
            out.write_text(subtitles.repair_vtt(f.read_text(encoding="utf-8", errors="replace")), encoding="utf-8")
            ok = subtitles.usable(out)
        else:
            ok = subtitles.convert_file(f, out)
        if ok:
            add_subtitle(vid, out, subtitles.normalize_language(lang_code), False, False, "download")
        else:
            out.unlink(missing_ok=True)
        f.unlink(missing_ok=True)


def subtitle_map(conn: sqlite3.Connection) -> dict[str, list[dict]]:
    """Subtitle tracks by video id: full tracks first, then SDH, then forced."""
    out: dict[str, list[dict]] = {}
    for r in conn.execute("SELECT * FROM subtitles ORDER BY forced, sdh, id"):
        out.setdefault(r["video_id"], []).append({
            "id": r["id"],
            "url": f"{PUBLIC_BASE_URL}/media/{r['file']}",
            "language": r["language"],
            "label": subtitles.make_label(r["language"], bool(r["forced"]), bool(r["sdh"])),
            "forced": bool(r["forced"]),
            "sdh": bool(r["sdh"]),
            "source": r["source"],
        })
    return out


# --- download worker ----------------------------------------------------------

def lane_of(row: sqlite3.Row) -> str:
    if row["source"] == "upload":
        return "upload"
    return "fast" if row["sniffed"] else "queue"


def worker(lane: str) -> None:
    wake = WAKE[lane]
    while True:
        with db() as conn:
            # LANES holds fixed SQL from this file, never user input.
            row = conn.execute(
                f"SELECT * FROM videos WHERE status = 'queued' AND {LANES[lane]} ORDER BY created_at LIMIT 1"
            ).fetchone()
        if row is None:
            wake.wait(timeout=30)
            wake.clear()
            continue
        if lane == "upload":
            import_file(row)
        else:
            download(row)


def download(row: sqlite3.Row) -> None:
    vid, url = row["id"], row["url"]
    set_fields(vid, status="downloading", progress=0, error=None)
    if free_gb() < MIN_FREE_GB:
        set_fields(vid, status="failed", error=f"Only {free_gb():.1f} GB free; need {MIN_FREE_GB:.0f} GB.")
        return

    # Send the same headers the browser sent, so CDNs that check them accept us.
    headers = {
        name: row[col]
        for name, col in (("Referer", "referer"), ("User-Agent", "user_agent"), ("Origin", "origin"))
        if row[col]
    }
    try:
        try:
            fetch(vid, url, headers, convert=False)
        except DownloadError as e:
            if "Requested format is not available" not in str(e):
                raise
            # The site has no H.264. Take the best format and convert it.
            remove_files(vid)
            fetch(vid, url, headers, convert=True)
        mp4 = MEDIA_DIR / f"{vid}.mp4"
        if not mp4.exists():
            raise RuntimeError("yt-dlp finished but produced no MP4.")
        fetch_site_subtitles(vid, url, headers)
        set_fields(vid, status="ready", progress=1, size_bytes=mp4.stat().st_size)
    except Exception as e:  # yt-dlp and ffmpeg fail in many ways; all mean "this download failed"
        remove_files(vid)
        set_fields(vid, status="failed", error=str(e)[:500])


def fetch(vid: str, url: str, headers: dict, convert: bool) -> None:
    """Download with yt-dlp. With convert=True, take any codec and run convert() after."""
    last_update = 0.0

    def on_progress(d: dict) -> None:
        nonlocal last_update
        total = d.get("total_bytes") or d.get("total_bytes_estimate")
        if d["status"] == "downloading" and total and time.monotonic() - last_update > 1:
            last_update = time.monotonic()
            set_fields(vid, progress=round(d["downloaded_bytes"] / total, 3))

    opts = {
        "format": FALLBACK_FORMAT if convert else FORMAT,
        # MKV holds any codec pair; convert() reads it and writes the MP4.
        "merge_output_format": "mkv" if convert else "mp4",
        "outtmpl": {
            "default": str(MEDIA_DIR / (f"{vid}.src.%(ext)s" if convert else f"{vid}.%(ext)s")),
            "thumbnail": str(MEDIA_DIR / f"{vid}.%(ext)s"),
        },
        "noplaylist": True,
        "writethumbnail": True,
        "postprocessors": [{"key": "FFmpegThumbnailsConvertor", "format": "jpg", "when": "before_dl"}],
        "progress_hooks": [on_progress],
        "quiet": True,
        "no_warnings": True,
    }
    if not convert:
        # Put the MP4 index at the front so the Roku starts playing before the whole file loads.
        # Separate streams go through the merger; HLS goes through the FixupM3u8 remux.
        faststart = ["-movflags", "+faststart"]
        opts["postprocessor_args"] = {"merger+ffmpeg_o": faststart, "fixupm3u8+ffmpeg_o": faststart}
    if headers:
        opts["http_headers"] = headers
    if IMPERSONATE:
        # yt-dlp picks the closest target curl-cffi actually supports.
        opts["impersonate"] = ImpersonateTarget.from_str(IMPERSONATE)

    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(url, download=False)
        set_fields(
            vid,
            uploader=info.get("uploader"),
            duration=int(info.get("duration") or 0),
            description=(info.get("description") or "")[:500],
            **library.from_ytdlp(info),
        )
        ydl.process_ie_result(info, download=True)

    if convert:
        src = next((p for p in MEDIA_DIR.glob(f"{vid}.src.*") if p.suffix not in (".part", ".ytdl")), None)
        if src is None:
            raise RuntimeError("yt-dlp finished but produced no file.")
        extract_embedded_subtitles(vid, src)
        convert_to_mp4(vid, src)


# --- conversion ---------------------------------------------------------------

def probe(path: Path) -> dict:
    """The first video and audio stream of a file, and its duration, from ffprobe."""
    proc = subprocess.run(
        ["ffprobe", "-v", "error", "-of", "json",
         "-show_entries", "stream=codec_type,codec_name,height,pix_fmt:format=duration", str(path)],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError("ffmpeg cannot read this file. It is not a video, or it is damaged.")
    data = json.loads(proc.stdout)
    streams = data.get("streams", [])

    def first(kind: str) -> dict:
        return next((s for s in streams if s.get("codec_type") == kind), {})

    return {
        "video": first("video"),
        "audio": first("audio"),
        "duration": float(data.get("format", {}).get("duration") or 0),
    }


def convert_to_mp4(vid: str, src: Path) -> None:
    """Write <vid>.mp4 as H.264/AAC, max 1080p. Copies a stream when it already fits."""
    info = probe(src)
    v, a = info["video"], info["audio"]
    if not v:
        raise RuntimeError("The downloaded file has no video stream.")
    # 8-bit 4:2:0 H.264 up to 1080p is what every Roku plays.
    video_ok = v.get("codec_name") == "h264" and v.get("pix_fmt") == "yuv420p" and (v.get("height") or 0) <= 1080

    tmp = MEDIA_DIR / f"{vid}.conv.mp4"
    cmd = ["ffmpeg", "-nostdin", "-y", "-v", "error", "-progress", "pipe:1",
           "-i", str(src), "-map", "0:v:0", "-map", "0:a:0?"]
    if video_ok:
        cmd += ["-c:v", "copy"]
    else:
        cmd += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "21", "-pix_fmt", "yuv420p",
                "-vf", "scale=-2:'min(1080,ih)'"]
    cmd += ["-c:a", "copy"] if a.get("codec_name") == "aac" else ["-c:a", "aac", "-b:a", "160k"]
    cmd += ["-movflags", "+faststart", str(tmp)]

    with _convert_lock:
        set_fields(vid, status="converting", progress=0)
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        last_update = 0.0
        for line in proc.stdout:
            # -progress prints key=value lines; out_time_us is how far ffmpeg has written.
            key, _, value = line.strip().partition("=")
            if key == "out_time_us" and value.isdigit() and info["duration"] and time.monotonic() - last_update > 1:
                last_update = time.monotonic()
                set_fields(vid, progress=round(min(int(value) / 1e6 / info["duration"], 1), 3))
        err = proc.stderr.read()
        if proc.wait() != 0:
            raise RuntimeError(f"ffmpeg failed: {err.strip()[-300:]}")

    tmp.rename(MEDIA_DIR / f"{vid}.mp4")
    src.unlink(missing_ok=True)


# --- import -------------------------------------------------------------------

def import_file(row: sqlite3.Row) -> None:
    """Turn an uploaded <vid>.src.<ext> into a ready <vid>.mp4 and <vid>.jpg."""
    vid = row["id"]
    try:
        src = next(MEDIA_DIR.glob(f"{vid}.src.*"), None)
        if src is None:
            raise RuntimeError("The uploaded file is missing. Upload it again.")
        duration = probe(src)["duration"]
        set_fields(vid, duration=int(duration))
        make_thumbnail(vid, src, duration)
        extract_embedded_subtitles(vid, src)
        convert_to_mp4(vid, src)
        mp4 = MEDIA_DIR / f"{vid}.mp4"
        set_fields(vid, status="ready", progress=1, size_bytes=mp4.stat().st_size)
    except Exception as e:  # ffprobe/ffmpeg fail in many ways; all mean "this import failed"
        remove_files(vid)
        set_fields(vid, status="failed", error=str(e)[:500])


# The Roku shows the focused card at 960x540 and the details backdrop at 1280x720.
THUMB_WIDTH = 1280


def make_thumbnail(vid: str, src: Path, duration: float) -> None:
    """One frame from 10% into the video. A missing thumbnail is not an error."""
    tmp = MEDIA_DIR / f"{vid}.thumb.jpg"
    subprocess.run(
        ["ffmpeg", "-nostdin", "-y", "-v", "error", "-ss", str(duration * 0.1), "-i", str(src),
         "-frames:v", "1", "-vf", f"scale='min({THUMB_WIDTH},iw)':-2", "-q:v", "3", str(tmp)],
        capture_output=True, timeout=120,
    )
    if tmp.exists() and tmp.stat().st_size > 0:
        tmp.replace(MEDIA_DIR / f"{vid}.jpg")  # the swap is atomic, so nginx never serves half a file
    else:
        tmp.unlink(missing_ok=True)


def image_width(path: Path) -> int:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width",
         "-of", "csv=p=0", str(path)],
        capture_output=True, text=True, timeout=30,
    )
    try:
        return int(out.stdout.strip())
    except ValueError:
        return 0


def upgrade_thumbnails() -> None:
    """Thumbnails from before the big home cards were 480 wide, and some sites give small
    ones. Make a new one from the video itself. Runs once per start; cheap when done."""
    with db() as conn:
        rows = conn.execute("SELECT id, duration FROM videos WHERE status = 'ready'").fetchall()
    for r in rows:
        mp4, jpg = MEDIA_DIR / f"{r['id']}.mp4", MEDIA_DIR / f"{r['id']}.jpg"
        if not mp4.exists() or (jpg.exists() and image_width(jpg) >= 960):
            continue
        try:
            make_thumbnail(r["id"], mp4, float(r["duration"] or 0))
        except subprocess.TimeoutExpired:
            pass


@app.on_event("startup")
def startup() -> None:
    MEDIA_DIR.mkdir(parents=True, exist_ok=True)
    with db() as conn:
        conn.execute(SCHEMA)
        conn.execute(SHOWS_SCHEMA)
        conn.execute(SUBTITLES_SCHEMA)
        conn.execute(ARTWORK_SCHEMA)
        have_shows = {r["name"] for r in conn.execute("PRAGMA table_info(shows)")}
        for col, sql_type in SHOWS_ADDED_COLUMNS.items():
            if col not in have_shows:
                conn.execute(f"ALTER TABLE shows ADD COLUMN {col} {sql_type}")
        conn.execute(
            "INSERT OR IGNORE INTO artwork (owner, slot, file, version) "
            "SELECT 'show:' || name, 'background', art, COALESCE(art_version, 0) FROM shows WHERE art IS NOT NULL")
        conn.execute("UPDATE shows SET art = NULL, art_version = NULL WHERE art IS NOT NULL")
        have = {r["name"] for r in conn.execute("PRAGMA table_info(videos)")}
        for col, sql_type in ADDED_COLUMNS.items():
            if col not in have:
                conn.execute(f"ALTER TABLE videos ADD COLUMN {col} {sql_type}")
        if "kind" not in have:
            # First start with the library fields: guess them for the existing videos.
            for r in conn.execute("SELECT id, title, source FROM videos").fetchall():
                fields = library.guess(r["title"] or "", "movie" if r["source"] == "upload" else "clip")
                if r["source"] != "upload":
                    fields["title"] = r["title"]  # keep a download's real title
                cols = ", ".join(f"{k} = ?" for k in fields)
                conn.execute(f"UPDATE videos SET {cols} WHERE id = ?", (*fields.values(), r["id"]))
        # A pod restart interrupts running work; queue it again.
        conn.execute("UPDATE videos SET status = 'queued' WHERE status IN ('downloading', 'converting')")
    for lane in LANES:
        threading.Thread(target=worker, args=(lane,), daemon=True).start()
    threading.Thread(target=upgrade_thumbnails, daemon=True).start()


# --- API ----------------------------------------------------------------------

def require_token(x_api_token: str = Header(default="")) -> None:
    if not API_TOKEN:
        raise HTTPException(503, "The server has no API_TOKEN set.")
    if not hmac.compare_digest(x_api_token.encode(), API_TOKEN.encode()):
        raise HTTPException(401, "Missing or wrong API token.")


def check_public_url(url: str) -> None:
    """Refuse a URL unless its host resolves only to public internet addresses.

    This stops the downloader from fetching Proxmox, ArgoCD, cluster services or
    Tailscale peers. Redirects and DNS changes after this check are stopped by the
    NetworkPolicy instead.
    """
    try:
        parts = urlsplit(url)
        host = parts.hostname
        if parts.scheme not in ("http", "https") or not host:
            raise ValueError
        addrs = {ai[4][0] for ai in socket.getaddrinfo(host, None, proto=socket.IPPROTO_TCP)}
    except (ValueError, UnicodeError, socket.gaierror):
        raise HTTPException(400, "URL must be an http:// or https:// address with a host that resolves.")
    for addr in addrs:
        ip = ipaddress.ip_address(addr.split("%")[0])
        if ip.version == 6 and ip.ipv4_mapped:
            ip = ip.ipv4_mapped
        # is_global is False for private, loopback, link-local and 100.64.0.0/10 (Tailscale).
        if not ip.is_global:
            raise HTTPException(400, "URL points to a private or internal address.")


def check_header(name: str, value: str | None, must_be_url: bool) -> str | None:
    if not value:
        return None
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise HTTPException(400, f"{name} has control characters.")
    if must_be_url and not value.startswith(("http://", "https://")):
        raise HTTPException(400, f"{name} must start with http:// or https://")
    return value


class DownloadRequest(BaseModel):
    # Unknown fields are an error, so a cookie or auth header can never ride along.
    model_config = ConfigDict(extra="forbid")

    url: str = Field(max_length=4096)
    # The only headers the downloader ever sends.
    referer: str | None = Field(default=None, max_length=4096)
    user_agent: str | None = Field(default=None, max_length=512)
    origin: str | None = Field(default=None, max_length=512)
    # True for media URLs caught by the browser extension: they skip the queue.
    sniffed: bool = False


def artwork_map(conn: sqlite3.Connection) -> dict[str, dict[str, str]]:
    """owner -> {slot: full URL}. Missing slots are absent."""
    art: dict[str, dict[str, str]] = {}
    for r in conn.execute("SELECT owner, slot, file, version FROM artwork"):
        art.setdefault(r["owner"], {})[r["slot"]] = f"{PUBLIC_BASE_URL}/media/art/{r['file']}?v={r['version']}"
    return art


def show_markers(conn: sqlite3.Connection) -> dict[str, dict]:
    """Per-show settings by show name, with its artwork URLs ("" = none)."""
    art = artwork_map(conn)
    shows = {}
    for r in conn.execute("SELECT * FROM shows"):
        s = dict(r)
        del s["art"], s["art_version"]
        shows[s["name"]] = s
    # A show may have artwork before it has any other settings.
    for owner in art:
        if owner.startswith("show:"):
            shows.setdefault(owner[5:], {"name": owner[5:]})
    for name, s in shows.items():
        slots = art.get(f"show:{name}", {})
        s["artwork"] = {slot: slots.get(slot, "") for slot in ART_SLOTS}
    return shows


def media_urls(vid: str) -> dict:
    thumb = MEDIA_DIR / f"{vid}.jpg"
    return {
        "url": f"{PUBLIC_BASE_URL}/media/{vid}.mp4",
        # ?v= changes when the picture does; the Roku caches pictures by URL.
        "thumbnail": f"{PUBLIC_BASE_URL}/media/{vid}.jpg?v={int(thumb.stat().st_mtime)}" if thumb.exists() else "",
    }


@app.post("/api/downloads", status_code=202, dependencies=[Depends(require_token)])
def create_download(req: DownloadRequest) -> dict:
    url = req.url.strip()
    check_public_url(url)
    referer = check_header("Referer", req.referer, must_be_url=True)
    origin = check_header("Origin", req.origin, must_be_url=True)
    user_agent = check_header("User-Agent", req.user_agent, must_be_url=False)
    vid = uuid.uuid4().hex[:12]
    with db() as conn:
        conn.execute(
            "INSERT INTO videos (id, url, status, created_at, referer, user_agent, origin, sniffed) "
            "VALUES (?, ?, 'queued', ?, ?, ?, ?, ?)",
            (vid, url, time.time(), referer, user_agent, origin, int(req.sniffed)),
        )
    WAKE["fast" if req.sniffed else "queue"].set()
    return {"id": vid, "status": "queued"}


@app.post("/api/uploads", status_code=202, dependencies=[Depends(require_token)])
async def upload_file(request: Request, filename: str = Query(min_length=1, max_length=255)) -> dict:
    """Import a video file. The request body is the raw file; it streams straight to disk."""
    ext = Path(filename).suffix.lower()
    if ext not in IMPORT_EXTS:
        raise HTTPException(400, f"Not a video file type I import: {ext or 'no extension'}.")
    size = int(request.headers.get("content-length") or 0)
    if not size:
        raise HTTPException(411, "Content-Length is required.")
    # Room for the upload and, if it needs converting, a second copy.
    if (shutil.disk_usage(MEDIA_DIR).free - 2 * size) / 1e9 < MIN_FREE_GB:
        raise HTTPException(507, f"Not enough disk: need {2 * size / 1e9:.1f} GB plus {MIN_FREE_GB:.0f} GB free.")

    vid = uuid.uuid4().hex[:12]
    src = MEDIA_DIR / f"{vid}.src{ext}"
    written = 0
    try:
        with open(src, "wb") as f:
            async for chunk in request.stream():
                written += len(chunk)
                if written > size:
                    raise HTTPException(400, "The body is larger than Content-Length.")
                await anyio.to_thread.run_sync(f.write, chunk)
        if written != size:
            raise HTTPException(400, "The upload stopped before the end of the file.")
    except BaseException:  # includes the browser closing the connection
        src.unlink(missing_ok=True)
        raise

    fields = library.guess(Path(filename).stem, default_kind="movie")
    with db() as conn:
        conn.execute(
            "INSERT INTO videos (id, url, status, created_at, source, title, kind, show, season, episode, year) "
            "VALUES (?, ?, 'queued', ?, 'upload', ?, ?, ?, ?, ?, ?)",
            (vid, f"upload:{filename}", time.time(), fields["title"], fields["kind"],
             fields["show"], fields["season"], fields["episode"], fields["year"]),
        )
    WAKE["upload"].set()
    return {"id": vid, "status": "queued"}


@app.get("/api/videos", dependencies=[Depends(require_token)])
def list_videos() -> dict:
    with db() as conn:
        rows = [dict(r) for r in conn.execute("SELECT * FROM videos ORDER BY created_at DESC")]
        shows = show_markers(conn)
        subs = subtitle_map(conn)
        art = artwork_map(conn)
    for r in rows:
        r["subtitles"] = subs.get(r["id"], [])
        slots = art.get(f"video:{r['id']}", {})
        r["artwork"] = {slot: slots.get(slot, "") for slot in ART_SLOTS}
    for r in rows:
        if r["status"] == "ready":
            r.update(media_urls(r["id"]))
    usage = shutil.disk_usage(MEDIA_DIR)
    return {
        "videos": rows,
        "shows": shows,
        "disk": {
            "free_gb": round(usage.free / 1e9, 1),
            "total_gb": round(usage.total / 1e9, 1),
            "min_free_gb": MIN_FREE_GB,
        },
    }


@app.post("/api/videos/{vid}/retry", status_code=202, dependencies=[Depends(require_token)])
def retry_video(vid: str) -> dict:
    with db() as conn:
        row = conn.execute("SELECT sniffed, source FROM videos WHERE id = ? AND status = 'failed'", (vid,)).fetchone()
        if row is None:
            raise HTTPException(404, "No failed video with that id.")
        if row["source"] == "upload":
            # A failed import deletes its file, so there is nothing to retry.
            raise HTTPException(409, "Upload the file again.")
        conn.execute("UPDATE videos SET status = 'queued', progress = 0, error = NULL WHERE id = ?", (vid,))
    WAKE[lane_of(row)].set()
    return {"id": vid, "status": "queued"}


class VideoUpdate(BaseModel):
    """Library fields the web form's Edit button may change. Send only what changes."""
    model_config = ConfigDict(extra="forbid")

    kind: Literal["movie", "episode", "clip"] | None = None
    title: str | None = Field(default=None, max_length=300)
    show: str | None = Field(default=None, max_length=200)
    season: int | None = Field(default=None, ge=0, le=999)
    episode: int | None = Field(default=None, ge=0, le=9999)
    year: int | None = Field(default=None, ge=1880, le=2100)
    description: str | None = Field(default=None, max_length=5000)
    # Per-episode overrides of the show's markers, in seconds. null = use the show's.
    intro_start: int | None = Field(default=None, ge=0, le=36000)
    intro_end: int | None = Field(default=None, ge=0, le=36000)
    credits_before_end: int | None = Field(default=None, ge=0, le=36000)


class Markers(BaseModel):
    """Intro and credits markers in seconds. All null = none."""
    model_config = ConfigDict(extra="forbid")

    intro_start: int | None = Field(default=None, ge=0, le=36000)
    intro_end: int | None = Field(default=None, ge=0, le=36000)
    credits_before_end: int | None = Field(default=None, ge=0, le=36000)


def check_intro(start: int | None, end: int | None) -> None:
    if (start is None) != (end is None):
        raise HTTPException(400, "Give both the intro start and end, or neither.")
    if start is not None and start >= end:
        raise HTTPException(400, "The intro must end after it starts.")


@app.patch("/api/videos/{vid}", dependencies=[Depends(require_token)])
def update_video(vid: str, req: VideoUpdate) -> dict:
    changes = req.model_dump(exclude_unset=True)
    for key in ("title", "show", "description"):
        if isinstance(changes.get(key), str):
            changes[key] = changes[key].strip() or None
    if "title" in changes and not changes["title"]:
        raise HTTPException(400, "Title cannot be empty.")
    with db() as conn:
        row = conn.execute("SELECT kind, show, intro_start, intro_end FROM videos WHERE id = ?", (vid,)).fetchone()
        if row is None:
            raise HTTPException(404, "No video with that id.")
        check_intro(changes.get("intro_start", row["intro_start"]), changes.get("intro_end", row["intro_end"]))
        kind = changes.get("kind") or row["kind"]
        if kind == "episode" and not changes.get("show", row["show"]):
            raise HTTPException(400, "An episode needs a show name.")
        # Fields that do not apply to the kind are cleared, so nothing stale lingers.
        if kind != "episode":
            changes.update(show=None, season=None, episode=None)
        if kind != "movie":
            changes["year"] = None
        if changes:
            cols = ", ".join(f"{k} = ?" for k in changes)
            conn.execute(f"UPDATE videos SET {cols} WHERE id = ?", (*changes.values(), vid))
        updated = dict(conn.execute("SELECT * FROM videos WHERE id = ?", (vid,)).fetchone())
    return updated


@app.delete("/api/videos/{vid}", status_code=204, dependencies=[Depends(require_token)])
def delete_video(vid: str) -> Response:
    with db() as conn:
        row = conn.execute("SELECT status FROM videos WHERE id = ?", (vid,)).fetchone()
        if row is None:
            raise HTTPException(404, "No video with that id.")
        if row["status"] in ("downloading", "converting"):
            raise HTTPException(409, "Video is still being processed; wait for it to finish.")
        conn.execute("DELETE FROM videos WHERE id = ?", (vid,))
    remove_files(vid)
    delete_artwork(f"video:{vid}")
    return Response(status_code=204)


@app.post("/api/videos/{vid}/subtitles", status_code=201, dependencies=[Depends(require_token)])
async def upload_subtitle(
    vid: str,
    request: Request,
    filename: str = Query(min_length=1, max_length=255),
    language: str | None = Query(default=None, max_length=20),
    forced: bool | None = None,
    sdh: bool | None = None,
) -> dict:
    """Add a subtitle file (.srt, .vtt, .ass, .ssa) to a video. The body is the file.
    Language, forced and SDH come from the query, else from the file name
    ('Show S01E05.en.srt', 'Movie.eng.forced.srt'), else unknown."""
    ext = Path(filename).suffix.lower()
    if ext not in subtitles.UPLOAD_EXTS:
        raise HTTPException(400, "Subtitles must be .srt, .vtt, .ass or .ssa.")
    size = int(request.headers.get("content-length") or 0)
    if not size:
        raise HTTPException(411, "Content-Length is required.")
    if size > subtitles.MAX_UPLOAD_BYTES:
        raise HTTPException(413, "Subtitle files can be at most 5 MB.")
    with db() as conn:
        if not conn.execute("SELECT 1 FROM videos WHERE id = ? AND status = 'ready'", (vid,)).fetchone():
            raise HTTPException(404, "No ready video with that id.")
    body = await request.body()

    guess = subtitles.guess_from_filename(filename)
    lang = subtitles.normalize_language(language) if language else guess["language"]
    tmp = MEDIA_DIR / f".subupload-{uuid.uuid4().hex}{ext}"
    out = next_subtitle_path(vid)
    try:
        tmp.write_bytes(subtitles.to_utf8(body))
        ok = await anyio.to_thread.run_sync(subtitles.convert_file, tmp, out)
    finally:
        tmp.unlink(missing_ok=True)
    if not ok:
        out.unlink(missing_ok=True)
        raise HTTPException(400, "That file has no subtitles ffmpeg can read.")
    sid = add_subtitle(vid, out, lang, guess["forced"] if forced is None else forced,
                       guess["sdh"] if sdh is None else sdh, "upload")
    with db() as conn:
        return next(s for s in subtitle_map(conn)[vid] if s["id"] == sid)


@app.delete("/api/videos/{vid}/subtitles/{sid}", status_code=204, dependencies=[Depends(require_token)])
def delete_subtitle(vid: str, sid: int) -> Response:
    with db() as conn:
        row = conn.execute("SELECT file FROM subtitles WHERE id = ? AND video_id = ?", (sid, vid)).fetchone()
        if row is None:
            raise HTTPException(404, "No such subtitle track on that video.")
        conn.execute("DELETE FROM subtitles WHERE id = ?", (sid,))
    (MEDIA_DIR / row["file"]).unlink(missing_ok=True)
    return Response(status_code=204)


@app.put("/api/shows/{name}/markers", dependencies=[Depends(require_token)])
def set_show_markers(name: str, req: Markers) -> dict:
    """Intro and credits markers for every episode of a show (episodes may override)."""
    check_intro(req.intro_start, req.intro_end)
    with db() as conn:
        if not conn.execute("SELECT 1 FROM videos WHERE show = ? LIMIT 1", (name,)).fetchone():
            raise HTTPException(404, "No show with that name.")
        conn.execute(
            "INSERT INTO shows (name, intro_start, intro_end, credits_before_end) VALUES (?, ?, ?, ?) "
            "ON CONFLICT(name) DO UPDATE SET intro_start = excluded.intro_start, "
            "intro_end = excluded.intro_end, credits_before_end = excluded.credits_before_end",
            (name, req.intro_start, req.intro_end, req.credits_before_end),
        )
    return {"name": name, **req.model_dump()}


def require_show(conn: sqlite3.Connection, name: str) -> None:
    if not conn.execute("SELECT 1 FROM videos WHERE show = ? LIMIT 1", (name,)).fetchone():
        raise HTTPException(404, "No show with that name.")


class ShowInfo(BaseModel):
    """The show's details screen fields. Send only what changes; null clears one."""
    model_config = ConfigDict(extra="forbid")

    year: int | None = Field(default=None, ge=1880, le=2100)
    description: str | None = Field(default=None, max_length=5000)


@app.patch("/api/shows/{name}", dependencies=[Depends(require_token)])
def update_show(name: str, req: ShowInfo) -> dict:
    changes = req.model_dump(exclude_unset=True)
    if isinstance(changes.get("description"), str):
        changes["description"] = changes["description"].strip() or None
    with db() as conn:
        require_show(conn, name)
        conn.execute("INSERT INTO shows (name) VALUES (?) ON CONFLICT(name) DO NOTHING", (name,))
        if changes:
            cols = ", ".join(f"{k} = ?" for k in changes)
            conn.execute(f"UPDATE shows SET {cols} WHERE name = ?", (*changes.values(), name))
        row = conn.execute("SELECT name, year, description FROM shows WHERE name = ?", (name,)).fetchone()
    return dict(row)


async def save_artwork(owner: str, slot: str, request: Request) -> dict:
    """Store the raw image in the request body as one artwork slot."""
    if slot not in ART_SLOTS:
        raise HTTPException(400, f"slot must be one of: {', '.join(ART_SLOTS)}.")
    size = int(request.headers.get("content-length") or 0)
    if not size:
        raise HTTPException(411, "Content-Length is required.")
    if size > MAX_ART_BYTES:
        raise HTTPException(413, f"Images can be at most {MAX_ART_BYTES // (1024 * 1024)} MB.")
    body = await request.body()
    if len(body) > MAX_ART_BYTES:
        raise HTTPException(413, "The body is larger than Content-Length.")

    ext, vf = ART_SLOTS[slot]
    ART_DIR.mkdir(parents=True, exist_ok=True)
    # The file name comes from a hash: show names may hold any character.
    filename = f"{hashlib.sha1(owner.encode()).hexdigest()[:12]}-{slot}.{ext}"
    upload = ART_DIR / f".upload-{uuid.uuid4().hex}"
    tmp = ART_DIR / f".{filename}"
    try:
        upload.write_bytes(body)
        # ffmpeg reads any common image format (JPEG, PNG, WebP...).
        proc = await anyio.to_thread.run_sync(lambda: subprocess.run(
            ["ffmpeg", "-nostdin", "-y", "-v", "error", "-i", str(upload), "-frames:v", "1",
             "-vf", vf, *(["-q:v", "3"] if ext == "jpg" else []), "-f", "image2", str(tmp)],
            capture_output=True, timeout=60))
        if proc.returncode != 0 or not tmp.exists():
            raise HTTPException(400, "That file is not an image ffmpeg can read.")
        tmp.rename(ART_DIR / filename)
    finally:
        upload.unlink(missing_ok=True)
        tmp.unlink(missing_ok=True)

    with db() as conn:
        conn.execute(
            "INSERT INTO artwork (owner, slot, file, version) VALUES (?, ?, ?, ?) "
            "ON CONFLICT(owner, slot) DO UPDATE SET file = excluded.file, version = excluded.version",
            (owner, slot, filename, int(time.time())),
        )
        url = artwork_map(conn)[owner][slot]
    return {"slot": slot, "url": url}


def delete_artwork(owner: str, slot: str | None = None) -> int:
    """Delete one slot, or every slot when slot is None. Returns how many went."""
    with db() as conn:
        if slot is None:
            rows = conn.execute("SELECT file FROM artwork WHERE owner = ?", (owner,)).fetchall()
            conn.execute("DELETE FROM artwork WHERE owner = ?", (owner,))
        else:
            rows = conn.execute("SELECT file FROM artwork WHERE owner = ? AND slot = ?", (owner, slot)).fetchall()
            conn.execute("DELETE FROM artwork WHERE owner = ? AND slot = ?", (owner, slot))
    for r in rows:
        (ART_DIR / r["file"]).unlink(missing_ok=True)
    return len(rows)


@app.put("/api/shows/{name}/art", dependencies=[Depends(require_token)])
async def set_show_art(name: str, request: Request, slot: str = "background") -> dict:
    """One artwork slot for a show. The body is the raw image."""
    with db() as conn:
        require_show(conn, name)
    return await save_artwork(f"show:{name}", slot, request)


@app.delete("/api/shows/{name}/art", status_code=204, dependencies=[Depends(require_token)])
def delete_show_art(name: str, slot: str = "background") -> Response:
    if not delete_artwork(f"show:{name}", slot):
        raise HTTPException(404, "That show has no artwork in that slot.")
    return Response(status_code=204)


@app.put("/api/videos/{vid}/art", dependencies=[Depends(require_token)])
async def set_video_art(vid: str, request: Request, slot: str = "background") -> dict:
    """One artwork slot for a video. Meant for movies; episodes use their show's."""
    with db() as conn:
        if not conn.execute("SELECT 1 FROM videos WHERE id = ?", (vid,)).fetchone():
            raise HTTPException(404, "No video with that id.")
    return await save_artwork(f"video:{vid}", slot, request)


@app.delete("/api/videos/{vid}/art", status_code=204, dependencies=[Depends(require_token)])
def delete_video_art(vid: str, slot: str = "background") -> Response:
    if not delete_artwork(f"video:{vid}", slot):
        raise HTTPException(404, "That video has no artwork in that slot.")
    return Response(status_code=204)


# --- watch progress -----------------------------------------------------------
# No token on these two: the Roku cannot keep a secret (its code ships in the
# channel zip), and they only change watch state, never files. LAN only.

class Progress(BaseModel):
    model_config = ConfigDict(extra="forbid")

    position: int = Field(ge=0, le=86400)


@app.post("/api/progress/{vid}")
def report_progress(vid: str, req: Progress) -> dict:
    """The player reports where it is. Past the credits marker the video counts as watched."""
    with db() as conn:
        row = conn.execute("SELECT duration, show, credits_before_end, intro_start, intro_end FROM videos "
                           "WHERE id = ? AND status = 'ready'", (vid,)).fetchone()
        if row is None:
            raise HTTPException(404, "No ready video with that id.")
        m = playback.markers(dict(row), show_markers(conn).get(row["show"] or ""))
        changes = playback.progress_update(row["duration"], m["credits_before_end"], req.position)
        cols = ", ".join(f"{k} = ?" for k in changes)
        conn.execute(f"UPDATE videos SET {cols} WHERE id = ?", (*changes.values(), vid))
    return {"id": vid, "position": changes["position"], "watched": bool(changes.get("watched"))}


class WatchedRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    ids: list[str] = Field(min_length=1, max_length=5000)
    watched: bool


@app.post("/api/watched")
def set_watched(req: WatchedRequest) -> dict:
    """Mark videos watched or unwatched (one episode, or a whole season at once).
    Both clear the resume position; unwatched also drops it from Continue Watching."""
    marks = ",".join("?" * len(req.ids))
    last = time.time() if req.watched else None
    with db() as conn:
        cur = conn.execute(f"UPDATE videos SET watched = ?, position = 0, last_watched_at = ? WHERE id IN ({marks})",
                           (int(req.watched), last, *req.ids))
    return {"updated": cur.rowcount, "watched": req.watched}


@app.get("/api/feed")
def feed() -> dict:
    """The Roku channel reads this. Only ready videos, newest first. No token: the
    Roku cannot hold secrets, and the feed holds only titles and media URLs."""
    with db() as conn:
        rows = conn.execute(
            "SELECT id, title, uploader, duration, description FROM videos "
            "WHERE status = 'ready' ORDER BY created_at DESC"
        ).fetchall()
    return {"videos": [{**dict(r), **media_urls(r["id"])} for r in rows]}


@app.get("/api/library")
def library_feed() -> dict:
    """The Roku library: Continue Watching, recent videos, TV shows (with seasons),
    movies and clips. Every video carries its progress, markers, next/previous episode
    and artwork (art, boxart, logo). Open like /api/feed, and for the same reason."""
    with db() as conn:
        rows = conn.execute(
            "SELECT id, title, uploader, duration, description, kind, show, season, episode, year, "
            "position, watched, last_watched_at, intro_start, intro_end, credits_before_end "
            "FROM videos WHERE status = 'ready' ORDER BY created_at DESC"
        ).fetchall()
        shows = show_markers(conn)
        subs = subtitle_map(conn)
        art = artwork_map(conn)
    videos = playback.enrich(
        [{**dict(r), **media_urls(r["id"]), "subtitles": subs.get(r["id"], [])} for r in rows], shows)
    no_art = {slot: "" for slot in ART_SLOTS}
    for v in videos:
        # A movie's own artwork, else its show's. art = the wide picture (falls back to
        # the thumbnail); boxart and logo are "" when nobody uploaded one.
        own = art.get(f"video:{v['id']}", {})
        show = shows.get(v.get("show") or "", {}).get("artwork", no_art)
        v["art"] = own.get("background") or show["background"] or v["thumbnail"]
        v["boxart"] = own.get("boxart") or show["boxart"]
        v["logo"] = own.get("logo") or show["logo"]
    lib = library.group(videos)
    for s in lib["shows"]:
        info = shows.get(s["name"], {})
        slots = info.get("artwork", no_art)
        s["art"] = slots["background"] or s["thumbnail"]
        s["boxart"] = slots["boxart"]
        s["logo"] = slots["logo"]
        s["year"] = info.get("year")
        s["description"] = info.get("description") or ""
    cont = playback.continue_watching(videos)
    # The home banner: what you watched last, or else the newest video.
    hero = (cont or lib["recent"] or [None])[0]
    return {"hero": hero, "continue": cont, **lib}


@app.get("/healthz")
def healthz() -> dict:
    return {"ok": True}


INDEX_HTML = (Path(__file__).parent / "static" / "index.html").read_text()


@app.get("/", response_class=HTMLResponse)
def index() -> str:
    return INDEX_HTML
