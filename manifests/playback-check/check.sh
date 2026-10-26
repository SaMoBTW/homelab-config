#!/bin/sh
# Playback check: read every video in zurg's library the way a player would.
#
# For each file under __magic__/tv and __magic__/movies, over zurg's WebDAV
# (never the FUSE mount - a stalled FUSE read can't be killed):
#   1. ffprobe the header: a video stream and at least MIN_SECS of duration
#   2. read 1 MB from the middle
#   3. read the last 1 MB, which catches truncated files
# Failures are re-checked in two more passes, RECHECK_SECS apart: TorBox
# refuses fresh links when many are asked for in a row (zurg answers those
# reads 503 "delivery cooldown"), and zurg's NZB sizing after a restart fails
# reads for a while too, without the file being dead. Re-checks are paced
# PACE_SECS apart. Only files that fail all three passes are reported.
#
# Report-only: nothing is replaced or deleted. When anything is confirmed
# dead the script exits 1, so the Job fails and KubeJobFailed fires.
# Reports: /volume1/k3s/media/playback-check/<date>/report.txt
set -u
DAV=${DAV:-http://zurg.zurg.svc:9999}
ROOTS=${ROOTS:-/dav/__magic__/tv/ /dav/__magic__/movies/}
MIN_SECS=${MIN_SECS:-60}
RECHECK_SECS=${RECHECK_SECS:-300}
PACE_SECS=${PACE_SECS:-2}
REPORTS=${REPORTS:-/reports}
FF=/usr/lib/jellyfin-ffmpeg/ffprobe
OUT=$REPORTS/$(date -u +%Y-%m-%d)
W=$(mktemp -d)
mkdir -p "$OUT"
stamp() { date -u +%FT%TZ; }

# PROPFIND one folder (zurg treats Depth: infinity as 1).
# Prints "D <href>" per subfolder and "F <size> <href>" per file; the first
# response is the folder itself and is skipped.
list() {
  curl -s -m 120 -X PROPFIND -H "Depth: 1" "$DAV$1" | awk '
    /<d:href>/ {
      h = $0; sub(/.*<d:href>/, "", h); sub(/<\/d:href>.*/, "", h); s = ""
      gsub(/&amp;/, "%26", h); gsub(/&#39;/, "%27", h); gsub(/&quot;/, "%22", h)
    }
    /<d:getcontentlength>/ {
      s = $0; sub(/.*<d:getcontentlength>/, "", s); sub(/<\/d:getcontentlength>.*/, "", s)
    }
    /<\/d:response>/ { if (++n == 1) next; if (s == "") print "D " h; else print "F " s " " h }'
}

# href -> readable path, for the report
decode() {
  printf '%s\n' "$1" | sed 's#^/dav/__magic__/##' | LC_ALL=C awk '
    function hex(x,   i, v) {
      v = 0; x = toupper(x)
      for (i = 1; i <= 2; i++) v = v * 16 + index("0123456789ABCDEF", substr(x, i, 1)) - 1
      return v
    }
    { o = ""; s = $0
      while (match(s, /%[0-9A-Fa-f][0-9A-Fa-f]/)) {
        o = o substr(s, 1, RSTART - 1) sprintf("%c", hex(substr(s, RSTART + 1, 2)))
        s = substr(s, RSTART + 3)
      }
      print o s }'
}

# check <size> <href>: prints why the file failed, or nothing if it passed
check() {
  size=$1; url="$DAV$2"; why=""; mb=1048576
  info=$(timeout 120 "$FF" -v error -rw_timeout 60000000 \
    -show_entries format=duration:stream=codec_type -of csv=p=0 "$url" 2>&1 | tr '\n' ' ')
  mid=$((size / 2)); endo=$((size - mb)); [ "$endo" -lt 0 ] && endo=0
  m=$(curl -s -m 60 -r "$mid-$((mid + mb - 1))" -o /dev/null -w "%{http_code}:%{size_download}" "$url")
  e=$(curl -s -m 60 -r "$endo-$((size - 1))" -o /dev/null -w "%{http_code}:%{size_download}" "$url")
  want_m=$((size - mid)); [ "$want_m" -gt "$mb" ] && want_m=$mb
  [ "$m" = "206:$want_m" ] || why="$why middle read $m;"
  [ "$e" = "206:$((size - endo))" ] || why="$why end read $e;"
  case "$info" in *video*) ;; *) why="$why no video stream;" ;; esac
  dur=$(printf '%s' "$info" | grep -oE '[0-9]+\.[0-9]+' | tail -n 1); dur=${dur%.*}
  [ "${dur:-0}" -ge "$MIN_SECS" ] || why="$why duration ${dur:-0}s;"
  if printf '%s' "$info" | grep -qiE 'error|invalid|timed out|refused|not found'; then
    why="$why ffprobe: $(printf '%s' "$info" | cut -c1-80);"
  fi
  printf '%s' "$why"
}

echo "$(stamp) listing $ROOTS"
printf '%s\n' $ROOTS > "$W/queue"
: > "$W/files"; : > "$W/unlisted"; : > "$W/suspect"; : > "$W/dead"
while [ -s "$W/queue" ]; do
  d=$(head -n 1 "$W/queue"); sed -i 1d "$W/queue"
  list "$d" > "$W/ls"
  if [ ! -s "$W/ls" ]; then echo "$d" >> "$W/unlisted"; continue; fi
  while read -r t a b; do
    if [ "$t" = D ]; then
      echo "$a" >> "$W/queue"
    else
      case "$b" in
        *.[mM][kK][vV]|*.[mM][pP]4|*.[aA][vV][iI]|*.[mM]4[vV]|*.[tT][sS]) echo "$a $b" >> "$W/files" ;;
      esac
    fi
  done < "$W/ls"
done

total=$(wc -l < "$W/files")
start=$(date +%s)
echo "$(stamp) checking $total files"
n=0
while read -r size href; do
  n=$((n + 1))
  why=$(check "$size" "$href" < /dev/null)
  if [ -n "$why" ]; then
    echo "$size $href" >> "$W/suspect"
    case "$why" in *503*) ;; *) echo "  suspect: $(decode "$href") -$why" ;; esac
  fi
  [ $((n % 500)) -eq 0 ] && echo "$(stamp) $n/$total done, $(wc -l < "$W/suspect") suspect"
done < "$W/files"

for pass in 2 3; do
  [ -s "$W/suspect" ] || break
  echo "$(stamp) pass $pass: re-checking $(wc -l < "$W/suspect") file(s) in ${RECHECK_SECS}s"
  sleep "$RECHECK_SECS"
  : > "$W/still"; : > "$W/dead"
  while read -r size href; do
    why=$(check "$size" "$href" < /dev/null)
    if [ -n "$why" ]; then
      echo "$size $href" >> "$W/still"
      echo "$(decode "$href") -$why" >> "$W/dead"
    fi
    sleep "$PACE_SECS"
  done < "$W/suspect"
  mv "$W/still" "$W/suspect"
done

dead=$(wc -l < "$W/dead"); unlisted=$(wc -l < "$W/unlisted")
{
  echo "Playback check $(date -u +%F)"
  echo "took $(( ($(date +%s) - start) / 60 )) min"
  echo "files: $total   passed: $((total - dead))   dead: $dead   folders that failed to list: $unlisted"
  [ "$dead" -gt 0 ] && { echo; echo "Dead (failed 3 passes, ${RECHECK_SECS}s+ apart):"; sed 's/^/  /' "$W/dead"; }
  [ "$unlisted" -gt 0 ] && { echo; echo "Folders zurg didn't list:"; sed 's/^/  /' "$W/unlisted"; }
} > "$OUT/report.txt"
cat "$OUT/report.txt"
rm -rf "$W"
[ "$total" -gt 0 ] && [ "$dead" -eq 0 ] && [ "$unlisted" -eq 0 ]
