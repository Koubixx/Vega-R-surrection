# Software stack: llama.cpp on Vulkan with two GCN cards

## Why Vulkan and not ROCm

ROCm dropped `gfx900` support. The community `rocm` forks that still carry it are
painful to maintain and give no advantage for single-user inference. **Vulkan is
the pragmatic backend for GCN5** and it works with the stock `mesa-vulkan-drivers`
/ `radeon_icd.json` from Ubuntu.

Notes that cost time:

- `VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/radeon_icd.json` — set it explicitly
  in the service or a container runtime, otherwise device enumeration can pick the
  wrong ICD (or none).
- Both cards must be listed: `-dev Vulkan0,Vulkan1`.
- `vulkaninfo | grep deviceName` is your sanity check before blaming llama.cpp.

## Build

```bash
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
cmake -B build -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc) --target llama-server llama-cli
```

On a Xeon E5-2683 v4 the build takes 15-30 minutes. This is the fixed cost of
every iteration — worth knowing before you start patching anything.

## Flags that matter

```bash
./llama-server \
  -m model.Q5_K_S.gguf \
  -c 65536 -np 1 \
  -ngl 99 -dev Vulkan0,Vulkan1 \
  -sm layer -fa on \
  --reasoning off --chat-template-kwargs '{"enable_thinking":false}' \
  --temp 0.7 --top-p 0.80 --top-k 20 --min-p 0.0 \
  --presence-penalty 0.0 --repeat-penalty 1.0 \
  --host 0.0.0.0 --port 8080 --jinja --alias my-model
```

| flag | why |
|---|---|
| `-sm layer` | **mandatory**. `row` needs `ggml_backend_split_buffer_type`, not implemented in `ggml-vulkan` → *"device Vulkan0 does not support split buffers"*. `tensor` works but offers nothing over `layer` here. |
| `-np 1` | default is 4 slots. For a single-user orchestrator, extra slots only fragment the KV budget. |
| `-fa on` | Flash Attention. Note it silently disables itself when KV is quantized (`Flash Attention over K/V rows not supported, set to disabled`). With f16 KV it stays active. |
| no `-ctk`/`-ctv` | leave KV at f16 unless VRAM forces q8_0. Quantized KV gains almost nothing here (see benchmarks) and turns FA off. |
| `--reasoning off` | disables the thinking phase. On a model with a reasoning mode this is the single biggest latency win — answers go from hundreds of tokens to a handful. |
| `--presence-penalty 0.0` | **do not** use the model card's 1.5. It costs 19 % of generation speed. See benchmarks. |

### Layer split and the pipeline bubble

`-sm layer` puts layer N on GPU N mod 2. With 2 GPUs each token pays one
hand-off. This is also why speculative decoding performs badly here: the draft
forward runs on a single card while the other idles, so a one-layer draft costs
~74 % of a full 40-layer forward.

### Sampling defaults on the server

`--temp`, `--top-p`, `--top-k`, `--min-p`, `--presence-penalty`, `--repeat-penalty`
set the **server-side defaults**. Clients that send their own `temperature` override
them — worth remembering when a UI "feels different" from a curl test.

## Model-specific: thinking toggle

The chat template exposes `enable_thinking`, and the build also has
`-rea/--reasoning [on|off|auto]` plus `--reasoning-format`. For an instruct-style
orchestrator:

```bash
--reasoning off --chat-template-kwargs '{"enable_thinking":false}'
```

Verify after launch — send a trivial question and check `usage.completion_tokens`
and that `message.reasoning_content` is absent:

```
Q: 17 x 23 ?
completion_tokens: 4      content: "391"
```

## MTP / NextN

Some models ship an MTP layer (extra 0.4 B block for multi-token prediction). Two
things to know:

- `unused tensor blk.N.nextn.* -- ignoring` at load is **normal**. The block is
  only allocated when the context is created as `LLAMA_CONTEXT_TYPE_MTP`, i.e.
  with `--spec-type draft-mtp`. There is nothing to patch.
- On this hardware it is a loss at useful settings — see
  [benchmarks.md](benchmarks.md).

## Health checks

```bash
curl -s http://127.0.0.1:8080/props | python3 -m json.tool | grep -E 'n_ctx|total_slots'
curl -s http://127.0.0.1:8080/v1/models
```

`/props` is the reliable way to confirm what context the server actually
allocated — the process command line will not tell you if a flag was rejected.