#!/usr/bin/env bash
# =============================================================================
#  gpu-setup-pin.sh — configuration persistante : OD 1000/850 + fréquence figée
#
#  Résultat mesuré (Groot-19B-A3B, prefill 16k, ctx 65536, cap 100 W) :
#    SCLK 1000 MHz @ 850 mV, MCLK 800 MHz figés
#    -> 579,6 t/s prefill, 38,1 t/s génération, clocks sans aucune variation
#  À comparer au mode auto à 80 W : 491 t/s / 22,8 t/s.
#
#  Ordre impératif : power cap AVANT OD (le commit OD peut réinitialiser le cap),
#  puis manuel AVANT les paliers.
# =============================================================================
set -uo pipefail
CARDS="${CARDS:-1 2}"
SCLK_IDX="${SCLK_IDX:-1}"; MCLK_IDX="${MCLK_IDX:-3}"
SCLK_MHZ="${SCLK_MHZ:-1000}"; SCLK_MV="${SCLK_MV:-850}"
CAP_W="${CAP_W:-100}"

for c in $CARDS; do
  d=/sys/class/drm/card$c/device
  h=$(ls -d "$d/hwmon/hwmon"* 2>/dev/null | head -1)

  # 1. power cap
  [ -n "$h" ] && echo $(( CAP_W * 1000000 )) > "$h/power1_cap"

  # 2. point OD : fréquence exacte + tension
  echo "s $SCLK_IDX $SCLK_MHZ $SCLK_MV" > "$d/pp_od_clk_voltage" 2>/dev/null
  echo c > "$d/pp_od_clk_voltage" 2>/dev/null

  # 3. figement (manual d'abord)
  echo manual > "$d/power_dpm_force_performance_level"
  echo "$SCLK_IDX" > "$d/pp_dpm_sclk"
  echo "$MCLK_IDX" > "$d/pp_dpm_mclk"

  # 4. le commit OD peut avoir rendu le cap : on le réaffirme
  [ -n "$h" ] && echo $(( CAP_W * 1000000 )) > "$h/power1_cap"
done

sleep 1
for c in $CARDS; do
  d=/sys/class/drm/card$c/device
  echo "card$c: $(cat $d/power_dpm_force_performance_level) | $(grep '\*' $d/pp_dpm_sclk | tr -s ' ') | $(grep '\*' $d/pp_dpm_mclk | tr -s ' ')"
done