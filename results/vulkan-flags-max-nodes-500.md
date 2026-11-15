| model                          |       size |     params | backend    | ngl |  fa |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | --: | --------------: | -------------------: |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |           pp512 |        514.61 ± 4.81 |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |           tg128 |         45.13 ± 0.33 |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |  pp512 @ d16384 |        311.12 ± 2.34 |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |  tg128 @ d16384 |         41.04 ± 0.23 |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |  pp512 @ d65536 |        143.54 ± 0.23 |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |  tg128 @ d65536 |         28.29 ± 0.03 |
build: c56be864f (12383)
