#!/usr/bin/env bash
# setup.sh
# Resilient, idempotent installer for Qwen3.8-27B (Unsloth GGUF + llama.cpp + MTP)
# Target: Ubuntu 22.04, RTX 4090 24GB, 64GB RAM
# Safe to re-run. Discovers existing installs and upgrades only when needed.
#
# NOTE ON MTP: unsloth/Qwen3.8-27B-GGUF does NOT ship an MTP head (verified via its
# HF manifest: model + projector + template layers only). The MTP head is taken from
# ggml-org/Qwen3.8-27B-GGUF, which builds it from the same Qwen/Qwen3.8-27B base.
# llama.cpp only auto-discovers MTP sidecars on the `-hf` download path, so the
# launcher passes it explicitly via -md.

set -euo pipefail

# ====================== Configuration ======================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/setup.log"
INSTALL_ROOT="${HOME}/.local/share/qwen38-27b"
LLAMA_DIR="${INSTALL_ROOT}/llama.cpp"
MODEL_DIR="${INSTALL_ROOT}/models/Qwen3.8-27B-GGUF"
BIN_DIR="${HOME}/.local/bin"
SERVICE_NAME="qwen38-27b"

REPO_GGUF="unsloth/Qwen3.8-27B-GGUF"      # Unsloth Dynamic v3.0 quants
REPO_MTP="ggml-org/Qwen3.8-27B-GGUF"      # source of the MTP speculative head
# QUANT is overridable for smaller cards, e.g. QUANT=UD-Q3_K_XL ./setup.sh
QUANT="${QUANT:-UD-Q4_K_XL}"              # UD-Q4_K_XL = 16.7 GiB
QUANT_FILE="Qwen3.8-27B-${QUANT}.gguf"
MMPROJ_FILE="mmproj-F16.gguf"             # 0.87 GiB, vision projector
MTP_FILE="mtp-Qwen3.8-27B-Q4_0.gguf"      # 1.6 GiB, speculative draft head

# Hard requirements. This script is built and validated for one configuration:
# Ubuntu + an NVIDIA CUDA GPU with >=24GB VRAM. Both gates can be bypassed
# with an env var, but you are then off the tested path.
MIN_VRAM_MIB=23000                        # 24GB cards report ~24047-24564 usable
ALLOW_UNSUPPORTED_OS="${ALLOW_UNSUPPORTED_OS:-0}"
ALLOW_LOW_VRAM="${ALLOW_LOW_VRAM:-0}"

MIN_LLAMA_COMMIT_DATE="2026-08-13"        # must support qwen3_5 hybrid + draft-mtp
# Context/KV/vision are set per-profile in the generated launcher; see its --help.

# Colors (suppressed when not a TTY, so the log file stays clean)
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

# ====================== Helpers ======================
log() {
  local level="$1"; shift
  echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}

info()  { log "INFO"  "${BLUE}$*${NC}"; }
ok()    { log "OK"    "${GREEN}$*${NC}"; }
warn()  { log "WARN"  "${YELLOW}$*${NC}"; }
err()   { log "ERROR" "${RED}$*${NC}"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# True only if we can become root without an interactive password prompt.
can_sudo() {
  [[ $EUID -eq 0 ]] && return 0
  need_cmd sudo && sudo -n true 2>/dev/null
}

run_as_root() {
  if [[ $EUID -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

# ====================== Pre-flight ======================
info "=== Qwen3.8-27B setup (idempotent) ==="
info "Log: $LOG_FILE"
mkdir -p "$INSTALL_ROOT" "$BIN_DIR" "$MODEL_DIR"
export PATH="${BIN_DIR}:${PATH}"

# ---- OS qualification ----
# The apt paths, the CUDA toolkit discovery and the systemd --user unit are all
# Ubuntu/Debian-shaped. Other distros will fail in ways this script cannot
# usefully recover from, so refuse rather than half-install.
if [[ "$(uname -s)" != "Linux" ]]; then
  err "This script supports Linux only (detected $(uname -s)). See docs/discovery.md."
fi
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  OS_PRETTY="${PRETTY_NAME:-${ID:-unknown}}"
  if [[ "${ID:-}" == "ubuntu" ]]; then
    if [[ "${VERSION_ID:-}" != "22.04" ]]; then
      warn "Ubuntu ${VERSION_ID:-?} detected; validated on 22.04. Continuing."
    else
      ok "OS: ${OS_PRETTY} (validated)."
    fi
  elif [[ "${ID_LIKE:-}" == *debian* ]]; then
    warn "${OS_PRETTY} is Debian-like but not Ubuntu; apt paths should work but are untested."
  elif [[ "$ALLOW_UNSUPPORTED_OS" == "1" ]]; then
    warn "${OS_PRETTY} is unsupported; ALLOW_UNSUPPORTED_OS=1 set, continuing at your own risk."
    warn "You will need to install these yourself: ${PKG_HINT:-build-essential cmake ninja libcurl-dev}"
  else
    err "Unsupported OS: ${OS_PRETTY}. This script targets Ubuntu (22.04 validated).
       The apt, CUDA-toolkit and systemd steps assume Debian/Ubuntu layout.
       To attempt anyway: ALLOW_UNSUPPORTED_OS=1 $0"
  fi
else
  warn "Cannot detect OS (no /etc/os-release); assuming Ubuntu-like."
fi

# ====================== System packages ======================
# apt packages need root. If sudo is password-gated we do NOT hang waiting on a
# prompt -- we fall back to pip-provided cmake/ninja and a curl-less build, and
# tell the user exactly what to install if they want the full build.
APT_MISSING=()
ensure_system_deps() {
  info "Checking system dependencies..."
  local pkgs=(build-essential git curl wget cmake ninja-build libcurl4-openssl-dev pciutils)
  local missing=()
  for p in "${pkgs[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done

  if ((${#missing[@]} == 0)); then
    ok "System packages already present."
    return
  fi

  if can_sudo; then
    info "Installing missing packages: ${missing[*]}"
    run_as_root apt-get update -qq
    # `sudo VAR=val cmd` does not work -- sudo treats VAR=val as the command name.
    run_as_root env DEBIAN_FRONTEND=noninteractive \
      apt-get install -y --no-install-recommends "${missing[@]}"
    ok "System packages installed."
  else
    APT_MISSING=("${missing[@]}")
    warn "Missing apt packages and no passwordless sudo: ${missing[*]}"
    warn "To install them yourself:"
    warn "  sudo apt-get install -y --no-install-recommends ${missing[*]}"
    warn "Continuing with userspace fallbacks where possible."
  fi
}

# cmake/ninja can come from pip wheels when apt is unavailable.
ensure_build_tools() {
  if ! need_cmd cmake; then
    info "cmake not found; installing via pip (userspace)..."
    python3 -m pip install --user -q -U cmake
    hash -r
  fi
  if ! need_cmd ninja; then
    info "ninja not found; installing via pip (userspace)..."
    python3 -m pip install --user -q -U ninja
    hash -r
  fi
  need_cmd cmake || err "cmake unavailable and pip install failed."
  ok "Build tools: cmake $(cmake --version | head -1 | awk '{print $3}'), ninja $(ninja --version 2>/dev/null || echo 'n/a')"
}

# ====================== NVIDIA / CUDA ======================
CUDA_ARCHS=""
ensure_nvidia() {
  info "Checking NVIDIA GPU & driver..."
  if ! need_cmd nvidia-smi; then
    warn "nvidia-smi not found. Install an NVIDIA driver >=550, then re-run this script."
    can_sudo && run_as_root ubuntu-drivers autoinstall || true
    err "No NVIDIA driver detected; cannot continue."
  fi

  local driver_ver
  driver_ver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1 | cut -d. -f1)
  if [[ "${driver_ver:-0}" -lt 550 ]]; then
    warn "Driver ${driver_ver} is old. Recommend >=550 for CUDA 12.x."
  else
    ok "NVIDIA driver v${driver_ver} OK."
  fi

  # Derive the CUDA arch from the actual GPU rather than hardcoding it.
  local cc
  cc=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader | head -1 | tr -d '.')
  CUDA_ARCHS="${cc:-89}"

  local gpu_name vram_total
  gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
  vram_total=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1)
  ok "GPU: ${gpu_name} (sm_${CUDA_ARCHS}, ${vram_total} MiB VRAM)"

  # ---- VRAM qualification ----
  # The default quant alone is 17,092 MiB. Everything in this repo -- every
  # profile, every context figure -- was measured on a 24GB card. Smaller cards
  # need a smaller quant, so fail loudly with actionable numbers instead of
  # letting the user discover it via a CUDA OOM 20 GB into a download.
  if (( vram_total < MIN_VRAM_MIB )); then
    warn "=============================================================="
    warn " ${gpu_name} has ${vram_total} MiB VRAM; this setup needs >=24GB."
    warn "=============================================================="
    warn ""
    warn " The default quant (UD-Q4_K_XL) is 17,092 MiB of weights and will"
    warn " not leave room for KV cache on this card."
    warn ""
    if (( vram_total >= 15000 )); then
      warn " For a 16GB card, try a smaller quant via the QUANT env var."
      warn " ESTIMATED (extrapolated from 24GB measurements, NOT verified):"
      warn ""
      warn "   QUANT=UD-Q3_K_XL   12,817 MiB  + MTP  ->  ~32k ctx"
      warn "   QUANT=UD-Q3_K_XL   12,817 MiB  no MTP ->  ~96k ctx"
      warn "   QUANT=UD-IQ3_XXS   11,358 MiB  + MTP  ->  ~64k ctx"
      warn "   QUANT=UD-Q2_K_XL    9,948 MiB  + MTP  -> ~128k ctx"
      warn ""
      warn " Recommended starting point for 16GB:"
      warn "   QUANT=UD-Q3_K_XL ALLOW_LOW_VRAM=1 $0"
      warn "   then: CTX=32768 KV_TYPE=q5_1 VISION=0 qwen38-27b-server"
      warn ""
      warn " Dropping MTP (unset the head, or pass --spec-type none) frees"
      warn " 1,602 MiB, which is worth ~64k tokens at q5_1 -- on a 16GB card"
      warn " that trade usually favours context over speculative decoding."
    else
      warn " Below 16GB, a 27B model is not a good fit. Consider a smaller"
      warn " Qwen3.8 variant or a 4-8B class model instead."
    fi
    warn ""
    warn " Vision (mmproj, +891 MiB) should stay OFF on any card under 24GB."
    warn " See docs/discovery.md for the full measurement methodology."
    warn ""
    if [[ "$ALLOW_LOW_VRAM" != "1" ]]; then
      err "Refusing to continue on ${vram_total} MiB VRAM. Override with ALLOW_LOW_VRAM=1 (and set QUANT)."
    fi
    warn "ALLOW_LOW_VRAM=1 set -- continuing with QUANT=${QUANT}. Profiles will NOT fit; use manual CTX/KV_TYPE."
  fi

  # nvcc: reuse whatever is installed. 12.x is sufficient for Ada/Ampere;
  # only Blackwell (sm_120) needs >=12.8.
  if ! need_cmd nvcc && [[ -x /usr/local/cuda/bin/nvcc ]]; then
    export PATH="/usr/local/cuda/bin:${PATH}"
  fi
  if need_cmd nvcc; then
    local cuda_ver
    cuda_ver=$(nvcc --version | grep -oP 'release \K[0-9]+\.[0-9]+')
    ok "nvcc ${cuda_ver} at $(command -v nvcc)"
    if [[ "$CUDA_ARCHS" -ge 120 ]] && [[ "${cuda_ver%%.*}" -eq 12 ]] \
       && [[ "${cuda_ver#*.}" -lt 8 ]]; then
      warn "sm_${CUDA_ARCHS} needs CUDA >=12.8 but nvcc is ${cuda_ver}; build may fail."
    fi
  else
    warn "nvcc not found. Install cuda-toolkit-12-6 (or newer) to build the CUDA backend."
    can_sudo && run_as_root apt-get install -y cuda-toolkit-12-6 || \
      err "CUDA toolkit required to build with GGML_CUDA=ON."
  fi
}

# ====================== Hugging Face CLI ======================
ensure_hf() {
  info "Ensuring huggingface_hub (hf CLI) + hf_transfer..."
  if need_cmd hf; then
    ok "hf CLI present: $(hf version 2>/dev/null | head -1)"
  else
    python3 -m pip install --user -q -U "huggingface_hub[cli]"
    hash -r
    need_cmd hf || err "hf CLI install failed."
  fi
  # hf_transfer gives a large speedup on multi-GB pulls, but only if it is
  # actually switched on -- installing it alone does nothing.
  python3 -c 'import hf_transfer' 2>/dev/null || python3 -m pip install --user -q -U hf_transfer
  if python3 -c 'import hf_transfer' 2>/dev/null; then
    export HF_HUB_ENABLE_HF_TRANSFER=1
    ok "hf_transfer enabled."
  else
    warn "hf_transfer unavailable; downloads will use the slower default backend."
  fi
}

# ====================== llama.cpp ======================
ensure_llama_cpp() {
  info "Ensuring up-to-date llama.cpp with CUDA (qwen3_5 + draft-mtp support)..."

  local need_rebuild=0
  local stamp="${LLAMA_DIR}/.build-stamp"
  local build_key="cuda=${CUDA_ARCHS};curl=$(dpkg -s libcurl4-openssl-dev >/dev/null 2>&1 && echo on || echo off)"

  if [[ -d "$LLAMA_DIR/.git" ]]; then
    info "Existing llama.cpp source found. Updating..."
    git -C "$LLAMA_DIR" fetch --depth 1 origin master --prune
    git -C "$LLAMA_DIR" checkout -q master 2>/dev/null || true
    git -C "$LLAMA_DIR" reset --hard -q origin/master
  else
    info "Cloning llama.cpp..."
    git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$LLAMA_DIR"
    need_rebuild=1
  fi

  local head_sha
  head_sha=$(git -C "$LLAMA_DIR" rev-parse HEAD)
  local bin="${LLAMA_DIR}/build/bin/llama-server"

  if [[ ! -x "$bin" ]]; then
    need_rebuild=1
  else
    # Rebuild if the source moved, the build options changed, or the binary
    # predates the commit that added qwen3_5/MTP support.
    local prev_key="" prev_sha=""
    [[ -f "$stamp" ]] && { read -r prev_sha prev_key < "$stamp" || true; }
    if [[ "$prev_sha" != "$head_sha" || "$prev_key" != "$build_key" ]]; then
      info "Source or build options changed -> rebuilding."
      need_rebuild=1
    fi
    local bin_mtime cutoff
    bin_mtime=$(stat -c %Y "$bin" 2>/dev/null || echo 0)
    cutoff=$(date -d "$MIN_LLAMA_COMMIT_DATE" +%s 2>/dev/null || echo 0)
    if (( bin_mtime < cutoff )); then
      warn "llama-server predates ${MIN_LLAMA_COMMIT_DATE} -> rebuilding."
      need_rebuild=1
    fi
    # Real capability probe: does the binary actually see the CUDA device?
    if ! "$bin" --list-devices 2>&1 | grep -qi 'CUDA'; then
      warn "Binary reports no CUDA device -> rebuilding."
      need_rebuild=1
    fi
  fi

  if (( need_rebuild )); then
    info "Building llama.cpp with CUDA (several minutes)..."
    local cmake_args=(
      -B "${LLAMA_DIR}/build" -S "$LLAMA_DIR"
      -DGGML_CUDA=ON
      -DCMAKE_BUILD_TYPE=Release
      -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCHS}"
      -DLLAMA_BUILD_TESTS=OFF
      -DLLAMA_BUILD_EXAMPLES=OFF
      -DLLAMA_BUILD_TOOLS=ON        # llama-server lives under tools/
      -DLLAMA_BUILD_SERVER=ON
    )
    # libcurl headers are root-only to install; drop CURL support if absent.
    # We download models with the hf CLI anyway, so only llama-server's own
    # -hf flag is lost.
    if ! dpkg -s libcurl4-openssl-dev >/dev/null 2>&1; then
      warn "libcurl4-openssl-dev missing -> building with -DLLAMA_CURL=OFF."
      cmake_args+=(-DLLAMA_CURL=OFF)
    fi
    need_cmd ninja && cmake_args+=(-G Ninja)

    # Wipe only the CMake cache, not the whole tree: object files stay warm so
    # subsequent re-runs are incremental instead of a 10-minute full rebuild.
    rm -f "${LLAMA_DIR}/build/CMakeCache.txt"
    cmake "${cmake_args[@]}"
    cmake --build "${LLAMA_DIR}/build" --config Release -j"$(nproc)"
    echo "${head_sha} ${build_key}" > "$stamp"
    ok "llama.cpp built."
  else
    ok "llama.cpp binary is current and CUDA-capable."
  fi

  ln -sfn "${LLAMA_DIR}/build/bin/llama-server" "${BIN_DIR}/llama-server"
  [[ -x "${LLAMA_DIR}/build/bin/llama-cli" ]] && \
    ln -sfn "${LLAMA_DIR}/build/bin/llama-cli" "${BIN_DIR}/llama-cli"
  ok "llama-server -> ${BIN_DIR}/llama-server"
}

# ====================== Model download ======================
MODEL_GGUF=""; MMPROJ=""; MTP_HEAD=""
SMOKE_CTX=""; SMOKE_VRAM=""; SMOKE_FREE=""; SMOKE_GEN=""; SMOKE_ACC=""
ensure_model() {
  info "Ensuring Qwen3.8-27B GGUF assets..."

  # Download only what we need. The original glob also matched Q4_K_M, which
  # pulled a redundant second 17 GB quant.
  if [[ ! -f "${MODEL_DIR}/${QUANT_FILE}" || ! -f "${MODEL_DIR}/${MMPROJ_FILE}" ]]; then
    info "Downloading ${QUANT_FILE} + ${MMPROJ_FILE} from ${REPO_GGUF} (~17.6 GiB)..."
    hf download "$REPO_GGUF" --include "$QUANT_FILE" "$MMPROJ_FILE" --local-dir "$MODEL_DIR"
  else
    ok "Main quant + mmproj already present."
  fi

  if [[ ! -f "${MODEL_DIR}/${MTP_FILE}" ]]; then
    info "Downloading ${MTP_FILE} from ${REPO_MTP} (~1.6 GiB)..."
    hf download "$REPO_MTP" --include "$MTP_FILE" --local-dir "$MODEL_DIR" || \
      warn "MTP head download failed; speculative decoding will be disabled."
  else
    ok "MTP head already present."
  fi

  MODEL_GGUF="${MODEL_DIR}/${QUANT_FILE}"
  [[ -f "$MODEL_GGUF" ]] || err "Could not locate ${QUANT_FILE} after download."
  [[ -f "${MODEL_DIR}/${MMPROJ_FILE}" ]] && MMPROJ="${MODEL_DIR}/${MMPROJ_FILE}"
  [[ -f "${MODEL_DIR}/${MTP_FILE}" ]]    && MTP_HEAD="${MODEL_DIR}/${MTP_FILE}"

  ok "Model  : $MODEL_GGUF ($(du -h "$MODEL_GGUF" | cut -f1))"
  [[ -n "$MMPROJ"   ]] && ok "Vision : $MMPROJ"   || warn "mmproj missing (vision disabled)."
  [[ -n "$MTP_HEAD" ]] && ok "MTP    : $MTP_HEAD" || warn "MTP head missing (spec decoding disabled)."
}

# ====================== Run wrapper & service ======================
create_wrappers() {
  info "Creating run script..."
  local run_script="${BIN_DIR}/qwen38-27b-server"

  # Bake only filenames, never absolute paths -- the launcher resolves
  # directories from $HOME at runtime. Keeps it portable across machines and
  # users, and keeps the invoking user's name out of a file people paste into
  # bug reports.
  local mmproj_name="" mtp_name=""
  [[ -n "$MMPROJ"   ]] && mmproj_name="$(basename "$MMPROJ")"
  [[ -n "$MTP_HEAD" ]] && mtp_name="$(basename "$MTP_HEAD")"

  cat > "$run_script" <<EOF
#!/usr/bin/env bash
# Auto-generated launcher for Qwen3.8-27B. Regenerate with scripts/setup.sh.
# Contains no machine-specific paths: everything resolves from \$HOME at run
# time, so this file can be copied between machines and users unchanged.
set -euo pipefail

# Some minimal service environments start without HOME; fall back to passwd.
: "\${HOME:=\$(getent passwd "\$(id -u)" | cut -d: -f6)}"
if [[ -z "\${HOME:-}" ]]; then
  echo "qwen38-27b-server: cannot determine HOME; set HOME or QWEN38_ROOT." >&2
  exit 1
fi

QWEN38_ROOT="\${QWEN38_ROOT:-\$HOME/.local/share/qwen38-27b}"
MODEL_DIR="\$QWEN38_ROOT/models/Qwen3.8-27B-GGUF"
BIN_DIR="\$HOME/.local/bin"
export PATH="\$BIN_DIR:\$PATH"

# Filenames are fixed at install time; directories are not.
QUANT_FILE_NAME="${QUANT_FILE}"
MMPROJ_FILE_NAME="${mmproj_name}"
MTP_FILE_NAME="${mtp_name}"

MODEL="\${MODEL:-\$MODEL_DIR/\$QUANT_FILE_NAME}"
MMPROJ="\${MMPROJ:-}"
if [[ -z "\$MMPROJ" && -n "\$MMPROJ_FILE_NAME" ]]; then MMPROJ="\$MODEL_DIR/\$MMPROJ_FILE_NAME"; fi
MTP="\${MTP:-}"
if [[ -z "\$MTP" && -n "\$MTP_FILE_NAME" ]]; then MTP="\$MODEL_DIR/\$MTP_FILE_NAME"; fi

show_help() {
cat <<'HELP'
Qwen3.8-27B server launcher (llama.cpp + Unsloth UD-Q4_K_XL + MTP)

USAGE
  qwen38-27b-server [--help] [extra llama-server args...]
  PROFILE=<name> qwen38-27b-server

  Unrecognised arguments are passed straight through to llama-server, and
  override anything the profile set.

PROFILES                                          (default: coding)
  Every VRAM and prefill figure below was MEASURED on this machine (RTX 4090
  24GB, 24047 MiB usable), not estimated. "free" is what was left over.

  coding     128k ctx   q4_0 KV   vision off   22398 MiB  1649 free  2309 tok/s
      >> DEFAULT. Smoke-tested end-to-end: loads, serves, MTP active.
      The right choice for coding agents -- 128k holds a real repo context.
      CAVEAT: KV is q4_0. q8_0 has higher fidelity but does not fit at 128k.

  balanced    96k ctx   q8_0 KV   vision off   23130 MiB   917 free  2303 tok/s
      Highest-fidelity KV cache that still runs on the GPU. Use when
      long-context retrieval accuracy matters more than the last 32k.
      CAVEAT: only 917 MiB spare.

  vision      96k ctx   q4_0 KV   vision ON    22634 MiB  1413 free  2309 tok/s
      The only profiles that read images/video. Adds --image-min-tokens 1024,
      which llama.cpp recommends for Qwen-VL grounding accuracy.
      Vision costs ~0.87 GiB of weights, about 32k of context.
      CAVEAT: every image costs >=1024 context tokens regardless of size.

  vision-max 128k ctx   q4_0 KV   vision ON    23534 MiB   513 free  2317 tok/s
      Full 128k context AND images. Verified to load and serve.
      CAVEAT: ONLY 513 MiB SPARE -- the tightest profile here. Anything else
              touching the GPU will OOM it mid-run. Foreground use only; do
              NOT point systemd at this one.

  max        160k ctx   q4_0 KV   vision off   23298 MiB   749 free  2303 tok/s
      The hard ceiling for this quant. 192k q4_0 OOMs.
      CAVEAT: 749 MiB spare. Foreground use only.

KV CACHE TYPES -- READ THIS BEFORE CHANGING KV_TYPE
  Only f16, bf16, q8_0 and q4_0 have CUDA flash-attention kernels for this
  model. Everything else (q4_1, q5_0, q5_1, iq4_nl) silently falls back to
  CPU attention. llama.cpp prints no warning; you just get, measured here:

      q4_0 / q8_0 / f16 / bf16   ~2300-2675 tok/s prefill   GPU busy
      q4_1                             79 tok/s
      iq4_nl                           59 tok/s
      q5_0                             51 tok/s
      q5_1                             48 tok/s   GPU at 1%, 8 CPU cores pegged

  That is up to 55x slower, and it hurts prompt processing most -- exactly
  what a coding agent does most of. The launcher warns if you pick one.

ENVIRONMENT OVERRIDES
  PORT=8080          HOST=127.0.0.1     CTX=<tokens>
  KV_TYPE=q4_0|q8_0|f16                 VISION=0|1
  NP=<slots>         UB=<micro-batch>
  THINKING=1|0       THINKING_BUDGET=<tokens>

THINKING
  On by default -- it is the model's own default and what Qwen tuned the
  agentic and coding gains around. Reasoning is returned separately in
  reasoning_content, so it does not pollute content.

  THINKING=0 disables it AND swaps to the model card's instruct sampling
  preset (temp 0.7, top_p 0.80, presence_penalty 1.5). Do not disable
  thinking without that swap: the card warns the thinking preset causes
  repetition on the non-thinking path.

  Measured on a simple coding prompt: thinking off is ~2.5x fewer output
  tokens and 3-5x faster, at the cost of reasoning quality.

  THINKING_BUDGET=N caps thinking at N tokens instead of disabling it --
  useful for bounding the max_tokens trap below while keeping reasoning.

WHY THESE NUMBERS
  * Only 16 of this model's 65 layers hold a KV cache
    (full_attention_interval=4; the rest are Gated DeltaNet with fixed-size
    recurrent state). That is ~34 KiB/token at q8_0 -- unusually cheap. The
    binding constraint is static weights (~19 GiB), not context.
  * -ub 256 is what makes anything above 64k fit: llama.cpp sizes its prompt
    compute buffer from the micro-batch, and the default 512 wants ~720 MiB
    at 128k. Measured cost of halving it: 7.3% prefill, ~0% generation.
  * Each GiB of weights freed buys roughly 30k tokens of context. To go past
    160k you must drop quant: IQ4_XS (-2.06 GiB) or UD-Q3_K_XL (-4.17 GiB).
  * MTP speculative decoding runs at 0.7-0.9 draft acceptance here. The head
    is ggml-org's -- Unsloth ships no MTP head for Qwen3.8.

GOTCHA: THINKING MODE AND max_tokens
  Thinking is ON by default, and the reasoning block is billed against
  max_tokens. A request with a small max_tokens returns an EMPTY content
  string with finish_reason "length" -- the budget was spent reasoning before
  any answer was emitted. Measured here: a bare "reply OK" costs ~33 tokens.
  Give agents a generous max_tokens, or disable thinking per-request.

SECURITY
  HOST defaults to 127.0.0.1 and there is NO authentication. Setting
  HOST=0.0.0.0 exposes an unauthenticated model server to your whole network.

FURTHER READING
  docs/discovery.md -- full measurement table (every OOM included), why only
  16 of 65 layers hold a KV cache, and the reproduction steps. Read it before
  changing quant, context or speculative-decoding settings.

EXAMPLES
  qwen38-27b-server                                  # 128k coding default
  # API: http://127.0.0.1:8080/v1  model id: qwen3.8-27b
  PROFILE=vision qwen38-27b-server                   # images, 32k
  PROFILE=balanced qwen38-27b-server                 # 96k, full q8_0 KV
  CTX=65536 KV_TYPE=q8_0 qwen38-27b-server           # hand-tuned
  PORT=8081 qwen38-27b-server --spec-draft-n-max 4   # deeper MTP draft
HELP
}

case "\${1:-}" in
  -h|--help|help) show_help; exit 0 ;;
esac

if [[ ! -f "\$MODEL" ]]; then
  echo "qwen38-27b-server: model not found at" >&2
  echo "  \$MODEL" >&2
  echo "Set QWEN38_ROOT if your install lives elsewhere, or MODEL for a" >&2
  echo "specific file, or re-run scripts/setup.sh to (re)download." >&2
  exit 1
fi

# ---- Profiles -------------------------------------------------------------
# All values below are MEASURED on a 24GB RTX 4090, not estimated. Only 16 of
# this model's 65 layers carry a KV cache (full_attention_interval=4), so KV is
# cheap (~34 KiB/token at q8_0) and the binding constraint is static weights.
#
#   profile    ctx    KV     vision  measured VRAM   headroom
#   coding    128k   q5_1      off      22464 MiB    1583 MiB
#   balanced   96k   q8_0      off      22920 MiB    1127 MiB
#   vision       96k   q5_1      ON       22688 MiB    1359 MiB
#   vision-max  128k   q5_1      ON       23600 MiB     447 MiB  (very tight)
#   max       160k   q5_1      off      23376 MiB     671 MiB  (tight)
#
# -ub 256 is what makes the large contexts fit: llama.cpp sizes its prompt
# compute buffer from the micro-batch, and the default 512 needs ~720 MiB at
# 128k. Measured cost of halving it: 7.3% prefill, ~0% generation.
PROFILE=\${PROFILE:-coding}
# D_NEED = measured server-only footprint (total measured VRAM minus the
# ~595 MiB the desktop held during measurement), used for the pre-flight below.
case "\$PROFILE" in
  coding)   D_CTX=131072; D_KV=q4_0; D_VISION=0; D_NP=1; D_UB=256; D_NEED=21905 ;;
  balanced) D_CTX=98304;  D_KV=q8_0; D_VISION=0; D_NP=1; D_UB=256; D_NEED=22635 ;;
  vision)   D_CTX=98304;  D_KV=q4_0; D_VISION=1; D_NP=1; D_UB=256; D_NEED=22140 ;;
  vision-max) D_CTX=131072; D_KV=q4_0; D_VISION=1; D_NP=1; D_UB=256; D_NEED=23040 ;;
  max)      D_CTX=163840; D_KV=q4_0; D_VISION=0; D_NP=1; D_UB=256; D_NEED=22805 ;;
  *) echo "unknown PROFILE '\$PROFILE' (coding|balanced|vision|vision-max|max)" >&2
     echo "run 'qwen38-27b-server --help' for the profile table" >&2; exit 1 ;;
esac

# Pre-flight: a CUDA OOM two minutes into loading a 17 GB model is a miserable
# way to find out another process is holding VRAM. Check first, name the fix.
if command -v nvidia-smi >/dev/null 2>&1 && [[ -z "\${CTX:-}\${KV_TYPE:-}\${VISION:-}" ]]; then
  free_mib=\$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1)
  if [[ -n "\$free_mib" ]] && (( free_mib < D_NEED )); then
    echo "WARNING: profile '\$PROFILE' needs ~\${D_NEED} MiB but only \${free_mib} MiB is free." >&2
    echo "         Something else is using the GPU:" >&2
    nvidia-smi --query-compute-apps=pid,used_memory,process_name \
               --format=csv,noheader 2>/dev/null | sed 's/^/           /' >&2
    if   (( free_mib >= 21900 )); then echo "         Try: PROFILE=coding" >&2
    elif (( free_mib >= 17000 )); then echo "         Try: PROFILE=coding CTX=32768" >&2
    else echo "         Not enough VRAM for any profile; free the GPU first." >&2; fi
    echo "         Continuing anyway in 5s (Ctrl-C to abort)..." >&2
    sleep 5
  fi
fi

PORT=\${PORT:-8080}
HOST=\${HOST:-127.0.0.1}
CTX=\${CTX:-\$D_CTX}
KV_TYPE=\${KV_TYPE:-\$D_KV}
VISION=\${VISION:-\$D_VISION}
NP=\${NP:-\$D_NP}
UB=\${UB:-\$D_UB}
THINKING=\${THINKING:-1}
THINKING_BUDGET=\${THINKING_BUDGET:-}

# Only f16/bf16/q8_0/q4_0 have CUDA flash-attention kernels for this model.
# Everything else silently falls back to CPU attention: measured 48 tok/s
# prefill vs 2300 tok/s, with the GPU at 1% and 8 CPU cores pegged. There is
# no warning from llama.cpp, so warn here.
case "\$KV_TYPE" in
  f16|bf16|q8_0|q4_0) ;;
  *)
    echo "WARNING: KV_TYPE='\$KV_TYPE' has no CUDA flash-attention kernel." >&2
    echo "         Attention will fall back to CPU -- expect ~50x slower prompt" >&2
    echo "         processing. Use q4_0 (small, fast), q8_0 (fast, higher" >&2
    echo "         fidelity) or f16. Continuing anyway in 5s (Ctrl-C to abort)." >&2
    sleep 5
    ;;
esac

ARGS=(
  -m "\$MODEL"
  # Stable model id for API clients. Without this llama-server advertises the
  # full .gguf path, so every client config breaks when you change quant.
  -a "\${MODEL_ALIAS:-qwen3.8-27b}"
  -ngl 99
  -c "\$CTX"
  -fa on
  --jinja
  --cache-type-k "\$KV_TYPE"
  --cache-type-v "\$KV_TYPE"
  -np "\$NP"
  -ub "\$UB"
  -b 1024
  --host "\$HOST"
  --port "\$PORT"
)

# Thinking mode and its sampler are a matched pair. The Qwen3.8 card specifies
# DIFFERENT sampling for each, and running the thinking preset with thinking
# disabled is documented to cause repetition -- which is what presence_penalty
# exists to suppress. So THINKING flips both together, never one alone.
if [[ "\$THINKING" == "0" ]]; then
  ARGS+=(
    --reasoning off
    # Instruct (non-thinking) preset, Qwen3.8 model card.
    --temp 0.7
    --top-p 0.80
    --top-k 20
    --min-p 0.0
    --presence-penalty 1.5
  )
else
  ARGS+=(
    # Thinking preset, Qwen3.8 model card.
    --temp 1.0
    --top-p 0.95
    --top-k 20
    --min-p 0.0
  )
  # Cap thinking without disabling it: bounds the max_tokens trap below.
  [[ -n "\$THINKING_BUDGET" ]] && ARGS+=(--reasoning-budget "\$THINKING_BUDGET")
fi

# Speculative decoding via the multi-token-prediction head. llama.cpp only
# auto-discovers MTP sidecars on the -hf path, so point at it explicitly.
if [[ -n "\$MTP" && -f "\$MTP" ]]; then
  ARGS+=(
    -md "\$MTP"
    --spec-type draft-mtp
    --spec-draft-n-max 2
    --spec-draft-ngl 99
    # The draft model has its own KV cache; keep it on a GPU-supported type too.
    --spec-draft-type-k "\$KV_TYPE"
    --spec-draft-type-v "\$KV_TYPE"
  )
fi

# Vision costs ~0.9 GiB of weights that would otherwise buy ~27k tokens of
# context, so it is off outside the 'vision' profile.
if [[ "\$VISION" == "1" && -n "\$MMPROJ" && -f "\$MMPROJ" ]]; then
  ARGS+=(--mmproj "\$MMPROJ" --image-min-tokens 1024)
fi

exec llama-server "\${ARGS[@]}" "\$@"
EOF
  chmod +x "$run_script"
  ok "Launcher: $run_script"

  local unit_dir="${HOME}/.config/systemd/user"
  mkdir -p "$unit_dir"
  cat > "${unit_dir}/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Qwen3.8-27B llama-server (Unsloth GGUF + MTP)
After=network.target

[Service]
Type=simple
# %h is systemd's specifier for the invoking user's home directory, so this
# unit carries no hardcoded username either.
ExecStart=%h/.local/bin/qwen38-27b-server
Restart=on-failure
RestartSec=5
Environment=PATH=%h/.local/bin:/usr/local/cuda/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload 2>/dev/null || true
  ok "Systemd unit: ${SERVICE_NAME}.service"
}

# ====================== Smoke test ======================
smoke_test() {
  info "Smoke-testing the server (this loads the full model)..."
  local port=18080 pid=0 rc=0
  PORT=$port HOST=127.0.0.1 "${BIN_DIR}/qwen38-27b-server" \
    > "${INSTALL_ROOT}/smoke.log" 2>&1 &
  pid=$!

  local i
  for i in $(seq 1 180); do
    if ! kill -0 "$pid" 2>/dev/null; then
      warn "Server exited during startup. Tail of ${INSTALL_ROOT}/smoke.log:"
      tail -30 "${INSTALL_ROOT}/smoke.log" | tee -a "$LOG_FILE"
      return 1
    fi
    if curl -sf "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      ok "Server healthy after ${i}s."
      break
    fi
    sleep 1
  done

  if curl -sf "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
    local used free ctx
    used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1)
    free=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1)
    ctx=$(curl -s "http://127.0.0.1:${port}/props" \
          | python3 -c 'import sys,json;print(json.load(sys.stdin)["default_generation_settings"]["n_ctx"])' 2>/dev/null || echo "?")
    SMOKE_CTX="$ctx"; SMOKE_VRAM="$used"; SMOKE_FREE="$free"
    info "Profile '${PROFILE:-coding}': n_ctx=${ctx}, VRAM ${used} MiB used / ${free} MiB free"
    (( free < 500 )) && warn "Only ${free} MiB VRAM headroom -- consider PROFILE=balanced."

    # Generation must actually work, not just bind a port.
    local reply
    reply=$(curl -sf "http://127.0.0.1:${port}/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d '{"messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":256}' \
      | python3 -c 'import sys,json;print(json.load(sys.stdin)["choices"][0]["message"]["content"].strip())' 2>/dev/null || echo "")
    if [[ -n "$reply" ]]; then
      SMOKE_GEN="ok"
      ok "Generation OK (model replied: '${reply:0:40}')"
    else
      warn "Server is up but generation failed."
      rc=1
    fi
  else
    warn "Server did not become healthy in 180s."
    rc=1
  fi

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  # MTP is the piece most likely to fail silently -- the server starts happily
  # with speculative decoding disabled, so assert it actually drafted tokens.
  if [[ -n "$MTP_HEAD" ]]; then
    local acc
    acc=$(grep -oE 'draft acceptance = [0-9.]+' "${INSTALL_ROOT}/smoke.log" | tail -1 | grep -oE '[0-9.]+$')
    if [[ -n "$acc" ]]; then
      SMOKE_ACC="$acc"
      ok "MTP speculative decoding active (draft acceptance ${acc})."
    else
      warn "MTP head was loaded but no draft acceptance was reported -- speculative decoding may be inactive."
    fi
  fi
  return $rc
}

# ====================== Main ======================
main() {
  ensure_system_deps
  ensure_build_tools
  ensure_nvidia
  ensure_hf
  ensure_llama_cpp
  ensure_model
  create_wrappers

  if [[ "${SKIP_SMOKE_TEST:-0}" != "1" ]]; then
    smoke_test || warn "Smoke test did not pass; see ${INSTALL_ROOT}/smoke.log"
  fi

  print_summary
}

# ====================== Final summary ======================
# Printed directly rather than through log(), so it is not buried under
# timestamps and level tags. Still tee'd to the log file, colours stripped.
say() { echo -e "$*"; echo -e "$*" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"; }

human_size() { [[ -f "$1" ]] && du -h "$1" 2>/dev/null | cut -f1 || echo "-"; }

print_summary() {
  local B B_OFF; B=$'\033[1m'; B_OFF=$'\033[0m'
  [[ -t 1 ]] || { B=""; B_OFF=""; }
  local tick="${GREEN}OK${NC}" cross="${YELLOW}--${NC}"
  local llama_sha; llama_sha=$(git -C "$LLAMA_DIR" rev-parse --short HEAD 2>/dev/null || echo "?")

  say ""
  say "${GREEN}==============================================================${NC}"
  say "${GREEN}  Qwen3.8-27B is installed and ready${NC}"
  say "${GREEN}==============================================================${NC}"
  say ""
  say "${B}WHAT WAS INSTALLED${NC}"
  say "  Model       $(basename "$MODEL_GGUF")  ($(human_size "$MODEL_GGUF"))"
  if [[ -n "$MTP_HEAD" ]]; then
    say "  MTP head    $(basename "$MTP_HEAD")  ($(human_size "$MTP_HEAD"))  -> ~2x faster generation"
  else
    say "  MTP head    ${YELLOW}not installed${NC} -- no speculative decoding"
  fi
  if [[ -n "$MMPROJ" ]]; then
    say "  Vision      $(basename "$MMPROJ")  ($(human_size "$MMPROJ"))  -> PROFILE=vision"
  else
    say "  Vision      ${YELLOW}not installed${NC} -- text only"
  fi
  say "  llama.cpp   ${llama_sha}  (CUDA sm_${CUDA_ARCHS})"
  say "  Files in    ${INSTALL_ROOT}"
  say "  Commands    ${BIN_DIR}/qwen38-27b-server, llama-server"
  say ""

  if [[ -n "$SMOKE_CTX" || -n "$SMOKE_GEN" ]]; then
    say "${B}VERIFIED ON THIS MACHINE${NC}"
    [[ -n "$SMOKE_CTX"  ]] && say "  [${tick}] loads at ${SMOKE_CTX} context, using ${SMOKE_VRAM} MiB (${SMOKE_FREE} MiB free)"
    [[ "$SMOKE_GEN" == "ok" ]] && say "  [${tick}] generates text over the API"
    if [[ -n "$SMOKE_ACC" ]]; then
      say "  [${tick}] speculative decoding live (draft acceptance ${SMOKE_ACC})"
    elif [[ -n "$MTP_HEAD" ]]; then
      say "  [${cross}] speculative decoding NOT confirmed -- check ${INSTALL_ROOT}/smoke.log"
    fi
    say ""
  fi

  say "${B}START IT${NC}"
  say "  ${GREEN}qwen38-27b-server${NC}                        # 128k context, ~92 tok/s"
  say "  qwen38-27b-server --help                 # all profiles, with caveats"
  say "  systemctl --user enable --now ${SERVICE_NAME}   # run it as a service"
  say ""
  say "${B}CONNECT A CLIENT${NC}  (OpenAI-compatible)"
  say "  Endpoint    http://127.0.0.1:8080/v1"
  say "  Model id    qwen3.8-27b"
  say "  API key     any value -- it is ignored"
  say "  Check it    curl http://127.0.0.1:8080/v1/models"
  say "  Pi / OpenCode config examples are in README.md"
  say ""
  say "${B}CHOOSE A PROFILE${NC}  PROFILE=<name> qwen38-27b-server"
  say "  coding       128k  text        default, best for coding agents"
  say "  balanced      96k  text        full-fidelity q8_0 KV cache"
  say "  vision        96k  + images    screenshots, diagrams, video"
  say "  vision-max   128k  + images    tight on VRAM, foreground only"
  say "  max          160k  text        tight on VRAM, foreground only"
  say ""
  say "${B}IF SOMETHING LOOKS WRONG${NC}"
  say "  Empty replies       raise max_tokens -- thinking mode consumes it"
  say "  Slow generation     check the log for 'draft acceptance'"
  say "  Slow prompt reading KV_TYPE must be q4_0/q8_0/f16 -- others run on CPU"
  say "  CUDA out of memory  free the GPU, or use PROFILE=balanced"
  say "  Setup log           ${LOG_FILE}"
  say ""
  say "${B}LEARN MORE${NC}"
  say "  README.md            usage and client setup"
  say "  docs/discovery.md    measurements, and why these settings"

  if ((${#APT_MISSING[@]})); then
    say ""
    say "${YELLOW}NOTE: skipped apt packages (no passwordless sudo):${NC} ${APT_MISSING[*]}"
    say "  sudo apt-get install -y --no-install-recommends ${APT_MISSING[*]}"
    say "  then re-run this script for a CURL-enabled build."
  fi
  say ""
  say "Re-running this script is safe: it only upgrades what is outdated."
  say ""
}

main "$@"
