"""Subtitles: find the text tracks in a video file, turn them into WebVTT (which
the Roku reads), and work out language and labels.

Image subtitles (Blu-ray PGS, DVD VobSub) are pictures, not text. Turning them
into text needs OCR, so they are skipped.
"""
import json
import re
import subprocess
from pathlib import Path

# Codecs ffmpeg can turn into WebVTT.
TEXT_CODECS = {"subrip", "srt", "ass", "ssa", "mov_text", "webvtt", "text"}
UPLOAD_EXTS = {".srt", ".vtt", ".ass", ".ssa"}
MAX_UPLOAD_BYTES = 5 * 1024 * 1024

# ISO 639-1 (two letters, yt-dlp and file names) to ISO 639-2 (three letters,
# what the Roku expects), with a readable name for each.
LANGUAGES = {
    "en": ("eng", "English"), "ja": ("jpn", "Japanese"), "es": ("spa", "Spanish"),
    "fr": ("fre", "French"), "de": ("ger", "German"), "it": ("ita", "Italian"),
    "pt": ("por", "Portuguese"), "nl": ("dut", "Dutch"), "da": ("dan", "Danish"),
    "fi": ("fin", "Finnish"), "no": ("nor", "Norwegian"), "sv": ("swe", "Swedish"),
    "pl": ("pol", "Polish"), "ru": ("rus", "Russian"), "ko": ("kor", "Korean"),
    "zh": ("chi", "Chinese"), "ar": ("ara", "Arabic"), "hi": ("hin", "Hindi"),
}
# Other three-letter spellings of the same languages.
ALIASES = {"fra": "fre", "deu": "ger", "nld": "dut", "zho": "chi"}
NAMES = {three: name for three, name in LANGUAGES.values()}
WORDS = {name.lower(): three for three, name in LANGUAGES.values()}


def normalize_language(code: str | None, known_only: bool = False) -> str:
    """'en', 'en-US', 'eng', 'English' -> 'eng'. Unknown -> 'und' (undetermined).

    known_only: accept only languages in LANGUAGES. Use it for words taken from
    file names, where 'The' or 'Ep' must not count as a language code.
    """
    if not code:
        return "und"
    code = code.strip().lower()
    if code in WORDS:
        return WORDS[code]
    base = re.split(r"[-_]", code)[0]
    if base in LANGUAGES:
        return LANGUAGES[base][0]
    base = ALIASES.get(base, base)
    if base in NAMES:
        return base
    return base if not known_only and len(base) == 3 and base.isalpha() else "und"


def make_label(language: str, forced: bool, sdh: bool) -> str:
    """'English', 'English (SDH)', 'English (Forced)'."""
    label = NAMES.get(language, "Unknown language" if language == "und" else language.upper())
    if sdh:
        label += " (SDH)"
    if forced:
        label += " (Forced)"
    return label


def _flags(title: str) -> tuple[bool, bool]:
    forced = "forced" in title.lower()
    sdh = bool(re.search(r"\b(sdh|cc|hearing)\b", title, re.I))
    return forced, sdh


def text_tracks(src: Path) -> list[dict]:
    """Text subtitle tracks in a video file: index, language, forced, sdh."""
    proc = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "s", "-of", "json", "-show_entries",
         "stream=index,codec_name:stream_tags=language,title:stream_disposition=forced,hearing_impaired",
         str(src)],
        capture_output=True, text=True, timeout=120,
    )
    if proc.returncode != 0:
        return []
    tracks = []
    for s in json.loads(proc.stdout).get("streams", []):
        if s.get("codec_name") not in TEXT_CODECS:
            continue
        tags, disp = s.get("tags", {}), s.get("disposition", {})
        forced, sdh = _flags(tags.get("title", ""))
        tracks.append({
            "index": s["index"],
            "language": normalize_language(tags.get("language")),
            "forced": forced or bool(disp.get("forced")),
            "sdh": sdh or bool(disp.get("hearing_impaired")),
        })
    return tracks


def extract(src: Path, tracks: list[dict], outs: list[Path]) -> list[bool]:
    """Write each track to its WebVTT file in one ffmpeg run (one read of a big file)."""
    if not tracks:
        return []
    cmd = ["ffmpeg", "-nostdin", "-y", "-v", "error", "-i", str(src)]
    for t, out in zip(tracks, outs):
        cmd += ["-map", f"0:{t['index']}", "-c:s", "webvtt", str(out)]
    subprocess.run(cmd, capture_output=True, timeout=1800)
    return [usable(out) for out in outs]


def usable(path: Path) -> bool:
    """A WebVTT file with at least one cue (an empty track is just the header)."""
    try:
        return "-->" in path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return False


_TIME = r"(?:\d+:)?\d{2}:\d{2}\.\d{3}"
_BROKEN_TIMING = re.compile(rf"^({_TIME}) --(?!>) ?({_TIME})(.*)$")
_TIMING = re.compile(rf"^({_TIME}) --> ({_TIME})")


def _seconds(t: str) -> float:
    parts = [float(p) for p in t.split(":")]
    return sum(p * 60 ** i for i, p in enumerate(reversed(parts)))


def repair_vtt(text: str) -> str:
    """Fix WebVTT that yt-dlp merged from HLS segments (seen with TED).

    Some sites start every segment with an empty 1 ms placeholder cue whose
    "blank" line is a space. WebVTT does not count that as a blank line, so the
    next real cue becomes part of the placeholder's text, and its timing line
    loses its '>'. Here: whitespace-only lines become blank, '--' timing lines
    get their '>' back, and empty placeholder cues are dropped.
    """
    lines = ["" if not line.strip() else line for line in text.splitlines()]
    lines = [_BROKEN_TIMING.sub(r"\1 --> \2\3", line) for line in lines]
    blocks, current = [], []
    for line in lines + [""]:
        if line:
            current.append(line)
        elif current:
            blocks.append(current)
            current = []
    kept = []
    for block in blocks:
        timing = next((i for i, line in enumerate(block) if _TIMING.match(line)), None)
        if timing is not None and timing == len(block) - 1:
            continue  # a cue with no text
        if timing is not None:
            m = _TIMING.match(block[timing])
            if _seconds(m.group(2)) - _seconds(m.group(1)) < 0.01 and not "".join(block[timing + 1:]).strip():
                continue
        kept.append("\n".join(block))
    return "\n\n".join(kept) + "\n"


def to_utf8(data: bytes) -> bytes:
    """Subtitle files are often Windows-1252 or UTF-16; ffmpeg wants UTF-8."""
    if data.startswith((b"\xff\xfe", b"\xfe\xff")):
        return data.decode("utf-16").encode("utf-8")
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    try:
        data.decode("utf-8")
        return data
    except UnicodeDecodeError:
        return data.decode("cp1252", errors="replace").encode("utf-8")


def convert_file(src: Path, out: Path) -> bool:
    """One .srt / .vtt / .ass / .ssa file -> WebVTT."""
    subprocess.run(["ffmpeg", "-nostdin", "-y", "-v", "error", "-i", str(src), "-c:s", "webvtt", str(out)],
                   capture_output=True, timeout=120)
    return usable(out)


def guess_from_filename(name: str) -> dict:
    """'Show S01E05.en.srt', 'Movie.eng.forced.srt', 'Movie.English.SDH.srt'."""
    parts = name.split(".")[1:-1]  # the pieces between the base name and the extension
    language = "und"
    for p in parts:
        lang = normalize_language(p, known_only=True)
        if lang != "und":
            language = lang
    forced, sdh = _flags(" ".join(parts))
    return {"language": language, "forced": forced, "sdh": sdh}
