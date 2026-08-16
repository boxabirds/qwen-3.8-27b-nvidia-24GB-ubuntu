# Discovery log — Qwen3.8-27B on a 24GB RTX 4090

Everything here was measured on one machine on 2026-08-16:

| | |
|---|---|
| GPU | RTX 4090, 24564 MiB VRAM (24047 MiB usable), sm_89 |
| Driver / CUDA | 580.159.03 / CUDA 12.3 toolkit |
| OS | Ubuntu 22.04.5 LTS, 64 GB RAM |
| llama.cpp | `b94041a` (b10452), built with Ninja, `CMAKE_CUDA_ARCHITECTURES=89` |
| Model | `unsloth/Qwen3.8-27B-GGUF` @ `UD-Q4_K_XL` (17,092 MiB) |

**Read this before changing quant, context, or speculative-decoding settings.**
Most of the surprises below cost an hour each to find and are not documented
upstream.

---

## 1. The model's architecture inverts the usual VRAM tradeoff

This is the single most important fact, and it is easy to get wrong.

From the GGUF metadata (`general.architecture = qwen35`):

```
qwen35.block_count                65
qwen35.full_attention_interval     4     <-- only every 4th layer is attention
qwen35.attention.head_count_kv     4
qwen35.attention.key_length      256
qwen35.attention.value_length    256
qwen35.ssm.state_size            128     <-- the other 49 layers are Gated DeltaNet
```

**Only 16 of 65 layers hold a KV cache.** The other 49 are Gated DeltaNet, which
carries a fixed-size recurrent state regardless of sequence length. So:

```
KV per token = 16 layers x 2 (K,V) x 4 kv-heads x 256 head-dim = 32,768 elements
  q8_0 (1.0625 B/elem) -> 34 KiB/token -> 1 GiB = ~30k tokens
  q5_1 (0.75   B/elem) -> 24 KiB/token -> 1 GiB = ~43k tokens
  q4_0 (0.5625 B/elem) -> 18 KiB/token -> 1 GiB = ~57k tokens
```

That is roughly **5x cheaper per token than a conventional dense 27B**.

### The blind alley

Initial sizing assumed KV was the constraint and concluded "32k is the safe
default, 64k is marginal." That was wrong in both directions — it *overestimated*
KV cost and *ignored* the real constraint, which is static weights:

```
model  17,092 MiB
MTP     1,602 MiB
mmproj    891 MiB
        ---------
        19,585 MiB of weights before a single token of context
```

**The correct mental model: every MiB freed from weights buys context.** At q5_1,
1 GiB of weights ≈ 43k tokens. Optimising KV quantisation is a second-order lever;
optimising *what you load* is first-order.

---

## 2. `-ub 256` is the highest-leverage flag, and it is not obvious

llama.cpp sizes its prompt-processing compute buffer from the **micro-batch**
(`-ub`), not from context length. At 128k context with the default `-ub 512`,
it tries to allocate ~720 MiB in one block:

```
ggml_backend_cuda_buffer_type_alloc_buffer: allocating 720.28 MiB on device 0: cudaMalloc failed: out of memory
ggml_gallocr_reserve_n_impl: failed to allocate CUDA0 buffer of size 755269888
graph_reserve: failed to allocate compute buffers
llama_init_from_model: failed to initialize the context: failed to allocate compute pp buffers
```

Note the failure is on **compute buffers**, not the KV cache. Reading that
message as "not enough room for context" sends you off tuning `-c` and
`--cache-type-*`, which is the wrong lever.

Halving the micro-batch took 96k from OOM to loading with 1.1 GiB spare:

| Config | Result |
|---|---|
| 96k, q8_0 KV, `-ub 512 -np 4` (default) | **OOM** |
| 96k, q8_0 KV, `-ub 256 -np 1` | **22,920 MiB**, loads fine |

### Measured cost (`llama-bench`, pp2048/tg32, MTP off)

| `-ub` | prefill tok/s | generation tok/s |
|---|---|---|
| 256 | 2701 | 43.85 |
| 512 | 2915 | 44.15 |

**7.3% prefill penalty, ~0% generation penalty.** Cheap for ~700 MiB. Every
profile above 64k depends on this.

---

## 3. MTP: the head is in a different repo, and it fails silently

The brief asked for "Unsloth GGUF + MTP". These are mutually exclusive from a
single repo, which is not stated anywhere obvious.

`unsloth/Qwen3.8-27B-GGUF` ships **no MTP head**. Verified via the HF manifest
endpoint, which is the fastest way to check:

```bash
curl -s https://huggingface.co/v2/unsloth/Qwen3.8-27B-GGUF/manifests/UD-Q4_K_XL | jq '.layers[].mediaType'
# vnd.ollama.image.model
# vnd.ollama.image.template
# vnd.ollama.image.projector      <-- mmproj present
# vnd.ollama.image.params
#                                 <-- no MTP layer
```

`ggml-org/Qwen3.8-27B-GGUF` **does** ship one: `mtp-Qwen3.8-27B-Q4_0.gguf`
(1,602 MiB). Both derive from `Qwen/Qwen3.8-27B`, and **mixing them works** —
measured 0.70–0.92 draft acceptance across every run.

### The trap

llama.cpp only auto-discovers MTP sidecars on the **`-hf` download path**
(`common/arg.cpp`, `plan_spec.mtp`). With a local `-m /path/model.gguf`, nothing
is discovered. And `COMMON_SPECULATIVE_TYPE_DRAFT_MTP` is only enabled when
`params.draft.ctx_dft != nullptr` (`common/speculative.cpp:2473`).

So this **starts cleanly and silently does nothing**:

```bash
llama-server -m model.gguf --spec-type draft-mtp --spec-draft-n-max 2   # NO -md
```

You must pass the head explicitly:

```bash
-md "$MTP" --spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-ngl 99
```

**Always verify from the log rather than trusting a clean startup:**

```
common_speculative_init_result: loading draft model '.../mtp-Qwen3.8-27B-Q4_0.gguf'
slot print_timing: draft acceptance = 0.90000 (18 accepted / 20 generated), mean len = 2.80
```

No `draft acceptance` line ⇒ speculative decoding is inactive, regardless of what
you passed. `setup.sh`'s smoke test now asserts this.

### Flag names that changed

`--draft-max` / `--draft-min` are **removed** in current llama.cpp. Use
`--spec-draft-n-max` / `--spec-draft-n-min`. Valid `--spec-type` values:
`none, draft-simple, draft-eagle3, draft-mtp, draft-dflash, draft-dspark,
ngram-simple, ngram-map-k, ngram-map-k4v, ngram-mod, ngram-cache`.

---

## 4. Full measurement table

All figures are total `nvidia-smi` VRAM used, which **includes ~595 MiB of
desktop**. "free" is against 24,047 MiB usable. MTP on and vision off unless
stated.

| Context | KV | Vision | `-np`/`-ub` | VRAM | Free | Result |
|---|---|---|---|---|---|---|
| 32k | q8_0 | on | 4 / 512 | 22,786 | 1,261 | OK |
| 64k | q8_0 | off | 4 / 512 | 23,028 | 1,019 | OK |
| 80k | q8_0 | off | 4 / 512 | 23,732 | 315 | OK, too tight |
| 96k | q8_0 | off | 4 / 512 | — | — | **OOM** |
| 96k | q8_0 | off | 1 / 256 | 22,920 | 1,127 | OK |
| 128k | q8_0 | off | 1 / 256 | — | — | **OOM** |
| 128k | q5_1 | off | 1 / 256 | 22,464 | 1,583 | OK |
| 128k | q4_0 | off | 1 / 256 | 22,248 | 1,799 | OK |
| 128k | q8_0 | off, **no MTP** | 1 / 256 | 22,196 | 1,851 | OK |
| 160k | q5_1 | off | 1 / 256 | 23,376 | 671 | OK, very tight |
| 192k | q5_1 | off | 1 / 256 | — | — | **OOM** |
| 256k | q4_0 | off | 1 / 256 | — | — | **OOM** |
| 64k | q8_0 | **on** | 1 / 256 | 22,680 | 1,367 | OK |
| 96k | q5_1 | **on** | 1 / 256 | 22,688 | 1,359 | OK |
| 128k | q5_1 | **on** | 1 / 256 | 23,600 | 447 | OK, too tight to rely on |

### Hard limits

- **160k is the ceiling** at `UD-Q4_K_XL`. 192k q5_1 and 256k q4_0 both OOM.
- **q8_0 KV does not fit at 128k.** q5_1 there is a constraint, not a preference.
- Model natively supports 262,144 context — unreachable on 24GB at this quant.

---

## 5. Blind alley: the vision profile was mis-measured

Worth recording because the *process* failure is more instructive than the number.

Vision was first measured early, with `-ub 512 -np 4`, giving 32k. The `-ub 256`
discovery came later and was applied only to the text profiles. Vision was never
re-measured, so "vision means 32k" got written into the docs as though it were a
property of vision.

It is not. Re-measured with `-ub 256`:

| | Context | VRAM | Free |
|---|---|---|---|
| Before (stale) | 32k | 22,786 | 1,261 |
| **After** | **96k** | 22,688 | 1,359 |

`mmproj` is 891 MiB ≈ 37k tokens at q5_1. The real cost of vision is **32k of
context** (128k → 96k), not the 4x penalty originally implied. Most of that
apparent gap was `-ub 512` vs `-ub 256`, which has nothing to do with vision.

**Lesson: when you find a global optimisation, re-run every prior measurement.
Stale numbers from before an optimisation look exactly like real constraints.**

---

## 6. Thinking mode silently eats `max_tokens`

Thinking is on by default and the reasoning block bills against `max_tokens`.
A too-small budget returns an **empty content string**, not an error:

```json
{"choices":[{"message":{"content":"","reasoning_content":"We need to..."},
             "finish_reason":"length"}]}
```

A bare "reply with OK" costs **~33 completion tokens**. This first showed up as a
smoke test that appeared to pass (server healthy, HTTP 200) while returning
nothing. The smoke test now uses `max_tokens: 256`.

**If you wire this to an agent, give it a generous `max_tokens`** or disable
thinking per-request. Symptoms of getting this wrong are empty responses and
`finish_reason: "length"` on trivial prompts.

---

## 7. Environment gotchas

**`sudo VAR=val cmd` does not work.** sudo treats `VAR=val` as the command name:

```
zsh: command not found: libcurl4-openssl-dev
```

Use `sudo env DEBIAN_FRONTEND=noninteractive apt-get ...`.

**CUDA 12.3 is sufficient.** No need to install 12.6+. `ggml-cuda/CMakeLists.txt`
only requires ≥12.8 for Blackwell (sm_120). Ada (sm_89) is fine on 12.x.

**cmake 3.22 (Ubuntu 22.04's) is sufficient**, but only because
`CMAKE_CUDA_ARCHITECTURES` is set explicitly. The native-arch autodetect path
needs cmake ≥3.24, which 22.04 does not ship.

**`llama-server` lives under `tools/`, not `examples/`.** Building with
`-DLLAMA_BUILD_EXAMPLES=OFF` alone is fine, but set `-DLLAMA_BUILD_TOOLS=ON`
explicitly so it cannot silently stop being built.

**`--help | grep -i cuda` is not a CUDA capability test.** Use
`llama-server --list-devices` and check for a `CUDA0` line.

**`rm -rf build` on every run** forces a ~10 min full rebuild. Removing only
`CMakeCache.txt` keeps object files warm; a stamp file of
`git-sha + build-options` decides when a rebuild is genuinely needed.

**`hf_transfer` does nothing unless enabled.** Installing the package is not
enough; export `HF_HUB_ENABLE_HF_TRANSFER=1`.

---

## 8. Extrapolated guidance for 16GB cards — NOT MEASURED

Everything above was measured. This section is **arithmetic only** — no 16GB card
was available. Treat as a starting point, not a result.

`UD-Q4_K_XL` (17,092 MiB) cannot fit on 16GB with any context. A smaller quant is
mandatory. Assume ~15,400 MiB usable after display.

| Quant | Weights | MTP | Est. context @ q5_1 |
|---|---|---|---|
| `UD-Q3_K_XL` | 12,817 MiB | on | ~32k |
| `UD-Q3_K_XL` | 12,817 MiB | **off** | ~96k |
| `UD-IQ3_XXS` | 11,358 MiB | on | ~64k |
| `UD-Q2_K_XL` | 9,948 MiB | on | ~128k |

```bash
QUANT=UD-Q3_K_XL ALLOW_LOW_VRAM=1 ./scripts/setup.sh
CTX=32768 KV_TYPE=q5_1 VISION=0 qwen38-27b-server
```

On 16GB, **dropping MTP is usually the right trade** — 1,602 MiB buys ~64k tokens
at q5_1, which generally beats a ~2x generation speedup. Keep vision **off**
below 24GB.

---

## 9. Reproducing these measurements

```bash
# 1. Does the repo ship an MTP head? (fastest check)
curl -s https://huggingface.co/v2/<org>/<repo>/manifests/<quant> | jq '.layers[].mediaType'

# 2. Read architecture from GGUF metadata without loading the model
#    (look for full_attention_interval, head_count_kv, key_length)

# 3. Probe a config: start, poll /health, record nvidia-smi, kill
llama-server -m "$MODEL" -ngl 99 -fa on -c "$CTX" \
  --cache-type-k "$KV" --cache-type-v "$KV" -np 1 -b 1024 -ub 256 \
  -md "$MTP" --spec-type draft-mtp --spec-draft-n-max 2 --spec-draft-ngl 99 &
until curl -sf http://127.0.0.1:8080/health; do sleep 1; done
nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader

# 4. Confirm MTP is actually live
grep 'draft acceptance' server.log

# 5. Benchmark a flag's cost
llama-bench -m "$MODEL" -ngl 99 -fa 1 -p 8192 -n 64 -ub 256,512 -r 2
```

**Always re-measure after changing a global flag.** Section 5 exists because that
step was skipped once.

---

## 10. Open questions

Not investigated; noted so nobody assumes they were.

- **`--spec-draft-n-max` is untuned.** Left at 2. Acceptance ranged 0.70–0.92,
  suggesting the draft is rarely wrong and could go deeper. 2 vs 4 vs 6 was never
  benchmarked.
- **q5_1 KV quality is unmeasured.** It fits and q8_0 does not; the cost to
  long-context retrieval — exactly where a coding agent lives — is unknown.
  `PROFILE=balanced` (96k, q8_0) is the conservative fallback.
- **Smaller quants unbenchmarked for quality.** `UD-Q3_K_XL` would free 4,275 MiB
  (~180k tokens at q5_1) but no quality comparison against `UD-Q4_K_XL` was run.
- **Prefill at large context unmeasured.** `llama-bench` was run at pp2048. The
  `-ub 256` penalty may differ at 100k+ prompts.
