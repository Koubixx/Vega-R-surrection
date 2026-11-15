| model                          |       size |     params | backend    | ngl |  fa |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | --: | --------------: | -------------------: |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |           pp512 |        508.67 ± 2.41 |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |           tg128 |         45.27 ± 0.22 |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |  pp512 @ d16384 |        311.00 ± 1.67 |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |  tg128 @ d16384 |         41.05 ± 0.12 |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |  pp512 @ d65536 |        143.57 ± 0.24 |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |  tg128 @ d65536 |         28.24 ± 0.01 |
build: c56be864f (12383)
