# TurboQuant — Analysis & Tidepool Applicability

**Source:** Google Research blog, "TurboQuant: Redefining AI efficiency with extreme compression" (March 2026)
**Paper:** Zandieh, Daliri, Hadian, Mirrokni. *TurboQuant: Online Vector Quantization with Near-optimal Distortion Rate*. arXiv 2504.19874. Accepted ICLR 2026.
**Companion paper:** *PolarQuant* (AISTATS 2026).

> **Note on sourcing:** The blog post (`research.google`) and the arXiv abstract page returned HTTP 403 to automated fetches. The technical claims below are reconstructed from the arXiv listing, OpenReview entry, secondary technical write-ups (Spheron, Kaitchup, themlsurgeon, frr.dev), the public GitHub re-implementations, and the dev.to follow-up that contests the RaBitQ comparison. Numbers should be re-verified against the PDF before any production decision.

---

## 1. What TurboQuant actually is

TurboQuant is an **online vector quantization** scheme — meaning quantization is applied per-vector at write/read time without any training, calibration set, or codebook fitting. It targets two workloads:

1. **KV-cache compression** for long-context LLM inference.
2. **Embedding compression** for vector search / ANN indexes.

### 1.1 Core idea (in one paragraph)

Apply a **random rotation** (typically a structured Hadamard / SRHT matrix for speed) to each input vector. After rotation, the per-coordinate distribution of a unit-norm vector concentrates around a known **Beta distribution**, and the coordinates become approximately independent in high dimensions. Once that's true, the optimal compressor reduces to applying an **optimal scalar quantizer per coordinate** — a problem with a known solution. TurboQuant then layers a **1-bit Quantized Johnson–Lindenstrauss (QJL) projection on the residual** to make the resulting inner-product estimator **unbiased**.

So the pipeline is:

```
x  ──▶  Rx (random rotation)  ──▶  per-coord scalar quantizer  ──▶  q(Rx)
                                       │
                                       └── residual r = Rx − q(Rx)
                                                         │
                                                         └── 1-bit QJL → unbiased correction term
```

### 1.2 Theoretical claims

- **Distortion-rate bound**: matches the information-theoretic lower bound on achievable distortion vs. bit budget for vector quantization, up to a small constant factor (≈ **2.7×**).
- **Estimator**: provides an **unbiased** estimator of inner products `⟨x, y⟩`, with bounded variance.
- **Online**: no training data, no codebook, no fine-tuning. One-pass per vector.

### 1.3 Reported empirical results

| Workload | Setting | Result |
|---|---|---|
| KV cache | 3.5 bits/channel | "Quality-neutral" — matches FP16 baseline on LongBench (≈50.06 avg) |
| KV cache | 2.5 bits/channel | "Marginal" degradation |
| KV cache | 4× compression on Llama-3.1-8B | Needle-in-a-Haystack 0.997 up to 104K context, identical to FP16 |
| KV cache | 3-bit on Qwen2-7B | GSM8K drops 1.4 pts (84.3% vs 85.7%) |
| Vector search | vs PQ, vs RaBitQ | Reported recall wins across budgets (**contested** — see §2) |
| Compression ratio | KV cache | Up to **6×** |

### 1.4 Caveats — what to read with skepticism

- **RaBitQ controversy (dev.to/gaoj0017).** RaBitQ has a published proof of asymptotically optimal space–distortion trade-off (Alon–Klartag bound). TurboQuant's paper offers a *variance* guarantee, which is weaker. The dev.to follow-up alleges TurboQuant's reported ANN benchmarks compared against a single-threaded Python port of RaBitQ on A100s, and that the released artifacts don't reproduce the paper's numbers under the stated config. Treat "outperforms RaBitQ" as unverified.
- **Dimensions matter.** JL-style guarantees are dimension-dependent. The "near-optimal" claim is most meaningful in the **high-dimension** regime (≥1024 dims). At <512 dims, the constant factor and rotation overhead may eat into wins.
- **Aggregation isn't free.** The unbiased estimator is for *pairwise inner products*. Summing many quantized vectors and *then* using one query against the sum is not the same operation — you pick up bias unless you sum in the residual domain or dequantize first.
- **Implementation maturity.** Google's official code is reportedly Q2 2026. Community ports (0xSero/TurboQuant for vLLM, AmesianX/TurboQuant for llama.cpp) are working but unaudited.

---

## 2. Mapping to Tidepool's actual data

Tidepool stores and exchanges three primary vector types per device profile (`TidepoolServer/Sources/App/Migrations/AddMultiVectors.swift`, `Models/DeviceProfile.swift`):

| Vector | Dim | Source | Index |
|---|---|---|---|
| `music_vector` | 512 | Spotify + Apple Music genres | pgvector HNSW (cosine) |
| `places_vector` | 512 | POI / favorites / visit history | pgvector HNSW (cosine) |
| `vibe_vector` | 130 | Aggregated TF-IDF over canonical interest tags | pgvector HNSW (cosine) |
| (legacy) `interest_vector` | 130 | Pre-multivector unified vector | pgvector HNSW (cosine) |

All vectors are **L2-normalized unit vectors** (see `vectorFromTags` in `InterestVectorComputation.swift:262-268`), which is exactly the input distribution TurboQuant assumes.

### 2.1 Storage footprint today

Per profile, multi-vector payload is **(512 + 512 + 130) × 4 B = 4,616 B ≈ 4.5 KB**. At the SPEC's 100k DAU target that's ~**450 MB** of raw vector data, plus the HNSW graph overhead (typically 2–3× the raw size), so call it **~1–1.5 GB resident** in the hot Postgres path.

### 2.2 Network footprint today

- `POST /v1/profile/multi-vector` ships the full 4.5 KB vibe+places+music payload on every recompute (`InterestVectorComputation.swift:96-107`).
- `POST /v1/tiles/heat` and search both ship the viewer's vector inline.
- On cellular, a flurry of these on integration changes is non-trivial — and Tidepool already has a 1.5 KB / vector budget called out in `SPEC.md:222`.

### 2.3 Compute footprint today

`TidepoolComputeService.swift` does an **all-pairs** cosine sweep across profiles (`computeSimilarityComposite`, lines ~205–225) using float32 dot products. That's O(N² · D) where D = 1154. Bit-packed vectors with Hamming/popcount give ~**32× speedup** at the inner-loop level on commodity CPUs (and >100× with AVX-512 popcount).

---

## 3. Where TurboQuant could help Tidepool

Ranked by likely value, with caveats.

### Tier 1 — High-leverage, low-risk

**A. Compress `music_vector` and `places_vector` for HNSW recall.**
These are the two 512-dim vectors that dominate storage. At 1-bit QJL (~64 B/vector) or 2-bit (~128 B/vector), the entire HNSW base layer fits in a fraction of RAM. pgvector already supports `bit` and `halfvec` column types, and there are HNSW-over-bit-vector implementations.
- *Win*: 16–32× storage reduction, faster pairwise distance kernel.
- *Risk*: 512 dims is on the lower side for JL guarantees; recall loss at 1-bit may be noticeable. Validate against current cosine HNSW on a held-out similarity set before flipping.

**B. Compress vectors at rest for the all-pairs tidepool compute job.**
`TidepoolComputeService.computeAllTidepools()` (line ~31) loads every profile and does composite cosine. Even without changing the storage format, **rotate-and-bit-quantize at job start**, run popcount in the inner loop, and you cut per-iteration cost ~10–30×. This is a reversible, isolated optimization — doesn't touch the API contract.
- *Win*: Lets the recompute job scale further before requiring sharding. Removes an obvious O(N²) bottleneck.
- *Risk*: Low. Compose with the existing weighted blend (places/music/vibe) by quantizing each independently and weighting their popcount distances.

### Tier 2 — Useful, needs design work

**C. Bit-quantized over-the-wire vectors.**
Replace the float32 array in `ProfileVectorRequest` / `MultiVectorRequest` with a packed bit string. Worst case (vibe 130 dim): 130 bits → 17 B, vs. 520 B today. Multi-vector total drops from 4.5 KB → ~150 B.
- *Win*: ~30× smaller upload payloads. Helps battery on cellular, reduces ingress bandwidth, lets us recompute more often.
- *Risk*: API break — needs versioned endpoint (`/v2/profile/multi-vector`) and a server-side dequant path for any consumer that still wants float32 (e.g. the aligned-heat composite weighting). Rotation seed needs to be deterministic and shared — bake it as a per-vector-type constant in `TidepoolShared`.

**D. ANN-quality search ranking with quantized indices.**
`SearchController` and `RecommendationController` compute interest-alignment scores against candidate venues. A bit-quantized venue catalog (when we eventually build one) would let us retrieve top-K candidates with Hamming distance, then re-rank a small set with full-precision cosine.
- *Win*: Standard "coarse-then-fine" ANN pattern; gives sub-200 ms p95 search latency with millions of venues.
- *Risk*: Premature until the venue corpus is large enough to matter. RaBitQ via pgvector extensions is a probably-equivalent alternative that's already battle-tested.

### Tier 1.5 — LLM-shaped workloads (this is where the *headline* TurboQuant claim actually pays off)

Tidepool has an LLM hook **scaffolded but not yet operational**: `TasteSummaryController.swift:99` is wired to call **Claude Haiku 4.5** via the Anthropic API (`model: claude-haiku-4-5-20251001`) to generate a 2–3 sentence taste profile, the route is registered (`routes.swift:25`), and `BackendClient.getTasteSummary()` exists on the client side. But the controller falls back to a static string ("You enjoy X, Y, Z spots.") when `ANTHROPIC_API_KEY` is unset (lines 55–64), and the iOS call site doesn't appear to be triggered from the UI yet. Read this as **intent, not production traffic**. The SPEC also reserves space for sentence-transformer / E5-class embedding models (on-device Core ML or server-hosted).

This is where TurboQuant's marquee KV-cache result becomes directly relevant — but **only on inference paths we control**. A clean taxonomy:

| Path | Who runs inference | TurboQuant applies? |
|---|---|---|
| Hosted Anthropic API (today's taste summary) | Anthropic | ❌ — KV-cache quantization is a runtime feature; we'd need Anthropic to offer it. We'd save nothing on our side. |
| Self-hosted server LLM (vLLM / TGI for re-ranking, summaries, conversational search) | Us, on GPU | ✅ — community vLLM port exists (`0xSero/turboquant`). 3.5 bits/channel ≈ 4× KV reduction at quality parity. |
| On-device LLM via Apple Foundation Models / Core ML / llama.cpp | iPhone | ✅ ✅ — RAM is *the* binding constraint on iPhone; 4–6× KV compression is the difference between "works at 8K context" and "works at 32K." Direct fit. |
| Offline batch (tag-graph generation, teacher labels for the relatedness matrix in `SPEC.md:198`) | Us, occasionally | Mild — KV compression helps throughput and context length per batch run. |

**Concrete LLM features that benefit:**

**G. On-device taste summaries.** Move `TasteSummaryController` from Anthropic API to Apple Foundation Models (iOS 18.1+) for the privacy story. The user's full interest history (favorites, top genres, visit patterns) is the prompt context, which gets long fast. TurboQuant'd KV cache lets a 3B-class on-device model accept that whole context.

**H. Conversational place search.** "Find me a quiet place with good coffee, somewhere I haven't been, that fits my vibe." Prompt context = interest vector summary + last-N visits + candidate venues from HNSW retrieval + venue descriptions. That's easily 4–8K tokens of context. With TurboQuant on a self-hosted small LLM, this fits cheaply. Slots into the existing `/v1/search/places` endpoint.

**I. Personalized venue blurbs.** Server-side, cached per (user, place) — "why this fits you." Self-hosted small model + TurboQuant KV compression gives more parallel generations per GPU.

**J. LLM-as-reranker.** ANN gives top-200 candidates, an LLM re-ranks the top-50 with structured venue features. KV cache compression matters here because the per-request context is huge (50 candidates × structured fields). This is a clean replacement for/augmentation of the cosine-only ranking in `SearchController.swift`.

**K. Tag-graph teacher labels.** The SPEC's offline pipeline (`SPEC.md:194-204`) needs an LLM to score tag pairs for the relatedness matrix. Standard batch inference workload; TurboQuant lowers cost.

**Why this changes the calculus:**
The §5 conclusion in the original draft said "the KV-cache use case doesn't apply to Tidepool." That was wrong as a forward-looking claim. The moment Tidepool runs *any* inference we control — server-side or on-device — the KV-cache result becomes the **single most valuable part of the paper**, more than the embedding-compression piece. On-device especially: Apple's Foundation Models + a TurboQuant'd KV cache is plausibly the unlock for "smart, private recommendations on iPhone with no server LLM call at all."

**Caveats specific to LLM paths:**
- Anthropic API path is locked out — they'd have to ship it.
- Apple Foundation Models are sandboxed; we can't customize their KV cache. So this benefit only materializes if we run our own model (llama.cpp / MLX / Core ML) on-device.
- Self-hosted server LLM means new infra. Worth it only if at least two of features G–J ship.

### Tier 3 — Speculative

**E. Differential-privacy interaction.**
The SPEC's tile aggregator already injects DP noise on counts. The random rotation in QJL is a kind of randomized response, and there's a literature on quantization providing privacy amplification. Worth asking whether *bit-quantized contributor vectors + reduced DP noise* gives the same end-to-end ε at lower utility cost. **Don't lean on this without a DP expert review.**

**F. On-device tag-embedding matrix.**
The roadmap calls for an `embedding_matrix.npy` shipped in-app (`SPEC.md:202`). Quantizing it with TurboQuant cuts the app bundle. Modest gain — the matrix is small at the planned vocab size (~10k tags × 384 dims = ~15 MB float32 → ~500 KB at 1 bit).

### Don't bother

- **The legacy 130-dim `vibe_vector`** alone isn't worth quantizing — at this dim, JL guarantees are weak and the absolute byte savings (520 B → ~17 B) don't move the needle compared to the 512-dim vectors.

---

## 4. Concrete next steps if we wanted to pilot this

1. **Benchmark stub** (1–2 days). Take a snapshot of current `device_profiles`, generate quantized variants at 1, 2, 4 bits/dim using QJL with a structured Hadamard rotation, and measure:
   - Pairwise cosine recall@10 (quantized vs. float32) on the existing tidepool clustering.
   - HNSW recall@10 on synthetic queries.
   - Wall-clock for `computeAllTidepools` rotated-bit vs. float32.
2. **Compare to baselines** — pgvector `halfvec` (fp16) and the published pgvector RaBitQ extension. TurboQuant only matters if it beats RaBitQ at the same bit budget, and the public benchmark dispute means we need our own number.
3. **API design** — if Tier 1 wins out, add a packed-bit transport on `/v2/profile/multi-vector` with a `quantization: "qjl-1bit"` field and a versioned per-vector-type rotation seed in `TidepoolShared`. Keep float32 path live for one app version cycle.
4. **DP coupling** — separate workstream; defer until item 1 is positive.

---

## 5. Bottom line

TurboQuant is a **promising but contested** scalar/JL hybrid for vector compression. For Tidepool, two distinct value stories:

1. **Today's pipeline (vector path).** The all-pairs cosine sweep in `TidepoolComputeService.computeAllTidepools` and the multi-vector pgvector HNSW indices are the immediate beneficiaries of the embedding-compression half of the paper. Lowest-friction win, fully on our side of the API. **Benchmark TurboQuant head-to-head against RaBitQ + pgvector first** — RaBitQ is more mature, has stronger published guarantees, and may be a drop-in pgvector extension. TurboQuant's edge over RaBitQ is currently disputed.

2. **Future LLM features (KV-cache path).** The headline 6× KV-cache compression result becomes valuable the moment Tidepool runs LLM inference *we control*. The existing `TasteSummaryController` hook targets the Anthropic API and isn't operational anyway — even when it lights up, KV quantization is a runtime concern at the inference engine, so it gives Tidepool nothing on a hosted-API path. The interesting branches are: (a) self-hosted server model for conversational search / re-ranking / personalized blurbs (vLLM with TurboQuant), and (b) on-device via llama.cpp / MLX / a custom Core ML model. On-device is the most exciting case: it's the difference between a recommendation chatbot that actually fits in iPhone RAM at usable context lengths and one that doesn't. **None of this is committed roadmap — it's the design space TurboQuant unlocks if/when we go that direction.**

The right framing: TurboQuant's two halves map to two separate roadmap bets. The vector half is a **near-term efficiency win**; the KV half is a **strategic enabler for any controlled LLM inference** Tidepool decides to run.

---

## References

- arXiv: [TurboQuant: Online Vector Quantization with Near-optimal Distortion Rate (2504.19874)](https://arxiv.org/abs/2504.19874)
- Google Research blog: [TurboQuant: Redefining AI efficiency with extreme compression](https://research.google/blog/turboquant-redefining-ai-efficiency-with-extreme-compression/)
- OpenReview (ICLR 2026): https://openreview.net/forum?id=tO3ASKZlok
- Critical follow-up: [TurboQuant and RaBitQ: What the Public Story Gets Wrong](https://dev.to/gaoj0017/turboquant-and-rabitq-what-the-public-story-gets-wrong-1i00)
- Community implementations: `0xSero/turboquant` (vLLM), `AmesianX/TurboQuant` (llama.cpp), `animehacker/llama-turboquant` (GGML)
