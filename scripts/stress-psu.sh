#!/usr/bin/env bash
# =============================================================================
#  stress-psu.sh — charge soutenue pour valider la tenue de l'alim
#
#  Enchaîne N itérations complètes (chargement du modèle + prefill long +
#  génération) : le chargement est justement la phase où les coupures sont
#  survenues à 100 W en mode auto.
#
#  Usage : bash stress-psu.sh [N] [prompt]
# =============================================================================
set -uo pipefail
N="${1:-6}"
PROMPT="${2:-/home/aitest/prompts/p48k.txt}"
BIN=/home/aitest/aitest-gpu/llama-vulkan/llama-cli
MODEL=/home/aitest/models/groot19/GrootTeam_Groot-19B-A3B-261023-IQ4_XS.gguf
LOG=/home/aitest/logs/stress-$(date +%Y%m%d-%H%M%S).log
CSV=${LOG%.log}.csv
echo "ts,c1_W,c2_W,tot_W" > "$CSV"

echo "# stress: $N itérations | prompt $(basename $PROMPT) | caps: $(for d in /sys/class/drm/card[1-9]/device; do h=$(ls -d $d/hwmon/hwmon*|head -1); echo -n "$(($(cat $h/power1_cap)/1000000))W "; done)" | tee "$LOG"
echo "# fréq: $(grep '\*' /sys/class/drm/card1/device/pp_dpm_sclk | tr -s ' ') / $(grep '\*' /sys/class/drm/card1/device/pp_dpm_mclk | tr -s ' ')" | tee -a "$LOG"

( while :; do
    a=$(cat /sys/class/drm/card1/device/hwmon/hwmon*/power1_input 2>/dev/null || echo 0)
    b=$(cat /sys/class/drm/card2/device/hwmon/hwmon*/power1_input 2>/dev/null || echo 0)
    echo "$(date +%s),$((a/1000000)),$((b/1000000)),$(((a+b)/1000000))" >> "$CSV"
    sync; sleep 1
  done ) & SPID=$!

T0=$(date +%s)
for i in $(seq 1 "$N"); do
  r=$(VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json timeout 900 "$BIN" \
      -m "$MODEL" -c 65536 -n 128 -ngl 99 -dev Vulkan0,Vulkan1 -sm layer -fa on \
      --no-display-prompt -f "$PROMPT" < /dev/null 2>&1 | grep -aE "Prompt: |Generation: " | tail -1)
  echo "  iter $i/$N ($(($(date +%s)-T0))s): $r" | tee -a "$LOG"
done
kill $SPID 2>/dev/null

awk -F, 'NR>1{ n++; s+=$4; if($4>mx)mx=$4; if($4<mn||mn==0)mn=$4 }
     END{ printf "# conso: moy=%.1f W  min=%d W  MAX=%d W  (%d éch.)\n", s/n, mn, mx, n }' "$CSV" | tee -a "$LOG"
echo "# durée totale: $(($(date +%s)-T0))s" | tee -a "$LOG"