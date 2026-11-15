| model                          |       size |     params | backend    | ngl |  fa |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | --: | --------------: | -------------------: |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |           pp512 |        506.35 ± 3.17 |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |           tg128 |         45.28 ± 0.18 |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |  pp512 @ d16384 |        310.77 ± 1.10 |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |  tg128 @ d16384 |         40.80 ± 0.14 |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |  pp512 @ d65536 |        143.35 ± 0.58 |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |  tg128 @ d65536 |         28.23 ± 0.02 |
build: c56be864f (12383)
