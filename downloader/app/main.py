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

from . import library

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
    year        INTEGER
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
    # Covers the final .mp4/.jpg, yt-dlp leftovers like .f137.mp4 and .part, and the
    # .src.* / .conv.mp4 files of a conversion.
    for f in MEDIA_DIR.glob(f"{vid}.*"):
        f.unlink(missing_ok=True)


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
        convert_to_mp4(vid, src)
        mp4 = MEDIA_DIR / f"{vid}.mp4"
        set_fields(vid, status="ready", progress=1, size_bytes=mp4.stat().st_size)
    except Exception as e:  # ffprobe/ffmpeg fail in many ways; all mean "this import failed"
        remove_files(vid)
        set_fields(vid, status="failed", error=str(e)[:500])


def make_thumbnail(vid: str, src: Path, duration: float) -> None:
    """One frame from 10% into the video. A missing thumbnail is not an error."""
    subprocess.run(
        ["ffmpeg", "-nostdin", "-y", "-v", "error", "-ss", str(duration * 0.1), "-i", str(src),
         "-frames:v", "1", "-vf", "scale=480:-2", str(MEDIA_DIR / f"{vid}.jpg")],
        capture_output=True, timeout=120,
    )


@app.on_event("startup")
def startup() -> None:
    MEDIA_DIR.mkdir(parents=True, exist_ok=True)
    with db() as conn:
        conn.execute(SCHEMA)
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


def media_urls(vid: str) -> dict:
    thumb = MEDIA_DIR / f"{vid}.jpg"
    return {
        "url": f"{PUBLIC_BASE_URL}/media/{vid}.mp4",
        "thumbnail": f"{PUBLIC_BASE_URL}/media/{vid}.jpg" if thumb.exists() else "",
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
    for r in rows:
        if r["status"] == "ready":
            r.update(media_urls(r["id"]))
    usage = shutil.disk_usage(MEDIA_DIR)
    return {
        "videos": rows,
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


@app.patch("/api/videos/{vid}", dependencies=[Depends(require_token)])
def update_video(vid: str, req: VideoUpdate) -> dict:
    changes = req.model_dump(exclude_unset=True)
    for key in ("title", "show"):
        if isinstance(changes.get(key), str):
            changes[key] = changes[key].strip() or None
    if "title" in changes and not changes["title"]:
        raise HTTPException(400, "Title cannot be empty.")
    with db() as conn:
        row = conn.execute("SELECT kind, show FROM videos WHERE id = ?", (vid,)).fetchone()
        if row is None:
            raise HTTPException(404, "No video with that id.")
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
    return Response(status_code=204)


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
    """The Roku home screen: recent videos, TV shows (with seasons), movies and clips.
    Open like /api/feed, and for the same reason."""
    with db() as conn:
        rows = conn.execute(
            "SELECT id, title, uploader, duration, description, kind, show, season, episode, year "
            "FROM videos WHERE status = 'ready' ORDER BY created_at DESC"
        ).fetchall()
    return library.group([{**dict(r), **media_urls(r["id"])} for r in rows])


@app.get("/healthz")
def healthz() -> dict:
    return {"ok": True}


INDEX_HTML = (Path(__file__).parent / "static" / "index.html").read_text()


@app.get("/", response_class=HTMLResponse)
def index() -> str:
    return INDEX_HTML
