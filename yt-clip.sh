#!/usr/bin/env bash
# yt-clip.sh — Download a YouTube clip between two timestamps
#
# Run './yt-clip.sh --help' for full usage. See README.md for details.

set -euo pipefail

# ── helpers ───────────────────────────────────────────────────────────────────
die()  { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*"; }

sec_to_hms() {
  local s=$1
  printf "%02d:%02d:%02d" $((s/3600)) $(( (s%3600)/60 )) $((s%60))
}

hms_to_sec() {
  # Accepts seconds, MM:SS, or HH:MM:SS and prints whole seconds.
  local t="$1"
  if [[ "$t" =~ ^[0-9]+$ ]]; then
    echo "$t"
  elif [[ "$t" =~ ^([0-9]+):([0-9]{1,2})$ ]]; then
    echo $(( 10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]} ))
  elif [[ "$t" =~ ^([0-9]+):([0-9]{1,2}):([0-9]{1,2})$ ]]; then
    echo $(( 10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]} ))
  else
    die "Invalid time '$t' (expected seconds, MM:SS, or HH:MM:SS)"
  fi
}

show_help() {
  cat <<EOF
yt-clip.sh — Download a YouTube clip between two timestamps

USAGE:
  $0 <URL> <start> <end> [output_name] [options]
  $0 --local <file.mp4> <start> <end> [output_name] [options]
  $0 <URL> --info

  <start> and <end> accept seconds, MM:SS, or HH:MM:SS (e.g. 90, 1:30, 00:01:30).

OPTIONS:
  -o, --output NAME    Output file base name (default: clip)
  -f, --format PRESET  best|1080|720|480|240|audio, or a raw yt-dlp -f expression.
                        Skips the interactive quality prompt.
      --url URL        Explicitly set the URL (alternative to positional arg)
      --start TIME     Explicitly set the start time (alternative to positional arg)
      --end TIME       Explicitly set the end time (alternative to positional arg)
      --local FILE     Use a previously downloaded local file instead of a URL
  -i, --info           Only print video info (title, duration, formats, ...) and exit.
                        No start/end/output needed.
  -h, --help           Show this help and exit

Note: when a full video download is required (livestream/DVR sources), the
downloaded file is always kept (as __full_<output_name>.mp4) so it can be
reused for future clips without re-downloading.

EXAMPLES:
  $0 "https://youtu.be/QACEW_vGBgw" --info
  $0 "https://youtu.be/QACEW_vGBgw" 90 150 clip
  $0 "https://youtu.be/QACEW_vGBgw" 1:30 2:30 clip
  $0 "https://youtu.be/QACEW_vGBgw" 00:01:30 00:02:30 clip -f 720
  $0 --local __full_clip.mp4 90 150 clip2
EOF
}

is_manifest_url() {
  # Returns 0 (true) if URL looks like a DASH/HLS manifest, not a direct stream
  [[ "$1" == *"manifest"* || "$1" == *"/api/manifest"* || "$1" == *.m3u8* ]]
}

install_cmd_for() {
  # Prints a shell command to install $1, or nothing if no known method exists.
  local cmd="$1"
  case "$cmd" in
    yt-dlp)
      if command -v pipx &>/dev/null; then echo "pipx install yt-dlp"
      elif command -v brew &>/dev/null; then echo "brew install yt-dlp"
      elif command -v pip3 &>/dev/null; then echo "pip3 install --user yt-dlp"
      elif command -v apt-get &>/dev/null; then echo "sudo apt-get install -y yt-dlp"
      elif command -v dnf &>/dev/null; then echo "sudo dnf install -y yt-dlp"
      elif command -v pacman &>/dev/null; then echo "sudo pacman -S --noconfirm yt-dlp"
      fi
      ;;
    ffmpeg)
      if command -v brew &>/dev/null; then echo "brew install ffmpeg"
      elif command -v apt-get &>/dev/null; then echo "sudo apt-get install -y ffmpeg"
      elif command -v dnf &>/dev/null; then echo "sudo dnf install -y ffmpeg"
      elif command -v pacman &>/dev/null; then echo "sudo pacman -S --noconfirm ffmpeg"
      fi
      ;;
  esac
}

require() {
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null && continue

    echo "[ERROR] '$cmd' is not installed." >&2
    local install_cmd
    install_cmd=$(install_cmd_for "$cmd")
    [[ -z "$install_cmd" ]] && die "No supported package manager found to install '$cmd' automatically. Please install it manually."

    read -rp "[?] Install it now with: $install_cmd ? [y/N]: " CONFIRM
    [[ "${CONFIRM,,}" == "y" ]] || die "'$cmd' is required. Aborting."

    info "Installing $cmd..."
    eval "$install_cmd" || die "Failed to install '$cmd'. Please install it manually."
    command -v "$cmd" &>/dev/null || die "'$cmd' still not found after installation (you may need to restart your shell for PATH changes to take effect)."
    info "'$cmd' installed successfully."
  done
}

# ── parse args ────────────────────────────────────────────────────────────────
LOCAL_FILE=""
URL=""
START=""
END=""
OUTNAME=""
FMT_ARG=""
INFO_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)      show_help; exit 0 ;;
    -i|--info)      INFO_ONLY=true; shift ;;
    --keep)         shift ;; # no-op: full downloads are always kept now
    --local)        LOCAL_FILE="${2:?--local requires a file}"; shift 2 ;;
    --url)          URL="${2:?--url requires a value}"; shift 2 ;;
    --start)        START="${2:?--start requires a value}"; shift 2 ;;
    --end)          END="${2:?--end requires a value}"; shift 2 ;;
    -o|--output)    OUTNAME="${2:?--output requires a value}"; shift 2 ;;
    -f|--format)    FMT_ARG="${2:?--format requires a value}"; shift 2 ;;
    --*)            die "Unknown option: $1 (see --help)" ;;
    *)
      if   [[ -z "$URL"   && -z "$LOCAL_FILE" ]]; then URL="$1"
      elif [[ -z "$START" ]]; then START="$1"
      elif [[ -z "$END"   ]]; then END="$1"
      elif [[ -z "$OUTNAME" ]]; then OUTNAME="$1"
      else die "Unexpected argument: $1 (see --help)"
      fi
      shift ;;
  esac
done

OUTNAME="${OUTNAME:-clip}"

[[ -n "$LOCAL_FILE" && -n "$URL" ]] && die "Use either --local or a URL, not both."
if [[ -z "$LOCAL_FILE" && -z "$URL" ]]; then
  show_help
  exit 1
fi

# ── INFO-ONLY MODE ────────────────────────────────────────────────────────────
if [[ "$INFO_ONLY" == "true" ]]; then
  [[ -n "$LOCAL_FILE" ]] && die "--info is not supported with --local; run 'ffprobe <file>' instead."
  require yt-dlp

  info "Probing video metadata..."
  META=$(yt-dlp --dump-json --no-playlist "$URL" 2>/dev/null) \
    || die "Could not fetch video info. Check the URL."

  echo "$META" | python3 -c "$(cat <<'PY'
import sys, json

def hms(seconds):
    if seconds is None:
        return "unknown"
    seconds = int(seconds)
    h, r = divmod(seconds, 3600)
    m, s = divmod(r, 60)
    return f"{h:02d}:{m:02d}:{s:02d}"

d = json.load(sys.stdin)
upload_date = d.get("upload_date")
if upload_date and len(upload_date) == 8:
    upload_date = f"{upload_date[0:4]}-{upload_date[4:6]}-{upload_date[6:8]}"
view_count = d.get("view_count")
view_count = f"{view_count:,}" if isinstance(view_count, int) else "unknown"
if d.get("is_live"):
    live_status = "live now"
elif d.get("was_live"):
    live_status = "was live / DVR (full download required for clipping)"
else:
    live_status = "regular video"

print(f"Title       : {d.get('title', 'unknown')}")
print(f"Channel     : {d.get('uploader') or d.get('channel') or 'unknown'}")
print(f"Duration    : {hms(d.get('duration'))}")
print(f"Type        : {live_status}")
print(f"Upload date : {upload_date or 'unknown'}")
print(f"Views       : {view_count}")
PY
)"

  echo ""
  info "Available formats:"
  yt-dlp --list-formats --no-playlist "$URL" 2>&1
  exit 0
fi

[[ -z "$START" || -z "$END" ]] && die "start and end are required (see --help)."

START=$(hms_to_sec "$START")
END=$(hms_to_sec "$END")

DURATION=$(( END - START ))
[[ $DURATION -le 0 ]] && die "end must be greater than start."

START_HMS=$(sec_to_hms "$START")
END_HMS=$(sec_to_hms "$END")
info "Clip: $START_HMS → $END_HMS  (${DURATION}s)"

require ffmpeg
[[ -z "$LOCAL_FILE" ]] && require yt-dlp

# ── trim helper (used by multiple strategies) ─────────────────────────────────
trim_local() {
  local src="$1" dst="$2"
  info "Trimming with ffmpeg: ${START}s → ${END}s ..."
  ffmpeg -y \
    -i "$src" \
    -ss "$START" -to "$END" \
    -c copy \
    "$dst"
}

announce_kept() {
  local full="$1"
  info "Full file kept → $full"
  info "Next clip: $0 --local $full <start> <end> [name]"
}

# ── LOCAL FILE MODE ───────────────────────────────────────────────────────────
if [[ -n "$LOCAL_FILE" ]]; then
  [[ -f "$LOCAL_FILE" ]] || die "Local file not found: $LOCAL_FILE"
  info "Using local file: $LOCAL_FILE"
  trim_local "$LOCAL_FILE" "${OUTNAME}.mp4"
  info "Done → ${OUTNAME}.mp4"
  exit 0
fi

# ── PROBE METADATA ────────────────────────────────────────────────────────────
info "Probing video metadata..."
META=$(yt-dlp --dump-json --no-playlist "$URL" 2>/dev/null) \
  || die "Could not fetch video info. Check the URL."

TITLE=$(echo "$META" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('title','unknown'))" 2>/dev/null || echo "unknown")
IS_LIVE=$(echo "$META" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print('true' if d.get('was_live') or d.get('is_live') else 'false')" \
  2>/dev/null || echo "false")

info "Title   : $TITLE"
info "Was live: $IS_LIVE"

# ── LIST FORMATS + QUALITY SELECTION ─────────────────────────────────────────
if [[ -n "$FMT_ARG" ]]; then
  case "$FMT_ARG" in
    best)  FMT="bestvideo+bestaudio/best" ;;
    1080)  FMT="bestvideo[height<=1080]+bestaudio/best[height<=1080]" ;;
    720)   FMT="bestvideo[height<=720]+bestaudio/best[height<=720]" ;;
    480)   FMT="bestvideo[height<=480]+bestaudio/best[height<=480]" ;;
    240)   FMT="bestvideo[height<=240]+bestaudio/best[height<=240]" ;;
    audio) FMT="bestaudio" ;;
    *)     FMT="$FMT_ARG" ;;
  esac
  info "Using format: $FMT (from --format)"
else
  info "Fetching available formats..."
  yt-dlp --list-formats --no-playlist "$URL" 2>&1
  echo ""

  echo "Choose a quality preset:"
  echo "  1) Best quality  (highest res + best audio)"
  echo "  2) 1080p         (1920x1080 + audio)"
  echo "  3) 720p          (1280x720  + audio)"
  echo "  4) 480p          (854x480   + audio)"
  echo "  5) 240p          (426x240   + audio)  ← fastest download"
  echo "  6) Audio only"
  echo "  7) Custom        (enter format IDs manually)"
  echo ""
  read -rp "Selection [1-7]: " CHOICE

  case "$CHOICE" in
    1) FMT="bestvideo+bestaudio/best" ;;
    2) FMT="bestvideo[height<=1080]+bestaudio/best[height<=1080]" ;;
    3) FMT="bestvideo[height<=720]+bestaudio/best[height<=720]" ;;
    4) FMT="bestvideo[height<=480]+bestaudio/best[height<=480]" ;;
    5) FMT="bestvideo[height<=240]+bestaudio/best[height<=240]" ;;
    6) FMT="bestaudio" ;;
    7) read -rp "Enter format IDs (e.g. 299+140): " FMT ;;
    *) die "Invalid selection" ;;
  esac

  info "Using format: $FMT"
fi

# ── STRATEGY 1: --download-sections (regular video, fast) ────────────────────
if [[ "$IS_LIVE" == "false" ]]; then
  info "Regular video — trying ranged download via --download-sections..."
  if yt-dlp \
      -f "$FMT" \
      --download-sections "*${START_HMS}-${END_HMS}" \
      --merge-output-format mp4 \
      -o "${OUTNAME}.%(ext)s" \
      --no-playlist \
      "$URL" 2>&1; then
    info "Done → ${OUTNAME}.mp4"
    exit 0
  fi
  info "--download-sections failed, trying direct stream URL method..."
fi

# ── STRATEGY 2: direct stream URL → ffmpeg partial download ──────────────────
# Works for regular videos. Skipped for live/DVR because yt-dlp returns a
# DASH manifest URL (not a seekable direct URL) for those streams.
if [[ "$IS_LIVE" == "false" ]]; then
  info "Extracting direct stream URL(s)..."
  URLS=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && URLS+=("$line")
  done < <(yt-dlp -f "$FMT" --get-url --no-playlist "$URL" 2>/dev/null)

  N_URLS=${#URLS[@]}
  info "Got $N_URLS stream URL(s)"

  DASH_MANIFEST=false
  [[ $N_URLS -gt 0 ]] && is_manifest_url "${URLS[0]}" && DASH_MANIFEST=true

  if [[ "$DASH_MANIFEST" == "false" && $N_URLS -gt 0 ]]; then
    if [[ $N_URLS -eq 1 ]]; then
      info "Single stream — partial download via ffmpeg..."
      ffmpeg -y -ss "$START" -i "${URLS[0]}" -t "$DURATION" -c copy "${OUTNAME}.mp4"
    else
      info "Separate video+audio streams — partial download via ffmpeg..."
      ffmpeg -y \
        -ss "$START" -i "${URLS[0]}" \
        -ss "$START" -i "${URLS[1]}" \
        -t "$DURATION" \
        -map 0:v -map 1:a \
        -c copy \
        "${OUTNAME}.mp4"
    fi
    info "Done → ${OUTNAME}.mp4"
    exit 0
  fi
  info "Stream URL is a DASH manifest — falling back to full download..."
fi

# ── STRATEGY 3: full download + ffmpeg trim (DVR/live streams, last resort) ───
# This is unavoidable for YouTube DVR streams: they use DASH manifests
# that cannot be seeked into directly. Full download is required.
warn "This is a DVR/live stream — a full download is required before trimming."
warn "The full file will be kept for reuse in future clips."
echo ""

FULL_FILE="__full_${OUTNAME}.mp4"
info "Downloading full video → $FULL_FILE ..."
yt-dlp \
  -f "$FMT" \
  --merge-output-format mp4 \
  -o "${FULL_FILE%.mp4}.%(ext)s" \
  --no-playlist \
  "$URL"

[[ -f "$FULL_FILE" ]] || die "Download completed but output file not found: $FULL_FILE"

trim_local "$FULL_FILE" "${OUTNAME}.mp4"
info "Done → ${OUTNAME}.mp4"

announce_kept "$FULL_FILE"
