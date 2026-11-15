| model                          |       size |     params | backend    | ngl |  fa |            test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | --: | --------------: | -------------------: |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |           pp512 |        513.88 ± 6.91 |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |           tg128 |         46.55 ± 0.28 |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |  pp512 @ d16384 |        312.58 ± 1.25 |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |  tg128 @ d16384 |         42.29 ± 0.15 |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |  pp512 @ d65536 |        144.21 ± 0.26 |
| qwen35moe 35B.A3B Q5_K - Small |  12.80 GiB |    18.99 B | Vulkan     |  99 |   1 |  tg128 @ d65536 |         29.04 ± 0.05 |
build: c56be864f (12383)
