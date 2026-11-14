# Deux Vega 56 de 2017 comme nœud d'inférence LLM de 16 Go

[English](README.md) · **Français** · [中文](README.zh.md)

**42 tok/s · 64 k de contexte · 226 k vérifiés · 200 W · ~220 € au total**

---

## Le point de départ

C'est un nœud d'inférence LLM fonctionnel, monté uniquement avec du matériel que
personne ne choisirait pour ça. Tous les chiffres ci-dessous ont été mesurés sur
la machine.

- Deux **AMD Radeon RX Vega 56** — 2017, GCN5 (`gfx900`), 8 Go de HBM2 chacune
- Une station **HP Z440** achetée d'occasion pour **60 €**
- **62 Go de DDR4** récupérés dans une poubelle à l'époque où ça ne valait rien
- Un **Xeon E5-2683 v4** (16c/32t, 2016)

Elle sert un modèle MoE de 19 milliards de paramètres (3 B actifs) à **42 tok/s**,
tient un **contexte de 64 k** avec de la marge, et a été vérifiée à **226 205
tokens** sans troncature — tout en restant sous un **plafond de 100 W par carte**
sur une alimentation dont le rail GPU est limité à 225 W.

Coût total, cartes comprises : environ **220 €**.

| | |
|---|---|
| Modèle | Groot-19B-A3B — 19,3 B au total, 3 B actifs, 40 couches (10 en attention pleine, 30 en linear attention), 128 experts routés + 1 partagé (8 actifs), dimension cachée 2048, contexte natif 262 144 |
| Quantification | `Q5_K_S`, 13,76 Go |
| Génération | **42,3 tok/s** (temp 0.7, réponses de 1 200 tokens) |
| Prefill | **593 tok/s** sur un prompt de 18 800 tokens |
| Contexte | 65 536 confortable · 226 205 vérifiés |
| VRAM | 7,39 / 7,09 Go sur 8,0 par carte |
| Puissance | Plafond 2 × 100 W ; 204 W de pic mesurés en charge soutenue |
| Backend | llama.cpp `b12383`, Vulkan |
| OS | Ubuntu 24.04.5 LTS |

---

## Pourquoi ça fonctionne

Deux propriétés de la charge de travail rendent ce matériel viable, et les deux
sont régulièrement mal comprises.

### 1. Le décodage est limité par la bande passante, pas par le calcul

À batch 1, un LLM lit ses poids actifs une fois par token et fait relativement peu
d'arithmétique par octet. Le débit suit la **bande passante mémoire**, pas la
fréquence du cœur. Une Vega 56 dispose encore de **409 Go/s de HBM2** — respectable
en 2026, et supérieur à beaucoup de cartes grand public actuelles.

C'est tout le secret du plafond de puissance. On tourne à :

```
SCLK  1000 MHz  (boost d'origine ≈ 1470–1590 MHz)   →  −32 %
MCLK   800 MHz  (d'origine, non touchée)
```

et on ne perd que **~20 % de débit** en coupant la consommation d'environ **40 %**.
Toucher à la MCLK aurait été catastrophique : la fréquence HBM est presque
linéairement liée à la vitesse de décodage.

Vérification arithmétique : 3 B de paramètres actifs à ~5,6 bits/poids, cela fait
~2,1 Go lus par token. À 42 tok/s, cela représente **88 Go/s effectifs** sur
819 Go/s de pic cumulé. Utiliser 11 % du pic est parfaitement normal en décodage
batch-1 — et c'est précisément pour ça que baisser la fréquence cœur coûte peu.

### 2. La linear attention change le budget mémoire

30 des 40 couches utilisent la linear attention, donc le cache KV croît bien plus
lentement que celui d'un transformeur classique. Passer de 64 k à 128 k de contexte
n'a coûté que **~0,6 Go**. Un modèle dense de 19 B ne tiendrait jamais 226 k sur
16 Go.

---

## Le problème : la machine s'éteignait toute seule

En configuration d'origine, le nœud **coupait sec** en charge — aucun panic noyau,
aucun OOM, aucun événement thermique, rien dans `journalctl`. Juste une machine
morte en pleine génération, toujours dans les secondes suivant le début d'un gros
prefill.

Le Z440 a une alimentation de 700 W, largement suffisante pour un Xeon de 120 W et
deux cartes. Mais son **rail GPU plafonne à 225 W** sur deux connecteurs 6-pin.

### Cause racine : les transitoires DPM, pas la puissance moyenne

Le DPM d'AMD monte la fréquence et la tension par paliers à l'arrivée de la charge.
Chaque palier est un échelon de courant, et la protection surintensité de
l'alimentation réagit au **front**, pas à la valeur moyenne.

Trois observations prouvent que c'est un problème de transitoire et non de
puissance totale :

1. Les coupures arrivaient **au début** de la charge, pas après plusieurs minutes.
2. **Un plafond à 80 W en mode auto coupait encore** — le plafond limite la
   moyenne, le DPM produit toujours les fronts.
3. **Figer les fréquences a tout résolu**, à une puissance moyenne *supérieure* à
   la configuration à 80 W qui échouait (204 W de pic, 8 essais sur 8, zéro
   coupure).

Ce n'était jamais une question de quantité d'énergie demandée, mais de la vitesse
à laquelle on la demandait.

### La correction

Deux paramètres noyau et une unité systemd.

```
amdgpu.ppfeaturemask=0xffffffff   # active l'interface overdrive
amdgpu.bapm=0                     # désactive le dépassement de TDP des Vega
```

`ppfeaturemask` doit inclure le bit overdrive, sinon `pp_od_clk_voltage` reste vide
et il est impossible de toucher aux tensions — la valeur par défaut courante
(`0xfff7bfff`) a ce bit coupé. `bapm` est spécifique aux Vega et autorise la carte
à dépasser son TDP nominal en rafale : une source d'excursions documentée mais
rarement mentionnée.

**L'ordre d'application n'est pas cosmétique :**

1. Plafond de puissance d'abord — committer un point overdrive peut le réinitialiser.
2. Point overdrive : `s <index> <MHz> <mV>`, puis `c` pour committer.
3. `manual` **avant** d'écrire un index DPM, sinon le gouverneur l'écrase au tick
   suivant.
4. Réaffirmer le plafond après le commit overdrive.

Voir [`scripts/gpu-setup-pin.sh`](scripts/gpu-setup-pin.sh) et
[`docs/power-and-clocks.md`](docs/power-and-clocks.md) (en anglais).

| configuration | prefill | génération | coupures |
|---|---|---|---|
| DPM auto, plafond 80 W | 491 tok/s | 22,8 tok/s | oui |
| **fréquences figées, 100 W** | **611 tok/s** | **38,1 tok/s** | **non (8/8)** |

La configuration figée est à la fois **plus rapide et stable**. Le DPM auto
n'exploite pas mieux la marge — il oscille entre états, et chaque transition est un
risque.

---

## Pile logicielle

ROCm a abandonné `gfx900` il y a longtemps. **Vulkan est la voie pragmatique pour
GCN5** et fonctionne avec les `mesa-vulkan-drivers` standard d'Ubuntu.

```bash
cmake -B build -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc) --target llama-server llama-cli
```

15 à 30 minutes sur ce Xeon — bon à savoir avant de décider de patcher quoi que ce
soit.

La ligne de service qui fonctionne réellement ici :

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

| option | pourquoi elle compte |
|---|---|
| `-sm layer` | **obligatoire.** `row` exige `ggml_backend_split_buffer_type`, non implémenté dans `ggml-vulkan` → *« device Vulkan0 does not support split buffers »*. `tensor` fonctionne mais n'apporte rien. |
| `-np 1` | le défaut est 4 slots ; en mono-utilisateur ils ne font que fragmenter le budget KV. |
| `-fa on` | Flash Attention se désactive silencieusement si le KV est quantifié. |
| pas de `-ctk/-ctv` | le KV reste en f16. Le KV quantifié n'apporte presque rien ici et coupe FA. |
| `--reasoning off` | le plus gros gain de latence disponible — voir plus bas. |
| `--presence-penalty 0.0` | la fiche modèle dit 1.5. Ça coûte **19 %** ici. |

---

## Mesures

Tous les chiffres viennent de ce nœud. Méthodologie : timings du serveur llama.cpp
(`predicted_per_second`), générations de 900 à 1 200 tokens, `-np 1`, KV f16 sauf
mention contraire.

### Quantification : la différence de vitesse est négligeable

À 64 k de contexte, `presence_penalty=0`, options identiques :

| quant | fichier | VRAM par carte | génération | prefill |
|---|---|---|---|---|
| IQ4_XS | 10,94 Go | 5,97 / 5,80 Go | 43,0 tok/s | 599 tok/s |
| Q4_K_M | 12,48 Go | 6,77 / 6,50 Go | **44,1 tok/s** | 604 tok/s |
| **Q5_K_S** | 13,76 Go | 7,39 / 7,09 Go | 42,3 tok/s | 593 tok/s |

**4 % d'écart pour 2,8 Go de taille de modèle**, et un prefill indiscernable. La
qualité sur un banc de 10 questions d'orchestrateur (calcul, émission de JSON,
suivi d'instruction, connaissances shell, logique) était tout aussi indifférenciée :
8/10, 8/10 et 7/10 — le seul écart étant la langue de réponse sur une question de
logique, pas la justesse.

**Conclusion :** acheter de la qualité avec la VRAM restante, c'est quasiment
gratuit. Q5_K_M (14,72 Go) et au-delà déborderaient des 16,3 Go de VRAM utilisable.

### Contexte : la génération se dégrade doucement, le prefill s'effondre

IQ4_XS, KV `q8_0`, plafond 100 W :

| contexte | génération | prefill | temps de prefill complet |
|---|---|---|---|
| 16 k | 37,2 tok/s | 619 tok/s | 30 s |
| 64 k | ~30 tok/s | 613 tok/s | 1 min 47 s |
| 113 k | 24,2 tok/s | 179 tok/s (marginal) | ~10 min |
| 226 k | 16,6 tok/s | 168 tok/s | **22 min** |
| 262 k | charge, mais 1,2 Go en GTT | — | — |

Multiplier le contexte par 14 ne coûte que 2,2× sur la génération. Le vrai coût du
contexte long, c'est le **prefill** — 22 minutes pour ingérer 226 000 tokens.

`-c 262144` se charge (7,56 Go de VRAM + 1,2 Go de GTT) mais llama.cpp prévient
`failed to fit params to free device memory` et veut retirer des couches ;
`-ngl 99` l'en empêche, donc on est simplement au-delà du budget. **131 072 est le
plafond confortable.**

Le test 226 k est réel : `n_tokens = 226236, truncated = 0`, prefill 1 347 s,
génération 16,6 tok/s.

### Quantification du KV : sans intérêt sur ce modèle

| KV | contexte | prefill | génération |
|---|---|---|---|
| f16 | 32 k | 611 tok/s | 38,1 tok/s |
| `q8_0` | 64 k | 613 tok/s | 37,6 tok/s |
| `q5_1` | 64 k | **520 tok/s** | 34,9 tok/s |

`q8_0` économise ~100 Mo sans rien coûter — mais à 64 k il n'y a pas besoin. `q5_1`
économise les mêmes ~100 Mo et **coûte 15 % du prefill**, déquantifier du q5_1 dans
l'attention étant plus cher que la disposition du q8_0. Avec un KV f16, Flash
Attention reste actif ; avec un KV quantifié il est désactivé
(`Flash Attention over K/V rows not supported`).

### MTP / NextN : présent, fonctionnel, et perdant

Le GGUF embarque une couche MTP de 0,4 B — `blk.40` contient un bloc d'attention
complet, un FFN MoE, et `nextn.eh_proj / enorm / hnorm / shared_head_norm` — ainsi
que `qwen35moe.nextn_predict_layers = 1`.

Les avertissements `unused tensor blk.40.nextn.* -- ignoring` au chargement sont
**normaux** : le bloc n'est alloué que si le contexte est créé en
`LLAMA_CONTEXT_TYPE_MTP`, ce que fait `--spec-type draft-mtp`. Aucun code à écrire,
le support existe dans `src/models/qwen35moe.cpp`.

Ça tourne. Ce n'est simplement pas rentable :

| `--spec-draft-n-max` | acceptation | génération | prefill |
|---|---|---|---|
| désactivé | — | 37,3 tok/s | **621 tok/s** |
| 1 | 84,1 % | **39,5 tok/s (+5,8 %)** | 511 tok/s (−18 %) |
| 2 | 65,2 % | 36,4 tok/s | 509 tok/s |
| 3 | 49,0 % | 28,7 tok/s (−23 %) | 506 tok/s |

Confirmation en usage réel à `n_max=3` et température 0.7 : l'acceptation tombe à
**28,8 %** et le débit à 27,9 tok/s — soit **−35 %** par rapport aux 42,9 tok/s de
référence pour la même forme de requête.

Pourquoi : un forward de draft coûte environ **74 % d'un forward complet de 40
couches**. Avec `-sm layer`, le bloc MTP tient sur une seule carte pendant que
l'autre tourne au ralenti — et chaque token draft traverse quand même la tête de
sortie partagée (projection 2048 × 151 k de vocabulaire).

Seul `n_max=1` est positif, et uniquement sur la génération. Sur du contexte long,
les 18 % de prefill perdus coûtent bien plus que les 5,8 % gagnés.

### `presence_penalty` : 19 % de débit pour une protection inutile

La fiche modèle recommande `temperature=0.7, top_p=0.80, top_k=20, min_p=0.0,
presence_penalty=1.5, repetition_penalty=1.0`. La pénalité de présence seule coûte :

| presence_penalty | génération | ms/token |
|---|---|---|
| 0.0 | **43,0 tok/s** | 23,26 |
| 0.0 (bis) | 43,05 tok/s | 23,23 |
| **1.5** | **34,8 tok/s** | 28,61 |
| 1.5 (bis) | 34,71 tok/s | 28,81 |

Reproductible sur quatre runs, à ±0,5 %. La cause, dans
`src/llama-sampler.cpp` :

```cpp
for (size_t i = 0; i < cur_p->size; ++i) {                    // tout le vocabulaire
    const auto it = ctx->token_count.find(cur_p->data[i].id); // hash par token
    ...
    logit -= count * freq + (count > 0) * presence;
}
cur_p->sorted = false;                                        // re-tri complet
```

Il parcourt les 151 000 candidats à chaque token, fait une recherche dans une table
de hachage pour chacun, puis invalide l'ordre de tri — ce qui force un re-tri des
151 000 entrées au token suivant. `repeat_penalty` et `frequency_penalty` partagent
le même sampler : le coût est donc « tout ou rien », soit les trois à leurs valeurs
neutres (le sampler s'auto-désactive), soit on paie le balayage complet.

**Et elle n'empêche pas les boucles ici.** Générations de 1 200 tokens, temp 0.7,
deux tâches (énumération exhaustive, prose technique) :

| tâche | pp | mots | 8-grammes dupliqués | série identique max | diversité |
|---|---|---|---|---|---|
| énumération | 0,0 | 705 | **0** | 2 | 0,454 |
| énumération | 1,5 | 594 | **0** | 1 | 0,564 |
| prose | 0,0 | 521 | **0** | 1 | 0,564 |
| prose | 1,5 | 525 | **0** | 1 | 0,560 |

Aucune boucle dans les deux cas. La pénalité de présence fait bien ce qu'elle
annonce — elle augmente la diversité lexicale (0,454 → 0,564), ce qui est son
véritable objectif, et non la prévention de boucles. Pour un orchestrateur qui émet
du JSON et des lignes de statut courtes, elle pénalise exactement les tokens qui
*doivent* se répéter (`{`, `"ok"`, `"node"`). Utiliser `--dry-multiplier` si une
protection devient nécessaire : il bloque les n-grammes répétés au lieu de tout le
vocabulaire.

### Mode instruct : le plus gros gain de latence

```bash
--reasoning off --chat-template-kwargs '{"enable_thinking":false}'
```

Vérifié : `17 × 23` renvoie `391` en **4 tokens**, `reasoning_content` absent,
aucune balise ` thinking`. Sur un modèle doté d'un mode raisonnement, cela vaut plus
en latence perçue que n'importe quel chiffre de tok/s — des centaines de tokens
cachés disparaissent de chaque réponse.

---

## Configuration finale

```bash
./llama-server \
  -m Groot-Q5_K_S.gguf -c 65536 -np 1 \
  -ngl 99 -dev Vulkan0,Vulkan1 -sm layer -fa on \
  --reasoning off --chat-template-kwargs '{"enable_thinking":false}' \
  --temp 0.7 --top-p 0.80 --top-k 20 --min-p 0.0 \
  --presence-penalty 0.0 --repeat-penalty 1.0 \
  --host 0.0.0.0 --port 8080 --jinja --alias groot-19b-a3b
```

Le nœud obtenu :

| | |
|---|---|
| Génération | 42,3 tok/s |
| Prefill | 593 tok/s |
| VRAM | 7,39 / 7,09 Go — ~0,8 Go de marge par carte |
| Débordement GTT | négligeable (~400 Mo) |
| Puissance | plafond 2 × 100 W, 1000/800 MHz figés |

---

## Reproduire

1. **Figer les fréquences d'abord.** Ne lancer aucune inférence soutenue sur un
   rail GPU de 225 W avant ça — [docs/power-and-clocks.md](docs/power-and-clocks.md).
2. **Compiler llama.cpp avec Vulkan** — [docs/software-stack.md](docs/software-stack.md).
3. **Dimensionner quant et contexte** — [docs/memory-budget.md](docs/memory-budget.md).
4. **Tableaux de mesure bruts** — [docs/benchmarks.md](docs/benchmarks.md).

```
scripts/
  gpu-setup-pin.sh      applique plafond + overdrive + fréquences figées (idempotent)
  gpu-tuning.service    unité systemd, l'exécute au boot
  stress-psu.sh         test de puissance en charge soutenue
  dpm_sweep.sh          balayage plafond/fréquences pour trouver l'enveloppe stable
  longctx_bench.sh      balayage de longueur de contexte
  gpu-pinclk.sh         aide interactive pour figer/défiger
  gpu-undervolt.sh      première tentative d'undervolt autonome (remplacée)
```

---

## Réserves

- **Batch 1, mono-utilisateur.** Rien de tout cela ne s'applique au service en
  batch ; une carte moderne gagne largement en tokens/watt.
- La limite de 225 W sur le rail est propre au HP Z440. D'autres châssis diffèrent —
  figer les fréquences quand même, cela économise aussi de l'énergie.
- Le modèle est un MoE à forte composante de linear attention. Un modèle dense de
  19 B n'approcherait jamais 226 k sur 16 Go.
- `gpu-tuning.service` est vérifié en lancement manuel ; **l'ordonnancement au boot
  face à l'initialisation d'`amdgpu` est le seul point non validé.**
- Les prix sont ceux de l'occasion européenne en 2026. L'exercice consiste à rendre
  du silicium ancien utile, pas à battre une 3090.

## Licence

MIT pour les scripts et les textes. Les poids du modèle appartiennent à leurs
auteurs.