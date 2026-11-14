# Sizing quant + context for 2×8 GB

The nerdiest useful thing about this build: the arithmetic that decides what fits.

## The budget

```
2 × 8176 MiB of VRAM            = 16.35 GB
minus driver/display reserve    ≈  0.2 GB
usable                          ≈ 16.1 GB
```

Measured overhead (model-independent, at 64 k context, f16 KV): **≈ 0.86 GB** for
compute buffers, the KV cache of a 40-layer MoE with mostly linear attention, and
the Vulkan runtime.

So: **model file must be ≤ ~15.0 GB** for a 64 k context, less for larger.

## Quant sizes for a 19B MoE

| quant | file | fits at 64 k? | measured VRAM |
|---|---|---|---|
| IQ3_M | 10.67 GB | yes, huge margin | — |
| IQ4_XS | 10.94 GB | yes | 5.97 / 5.80 GB |
| Q4_K_M | 12.48 GB | yes | 6.77 / 6.50 GB |
| Q4_K_L | 13.35 GB | yes | — |
| Q5_K_S | 13.76 GB | **yes, ~0.8 GB margin/card** | 7.39 / 7.09 GB |
| Q5_K_M | 14.72 GB | marginal — spills | — |
| Q6_K | 16.79 GB | no | — |
| Q8_0 | 20.23 GB | no | — |

Speed is nearly independent of the quant (see [benchmarks.md](benchmarks.md)): a
4 % spread between IQ4_XS and Q5_K_S. **Take the highest quant that fits**; you are
buying quality at ~4 % of throughput.

## Context cost is model-dependent

For a **classic dense transformer**, KV per token is:

```
bytes/token = 2 (K and V) × n_layer × n_kv_heads × head_dim × bytes_per_element
```

For a 40-layer model with GQA 8 KV heads × 128 head_dim at f16:

```
2 × 40 × 8 × 128 × 2 = 163 840 bytes/token = 160 KiB/token
→ 64 k context = 10.5 GB     ← does not fit, period
```

For **this** model, 30 of 40 layers use linear attention with constant-size state.
Only 10 layers allocate a growing KV cache:

```
2 × 10 × 8 × 128 × 2 = 40 960 bytes/token = 40 KiB/token
→ 64 k  ≈ 2.6 GB
→ 128 k ≈ 5.2 GB
→ 226 k ≈ 9.2 GB          ← would not fit alone
```

Measured reality differs (much smaller) because the linear-attention layers keep a
fixed recurrent state, and llama.cpp's KV allocation for the 10 full-attention
layers is what we actually observe:

| context | measured delta vs 64 k |
|---|---|
| 64 k → 128 k | **+0.6 GB** |
| 64 k → 226 k | +~3.2 GB (and GTT spill) |

**Lesson:** do not compute context size from first principles on a hybrid-attention
model. Measure it: launch, read `mem_info_vram_used`, done.

## The GTT spill threshold

When the model does not fit, the Vulkan backend spills to **GTT** (host memory over
PCIe). It still runs, much slower, and `mem_info_gtt_used` shows it:

```bash
for d in /sys/class/drm/card[1-9]/device; do
  echo "vram=$(( $(cat $d/mem_info_vram_used)/1048576 ))M \
gtt=$(( $(cat $d/mem_info_gtt_used)/1048576 ))M"
done
```

Observed at `-c 262144` with IQ4_XS: 7.56 GB VRAM **+ 1.2 GB GTT** per card, with
llama.cpp warning `failed to fit params to free device memory`. Below ~400 MB of
GTT you are effectively fine; past 1 GB, throughput drops measurably.

Keep **0.7–1.0 GB of free VRAM per card**. Under that, a long prompt allocation can
fail mid-request.

## Recommended operating points

| goal | quant | context | result |
|---|---|---|---|
| max quality, orchestration | Q5_K_S | 64 k | 42 tok/s, 0.8 GB margin |
| max context | IQ4_XS | 226 k | 16.6 tok/s, 1.1 GB GTT |
| balance | Q4_K_M | 128 k | ~44 tok/s, comfortable |
| fastest | IQ4_XS | 64 k | 43 tok/s, 4 GB spare |

## Per-card symmetry

`-sm layer` splits by layer index, not by size, so the two cards do **not** hold
identical amounts. A 2 GB asymmetry is normal and harmless:

```
7.39 GB  /  7.09 GB      ← Q5_K_S at 64 k
```

What matters is that **neither** card overflows. Size your quant against the
*larger* of the two, not the average.

## Note on `-tensor-split`

`-ts 1.15,1.0` gives GPU0 53.5 % of the work. On Vulkan with `-sm layer` this only
redistributes layer counts, which barely helps — unlike CUDA where tensor-split
balances actual tensor partitioning. Do not expect the same gains.