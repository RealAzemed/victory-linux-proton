#!/usr/bin/env bash
# Hands-free benchmark run: boots the title through the launcher with
# auto-pressed A (VICTORY_AUTO_INPUT, first 120 s), lets it run for
# DURATION seconds, records RAM/swap every 5 s into the log, then ends the
# title and prints the in-world summary.
#
#   tools/bench.sh <label> [duration_s]     (extra VICTORY_* env vars pass through)
#   echo "A" > press.txt                    (send buttons while it runs)
set -uo pipefail

BASE_DIR="$HOME/.local/share/ztrx"
PROTON="${PROTON:-$HOME/.local/share/Steam/steamapps/common/Proton - Experimental}"
LABEL="${1:?label}"
DURATION="${2:-420}"
PRESS="$BASE_DIR/press.txt"
: > "$PRESS"

export VICTORY_AUTO_INPUT=1
export VICTORY_PRESS_FILE='Z:\home\$USER\.local\share\ztrx\press.txt'

"$BASE_DIR/launch-scarlett.sh" play >/dev/null 2>&1 &
launcher=$!
sleep 3
log=$(readlink -f "$BASE_DIR/logs/latest.log")
echo "bench '$LABEL': $log (${DURATION}s)"

start=$(date +%s)
while kill -0 "$launcher" 2>/dev/null && (( $(date +%s) - start < DURATION )); do
    avail=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)
    swap=$(awk '/SwapTotal/ {t=$2} /SwapFree/ {f=$2} END {printf "%d", (t-f)/1024}' /proc/meminfo)
    rss=$(ps -eo rss,args | awk '/victory\.exe/ && !/awk/ {s+=$1} END {printf "%d", s/1024}')
    t=$(( $(date +%s) - start ))
    # pages swapped in/out since boot (4 KiB each): the summary turns them into MB/s
    swin=$(awk '/^pswpin/ {print $2}' /proc/vmstat); swout=$(awk '/^pswpout/ {print $2}' /proc/vmstat)
    echo "#mem $t avail_mb=$avail swap_mb=$swap rss_mb=$rss swpin=$swin swpout=$swout" >> "$log.mem"
    # SKIP_CUTSCENE=1: periodically send A + START via press.txt after entering world
    # so long intro cutscenes skip straight to gameplay.
    if [[ "${SKIP_CUTSCENE:-0}" == "1" ]] && (( t >= 105 && t % 15 < 5 )); then
        printf 'A START\n' > "$PRESS"
    fi
    # SHOTS=1: a full-screen screenshot every SHOT_EVERY s (default 120) after 150 s.
    if [[ "${SHOTS:-0}" == "1" ]] && (( t >= 150 && (t - 150) % ${SHOT_EVERY:-120} < 5 )); then
        mkdir -p "$BASE_DIR/research/shots"
        timeout 20 spectacle -b -n -f -o "$BASE_DIR/research/shots/$LABEL-$(printf %04d "$t").png" >/dev/null 2>&1 &
    fi
    if (( t >= DURATION - 35 )) && [[ -z "${warned:-}" ]]; then
        warned=1
        notify-send -a "victory bench" -u critical "Test run '$LABEL' ends in ~30 s" "The game window will close by itself. That is the test ending, not a crash." 2>/dev/null || true
    fi
    sleep 5
done

if kill -0 "$launcher" 2>/dev/null; then
    WINEPREFIX="$BASE_DIR/proton/pfx" "$PROTON/files/bin/wineserver" -k 2>/dev/null
    wait "$launcher" 2>/dev/null
    echo "ended after ${DURATION}s"
else
    echo "title exited on its own after $(( $(date +%s) - start ))s"
fi
echo "#bench label=$LABEL" >> "$log.mem"
notify-send -a "victory bench" "Test run '$LABEL' finished" "Closed on purpose after ${DURATION}s (not a crash)." 2>/dev/null || true
python3 "$BASE_DIR/tools/bench-summary.py" "$log"
grep -c "unhandled exception" "$log" | xargs -I{} echo "   unhandled exceptions: {}"
