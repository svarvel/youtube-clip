# youtube-clip

Download a clip from a YouTube video (or livestream) between two timestamps,
without downloading the whole video when possible.

## Requirements

- [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) (not needed with `--local`)
- [`deno`](https://deno.com/) — the JS runtime yt-dlp uses to solve YouTube's
  signature challenges; without it, fetching some videos fails outright
- `ffmpeg`
- `python3`

If a dependency is missing, the script offers to install it for you (asks
for confirmation first). For `yt-dlp`, it prefers downloading the current
standalone binary straight from GitHub releases into `~/.local/bin` — this
avoids `pip`/`pipx`/your OS package manager installing a version capped (and
possibly broken against current YouTube) by an old system Python. It falls
back to `pipx`, `brew`, `pip3`, `apt-get`, `dnf`, or `pacman` if your
platform/arch isn't one it has a standalone binary for. `deno` is installed
the same way, straight from GitHub releases.

## Usage

```
./yt-clip.sh <URL> <start> <end> [output_name] [options]
./yt-clip.sh --local <file.mp4> <start> <end> [output_name] [options]
./yt-clip.sh <URL> --info
./yt-clip.sh <URL> --full [output_name] [options]
```

`<start>` and `<end>` accept plain seconds, `MM:SS`, or `HH:MM:SS` — e.g.
`90`, `1:30`, or `00:01:30` all mean the same thing.

### Options

| Option              | Description |
|---------------------|-------------|
| `-o, --output NAME` | Output file base name (default: `clip`) |
| `-f, --format PRESET` | `best`, `1080`, `720`, `480`, `240`, `audio`, or a raw yt-dlp `-f` expression. Skips the interactive quality prompt. |
| `--url URL`         | Explicitly set the URL (alternative to the positional arg) |
| `--start TIME`       | Explicitly set the start time (alternative to the positional arg) |
| `--end TIME`         | Explicitly set the end time (alternative to the positional arg) |
| `--local FILE`       | Use a previously downloaded local file instead of a URL |
| `-i, --info`         | Only print video info (title, channel, duration, live status, available formats) and exit — no start/end/output needed |
| `--full`             | Download the entire video (no clipping) as `<output_name>.mp4` — no start/end needed |
| `-h, --help`         | Show usage and exit |

Downloaded files are never deleted by the script. When clipping requires a
full download first (strategy 3 below), that file (`__full_<output_name>.mp4`)
is always kept too. `--keep` is still accepted for backward compatibility but
is now a no-op.

## Examples

```bash
# Just check info about a video (title, duration, formats) before clipping
./yt-clip.sh "https://youtu.be/QACEW_vGBgw" --info

# Basic clip, seconds
./yt-clip.sh "https://youtu.be/QACEW_vGBgw" 90 150 clip

# Same clip, using MM:SS or HH:MM:SS
./yt-clip.sh "https://youtu.be/QACEW_vGBgw" 1:30 2:30 clip
./yt-clip.sh "https://youtu.be/QACEW_vGBgw" 00:01:30 00:02:30 clip

# Non-interactive: pick 720p up front instead of the quality prompt
./yt-clip.sh "https://youtu.be/QACEW_vGBgw" 1:30 2:30 clip -f 720

# Cut another clip from a full download kept by a previous run
./yt-clip.sh --local __full_clip.mp4 90 150 clip2

# Download the entire video, not just a clip
./yt-clip.sh "https://youtu.be/QACEW_vGBgw" --full whole-video
```

## How it works

For a regular (non-live) video, the script tries progressively more
expensive strategies until one works:

1. **`--download-sections`** — ask yt-dlp to fetch only the requested time
   range directly (fastest, no full download).
2. **Direct stream URL + `ffmpeg -ss`** — resolve the stream URL(s) and let
   `ffmpeg` seek and cut without a full download.
3. **Full download + trim** — download the whole video and cut locally with
   `ffmpeg`. This is the fallback for livestream/DVR sources, since YouTube
   serves those as DASH manifests that can't be seeked into directly.

If a full download happens, the file (`__full_<output_name>.mp4`) is always
kept afterward — pass `--local <file>` next time to cut more clips from the
same download without re-fetching it.
