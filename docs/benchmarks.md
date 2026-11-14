# Raw measurements

Every number here was produced on the node described in the README. Nothing is
estimated.

## Methodology

- Server-side timing: `timings.predicted_per_second` and `prompt_per_second` from
  the llama.cpp `/v1/chat/completions` response.
- Generation benchmarks: 900–1 200 tokens, to get past warm-up effects. 64-token
  runs read ~5 % high and are not used for conclusions.
- Clock state verified before each run: `pp_dpm_sclk` / `pp_dpm_mclk` must show the
  same active index throughout. Thermal throttle would silently corrupt results.
- Temperatures during these runs: 68–72 °C edge, 75–77 °C hotspot.

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

## Power configurations

Groot-19B-A3B IQ4_XS, 16 k prompt, 64 k context:

| config | prefill | generation | shutdowns |
|---|---|---|---|
| auto DPM, 80 W cap | 491 tok/s | 22.8 tok/s | yes |
| auto DPM, cap removed | — | — | yes, immediately |
| **pinned 1000/800, 100 W cap** | **611 tok/s** | **38.1 tok/s** | no |
| pinned, sustained stress | 611 tok/s | 38.1 tok/s | **no, 8/8 runs** |

Stress test: 8 consecutive iterations of a 16 k-token prompt. Peak draw measured
across both cards: **204 W**. Clock indices never moved. Wall-clock total run time
stable at ±0.9 %.

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

## Effective bandwidth check

3 B active parameters at 5.6 bits ≈ 2.1 GB read per token. At 42.3 tok/s:
**88 GB/s effective**, against 819 GB/s of combined HBM2 peak. Batch-1 decoding
using ~11 % of peak bandwidth is normal — and explains why halving the core clock
costs so little.