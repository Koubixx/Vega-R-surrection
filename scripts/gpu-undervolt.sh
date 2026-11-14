#!/usr/bin/env bash
# =============================================================================
#  gpu-undervolt.sh — undervolt Vega 56 via l'interface OD d'amdgpu
#
#  Prérequis : amdgpu.ppfeaturemask=0xffffffff dans GRUB (sinon pp_od_clk_voltage
#  est vide). Voir SKILL.md §undervolt.
#
#  La carte tourne sous power cap : elle passe l'essentiel de son temps sur les
#  paliers BAS (0-2). Les baisser est donc plus rentable que le palier 7.
#
#  Usage :
#    bash gpu-undervolt.sh mild     # -50/-75 mV (premier essai)
#    bash gpu-undervolt.sh medium   # -100/-125 mV
#    bash gpu-undervolt.sh reset    # retour aux valeurs stock (echo r)
#    CARDS="1" bash gpu-undervolt.sh mild
# =============================================================================
set -uo pipefail

CARDS="${CARDS:-1 2}"
PROFILE="${1:-mild}"
OD() { echo /sys/class/drm/card$1/device/pp_od_clk_voltage; }

# profil: "sclk_idx:mV" par ligne — les fréquences restent celles du stock
case "$PROFILE" in
  mild)   POINTS="1:825 2:900 3:950 4:1000 5:1050 6:1100 7:1150" ;;  # -75/-50
  medium) POINTS="1:800 2:875 3:925 4:975 5:1025 6:1075 7:1125" ;;   # -100/-75
  hard)   POINTS="1:775 2:850 3:900 4:950 5:1000 6:1050 7:1100" ;;   # -125/-100
  reset)  POINTS="" ;;
  *) echo "profil inconnu: $PROFILE (mild|medium|hard|reset)" >&2; exit 64 ;;
esac

FREQ=(852 991 1138 1269 1312 1474 1569 1622)     # index 0..7 = fréquences stock

for c in $CARDS; do
  f=$(OD $c)
  [ -w "$f" ] || { echo "card$c: $f non accessible (root + ppfeaturemask ?)" >&2; continue; }
  if [ "$PROFILE" = reset ]; then
    echo r > "$f" && echo c > "$f" && echo "card$c: valeurs stock restaurées"
    continue
  fi
  for p in $POINTS; do
    idx=${p%%:*}; mv=${p##*:}
    echo "s $idx ${FREQ[$idx]} $mv" > "$f" || echo "card$c: échec palier $idx" >&2
  done
  echo c > "$f" || echo "card$c: échec du commit" >&2
  # le commit OD peut réinitialiser le cap : on le remet
  h=$(ls -d /sys/class/drm/card$c/device/hwmon/hwmon* 2>/dev/null | head -1)
  cap=$(cat /home/aitest/.gpu_cap 2>/dev/null || echo "")
  [ -n "$cap" ] && [ -n "$h" ] && { echo $(( cap * 1000000 )) > "$h/power1_cap"; }
  echo "card$c: profil $PROFILE appliqué ($(cat $f | grep -cE '^[0-9]:'))"
done

echo "--- état ---"
for c in $CARDS; do
  echo "card$c:"; cat "$(OD $c)" | sed -n '/OD_SCLK/,/OD_RANGE/p' | head -10
done