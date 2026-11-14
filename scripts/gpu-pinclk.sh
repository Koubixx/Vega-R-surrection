#!/usr/bin/env bash
# =============================================================================
#  gpu-pinclk.sh — fige les fréquences pour supprimer les rampes de courant
#
#  Hypothèse : les coupures d'alim viennent des SAUTS de tension/fréquence
#  (DPM 167→800 MHz, 852→1269 MHz), pas de la puissance moyenne. En mode
#  `manual` avec un palier figé, le courant reste plat : l'alim ne voit plus
#  de marche d'escalier.
#
#  Usage (root) :
#    bash gpu-pinclk.sh pin 2 3      # SCLK palier 2 (1138 MHz), MCLK palier 3 (800 MHz)
#    bash gpu-pinclk.sh pin 1 2      # plus bas : 991 MHz / 700 MHz
#    bash gpu-pinclk.sh off          # retour en auto
#    CARDS="1" bash gpu-pinclk.sh pin 2 3
# =============================================================================
set -uo pipefail
ACTION="${1:-pin}"; SCLK="${2:-2}"; MCLK="${3:-3}"
CARDS="${CARDS:-1 2}"
D() { echo /sys/class/drm/card$1/device; }

for c in $CARDS; do
  d=$(D $c)
  if [ "$ACTION" = off ]; then
    echo auto > "$d/power_dpm_force_performance_level" && echo "card$c: DPM auto"
    continue
  fi
  # ordre important : manual AVANT d'écrire les paliers
  echo manual > "$d/power_dpm_force_performance_level" || { echo "card$c: manual refusé"; continue; }
  echo "$SCLK" > "$d/pp_dpm_sclk" || echo "card$c: écriture sclk refusée"
  echo "$MCLK" > "$d/pp_dpm_mclk" || echo "card$c: écriture mclk refusée"
  sleep 1
  echo "card$c: $(cat $d/power_dpm_force_performance_level) | $(grep '\*' $d/pp_dpm_sclk | tr -s ' ') | $(grep '\*' $d/pp_dpm_mclk | tr -s ' ')"
done

echo "--- conso au repos (10 s) ---"
for i in 1 2 3; do
  t=0; for c in $CARDS; do h=$(ls -d $(D $c)/hwmon/hwmon*|head -1); t=$(( t + $(cat $h/power1_input) )); done
  echo -n "$((t/1000000))W "; sleep 3
done; echo