# Scripts

All of these were written for this specific node. **Paths and card indices need
adjusting for your hardware** — nothing here is distribution-agnostic.

| script | purpose | notes |
|---|---|---|
| `gpu-setup-pin.sh` | apply power cap + overdrive point + pin clocks | idempotent, safe to re-run. Order inside matters — see comments. Driven by `CARDS`, `SCLK_IDX`, `MCLK_IDX`, `SCLK_MHZ`, `SCLK_MV`, `CAP_W` env vars. |
| `gpu-tuning.service` | systemd unit running the above at boot | hardcodes `/home/aitest/bin/gpu-setup-pin.sh` — change it. |
| `stress-psu.sh` | sustained load power test | `./stress-psu.sh <iterations> <prompt-file>` |
| `dpm_sweep.sh` | sweep caps/frequencies to find the stable envelope | slow; run it once when you change the PSU or cabling |
| `longctx_bench.sh` | context-length sweep | writes a table |
| `gpu-pinclk.sh` | interactive pin / unpin helper | `gpu-pinclk.sh pin 1 3` |
| `gpu-undervolt.sh` | earlier standalone undervolt attempt | superseded by `gpu-setup-pin.sh`; kept for reference |

## Required prerequisites

```bash
# /etc/default/grub
amdgpu.ppfeaturemask=0xffffffff
amdgpu.bapm=0
```

Without `ppfeaturemask` bit 0x4000 (included in `0xffffffff`), the entire
`pp_od_clk_voltage` interface is empty and none of the voltage work is possible.

## Checking the result

```bash
for d in /sys/class/drm/card[1-9]/device; do
  h=$(ls -d $d/hwmon/hwmon* | head -1)
  echo "card: cap=$(($(cat $h/power1_cap)/1000000))W \
$(grep '\*' $d/pp_dpm_sclk | tr -s ' ') \
$(grep '\*' $d/pp_dpm_mclk | tr -s ' ') \
| $(sed -n 4p $d/pp_od_clk_voltage)"
done
```

Expected on this node:

```
cap=100W   1: 1000Mhz *   3: 800Mhz *
```

If `pp_dpm_sclk` shows a different active index after a few minutes of load, the
pin did not hold and DPM is back in charge.