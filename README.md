# Two 2017 Vega 56 cards as a 16 GB LLM inference node

**English** · [Français](README.fr.md) · [中文](README.zh.md)

**42 tok/s · 64 k context · 226 k verified · 200 W**

---

## The premise

This is a working LLM inference node built entirely from hardware nobody would
choose for the job, and every number below was measured on it.

- Two **AMD Radeon RX Vega 56** — 2017, GCN5 (`gfx900`), 8 GB HBM2 each
- An **HP Z440** workstation
- **62 GB of DDR4** salvaged from a skip
- A **Xeon E5-2683 v4** (16c/32t, 2016)

It serves a 19B-parameter MoE model (3B active) at **42 tok/s**, holds a **64 k
context** with headroom, and was verified at **226 205 tokens** without
truncation — while never exceeding a **100 W per-card cap** on a PSU whose GPU
rail is limited to 225 W.

| | |
|---|---|
| Model | Groot-19B-A3B — 19.3 B total, 3 B active, 40 layers (10 full-attention, 30 linear-attention), 128 routed experts + 1 shared (8 active), hidden 2048, native context 262 144 |
| Quantization | `Q5_K_S`, 13.76 GB |
| Generation | **42.3 tok/s** (temp 0.7, 1 200-token outputs) |
| Prefill | **593 tok/s** at 18.8 k prompt tokens |
| Context | 65 536 comfortable · 226 205 verified |
| VRAM | 7.39 / 7.09 GB out of 8.0 per card |
| Power | 2 × 100 W cap; 204 W peak measured under sustained load |
| Backend | llama.cpp `b12383`, Vulkan |
| OS | Ubuntu 24.04.5 LTS |

---

## Why this works at all

Two properties of the workload make old hardware viable, and both are routinely
misunderstood.

### 1. Decode is bandwidth-bound, not compute-bound

At batch size 1, an LLM reads its active weights once per token and performs
comparatively little arithmetic per byte. Throughput tracks **memory bandwidth**,
not core frequency. A Vega 56 still has **409 GB/s of HBM2** — respectable even
today, and better than many current consumer cards.

That is the whole trick behind the power cap. We run:

```
SCLK  1000 MHz  (stock boost ≈ 1470–1590 MHz)   →  −32 %
MCLK   800 MHz  (stock, untouched)
```

and lose only **~20 % throughput** while cutting power by roughly **40 %**.
Cutting MCLK instead would have been catastrophic — HBM frequency is almost
linearly tied to decode speed.

Sanity check on the numbers: 3 B active parameters at ~5.6 bits/weight is ~2.1 GB
streamed per token. At 42 tok/s that is **88 GB/s effective** out of 819 GB/s of
combined peak. Using 11 % of peak bandwidth is perfectly normal for batch-1
decoding — and it is exactly why clocking the core down is cheap.

### 2. Linear attention changes the memory budget

30 of the 40 layers use linear attention, so the KV cache grows far slower than a
classic transformer's. Going from 64 k to 128 k context added only **~0.6 GB**.
A dense 19B would not fit 226 k anywhere near 16 GB.

---

## The problem: the machine kept switching itself off

In stock configuration the node would **hard power off** under load — no kernel
panic, no OOM, no thermal event, nothing in `journalctl`. Just a dead box
mid-generation, always within seconds of a heavy prefill starting.

The HP Z440 has a 700 W PSU, which is plenty for a 120 W Xeon plus two cards.
But its **GPU rail tops out at 225 W** through two 6-pin connectors.

### Root cause: DPM transients, not average power

AMD's Dynamic Power Management ramps core frequency and voltage in steps when load
arrives. Each ramp is a step change in current, and the supply's over-current
protection reacts to the **edge**, not the steady-state value.

Three observations prove it is a transient problem, not a total-power problem:

1. Shutdowns happened **at the onset** of load, not after minutes of steady draw.
2. An **80 W cap in auto DPM still shut down** — the cap limits the average, DPM
   still produces the edges.
3. **Pinning the clocks eliminated it**, at a *higher* average power than the
   failing 80 W configuration (204 W peak, 8/8 stress runs, zero shutdowns).

It was never about how much power we drew, but how fast we asked for it.

### The fix

Two kernel parameters and one systemd unit.

```
amdgpu.ppfeaturemask=0xffffffff   # enable the overdrive interface
amdgpu.bapm=0                     # disable Vega's TDP-bursting behaviour
```

`ppfeaturemask` must include the overdrive bit or `pp_od_clk_voltage` stays empty
and you cannot touch voltages at all — the common default `0xfff7bfff` has that
bit cleared. `bapm` is Vega-specific and lets the card exceed its nominal TDP in
bursts; a documented but rarely mentioned source of excursions.

The pinning script's **ordering is not cosmetic**:

1. Power cap first — committing an overdrive point can reset it.
2. Overdrive point: `s <index> <MHz> <mV>`, then `c` to commit.
3. `manual` **before** writing a DPM index, or the governor overwrites it on the
   next tick.
4. Re-assert the cap after the OD commit.

See [`scripts/gpu-setup-pin.sh`](scripts/gpu-setup-pin.sh) and
[`docs/power-and-clocks.md`](docs/power-and-clocks.md).

| configuration | prefill | generation | shutdowns |
|---|---|---|---|
| auto DPM, 80 W cap | 491 tok/s | 22.8 tok/s | yes |
| **pinned, 100 W cap** | **611 tok/s** | **38.1 tok/s** | **no (8/8)** |

The pinned configuration is simultaneously faster *and* stable. Auto DPM does not
use the headroom better — it thrashes between states, and every transition is a
risk.

---

## Software stack

ROCm dropped `gfx900` long ago. **Vulkan is the pragmatic backend for GCN5** and
works with the stock `mesa-vulkan-drivers` from Ubuntu.

```bash
cmake -B build -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc) --target llama-server llama-cli
```

15–30 minutes on this Xeon — worth knowing before you decide to patch anything.

The serving line that actually works here:

```bash
./llama-server \
  -m Groot-Q5_K_S.gguf \
  -c 65536 -np 1 \
  -ngl 99 -dev Vulkan0,Vulkan1 \
  -sm layer -fa on \
  --reasoning off --chat-template-kwargs '{"enable_thinking":false}' \
  --temp 0.7 --top-p 0.80 --top-k 20 --min-p 0.0 \
  --presence-penalty 0.0 --repeat-penalty 1.0 \
  --host 0.0.0.0 --port 8080 --jinja --alias groot-19b-a3b
```

| flag | why it matters |
|---|---|
| `-sm layer` | **mandatory.** `row` requires `ggml_backend_split_buffer_type`, which `ggml-vulkan` does not implement → *"device Vulkan0 does not support split buffers"*. `tensor` works but gains nothing. |
| `-np 1` | default is 4 slots; for single-user serving they only fragment the KV budget. |
| `-fa on` | Flash Attention silently disables itself when KV is quantized. |
| no `-ctk/-ctv` | KV stays f16. Quantized KV gains almost nothing on this model and turns FA off. |
| `--reasoning off` | the biggest latency win available — see below. |
| `--presence-penalty 0.0` | the model card says 1.5. It costs **19 %** here. |

---

## Measurements

All figures below come from this node. Methodology: llama.cpp server timings
(`predicted_per_second`), 900–1200 token generations, `-np 1`, KV f16 unless
stated.

### Standard tooling: llama-bench, perplexity, HellaSwag, Winogrande

Reproducible figures in the format the community publishes. Full tables and the exact
commands are in [docs/benchmarks.md](docs/benchmarks.md).

| llama-bench, Q5_K_S | t/s |
|---|---|
| pp512 | 496.72 ± 4.28 |
| tg128 | 44.70 ± 0.34 |
| pp512 @ d16384 | 314.22 ± 1.97 |
| pp512 @ d65536 | 144.01 ± 0.65 |
| tg128 @ d65536 | 28.29 ± 0.03 |

| quality | score |
|---|---|
| Perplexity, wikitext-2, 120 × 512 tokens | **13.2016 ± 0.2179** |
| Winogrande, 1267 tasks | **67.01 % ± 1.32** |
| HellaSwag, 400 of 10 042 tasks | **64.00 %** [59.18 – 68.55] |

HellaSwag and Winogrande come from llama.cpp's built-in scorer, which uses its own
prompt format. They are valid for comparing two quants on identical ground and are
**not** comparable to `lm-evaluation-harness` leaderboard numbers.

### Concurrency is the real throughput lever

`llama-batched-bench`, same model and settings:

| concurrent sequences | aggregate generation | per sequence |
|---|---|---|
| 1 | **45.0 tok/s** | 45.0 |
| 2 | 65.0 tok/s | 32.5 |
| 4 | **78.1 tok/s** | 19.5 |

**+73 % aggregate throughput** going from one to four sequences (two independent
runs: 45.00/45.20, 64.96/65.01, 78.08/78.13 tok/s — under 0.5 % spread). With layer split on
two cards, a single sequence is processed sequentially — GPU0 does its half of the
layers, then GPU1 does its half — so at batch 1 the second card idles about half the
time. Batching fills it.

Practical consequence: 45 tok/s is this node's *latency* figure, ~78 tok/s is its
*throughput* figure. Driving several agents in parallel nearly doubles the tokens per
second at the cost of longer individual answers.

### Quantization: the speed difference is negligible

At 64 k context, `presence_penalty=0`, identical flags:

| quant | file | VRAM per card | generation | prefill |
|---|---|---|---|---|
| IQ4_XS | 10.94 GB | 5.97 / 5.80 GB | 43.0 tok/s | 599 tok/s |
| Q4_K_M | 12.48 GB | 6.77 / 6.50 GB | **44.1 tok/s** | 604 tok/s |
| **Q5_K_S** | 13.76 GB | 7.39 / 7.09 GB | 42.3 tok/s | 593 tok/s |

A **4 % spread across 2.8 GB of model size**, and prefill is indistinguishable.
Quality on a 10-question orchestrator benchmark (arithmetic, JSON emission,
instruction-following, shell knowledge, logic) was equally undifferentiated:
8/10, 8/10 and 7/10 for IQ4_XS, Q4_K_M and Q5_K_S — with the single difference
being the answer language on one logic question, not correctness.

**Conclusion:** buy quality with the spare VRAM, it is essentially free. Q5_K_M
(14.72 GB) and above would spill past the 16.3 GB of usable VRAM.

### Context: generation degrades gently, prefill falls off a cliff

IQ4_XS, KV `q8_0`, 100 W cap:

| context | generation | prefill | time to prefill the full window |
|---|---|---|---|
| 16 k | 37.2 tok/s | 619 tok/s | 30 s |
| 64 k | ~30 tok/s | 613 tok/s | 1 min 47 s |
| 113 k | 24.2 tok/s | 179 tok/s (marginal) | ~10 min |
| 226 k | 16.6 tok/s | 168 tok/s | **22 min** |
| 262 k | loads, but spills 1.2 GB to GTT | — | — |

A 14× context increase costs only 2.2× generation speed. The real cost of long
context is **prefill** — 22 minutes to ingest a 226 k-token prompt.

`-c 262144` loads (7.56 GB VRAM + 1.2 GB GTT) but llama.cpp warns
`failed to fit params to free device memory` and wants to shed layers; `-ngl 99`
prevents that, so you are simply over budget. **131 072 is the comfortable ceiling.**

The 226 k test is real: `n_tokens = 226236, truncated = 0`, prompt eval 1 347 s,
eval 16.6 tok/s.

### KV quantization: not worth it on this model

| KV | context | prefill | generation |
|---|---|---|---|
| f16 | 32 k | 611 tok/s | 38.1 tok/s |
| `q8_0` | 64 k | 613 tok/s | 37.6 tok/s |
| `q5_1` | 64 k | **520 tok/s** | 34.9 tok/s |

`q8_0` saves ~100 MB and costs nothing — but at 64 k there is no need. `q5_1`
saves the same ~100 MB and **costs 15 % of prefill**, because dequantizing q5_1
inside attention is more expensive than q8_0's layout. With f16 KV, Flash
Attention stays enabled; with quantized KV it is disabled with
`Flash Attention over K/V rows not supported`.

### MTP / NextN: present, functional, and a net loss

The GGUF carries a 0.4 B MTP layer — `blk.40` holds a full attention block, a MoE
FFN, and `nextn.eh_proj / enorm / hnorm / shared_head_norm` — plus
`qwen35moe.nextn_predict_layers = 1`.

The `unused tensor blk.40.nextn.* -- ignoring` warnings at load are **normal**: the
block is only allocated when the context is created as `LLAMA_CONTEXT_TYPE_MTP`,
which happens with `--spec-type draft-mtp`. No code changes are needed; the
support is in `src/models/qwen35moe.cpp`.

It runs. It just is not worth it:

| `--spec-draft-n-max` | acceptance | generation | prefill |
|---|---|---|---|
| off | — | 37.3 tok/s | **621 tok/s** |
| 1 | 84.1 % | **39.5 tok/s (+5.8 %)** | 511 tok/s (−18 %) |
| 2 | 65.2 % | 36.4 tok/s | 509 tok/s |
| 3 | 49.0 % | 28.7 tok/s (−23 %) | 506 tok/s |

Real-world confirmation at `n_max=3` with temperature 0.7: acceptance fell to
**28.8 %** and throughput to 27.9 tok/s — a **35 % loss** against the 42.9 tok/s
baseline for the same request shape.

Why: a draft forward costs roughly **74 % of a full 40-layer forward**. With
`-sm layer`, the MTP block lives on a single card while the other idles — and each
draft token still goes through the shared output head (2048 × 151 k vocabulary
projection).

Only `n_max=1` is positive, and only for generation. For long-context work the
18 % prefill penalty costs far more than 5.8 % of generation earns.

### `presence_penalty`: 19 % of throughput for something you do not need

The model card recommends `temperature=0.7, top_p=0.80, top_k=20, min_p=0.0,
presence_penalty=1.5, repetition_penalty=1.0`. The presence penalty alone costs:

| presence_penalty | generation | ms/token |
|---|---|---|
| 0.0 | **43.0 tok/s** | 23.26 |
| 0.0 (repeat) | 43.05 tok/s | 23.23 |
| **1.5** | **34.8 tok/s** | 28.61 |
| 1.5 (repeat) | 34.71 tok/s | 28.81 |

Reproducible, four runs, ±0.5 %. Cause, from `src/llama-sampler.cpp`:

```cpp
for (size_t i = 0; i < cur_p->size; ++i) {                    // whole vocabulary
    const auto it = ctx->token_count.find(cur_p->data[i].id); // hash per token
    ...
    logit -= count * freq + (count > 0) * presence;
}
cur_p->sorted = false;                                        // full re-sort
```

It walks all 151 k candidates per token, hash-looking-up each one, then invalidates
the sort order so the next token re-sorts 151 k entries. `repeat_penalty` and
`frequency_penalty` share the same sampler, so the cost is all-or-nothing: either
all three are neutral (the sampler self-disables) or you pay the full sweep.

**And it does not prevent loops here.** 1 200-token generations, temp 0.7, two
tasks (exhaustive enumeration, technical prose):

| task | pp | words | duplicated 8-grams | longest identical run | lexical diversity |
|---|---|---|---|---|---|
| enumeration | 0.0 | 705 | **0** | 2 | 0.454 |
| enumeration | 1.5 | 594 | **0** | 1 | 0.564 |
| prose | 0.0 | 521 | **0** | 1 | 0.564 |
| prose | 1.5 | 525 | **0** | 1 | 0.560 |

Zero loops either way. Presence penalty does what it advertises — it raises lexical
diversity (0.454 → 0.564), which is its real purpose, not loop prevention. For an
orchestrator emitting JSON and short status lines, it penalizes exactly the tokens
that *must* repeat (`{`, `"ok"`, `"node"`). Use `--dry-multiplier` if you ever
need loop protection: it blocks repeated n-grams instead of the whole vocabulary.

### Instruct mode: the biggest latency win

```bash
--reasoning off --chat-template-kwargs '{"enable_thinking":false}'
```

Verified: `17 × 23` returns `391` in **4 tokens**, `reasoning_content` absent, no
` thinking` tag. On a model with a reasoning mode this is worth more in perceived
latency than any tok/s number — hundreds of hidden tokens disappear from every
response.

---

## Why 64 k, and not 226 k

The model supports 262 144 tokens natively (~1 M with YaRN) and this node proved it
can ingest **226 205 tokens without truncation**. We still run 64 k. That is a
deliberate engineering choice, not a hardware ceiling — and it is the single most
useful decision in this build.

**1. The workload does not need more.** This node serves an orchestrator: short and
repetitive tasks, node health checks, follow-ups, small tool calls with structured
output. It is never asked to absorb a codebase. 64 k covers the working set with a
large margin.

**2. Context is paid twice — in VRAM and in prefill time.** Generation degrades
gently with depth, but prefill collapses:

| context | generation | prefill | time to fill the window |
|---|---|---|---|
| 16 k | 37.2 tok/s | 619 tok/s | 30 s |
| 64 k | ~30 tok/s | 613 tok/s | 1 min 47 s |
| 113 k | 24.2 tok/s | 179 tok/s | ~10 min |
| 226 k | 16.6 tok/s | 168 tok/s | **22 min** |

An orchestrator that answers in seconds cannot afford 22 minutes of prompt
ingestion. The generation penalty is mild; the prefill penalty is what actually
kills the use case.

**3. Context competes directly with quantization.** Every token of KV cache is VRAM
taken away from weights. At 64 k we run **Q5_K_S (13.76 GB)** with 0.8 GB of margin
per card. At 226 k the same model needs GTT spill and would force a drop to
IQ4_XS (10.94 GB). Measurements say the quantization costs **~4 % of throughput**,
while the extra context costs **71 % of prefill** — so the trade is heavily in
favour of quality at 64 k.

**4. With two cards in layer split, context buys nothing back.** At batch 1 only one
GPU works at a time (see the measurements above), so extra context never becomes
extra parallelism. It is pure cost.

**What would justify going further:** a retrieval workload where a single prompt
genuinely contains hundreds of thousands of tokens (whole-repository analysis,
long-document summarisation, log forensics). In that case the node still works —
226 k at 16.6 tok/s is usable — but you accept minutes of prefill and you give up
the higher quantization. For orchestration, 64 k is the right point on the curve.

## Final configuration

```bash
./llama-server \
  -m Groot-Q5_K_S.gguf -c 65536 -np 1 \
  -ngl 99 -dev Vulkan0,Vulkan1 -sm layer -fa on \
  --reasoning off --chat-template-kwargs '{"enable_thinking":false}' \
  --temp 0.7 --top-p 0.80 --top-k 20 --min-p 0.0 \
  --presence-penalty 0.0 --repeat-penalty 1.0 \
  --host 0.0.0.0 --port 8080 --jinja --alias groot-19b-a3b
```

Resulting node:

| | |
|---|---|
| Generation | 42.3 tok/s |
| Prefill | 593 tok/s |
| VRAM | 7.39 / 7.09 GB — ~0.8 GB margin per card |
| GTT spill | negligible (~400 MB) |
| Power | 2 × 100 W cap, pinned 1000/800 MHz |

---

## Reproduce

1. **Pin the clocks first.** Do not run sustained inference on a 225 W GPU rail
   before you do — [docs/power-and-clocks.md](docs/power-and-clocks.md).
2. **Build llama.cpp with Vulkan** — [docs/software-stack.md](docs/software-stack.md).
3. **Size your quant and context** — [docs/memory-budget.md](docs/memory-budget.md).
4. **Raw measurement tables** — [docs/benchmarks.md](docs/benchmarks.md).
5. **Verbatim tool output** (llama-bench, perplexity, hellaswag, batched) — [results/](results/).

```
scripts/
  gpu-setup-pin.sh      apply cap + overdrive + pinned clocks (idempotent)
  gpu-tuning.service    systemd unit, runs it at boot
  stress-psu.sh         sustained-load power test
  dpm_sweep.sh          sweep caps/frequencies to find the stable envelope
  longctx_bench.sh      context-length sweep
  gpu-pinclk.sh         interactive pin/unpin helper
  gpu-undervolt.sh      earlier standalone undervolt attempt (superseded)
```

---

## Caveats

- **Batch-1, single user.** None of this applies to batched serving; a modern card
  wins on tokens/watt by a wide margin.
- The 225 W rail limit is specific to the HP Z440. Other chassis differ — pin the
  clocks anyway, it also saves power.
- The model is an MoE with heavy linear attention. A dense 19B would not approach
  226 k on 16 GB.
- `gpu-tuning.service` is verified working when started manually; **boot-time
  ordering against `amdgpu` initialisation is the one unverified thing.**
- The exercise is about making old silicon useful, not about beating a modern
  card on a per-watt basis.

## License

MIT for scripts and text. Model weights belong to their authors.