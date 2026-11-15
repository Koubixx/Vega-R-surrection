# Measurements

Two families of numbers live here, and they answer different questions:

- **Tool benchmarks** (`llama-bench`, `llama-perplexity`, `llama-batched-bench`) —
  reproducible, with error bars, in the format the community publishes.
- **Server measurements** — what an HTTP client actually experiences, including the
  sampling stack.

Every number was produced on this node. Node state for all runs: 100 W per-card cap,
clocks pinned at 1000/800 MHz, Q5_K_S unless stated, `-sm layer`, KV f16,
temperatures 68–72 °C edge / 75–77 °C hotspot.

Clock state was verified before each run: `pp_dpm_sclk` / `pp_dpm_mclk` must show the
same active index throughout. Thermal throttle would silently corrupt results.

---

# Tool benchmarks

Reproduce any row with the command shown. Build `c56be864f` (b12383).

## llama-bench — depth scaling

```bash
llama-bench -m Groot-Q5_K_S.gguf -ngl 99 -sm layer \
  -p 512 -n 128 -d 0,4096,16384,65536 -r 3 -o md
```

| test | t/s |
|---|---|
| pp512 | **496.72 ± 4.28** |
| tg128 | **44.70 ± 0.34** |
| pp512 @ d4096 | 445.55 ± 0.86 |
| tg128 @ d4096 | 43.82 ± 0.28 |
| pp512 @ d16384 | 314.22 ± 1.97 |
| tg128 @ d16384 | 40.92 ± 0.09 |
| pp512 @ d65536 | **144.01 ± 0.65** |
| tg128 @ d65536 | **28.29 ± 0.03** |

The asymmetry is the headline: prefill loses **71 %** between d0 and d65k, generation
only **37 %**. Long context on this node costs far more in prompt ingestion than in
answer speed.

## llama-bench — prompt size sweep

```bash
llama-bench -m Groot-Q5_K_S.gguf -ngl 99 -sm layer -p 128,512,2048,8192 -n 0 -r 3
```

| prompt | prefill t/s |
|---|---|
| 128 | 303.60 ± 6.08 |
| 512 | 513.47 ± 3.83 |
| **2048** | **699.28 ± 1.90** |
| 8192 | 639.34 ± 3.08 |

Prefill peaks around 2 k tokens. Very short prompts underutilise the GPU (dispatch
overhead dominates), and past ~8 k the attention cost starts to win. This is the curve
to look at before tuning `-b`/`-ub`.

## llama-perplexity — objective quality

```bash
llama-perplexity -m Groot-Q5_K_S.gguf -ngl 99 -sm layer \
  -f wikitext-2-raw/wiki.test.raw -c 512 --chunks 120
```

```
Final estimate: PPL = 13.2016 +/- 0.21789
```

## Winogrande

```bash
llama-perplexity -m Groot-Q5_K_S.gguf -ngl 99 -sm layer \
  -f winogrande-debiased-eval.csv --winogrande
```

```
Final Winogrande score (1267 tasks): 67.0087 +/- 1.3214
```

## HellaSwag

```bash
llama-perplexity -m Groot-Q5_K_S.gguf -ngl 99 -sm layer \
  -f hellaswag_val_full.txt --hellaswag --hellaswag-tasks 400
```

```
400   64.00000000%   [59.1834%, 68.5502%]
```

> **Important caveat.** llama.cpp's built-in HellaSwag and Winogrande scoring uses its
> own prompt format and a log-probability comparison of the candidate continuations.
> These numbers are **not** comparable to `lm-evaluation-harness` leaderboard figures
> for the same model. They are useful for comparing two quants *on the same harness* —
> which is what we needed — and are not a claim about absolute model quality.

## llama-batched-bench — concurrency

```bash
llama-batched-bench -m Groot-Q5_K_S.gguf -ngl 99 -sm layer \
  -c 65536 -b 2048 -ub 512 -npp 512,2048 -ntg 128 -npl 1,2,4
```

| PP | TG | B | N_KV | prefill t/s | generation t/s (agg) | total t/s |
|---|---|---|---|---|---|---|
| 512 | 128 | 1 | 640 | 519.91 | **45.00** | 167.14 |
| 512 | 128 | 2 | 1280 | 522.61 | 64.96 | 216.93 |
| 512 | 128 | 4 | 2560 | 652.52 | **78.08** | 264.02 |
| 2048 | 128 | 1 | 2176 | 644.55 | 44.26 | 358.53 |
| 2048 | 128 | 2 | 4352 | 703.49 | 64.25 | 443.76 |
| 2048 | 128 | 4 | 8704 | 728.36 | **76.91** | **486.14** |

**Reproducibility:** two independent runs gave 45.00 / 45.20 (B=1), 64.96 / 65.01 (B=2)
and 78.08 / 78.13 tok/s (B=4) — a spread under 0.5 % on generation, under 2.5 % on
prefill. The +73 % is not noise.

### The most important table here

Aggregate generation throughput goes **45 → 78 tok/s (+73 %)** from batch 1 to batch 4.
Per-sequence speed drops (45 → 19.5 tok/s), which is the normal latency/throughput
trade.

The explanation is structural: with `-sm layer` on two cards, a single sequence is
processed sequentially — GPU0 does its half of the layers, then GPU1 does its half.
**At batch 1 the second GPU idles roughly half the time.** Four concurrent sequences
give both cards real work, and throughput nearly doubles with no software change.

Consequences:

- **Do not judge this node by its single-stream number.** 45 tok/s is its *latency*
  figure; ~78 tok/s is its *throughput* figure.
- An orchestrator driving several agents in parallel gets close to 2× the tokens per
  second out of the same hardware, at the cost of longer individual answers.
- Any benchmark of two-card layer-split rigs that reports batch-1 numbers only
  understates them by roughly a factor of two.

---

# Server measurements

What a real HTTP client sees, with sampling active. These differ from `llama-bench`
because every token also pays the sampler.

Minimal harness (`bench.py`):

```python
import json, urllib.request, time
req = {"model": "groot-19b-a3b",
       "messages": [{"role": "user", "content": prompt}],
       "max_tokens": 900, "temperature": 0.7, "top_p": 0.80, "top_k": 20,
       "min_p": 0.0, "presence_penalty": 0.0, "repetition_penalty": 1.0,
       "stream": False}
r = urllib.request.Request("http://127.0.0.1:8080/v1/chat/completions",
        data=json.dumps(req).encode(),
        headers={"Content-Type": "application/json"})
resp = json.load(urllib.request.urlopen(r, timeout=1800))
print(resp["timings"]["predicted_per_second"])
```

Generation benchmarks used 900–1 200 tokens to get past warm-up; 64-token runs read
~5 % high and are not used for conclusions.

## Power configurations

Groot-19B-A3B IQ4_XS, 16 k prompt, 64 k context:

| config | prefill | generation | shutdowns |
|---|---|---|---|
| auto DPM, 80 W cap | 491 tok/s | 22.8 tok/s | yes |
| auto DPM, cap removed | — | — | yes, immediately |
| **pinned 1000/800, 100 W cap** | **611 tok/s** | **38.1 tok/s** | no |
| pinned, sustained stress | 611 tok/s | 38.1 tok/s | **no, 8/8 runs** |

Stress test: 8 consecutive iterations of a 16 k-token prompt. Peak draw measured
across both cards: **204 W**. Clock indices never moved. Wall-clock stability ±0.9 %.

## Quantization

64 k context, f16 KV, `presence_penalty=0`:

| quant | file | VRAM card1/card2 | prefill | generation |
|---|---|---|---|---|
| IQ4_XS | 10.94 GB | 5.97 / 5.80 GB | 599 tok/s | 43.0 / 43.05 / 42.95 tok/s |
| Q4_K_M | 12.48 GB | 6.77 / 6.50 GB | 604 tok/s | 44.15 / 44.01 tok/s |
| Q5_K_S | 13.76 GB | 7.39 / 7.09 GB | 593 tok/s | 42.31 / 42.32 tok/s |

Quality screen — 10 questions: arithmetic word problems, exact JSON emission,
one-word instruction following, shell knowledge, syllogism, ordering:

| quant | score | notes |
|---|---|---|
| IQ4_XS | 8/10 | answered one logic question in English, used `pgrep` |
| Q4_K_M | 8/10 | answered the same question in French |
| Q5_K_S | 7/10 | same, plus `ps aux \| grep` instead of `pidof` |

Grading was strict string matching, so two "failures" were answer-language or
alternative-but-valid-command artefacts. On substance all three are equivalent.
**A 19B MoE at 4–5.6 bits loses nothing measurable on this class of task.**

## KV cache quantization

| KV type | context | prefill | generation |
|---|---|---|---|
| f16 | 32 k | 611 tok/s | 38.1 tok/s |
| `q8_0` | 64 k | 613 tok/s | 37.6 tok/s |
| `q5_1` | 64 k | **520 tok/s** | 34.9 tok/s |

`q8_0` saves ~100 MB and costs nothing measurable. `q5_1` saves the same ~100 MB
and costs 15 % of prefill — q5_1 dequantization inside attention is more expensive
than q8_0's block layout.

Flash Attention interaction:

```
with f16 KV    → FA = enabled
with q8_0/q5_1 → "Flash Attention over K/V rows not supported, set to disabled"
```

No usability impact on this model (only 10 layers have a real KV cache), but it
removes the prefill acceleration you may be counting on.

## Context scaling

IQ4_XS, KV `q8_0`, 100 W, pinned clocks:

| context | prompt tokens | prefill | generation | time |
|---|---|---|---|---|
| 16 k | 18 856 | 619 tok/s | 37.2 tok/s | 30 s |
| 48 k | ~56 000 | 441 tok/s | 20.2 tok/s | 137 s |
| 64 k | 18 858 | 613 tok/s | ~30 tok/s | — |
| 113 k | 113 138 total | 179 tok/s marginal | 24.2 tok/s | ~10 min |
| 226 k | 226 205 | 168 tok/s | 16.6 tok/s | **1 347 s** |
| 262 k | — | — | — | loads, 1.2 GB GTT spill |

The 226 k run, verbatim from the server log:

```
slot print_timing: prompt eval time = 1346679.11 ms / 226205 tokens (5.95 ms/token)
slot print_timing:        eval time =    1868.56 ms /    32 tokens (60.28 ms/token)
slot release: stop processing: n_tokens = 226236, truncated = 0
```

`truncated = 0` is the point: the full prompt was ingested, nothing was silently cut.

## MTP / NextN

`--spec-type draft-mtp`, 64 k context, 18.8 k prompt, temperature 0:

| n_max | draft_n | accepted | acceptance | generation | prefill |
|---|---|---|---|---|---|
| off | — | — | — | 37.24 / 37.38 tok/s | 621 tok/s |
| 1 | 138 | 116 | **84.1 %** | **39.46 tok/s** | 511 tok/s |
| 2 | 221 | 144 | 65.2 % | 36.35 tok/s | 509 tok/s |
| 3 | 308 | 151 | 49.0 % | 28.70 tok/s | 506 tok/s |

Real-world request at `n_max=3`, temperature 0.7:

```
draft acceptance = 0.28785 (424 accepted / 1473 generated), mean len = 1.3
eval time = 32873.99 ms / 916 tokens (35.93 ms/token)   → 27.9 tok/s
```

Against 42.9 tok/s for the same request shape without MTP: **−35 %**.

Derivation of the draft cost. Without MTP: 256 steps × 1 forward = 256 forwards.
With MTP at `n_max=3`, mean accept length 2.47: 104 verifies + 308 drafts for 256
tokens. Solving 256 / (104 + 308·f) = 0.77 gives **f ≈ 0.74** — a draft forward
costs 74 % of a full 40-layer forward. That is the whole story: the draft is not
cheap on this backend.

## presence_penalty

| presence_penalty | generation | ms/token |
|---|---|---|
| 0.0 | 43.00 | 23.26 |
| 0.0 | 43.05 | 23.23 |
| 0.0 (top_p 0.80) | 42.95 | 23.28 |
| 1.5 | 34.96 | 28.61 |
| 1.5 | 34.71 | 28.81 |

Repeat/loop screen, 1 200 max tokens, temp 0.7, two prompts:

| prompt | pp | words | duplicate 8-grams | max identical run | diversity |
|---|---|---|---|---|---|
| exhaustive enumeration | 0.0 | 705 | 0 | 2 | 0.454 |
| exhaustive enumeration | 1.5 | 594 | 0 | 1 | 0.564 |
| technical prose | 0.0 | 521 | 0 | 1 | 0.564 |
| technical prose | 1.5 | 525 | 0 | 1 | 0.560 |

---

# What the numbers say about the ceiling

Effective bandwidth and FLOP utilisation, derived from the llama-bench figures
(3 B active parameters at 5.79 bits/weight → 2.17 GB read per token):

| metric | value | % of peak |
|---|---|---|
| tg128 @ d0 | 97.1 GB/s | **23.7 %** of one card's 409.6 GB/s |
| tg128 @ d65536 | 61.4 GB/s | 15.0 % |
| prefill @ d0 | 2.98 TFLOP/s | **41.6 %** of 14.3 TFLOP/s FP16 |

Two honest notes:

1. **The percentage is against one card, not two.** With layer split only one GPU is
   active at any instant, so 819 GB/s of aggregate bandwidth is never available to a
   single sequence. Against the cumulated peak we sit at 11.8 %, but that figure is
   misleading — see the batching table for why.
2. **The remaining headroom is modest, not dramatic.** gfx900 has no DP4A:
   `VK_KHR_shader_integer_dot_product` is exposed but
   `integerDotProduct4x8BitPackedSignedAccelerated = false`, so quantized weights go
   through dequantise+FMA. Realistic software gains are ~1.5–2.5×, not 4×.

The largest available win is not a kernel at all: **use the batch.** +73 % aggregate
throughput is sitting there for free.
