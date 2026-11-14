#!/usr/bin/env bash
# =============================================================================
#  longctx_bench.sh — coût réel du contexte lourd (prefill) par mode de split
#
#  Mesure ce que les benchmarks classiques cachent : le prefill d'un VRAI gros
#  prompt (16k/48k tokens), pour chaque mode de découpage multi-GPU.
#
#  Sur Vulkan, -sm row échoue (pas de split buffers) : seuls layer et tensor
#  sont utilisables. -sm tensor est implémenté dans le graphe (expérimental).
#
#  Usage :
#    bash longctx_bench.sh                          # layer+tensor, 16k puis 48k
#    bash longctx_bench.sh --modes layer --files /path/a.txt
#    bash longctx_bench.sh --ctx 65536 --n 64
# =============================================================================
set -uo pipefail

STATE="${STATE_DIR:-/home/aitest/aitest-gpu}"
BIN="${BIN:-$STATE/llama-vulkan/llama-cli}"
ICD="${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/radeon_icd.json}"
MODEL="${MODEL:-/home/aitest/models/groot19/GrootTeam_Groot-19B-A3B-261023-IQ4_XS.gguf}"
CTX=65536; NTOK=64; MODES="layer tensor"; MAXJ="${MAXJ:-92}"
FILES="$HOME/prompts/p16k.txt $HOME/prompts/p48k.txt"
LOGDIR="$HOME/logs"; mkdir -p "$LOGDIR"
LOG="$LOGDIR/longctx-$(date +%Y%m%d-%H%M%S).log"

while [ $# -gt 0 ]; do
  case "$1" in
    --modes) MODES="$2"; shift ;;
    --files) FILES="$2"; shift ;;
    --ctx) CTX="$2"; shift ;;
    --n) NTOK="$2"; shift ;;
    --model) MODEL="$2"; shift ;;
    --max-junction) MAXJ="$2"; shift ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "option inconnue: $1" >&2; exit 64 ;;
  esac; shift
done

[ -s "$MODEL" ] || { echo "modèle introuvable: $MODEL" >&2; exit 1; }

HWMONS=$(ls -d /sys/class/drm/card[1-9]/device/hwmon/hwmon* 2>/dev/null)
jmax() { local m=0 v; for h in $HWMONS; do v=$(( $(cat "$h/temp2_input" 2>/dev/null||echo 0)/1000 )); [ "$v" -gt "$m" ] && m=$v; done; echo "$m"; }
vram()  { for d in /sys/class/drm/card[1-9]/device; do echo -n "$(( $(cat $d/mem_info_vram_used)/1048576 ))M "; done; }

echo "# longctx_bench — $(date '+%F %T') — modèle $(basename "$MODEL") ctx=$CTX n=$NTOK" | tee -a "$LOG"
printf '%-8s %-8s %-10s %-12s %-12s %-9s %-6s\n' "mode" "prompt" "prefill" "génération" "wall" "VRAM" "junc" | tee -a "$LOG"

for mode in $MODES; do
  for f in $FILES; do
    [ -s "$f" ] || { echo "$mode $(basename $f) absent" | tee -a "$LOG"; continue; }
    # garde-fou thermique en tâche de fond
    ( while :; do j=$(jmax); [ "$j" -ge "$MAXJ" ] && { echo "  !! garde-fou ${j}C: arrêt" >> "$LOG"; pkill -9 -x llama-cli; break; }; sleep 2; done ) & GPID=$!
    T0=$(date +%s)
    VK_ICD_FILENAMES="$ICD" timeout 2400 "$BIN" -m "$MODEL" -c "$CTX" -n "$NTOK" \
      -ngl 99 -dev Vulkan0,Vulkan1 -sm "$mode" -fa on \
      --no-display-prompt -f "$f" > "$LOGDIR/raw-$mode-$(basename "$f" .txt).log" 2>&1
    T1=$(date +%s)
    kill $GPID 2>/dev/null; wait $GPID 2>/dev/null
    PP=$(grep -ao 'Prompt: [0-9.]* t/s' "$LOGDIR/raw-$mode-$(basename "$f" .txt).log" | tail -1 | awk '{print $2}')
    TG=$(grep -ao 'Generation: [0-9.]* t/s' "$LOGDIR/raw-$mode-$(basename "$f" .txt).log" | tail -1 | awk '{print $2}')
    J=$(jmax); V=$(vram | tr '\n' ' ')
    printf '%-8s %-8s %-10s %-12s %-12s %-9s %-6s\n' "$mode" "$(basename "$f" .txt)" \
      "${PP:-NA} t/s" "${TG:-NA} t/s" "$(( T1-T0 ))s" "$V" "${J}C" | tee -a "$LOG"
  done
done
echo "# fin — log complet : $LOG" | tee -a "$LOG"