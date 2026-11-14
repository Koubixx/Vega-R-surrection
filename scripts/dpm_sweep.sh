#!/usr/bin/env bash
# =============================================================================
#  dpm_sweep.sh — trouve le cap de puissance où le DPM des Vega se débloque
#
#  Problème mesuré : à 80 W, sous charge 100 %, les cartes restent au palier
#  0 (SCLK ~850 MHz, MCLK 167 MHz) alors que le SMU demande 1269/700.
#  Résultat : 80 W payés pleins pour ~21 % de la bande mémoire.
#
#  Ce banc monte le cap par paliers, applique une charge réelle (prefill
#  llama.cpp) et relève les fréquences RÉELLES (amdgpu_pm_info, pas les
#  paliers "demandés" de pp_dpm_*), pour trouver le genou.
#
#  Usage (root) :
#    bash dpm_sweep.sh                          # 80→165 W par 10
#    CAPS="80 100 120" bash dpm_sweep.sh        # paliers choisis
#    CARDS="1" bash dpm_sweep.sh                # une seule carte (plus sûr)
#    RESTORE=80 bash dpm_sweep.sh               # cap remis à 80 W à la fin
# =============================================================================
set -uo pipefail

BIN="${BIN:-/home/aitest/aitest-gpu/llama-vulkan/llama-cli}"
MODEL="${MODEL:-/home/aitest/models/groot19/GrootTeam_Groot-19B-A3B-261023-IQ4_XS.gguf}"
PROMPT="${PROMPT:-/home/aitest/prompts/p16k.txt}"
CAPS="${CAPS:-80 90 100 110 120 130 140 150 165}"
CARDS="${CARDS:-1 2}"
N="${N:-24}"; CTX="${CTX:-16384}"; MAXJ="${MAXJ:-92}"
DEV="${DEV:-Vulkan0,Vulkan1}"   # restreindre à Vulkan0 quand CARDS=1
RESTORE="${RESTORE:-}"
LOGDIR=/home/aitest/logs; mkdir -p "$LOGDIR"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$LOGDIR/sweep-dpm-$STAMP.log"
RAW="$LOGDIR/sweep-dpm-$STAMP.csv"
echo "ts,cap_W,card,busy,sclk_MHz,mclk_MHz,pwr_W,junc_C" > "$RAW"

pci()  { case "$1" in 1) echo 0000:04:00.0 ;; 2) echo 0000:07:00.0 ;; esac; }
sysd() { echo /sys/class/drm/card$1/device; }
setcap() { local w=$1 h c; shift; for c in "$@"; do h=$(ls -d "$(sysd $c)/hwmon/hwmon"* 2>/dev/null | head -1); [ -n "$h" ] && echo $(( w * 1000000 )) > "$h/power1_cap"; done; }
jmax()   { local m=0 v; for c in $CARDS; do h=$(ls -d "$(sysd $c)/hwmon/hwmon"* 2>/dev/null | head -1); v=$(( $(cat "$h/temp2_input" 2>/dev/null || echo 0)/1000 )); [ "$v" -gt "$m" ] && m=$v; done; echo "$m"; }

# une ligne de mesures réelles par carte
sample_once() { # $1 = cap courant
  local cap=$1 c d h busy sclk mclk pwr j
  for c in $CARDS; do
    d="$(sysd $c)"; local dev="/sys/kernel/debug/dri/$(pci $c)/amdgpu_pm_info"
    busy=$(cat "$d/gpu_busy_percent" 2>/dev/null || echo 0)
    sclk=$(grep -oE '^[[:space:]]*[0-9]+ MHz \(SCLK\)' "$dev" 2>/dev/null | grep -oE '^[[:space:]]*[0-9]+' | tr -d ' ')
    mclk=$(grep -oE '^[[:space:]]*[0-9]+ MHz \(MCLK\)' "$dev" 2>/dev/null | grep -oE '^[[:space:]]*[0-9]+' | tr -d ' ')
    h=$(ls -d "$d/hwmon/hwmon"* 2>/dev/null | head -1)
    pwr=$(( $(cat "$h/power1_input" 2>/dev/null || echo 0)/1000000 ))
    j=$(( $(cat "$h/temp2_input" 2>/dev/null || echo 0)/1000 ))
    echo "$(date +%s),$cap,$c,${busy:-0},${sclk:-0},${mclk:-0},$pwr,$j" >> "$RAW"
  done
}

echo "# dpm_sweep — $(date '+%F %T') — cartes: $CARDS — paliers: $CAPS — prompt $(basename $PROMPT)" | tee "$OUT"
printf '%-6s %-6s %-9s %-9s %-8s %-9s\n' "cap_W" "carte" "SCLK_réel" "MCLK_réel" "conso" "junc" >> "$OUT"

for cap in $CAPS; do
  setcap "$cap" $CARDS
  sleep 2
  VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json \
    timeout 600 "$BIN" -m "$MODEL" -c "$CTX" -n "$N" -ngl 99 -dev "$DEV" \
    -sm layer -fa on --no-display-prompt -f "$PROMPT" > "$LOGDIR/sweep-raw-$cap.log" 2>&1 &
  LPID=$!
  while kill -0 $LPID 2>/dev/null; do
    sample_once "$cap"
    [ "$(jmax)" -ge "$MAXJ" ] && { echo "  !! garde-fou $(jmax)C à ${cap}W" | tee -a "$OUT"; pkill -9 -x llama-cli; break; }
    sleep 1
  done
  wait $LPID 2>/dev/null
  PP=$(grep -ao 'Prompt: [0-9.]* t/s' "$LOGDIR/sweep-raw-$cap.log" | tail -1 | awk '{print $2}')
  # stats sur les échantillons réellement chargés (busy >= 90)
  for c in $CARDS; do
    # attention : mawk (défaut Ubuntu) n'a pas asort() -> moyennes, pas médianes
    stats=$(awk -F, -v cap="$cap" -v c="$c" '
      $2==cap && $3==c && $4>=90 {
        n++; ss+=$5; if($5>ms) ms=$5; mm+=$6; if($6>mmax) mmax=$6; p+=$7; j=$8
      }
      END { if(n==0){print "0 0 0 0 0"; exit}
            printf "%d %d %d %d %d", ss/n, ms, mm/n, mmax, p/n }' "$RAW")
    set -- $stats
    printf '%-6s %-6s %-9s %-9s %-8s %-9s\n' "${cap}W" "card$c" "$1 MHz (max $2)" "$3 MHz (max $4)" "$5 W" "$(jmax)C" >> "$OUT"
  done
  printf '  -> prefill: %s t/s\n' "${PP:-NA}" >> "$OUT"
done

[ -n "$RESTORE" ] && { setcap "$RESTORE" $CARDS; echo "# cap restauré à ${RESTORE}W" >> "$OUT"; }

echo "# ---" >> "$OUT"
echo "# CSV brut: $RAW" >> "$OUT"
awk -F, 'NR>1 && $4>=90 {key=$2"W card"$3; if($6>mx[key]) mx[key]=$6} END{print "# MCLK max atteint par palier:"; for(k in mx) print "#   "k" -> "mx[k]" MHz"}' "$RAW" >> "$OUT"
cat "$OUT"