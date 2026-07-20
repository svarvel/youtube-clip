#!/usr/bin/env bash
# yt-clip.sh — Download a YouTube clip between two timestamps
#
# Usage:
#   ./yt-clip.sh <URL> <start_sec> <end_sec> [output_name] [--keep]
#   ./yt-clip.sh --local <file.mp4> <start_sec> <end_sec> [output_name]
#
# Options:
#   --keep       Keep the full downloaded file after trimming (for future clips)
#   --local FILE Use a previously downloaded local file instead of re-downloading
#
# Examples:
#   ./yt-clip.sh "https://youtu.be/FMT_-NZmpsY" 7980 8254 relay-clip
#   ./yt-clip.sh "https://youtu.be/FMT_-NZmpsY" 9000 9300 relay-clip2 --keep
#   ./yt-clip.sh --local __full_relay-clip.mp4 9000 9300 relay-clip2

set -euo pipefail

# ── helpers ───────────────────────────────────────────────────────────────────
die()  { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*"; }

sec_to_hms() {
  local s=$1
  printf "%02d:%02d:%02d" $((s/3600)) $(( (s%3600)/60 )) $((s%60))
}

is_manifest_url() {
  # Returns 0 (true) if URL looks like a DASH/HLS manifest, not a direct stream
  [[ "$1" == *"manifest"* || "$1" == *"/api/manifest"* || "$1" == *.m3u8* ]]
}

require() {
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || die "'$cmd' is not installed."
  done
}

require yt-dlp ffmpeg

# ── parse args ────────────────────────────────────────────────────────────────
LOCAL_FILE=""
KEEP=false
URL=""
START=""
END=""
OUTNAME="clip"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep)   KEEP=true; shift ;;
    --local)  LOCAL_FILE="$2"; shift 2 ;;
    --*)      die "Unknown option: $1" ;;
    *)
      if   [[ -z "$URL"   && -z "$LOCAL_FILE" ]]; then URL="$1"
      elif [[ -z "$START" ]]; then START="$1"
      elif [[ -z "$END"   ]]; then END="$1"
      else OUTNAME="$1"
      fi
      shift ;;
  esac
done

[[ -n "$LOCAL_FILE" && -n "$URL" ]] && die "Use either --local or a URL, not both."
[[ -z "$LOCAL_FILE" && -z "$URL" ]] && {
  echo "Usage: $0 <URL> <start_sec> <end_sec> [output_name] [--keep]"
  echo "       $0 --local <file.mp4> <start_sec> <end_sec> [output_name]"
  exit 1
}
[[ -z "$START" || -z "$END" ]] && die "start_sec and end_sec are required."

DURATION=$(( END - START ))
[[ $DURATION -le 0 ]] && die "end_sec must be greater than start_sec."

START_HMS=$(sec_to_hms "$START")
END_HMS=$(sec_to_hms "$END")
info "Clip: $START_HMS → $END_HMS  (${DURATION}s)"

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

maybe_keep() {
  local full="$1"
  if [[ "$KEEP" == "true" ]]; then
    info "Full file kept → $full"
    info "Next clip: $0 --local $full <start> <end> [name]"
  else
    # Prompt only if not already specified
    echo ""
    read -rp "[?] Delete full download '$full'? [Y/n]: " DEL
    if [[ "${DEL,,}" == "n" ]]; then
      info "Kept → $full"
      info "Next clip: $0 --local $full <start> <end> [name]"
    else
      rm -f "$full"
      info "Full file deleted."
    fi
  fi
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
warn "Tip: use --keep to save the file and avoid re-downloading for future clips."
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

maybe_keep "$FULL_FILE"
