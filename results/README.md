# Raw results

Verbatim output of the tools, unedited. Every table in the README and in
[../docs/benchmarks.md](../docs/benchmarks.md) comes from these files — included so
anyone can check the arithmetic instead of trusting a summary.

Captured **2026-11-15, 01:09 → 01:53**, on the node described in the README.

## Environment at capture time

| | |
|---|---|
| Kernel | `7.0.0-43-generic` |
| CPU | Intel Xeon E5-2683 v4 @ 2.10 GHz, 32 threads |
| GPUs | 2 × Radeon RX Vega 56 (gfx900), 8 GB HBM2, `RADV VEGA10`, Mesa 25.2.8 |
| Clocks | SCLK 1000 MHz pinned, MCLK 800 MHz pinned (stock), cap 100 W/card |
| llama.cpp | build 12383, commit `c56be864f`, `-DGGML_VULKAN=ON` |
| Model | `GrootTeam_Groot-19B-A3B-261023-Q5_K_S.gguf` (13.76 GB) |
| Flags | `-ngl 99 -sm layer`, KV f16 |

## Files

### `lbench-q5.md`

```bash
llama-bench -m Groot-Q5_K_S.gguf -ngl 99 -sm layer \
  -p 512 -n 128 -d 0,4096,16384,65536 -r 3 -o md
```

Eight rows: `pp512` and `tg128` at four context depths, 3 repetitions each, with
standard deviations. Source of the depth table.

### `lbench-pp-q5.md`

```bash
llama-bench -m Groot-Q5_K_S.gguf -ngl 99 -sm layer -p 128,512,2048,8192 -n 0 -r 3
```

Prefill throughput as a function of prompt size. The peak at 2048 tokens is here.

### `ppl-q5.txt`

```bash
llama-perplexity -m Groot-Q5_K_S.gguf -ngl 99 -sm layer \
  -f wikitext-2-raw/wiki.test.raw -c 512 --chunks 120
```

```
Final estimate: PPL = 13.2016 +/- 0.21789
```

### `hellaswag-q5-full.txt`

```bash
llama-perplexity -m Groot-Q5_K_S.gguf -ngl 99 -sm layer \
  -f hellaswag_val_full.txt --hellaswag --hellaswag-tasks 400
```

The full 400-line running table. **The score is the last line**, not a summary line —
which is a good reason to keep the file rather than a grep:

```
400   64.00000000%   [59.1834%, 68.5502%]
```

### `winogrande-q5.txt`

```bash
llama-perplexity -m Groot-Q5_K_S.gguf -ngl 99 -sm layer \
  -f winogrande-debiased-eval.csv --winogrande
```

```
Final Winogrande score (1267 tasks): 67.0087 +/- 1.3214
```

### `batched-q5.txt`

```bash
llama-batched-bench -m Groot-Q5_K_S.gguf -ngl 99 -sm layer \
  -c 65536 -b 2048 -ub 512 -npp 512,2048 -ntg 128 -npl 1,2,4
```

Six rows: batch 1, 2 and 4 at two prompt sizes. This is where the +73 % aggregate
throughput figure comes from.

Three independent runs of this command gave 45.00 / 45.20 / 45.21 (B=1),
64.96 / 65.01 / 64.97 (B=2) and 78.08 / 78.13 / 78.16 tok/s (B=4). Only the third run
is stored here; the spread is under 0.5 %.

## What is not here

- **Q4_K_M and IQ4_XS** were measured for speed and one perplexity pass, then dropped
  from the campaign: at 64 k the speed difference is under 4 % and the quant choice
  came down to VRAM budget, not performance. Their partial logs stay on the node.
- **Server-side numbers** (quantization comparison, MTP, `presence_penalty`, context
  scaling to 226 k) were produced with a Python HTTP harness rather than these tools,
  so they are documented in [../docs/benchmarks.md](../docs/benchmarks.md) with the
  harness shown inline instead of raw logs.
- **Power measurements** came from `hwmon` sampling during the stress test, not from
  a wall meter. GPU-side only.
