# Qwen3.8-27B on a 24GB NVIDIA GPU (Ubuntu)

A one-command, re-runnable installer that puts **Qwen3.8-27B** on a 24GB NVIDIA
GPU as a local OpenAI-compatible API — with speculative decoding, optional
vision, and a **128k context window** tuned for coding agents.

```bash
git clone https://github.com/boxabirds/qwen-3.8-27b-nvidia-24GB-ubuntu.git
cd qwen-3.8-27b-nvidia-24GB-ubuntu
./scripts/setup.sh          # build + download + verify (~20 min first run)
qwen38-27b-server           # serve on 127.0.0.1:8080 with 128k context
```

Every performance and VRAM number in this repo was **measured on real hardware**,
not estimated. Where a figure is extrapolated, it says so.

---

## Who this is for

**You want this if you are:**

- Running **coding agents locally** and need a large context window — 128k on a
  single consumer GPU, enough to hold a real repository.
- Someone with **exactly this hardware**: a 24GB NVIDIA card (RTX 4090, 3090,
  4090D, A5000) on Ubuntu. The setup is deliberately narrow and refuses to run
  outside it rather than half-installing.
- Tired of **guessing at llama.cpp flags**. The tuning here is empirical: five
  measured profiles and a [discovery log](docs/discovery.md) showing every
  configuration tried, including the ones that OOM'd.
- Wanting **tool-calling and vision** from one local endpoint, without paying
  per token or sending code to a third party.

**You do not want this if:**

- Your GPU has **less than 24GB** — the script will refuse. It prints a quant
  table for 16GB cards, but those figures are extrapolated and unverified.
- You are on **Windows, macOS, or a non-Debian distro** — nothing here is
  portable. macOS users want plain llama.cpp with Metal.
- You need **multi-GPU, batch serving, or high concurrency** — this is a
  single-GPU, single-user setup. Look at vLLM or SGLang.
- You want to **fine-tune** — inference only.
- You need an **exposed or shared endpoint** — this binds to localhost with no
  authentication by design.

**Assumed knowledge:** comfortable with a terminal and `systemd`. You do *not*
need to know llama.cpp — the flags are chosen and explained for you.

---

## What this is for

Running a capable 27B model locally as an **agent backend** — the kind of
workload that needs a large context window, fast generation, and an
OpenAI-compatible endpoint you can point existing tooling at.

Concretely, it is tuned for:

- **Coding agents** that load large repository context (128k default)
- **Tool-calling agents** — `--jinja` is on, so tool-call parsing works
- **Multimodal work** — screenshots, UI debugging, diagrams (`PROFILE=vision`)
- **Always-on local inference** via a systemd user service

### What this is *not*

- Not a fine-tuning or training setup — inference only.
- Not multi-GPU. Single-GPU, all layers offloaded.
- Not a hosted/shared deployment. Binds to `127.0.0.1` with **no
  authentication**. Do not expose it without putting a proxy in front.
- Not portable beyond Ubuntu + NVIDIA CUDA. The script refuses to run elsewhere
  rather than half-installing (see [Requirements](#requirements)).

---

## Requirements

**Hard requirements — the script checks and refuses if unmet:**

| | Requirement | Bypass |
|---|---|---|
| OS | Ubuntu (22.04 validated) | `ALLOW_UNSUPPORTED_OS=1` |
| GPU | NVIDIA CUDA, **≥24GB VRAM** | `ALLOW_LOW_VRAM=1` |
| Driver | ≥550 (580 validated) | — |
| CUDA | 12.x toolkit (12.3 validated) | — |
| Disk | ~40 GB (20 GB models, ~2 GB build) | — |
| RAM | 16 GB+ | — |

Validated on: RTX 4090 24GB, Ubuntu 22.04.5, driver 580.159.03, CUDA 12.3.

**Existing installs are reused.** The script detects and upgrades rather than
reinstalling — your CUDA toolkit, Python, and `hf` CLI are left alone if usable.

### Under 24GB?

`UD-Q4_K_XL` is 17,092 MiB of weights and will not fit alongside a usable KV
cache on a 16GB card. The script refuses and prints a quant table. Short version:

```bash
QUANT=UD-Q3_K_XL ALLOW_LOW_VRAM=1 ./scripts/setup.sh
CTX=32768 KV_TYPE=q5_1 VISION=0 qwen38-27b-server
```

Those 16GB figures are **extrapolated, not measured** — see
[docs/discovery.md §8](docs/discovery.md).

---

## Install

```bash
git clone https://github.com/boxabirds/qwen-3.8-27b-nvidia-24GB-ubuntu.git
cd qwen-3.8-27b-nvidia-24GB-ubuntu
./scripts/setup.sh
```

The script is **idempotent** — re-running only upgrades what is outdated. It:

1. Qualifies OS, GPU, VRAM, driver, CUDA
2. Installs missing apt packages (falls back to pip `cmake`/`ninja` if no sudo)
3. Builds llama.cpp with CUDA for your GPU's arch (auto-detected)
4. Downloads the model, MTP head, and vision projector (~20 GB)
5. Generates the launcher and a systemd user unit
6. **Smoke-tests**: loads the model, generates, and asserts MTP is active

If `sudo` needs a password it will not hang — it tells you the one command to run
and continues with userspace fallbacks.

Skip the model load at the end with `SKIP_SMOKE_TEST=1`.

---

## Usage

```bash
qwen38-27b-server                 # coding profile: 128k context
qwen38-27b-server --help          # all profiles, with caveats
```

Then point any OpenAI client at `http://127.0.0.1:8080/v1`:

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Explain this repo"}],"max_tokens":2048}'
```

### Profiles

Select with `PROFILE=<name>`. **All VRAM figures measured on a 24GB RTX 4090.**

| Profile | Context | KV | Vision | VRAM | Free | Use for |
|---|---|---|---|---|---|---|
| **`coding`** *(default)* | 128k | q5_1 | — | 22,464 | 1,583 | Coding agents |
| `balanced` | 96k | q8_0 | — | 22,920 | 1,127 | Max KV fidelity |
| `vision` | 96k | q5_1 | ✓ | 22,688 | 1,359 | Images + long context |
| `vision-max` | 128k | q5_1 | ✓ | 23,600 | **448** ⚠ | Foreground only |
| `max` | 160k | q5_1 | — | 23,376 | **671** ⚠ | Foreground only |

⚠ Under ~700 MiB of headroom. These load and serve, but a browser tab or a second
CUDA process will OOM them mid-run. **Do not point systemd at these.**

### Overrides

Any profile value can be overridden:

```bash
PORT=8081 qwen38-27b-server                        # different port
CTX=65536 KV_TYPE=q8_0 qwen38-27b-server           # hand-tuned
VISION=1 qwen38-27b-server                         # vision on any profile
HOST=0.0.0.0 qwen38-27b-server                     # expose on LAN (see Security)
qwen38-27b-server --spec-draft-n-max 4             # passthrough to llama-server
```

| Variable | Default | Meaning |
|---|---|---|
| `PROFILE` | `coding` | Profile name |
| `PORT` / `HOST` | `8080` / `127.0.0.1` | Bind address |
| `CTX` | per profile | Context window in tokens |
| `KV_TYPE` | per profile | `q8_0` \| `q5_1` \| `q4_0` |
| `VISION` | per profile | `0` \| `1` |
| `NP` / `UB` | `1` / `256` | Parallel slots / micro-batch |

Unrecognised arguments pass straight through to `llama-server`.

### Connecting a coding agent

The server speaks the OpenAI API at `http://127.0.0.1:8080/v1` and advertises a
stable model id of **`qwen3.8-27b`** (override with `MODEL_ALIAS=`). Any
OpenAI-compatible client works; two good terminal agents:

#### Pi ([pi.dev](https://pi.dev))

Minimal, MIT-licensed, and it has **built-in llama.cpp support**.

```bash
npm install -g @earendil-works/pi-coding-agent
```

Add to `~/.pi/agent/models.json`:

```json
{
  "providers": {
    "qwen38-local": {
      "baseUrl": "http://127.0.0.1:8080/v1",
      "api": "openai-completions",
      "apiKey": "local",
      "models": [
        {
          "id": "qwen3.8-27b",
          "name": "Qwen3.8-27B (local)",
          "input": ["text"],
          "contextWindow": 131072,
          "maxTokens": 32768,
          "reasoning": true
        }
      ]
    }
  }
}
```

Then `pi` and pick the model with `/model`. `apiKey` is required but ignored —
any placeholder works.

#### OpenCode ([opencode.ai](https://opencode.ai))

Create `opencode.json` in your project (or `~/.config/opencode/`):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "qwen38-local": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Qwen3.8-27B (local)",
      "options": { "baseURL": "http://127.0.0.1:8080/v1" },
      "models": {
        "qwen3.8-27b": {
          "name": "Qwen3.8-27B (local)",
          "limit": { "context": 131072, "output": 32768 }
        }
      }
    }
  }
}
```

The model key **must** match what `/v1/models` returns — `qwen3.8-27b`.

#### Anything else

```bash
export OPENAI_BASE_URL=http://127.0.0.1:8080/v1
export OPENAI_API_KEY=local          # required by most clients, ignored here
```

Works with the OpenAI Python/JS SDKs, Aider, Continue, Cline, LangChain, and
similar. Point them at the base URL and use model `qwen3.8-27b`.

> **Set a generous output limit.** Thinking mode bills reasoning against
> `max_tokens`; too small a budget returns empty content. See
> [Thinking mode](#thinking-mode-consumes-max_tokens).

### Run as a service

```bash
systemctl --user enable --now qwen38-27b
journalctl --user -u qwen38-27b -f
```

Uses the default `coding` profile. To change it, add
`Environment=PROFILE=vision` to `~/.config/systemd/user/qwen38-27b.service`.

---

## Important behaviours

### Thinking mode consumes `max_tokens`

Thinking is **on by default** and the reasoning block bills against
`max_tokens`. Too small a budget returns an **empty `content`** with
`finish_reason: "length"` — not an error. A bare "reply OK" costs ~33 tokens.

**Give agents a generous `max_tokens`.** Reasoning is returned separately in
`reasoning_content`.

### Speculative decoding (MTP)

Enabled by default and roughly doubles generation speed. Measured **0.70–0.92
draft acceptance**; ~92 tok/s generation with it, ~44 without.

The MTP head comes from `ggml-org/Qwen3.8-27B-GGUF` because **Unsloth ships none
for Qwen3.8**. Mixing the two repos is deliberate and verified. If speculative
decoding ever appears inactive, check for `draft acceptance` in the server log —
llama.cpp starts happily with it silently disabled.

### Security

Binds to `127.0.0.1` with **no authentication**. `HOST=0.0.0.0` exposes an
unauthenticated model server to your entire network. Put a reverse proxy with
auth in front if you need remote access.

---

## Performance

RTX 4090, `UD-Q4_K_XL`, `coding` profile:

| Metric | Value |
|---|---|
| Generation (MTP on) | ~92 tok/s |
| Generation (MTP off) | ~44 tok/s |
| Prefill (pp2048, `-ub 256`) | ~2700 tok/s |
| Prefill (pp2048, `-ub 512`) | ~2915 tok/s |
| Model load (warm cache) | ~4 s |
| VRAM | 22,464 MiB |

---

## Layout

```
scripts/setup.sh    installer (idempotent, self-verifying)
scripts/setup.log   run log
docs/discovery.md   measurements, blind alleys, methodology
README.md           this file

~/.local/share/qwen38-27b/          llama.cpp source + build, models
~/.local/bin/qwen38-27b-server      generated launcher
~/.local/bin/llama-server           symlink to the build
~/.config/systemd/user/qwen38-27b.service
```

---

## Troubleshooting

**CUDA OOM on startup** — something else is using the GPU. The launcher
pre-flights this and names the offending processes. Check `nvidia-smi`, or drop
to `PROFILE=balanced`.

**Empty responses** — `max_tokens` too small; the reasoning block consumed it.
See [Thinking mode](#thinking-mode-consumes-max_tokens).

**Generation feels slow** — MTP may be inactive. Look for `draft acceptance` in
the log; absent means speculative decoding is off.

**`sudo: command not found: <package>`** — a shell mangled a `&&` chain. Run the
`apt-get install` line on its own.

**Rebuild from scratch** — `rm -rf ~/.local/share/qwen38-27b/llama.cpp/build`
then re-run `setup.sh`. Models are cached separately and will not re-download.

**Want more context than 160k?** Not possible at this quant on 24GB. Use a
smaller one (`QUANT=UD-Q3_K_XL`); each GiB freed buys ~43k tokens at q5_1.

---

## License

This repository is Apache 2.0 (see [LICENSE](LICENSE)).

The model weights are licensed separately by their publishers — Qwen3.8-27B is
Apache 2.0 per the [Qwen model card](https://huggingface.co/Qwen/Qwen3.8-27B),
and llama.cpp is MIT. This repo contains no weights; `setup.sh` downloads them
from Hugging Face at install time.

---

## Further reading

**[docs/discovery.md](docs/discovery.md)** — the full investigation: why only 16
of 65 layers hold a KV cache, why `-ub 256` matters more than any KV setting, the
complete measurement table with every OOM, the mis-measurement that made vision
look 4x more expensive than it is, and reproduction steps.

Read it before changing quant, context, or speculative-decoding settings.
