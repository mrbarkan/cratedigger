#!/bin/bash
# Compare two style captures pixel by pixel, ignoring the parts that change from
# launch to launch. Usage: scripts/style-compare.sh <a.png> <b.png>
# Prints the number of differing pixels outside the masks; exits 0 only when it is 0.
# Layout is read from the image size (captures are 2x): mini < 1000 px wide,
# compact is wide and short, full is wide and tall.
set -u
A="${1:?a.png}"; B="${2:?b.png}"
dims() { ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$1"; }
DA="$(dims "$A" 2>/dev/null)"; DB="$(dims "$B" 2>/dev/null)"
[ -n "$DA" ] && [ -n "$DB" ] || { echo "cannot read $A or $B"; exit 2; }
[ "$DA" = "$DB" ] || { echo "size differs: $DA vs $DB"; exit 1; }
W="${DA%x*}"; H="${DA#*x}"

# Masks in capture pixels (x:y:w:h). Measured on back-to-back baseline captures:
#  - the display changes per launch (idle phrase, LED matrix, and in light compact even its
#    annunciator strip), so all of it is masked
#  - the titlebar status LED / matrix switch sits top right (full) or beside the traffic lights (compact)
if [ "$W" -lt 1000 ]; then
  LAYOUT=mini;    MASKS=("20:25:40:40")                       # status LED dot
elif [ "$H" -lt 1000 ]; then
  LAYOUT=compact; MASKS=("510:20:2270:360" "440:0:80:80")      # whole display, LED
else
  LAYOUT=full;    MASKS=("370:20:2180:360" "2700:0:100:90")    # whole display, LED
fi
VF="format=rgb24"
for m in "${MASKS[@]}"; do
  IFS=: read -r x y w h <<<"$m"
  VF="$VF,drawbox=x=$x:y=$y:w=$w:h=$h:color=black:t=fill"
done
N="$(ffmpeg -loglevel error -i "$A" -i "$B" -filter_complex \
  "[0:v]$VF[a];[1:v]$VF[b];[a][b]blend=all_mode=difference,lutrgb=r='if(gt(val,0),255,0)':g='if(gt(val,0),255,0)':b='if(gt(val,0),255,0)',format=gray" \
  -frames:v 1 -f rawvideo -pix_fmt gray - | python3 -c "import sys;d=sys.stdin.buffer.read();print(len(d)-d.count(0))")"
case "$N" in
  ""|*[!0-9]*) echo "compare failed (no pixel count)"; exit 2 ;;
esac
echo "$LAYOUT: $N differing pixels outside masks"
[ "$N" = 0 ]
