# stream-kubenex

Download videos with yt-dlp on the k3s cluster and stream them on the LAN to a private Roku channel.

```
Web form / curl ──► app (FastAPI + yt-dlp) ──► /data/media/<id>.mp4 + .jpg   (local-path PVC on k3s-agent-2)
                                                        │
Roku channel ◄── http://192.168.4.247 ── nginx (same pod): /media/* from disk (range requests), /* → app
```

- Videos are H.264 + AAC MP4, max 1080p, with `+faststart`. The Roku plays them directly.
- If a site has no H.264 format, the app downloads the best format and converts it once
  with ffmpeg (status `converting`). Streams that already fit are copied, not re-encoded.
  One conversion runs at a time.
- Two lanes, one download each. Page URLs from the web form wait in a queue. Media URLs from
  the browser extension start at once, because signed URLs expire in minutes.
- New downloads fail when the disk has less than `MIN_FREE_GB` (15) free.
- The Roku cannot use Tailscale, so every URL uses the LAN IP `192.168.4.247` (MetalLB).

## Use it

| What | Where |
|---|---|
| Web form | http://192.168.4.247 (asks for the API token once) |
| Import your own files | Web form → **Import video files from this computer…** |
| Browser extension | `extension/` (see below) |
| Add by curl | `curl -X POST http://192.168.4.247/api/downloads -H "X-Api-Token: $TOKEN" -H 'Content-Type: application/json' -d '{"url":"<url>"}'` |
| Roku library | http://192.168.4.247/api/library (no token). `/api/feed` is the old flat list, kept for older channel builds. |

## Library: movies, TV shows, clips

Each video is a **movie**, a **TV episode** (show, season, episode) or a **clip**.

- Imported files are guessed from the file name: `Show.Name.S02E05.Title.mkv`, `Show 2x05`,
  `Show Season 2 Episode 5` become episodes; `Movie Name (2010).mp4` or `Movie.Name.2010.1080p.mkv`
  become movies; anything else becomes a movie with the file name as title.
- Downloads become episodes when the site gives yt-dlp series data, otherwise clips.
- Fix anything with **Edit** on the web form. The **TV shows** view groups by show and season.

Get the token on the Mac:

```bash
kubectl get secret stream-api -n stream -o jsonpath='{.data.token}' | base64 -d; echo
```

## Import your own video files

Click **Import video files from this computer…** on the web form and pick one or more files
(mp4, mov, mkv, webm, avi, ts and more). Files from a USB drive or a network share work the
same way: pick them in the file window. Keep the page open until the upload reaches 100%.

The title is the file name. H.264/AAC files up to 1080p are only copied, which takes seconds.
Other codecs are converted with ffmpeg, which takes a while on the Mini PCs.

By curl (streams the file, any size):

```bash
curl -X POST "http://192.168.4.247/api/uploads?filename=my-video.mp4" -H "X-Api-Token: $TOKEN" -T ~/Downloads/my-video.mp4
```

## Browser extension (one-click download)

The extension watches the current tab for video streams (HLS `.m3u8`, DASH `.mpd`, and video
files of 5 MB or more). Its popup sends one to the downloader with a click.

Set up once, on the Mac:

1. Create a new Chrome profile only for this. Never sign in to any site in it, and turn sync off.
2. In that profile, open `chrome://extensions`, turn on Developer mode, click **Load unpacked**,
   and pick the `extension/` folder.
3. Open the extension's **Settings**. Enter `http://192.168.4.247` and the API token.

Use: open the video page in that profile and press play. Click the extension icon, then
**Download** next to the stream (HLS first), or **Send page** for sites yt-dlp supports.
When the extension can read an HLS master playlist, it shows only the master (for example
"5 qualities, up to 1080p") and hides the per-quality playlists. yt-dlp picks the quality.

## Security

| Rule | How |
|---|---|
| No cookies, ever | The extension has no `cookies` permission and never asks for `extraHeaders`, so Chrome never shows it Cookie headers. Its only own request is a cookie-free (`credentials: "omit"`) read of each HLS playlist, to hide variants of a master. The API rejects any field except `url`, `referer`, `origin`, `user_agent` and `sniffed`. |
| Nothing to steal in the browser | The extension runs only in a profile with no logins. It is loaded unpacked, so it never auto-updates. |
| Only you can add or delete videos | Writes and `/api/videos` need the `X-Api-Token` header (Secret `stream-api`). Without `API_TOKEN` set, the API refuses them. `/api/feed` and `/media/` stay open for the Roku. |
| The downloader cannot reach the LAN | The app refuses URLs that resolve to private, LAN, cluster or Tailscale addresses. The NetworkPolicy `stream-egress` blocks the same ranges at the network level, which also covers redirects. |
| LAN only | Do not route this service through the Cloudflare tunnel. |

Known limits: traffic is plain HTTP, so a device on the LAN could read the token. Sites that
need a login do not work (by design). DRM sites (Netflix, Disney+, Prime) cannot work.

## Build and deploy (CI/CD)

```
git push ──► Jenkins (polls every 3 min) ──► kaniko builds downloader/ in-cluster
         ──► 192.168.4.245:5001/stream-kubenex:<build>-<commit>
         ──► commits the new tag to k3s-data-platform/manifests/stream-kubenex
         ──► ArgoCD syncs it to namespace `stream`
```

- The Kubernetes manifests live in `k3s-data-platform/manifests/stream-kubenex/`, not here.
  The ArgoCD Application is `k3s-data-platform/argocd-apps/stream-kubenex.yaml`.
- Jenkins job: Pipeline from SCM, `https://github.com/AmanHogan/stream-kubenex.git`, branch
  `main`, credential `github-pat`, script path `Jenkinsfile`. The `Jenkinsfile` sets the
  polling trigger itself after the first run.
- The API token Secret is made by hand once, never in git:
  `kubectl create secret generic stream-api -n stream --from-literal=token="$(openssl rand -hex 32)"`
- YouTube changes break old yt-dlp versions. The kaniko cache reuses the pip layer while
  `requirements.txt` is unchanged, so to get a newer yt-dlp, raise its minimum version there
  and push.
- The Roku channel and the browser extension are not built by CI; sideload or reload them by hand.

## Roku channel (Mac, same LAN as the Roku)

1. Enable Developer Mode on the Roku: Home ×3, Up ×2, Right, Left, Right, Left, Right. Set a password.
2. `ROKU_IP=<roku ip> scripts/roku-sideload.sh` (it prompts for the dev password)
   (or run `scripts/roku-package.sh` and upload `build/stream-kubenex-roku.zip` at `http://<roku ip>`).
3. Home opens on a banner with the last played video (else the newest): Resume, Play from
   beginning, Go to show. Down moves to the rows (the banner slides away); Up on the first row
   brings it back. A show's banner and card use its artwork if one was uploaded (web form →
   TV shows → **Artwork**; a wide 16:9 picture works best).
   Rows: Continue Watching, Recently added, TV Shows, Movies, Clips. OK on a show
   opens its seasons (left) and episodes (right); OK on a video plays it (part-watched: Resume
   or Play from beginning). Back goes back one screen. Cards show a progress bar or "Watched".
4. `*` opens a menu: on a video, resume / play from beginning / mark watched or not; on a show
   or a season, mark all watched or not; on the home screen, Refresh library. While playing:
   next episode, previous episode, play from beginning.
5. In the player: **Pause** (or OK) shows Resume, Previous episode, Play from beginning and Next
   episode above the progress bar; Play or Fast-forward/Rewind hides them.
   **Skip intro** appears during the intro (OK skips it). At the credits the
   episode counts as watched and **Up next** counts down 10 s (OK plays now, Back keeps watching).
6. Debug output: `nc <roku ip> 8085`.

## Watch progress

The Roku reports the position to the server every 15 seconds and on stop
(`POST /api/progress/{id}`), so progress, Continue Watching and Watched marks are the same on
every device and on the web form. A video counts as **watched** when it reaches the credits:

- the show's **credits** marker (web form → TV shows → **Intro & credits**), or the episode's
  own override (Edit), given as time before the end;
- otherwise the last 2 minutes (10% for videos under 20 minutes).

The **intro** marker (start and end) drives the Skip intro button. Set it once per show; an
episode's Edit can override it. Stopping in the first 30 seconds leaves nothing to resume.
`POST /api/progress` and `/api/watched` need no token, like the feed: the Roku cannot keep a
secret, and they change watch state only.

Check the code without a Roku: `npx -p brighterscript bsc --rootDir roku --createPackage false`.

## Storage

The VM root volume is 100 GB, but each VM disk has about 118 GB of unallocated LVM space.
To use it on k3s-agent-2 (run as root on k3s-agent-2, online, no reboot):

```bash
lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
```

Deleting the `stream-data` PVC deletes every video (local-path reclaim policy is Delete).
