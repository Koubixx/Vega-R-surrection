# Power, clocks, and why the machine kept switching itself off

## The symptom

Sustained inference on the Z440 produced **instant power-offs** — no kernel panic,
no OOM, no thermal trip in `journalctl`, nothing. Just a dead box mid-generation.
It happened within seconds of a heavy prefill starting, and never at idle.

## The hardware constraint

HP Z440, 700 W PSU. The GPU rail is the problem: **225 W maximum** across two
6-pin PCIe connectors. Two Vega 56 at stock (210 W TDP each, with boost transients
well above that) are far outside that envelope.

Note what this is *not*: the total is not the issue. 700 W is plenty for a
Xeon E5-2683 v4 plus two cards. The issue is the **instantaneous rate of change**
on the 12 V rail.

## Root cause: DPM transients, not average power

AMD's Dynamic Power Management ramps core frequency and voltage in steps when it
detects load. Each ramp is a step change in current draw, and the supply's
over-current protection reacts to the edge, not to the steady-state value. With a
rail that is already close to its limit, the transient overshoot is what trips it.

Evidence that it was transients and not total power:

- Shutdowns happened **at the start** of load, not after minutes of steady draw.
- Capping power to 80 W in *auto* DPM mode still shut down — the cap limits the
  average, DPM still produces the edges.
- Pinning the frequencies at 100 W **eliminated** the shutdowns entirely, at a
  higher average power than the failing 80 W auto configuration (204 W peak
  measured across both cards under stress).

That last point is the whole story. It was never about how much power we drew,
but about how fast we asked for it.

## The fix

Two kernel parameters and one systemd unit.

### Kernel parameters (`/etc/default/grub`)

```
amdgpu.ppfeaturemask=0xffffffff   # enable the overdrive interface
amdgpu.bapm=0                     # disable Vega's TDP-bursting behaviour
```

`ppfeaturemask` must include the overdrive bit or `pp_od_clk_voltage` is empty and
you cannot touch voltages at all — `0xfff7bfff`, the common default, has that bit
cleared.

`bapm` (bi-directional application power management) is Vega-specific and lets the
card exceed its nominal TDP for bursts. It is a documented but rarely mentioned
source of excursions. Disabling it alone was not sufficient on this node, but it
removes a class of spikes.

### `/etc/systemd/system/gpu-tuning.service`

```ini
[Unit]
Description=Tuning Vega 56 (cap 100 W + OD 1000/850 + pinned clocks)
After=systemd-udev-settle.service graphical.target
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/home/aitest/bin/gpu-setup-pin.sh

[Install]
WantedBy=multi-user.target
```

`systemd-udev-settle` matters: applying overdrive settings before the DRM device
is fully populated silently fails.

### Ordering inside the script

The order is not cosmetic:

1. **Power cap first.** Committing an overdrive point can reset the cap.
2. **Overdrive point** (`s <index> <MHz> <mV>` then `c` to commit).
3. **`manual` before pinning** — writing an index to `pp_dpm_sclk` while the
   governor is in `auto` gets overwritten on the next DPM tick.
4. **Re-assert the cap** after the OD commit.

See [`scripts/gpu-setup-pin.sh`](../scripts/gpu-setup-pin.sh).

## The resulting operating point

```
SCLK  1000 MHz @ 850 mV   (stock boost ≈ 1470-1590 MHz)
MCLK   800 MHz            (stock — deliberately left alone)
Cap    100 W per card
```

Measured effect on inference (Groot-19B-A3B, 16 k prompt, 64 k context):

| config | prefill | generation | shutdowns |
|---|---|---|---|
| auto DPM, 80 W cap | 491 tok/s | 22.8 tok/s | yes |
| **pinned, 100 W cap** | **611 tok/s** | **38.1 tok/s** | **no (8/8 runs)** |

The pinned configuration is both **faster and stable**. Auto DPM does not "use the
headroom better" — it thrashes between states, and every transition is a risk.

## Why cutting the core clock is cheap

Vega 56: 14 nm, 56 CUs, 2048-bit HBM2 at 409 GB/s. Autoregressive decode at batch
size 1 reads the active weights once per token and does comparatively little math,
so throughput follows memory bandwidth, not core frequency.

- Core clock: **−32 %**
- Throughput: **−20 %**
- Power: roughly **−40 %**

Cutting MCLK instead would have been catastrophic: HBM frequency is almost
linearly tied to decode speed.

## Verification

```bash
# clocks and cap
for d in /sys/class/drm/card[1-9]/device; do
  h=$(ls -d $d/hwmon/hwmon* | head -1)
  echo "cap=$(($(cat $h/power1_cap)/1000000))W  $(grep '\*' $d/pp_dpm_sclk | tr -s ' ')  $(grep '\*' $d/pp_dpm_mclk | tr -s ' ')"
done

# sustained test (8 iterations of a 16 k prompt)
scripts/stress-psu.sh 8 /path/to/prompt-16k.txt
```

During a passing run, `pp_dpm_sclk` never shows a different active index. If it
moves, your pinning did not take and you are one transient away from a shutdown.

## The one unverified thing

`gpu-tuning.service` is enabled and works when started manually. Boot-time
ordering against `amdgpu` module initialisation has **not** been validated on a
cold start — the node has only been rebooted with the unit already applied. Check
it after your first reboot:

```bash
systemctl status gpu-tuning.service
cat /sys/class/drm/card1/device/pp_dpm_sclk | grep '\*'
```

If the service is `inactive`, a `udev` rule on the DRM device is a more reliable
trigger than `multi-user.target`.