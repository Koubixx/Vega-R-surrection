| model                          |       size |     params | backend    | ngl |  fa |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | --: | --------------: | -------------------: |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |           pp512 |        521.07 ± 4.97 |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |           tg128 |         45.56 ± 0.20 |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |  pp512 @ d16384 |        315.69 ± 0.66 |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |  tg128 @ d16384 |         41.18 ± 0.20 |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |  pp512 @ d65536 |        143.91 ± 0.52 |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |  tg128 @ d65536 |         28.23 ± 0.02 |
build: c56be864f (12383)
