#!/usr/bin/env bash
set -euo pipefail

PROTON="${PROTON:-$HOME/.local/share/Steam/steamapps/common/Proton - Experimental}"
RUNTIME="${RUNTIME:-fork}" # fork (victory-fork + Proton/Linux opts, default), perf (victory-perf), vitoriabr, ztrx
BASE_DIR="$HOME/.local/share/ztrx"
LOG_DIR="$BASE_DIR/logs"
GAME_WIN="${GAME_WIN:-Z:\\path\\to\\title\\title.exe}"

if [[ "$RUNTIME" == "ztrx" ]]; then
    EXE="${VICTORY_EXE:-$HOME/ztrx/target/x86_64-pc-windows-gnu/release/victory.exe}"
    CONSOLE_MODE="${CONSOLE_MODE:-series-x}"
    DEFAULT_CACHE='Z:\home\$USER\.local\share\ztrx\cache'
    CACHE_UNIX="$BASE_DIR/cache"
elif [[ "$RUNTIME" == "fork" ]]; then
    # fxceless/victory-fork (newest) + Proton fixes: ~/victory-fork, branch fork-proton.
    # Upstream only tests Series X (native 4K: too heavy for 8 GB). Our branch adds the
    # Series S fixes (second-plane present, own-upscaler/render-scale/watchdog hooks).
    EXE="${VICTORY_EXE:-$HOME/victory-fork/target/x86_64-pc-windows-gnu/release/victory.exe}"
    CONSOLE_MODE="${CONSOLE_MODE:-series-s}"
    DEFAULT_CACHE='Z:\home\$USER\.local\share\ztrx\cache-fork'
    CACHE_UNIX="$BASE_DIR/cache-fork"
    export VICTORY_LEVELS_ON_DEMAND="${VICTORY_LEVELS_ON_DEMAND:-1}"
    export VICTORY_CARD_ROOM_FOR_TARGETS_MB="${VICTORY_CARD_ROOM_FOR_TARGETS_MB:-1536}"
    # "Frame rate, second night" switches (README: 3.5-4 -> 6-7 fps on an RTX 4070)
    export VICTORY_ASYNC_SUBMIT="${VICTORY_ASYNC_SUBMIT:-1}"
    export VICTORY_QUEUE2="${VICTORY_QUEUE2:-1}"
    export VICTORY_INDIRECT_WINDOW="${VICTORY_INDIRECT_WINDOW:-1}"
    export VICTORY_TEXTURE_NO_WAIT="${VICTORY_TEXTURE_NO_WAIT:-1}"
    export VICTORY_MERGE_GAP="${VICTORY_MERGE_GAP:-64}"
    export VICTORY_MERGE_RUNS="${VICTORY_MERGE_RUNS:-4096}"
    # Unified memory: windows of title memory in private memory are used by the GPU in
    # place (no RAM copy, no per-frame copy). Measured: 1044 -> 915 ms/frame, swap -0.9 GB.
    export VICTORY_INPLACE="${VICTORY_INPLACE:-1}"
    export VICTORY_INPLACE_COMMIT="${VICTORY_INPLACE_COMMIT:-1}"
    export VICTORY_INPLACE_SECTIONS="${VICTORY_INPLACE_SECTIONS:-0}"
    # "Frame rate, third/fourth session" (465b94f) + Linux/Proton tuning:
    # Direct in-process copies/writes avoid Wine ReadProcessMemory/NtWriteVirtualMemory IPC.
    export VICTORY_COPY_PLAIN="${VICTORY_COPY_PLAIN:-1}"
    export VICTORY_WRITE_PLAIN="${VICTORY_WRITE_PLAIN:-1}"
    export VICTORY_JOIN_PARTS="${VICTORY_JOIN_PARTS:-1}"
    export VICTORY_BACK_OWN_VIEW="${VICTORY_BACK_OWN_VIEW:-1}"
    export VICTORY_INDIRECT_GATHER="${VICTORY_INDIRECT_GATHER:-1}"
    export VICTORY_WINDOW_JUMP="${VICTORY_WINDOW_JUMP:-1}"
    export VICTORY_REFRESH_ONCE="${VICTORY_REFRESH_ONCE:-1}"
    # Keep wide refresh off: concurrent watch::writes across WORKERS contends on JOURNAL/GUARDS
    # and collides with relay_worker's find_all pool.
    export VICTORY_WIDE_REFRESH="${VICTORY_WIDE_REFRESH:-0}"
    # On Wine/Proton, VirtualQuery is O(log N) in ntdll's VMA tree (unlike Windows page-table walk),
    # eliminating ~10k/frame 1-byte ReadProcessMemory IPC calls from K32QueryWorkingSetEx fallback.
    export VICTORY_COMMITTED_QUERY="${VICTORY_COMMITTED_QUERY:-1}"
    export VICTORY_TEXTURE_STAGE_MS="${VICTORY_TEXTURE_STAGE_MS:-80}"
    # Keep normal texture uploads at 88% so 8 GB GPUs always preserve ~650 MiB of
    # headroom under bake_room()'s 97% ceiling for one-time PS_BakeDecorations_* character bakes.
    export VICTORY_TEXTURE_ROOM_PERCENT="${VICTORY_TEXTURE_ROOM_PERCENT:-88}"
    export VICTORY_DRIVER_WATCH="${VICTORY_DRIVER_WATCH:-0}"
    # Belobug depth-shaded ambient post-pass (replaces flat VICTORY_AMBIENT_STUB)
    export VICTORY_AMBIENT="${VICTORY_AMBIENT:-0.6}"
    export VICTORY_AMBIENT_STUB="${VICTORY_AMBIENT_STUB:-0}"
    # 16 GB RAM + 8 GB VRAM tuning: don't steal 512 MB VRAM for card windows (they still pin
    # 512 MB in system RAM), trim mapped pipeline library blob once loaded, join adjacent card
    # rehash runs into fewer compute dispatches, userspace placeholder/view fast path,
    # and same-frame adaptive hot-block unguarding. Keep VICTORY_PAGE_WRITES at default
    # "guards" (bake passes automatically flush retained DirectStorage page writes without
    # flooding mid-game streaming).
    export VICTORY_CARD_WINDOWS_MB="${VICTORY_CARD_WINDOWS_MB:-0}"
    export VICTORY_LIBRARY_TRIM="${VICTORY_LIBRARY_TRIM:-1}"
    export VICTORY_CARD_REHASH_RUNS="${VICTORY_CARD_REHASH_RUNS:-1}"
    export VICTORY_PLACEHOLDER_FAST="${VICTORY_PLACEHOLDER_FAST:-1}"
    export VICTORY_HOT_GUARD="${VICTORY_HOT_GUARD:-1}"
    export VICTORY_PAGE_WRITES="${VICTORY_PAGE_WRITES:-guards}"
    export VICTORY_HYBRID_WINDOWS="${VICTORY_HYBRID_WINDOWS:-0}"
    # Give character skin bakes (PS_BakeDecorations_*) extra time budget while keeping loading-screen
    # early uploads at default 12 ms so textures are not uploaded prematurely while still zeroed.
    export VICTORY_EARLY_TEXTURES_MS="${VICTORY_EARLY_TEXTURES_MS:-12}"
    export VICTORY_BAKE_TEXTURES_MS="${VICTORY_BAKE_TEXTURES_MS:-2000}"
elif [[ "$RUNTIME" == "vitoriabr" ]]; then
    EXE="${VICTORY_EXE:-$HOME/VItoriaBr/target/x86_64-pc-windows-gnu/release/victory.exe}"
    CONSOLE_MODE="${CONSOLE_MODE:-series-s}"
    DEFAULT_CACHE='Z:\home\$USER\.local\share\ztrx\cache-vitoriabr'
    CACHE_UNIX="$BASE_DIR/cache-vitoriabr"
    # fxceless first-room fixes: levels on demand (~3 GB VRAM saved), room for render targets
    export VICTORY_LEVELS_ON_DEMAND="${VICTORY_LEVELS_ON_DEMAND:-1}"
    export VICTORY_CARD_ROOM_FOR_TARGETS_MB="${VICTORY_CARD_ROOM_FOR_TARGETS_MB:-1536}"
    export VICTORY_PIPELINE_WAIT_MS="${VICTORY_PIPELINE_WAIT_MS:-1500}"
else
    EXE="${VICTORY_EXE:-$HOME/victory-perf/target/x86_64-pc-windows-gnu/release/victory.exe}"
    CONSOLE_MODE="${CONSOLE_MODE:-series-s}"
    DEFAULT_CACHE='Z:\home\$USER\.local\share\ztrx\cache-vperf'
    CACHE_UNIX="$BASE_DIR/cache-vperf"
fi

export STEAM_COMPAT_DATA_PATH="$BASE_DIR/proton"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$HOME/.local/share/Steam"
export UMU_ID="ztrx-scarlett"
export DISPLAY="${DISPLAY:-:0}"
export PROTON_USE_NTSYNC="${PROTON_USE_NTSYNC:-1}"
export PROTON_ENABLE_HDR="0"
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-d3d12=n;d3d12core=n;dxgi=n;d3dcompiler_47=n}"

# Disable lsfg-vk frame-generation Vulkan layer (fails swapchain init under vkd3d-proton)
export DISABLE_LSFGVK="${DISABLE_LSFGVK:-1}"
export VK_LOADER_LAYERS_DISABLE="${VK_LOADER_LAYERS_DISABLE:-VK_LAYER_LSFGVK_frame_generation}"

# Enable MangoHud Vulkan overlay by default during gameplay (MANGOHUD_ENABLE=0 to disable)
if [[ "${MANGOHUD_ENABLE:-1}" == "1" ]] && command -v mangohud >/dev/null 2>&1; then
    export MANGOHUD=1
    export MANGOHUD_CONFIG="${MANGOHUD_CONFIG:-fps,frametime,gpu_stats,gpu_temp,vram,cpu_stats,ram,swap,position=top-left,font_size=18,background_alpha=0.45}"
fi

export VICTORY_CONFIG="${VICTORY_CONFIG:-Z:\\home\\$USER\\.local\\share\\ztrx\\victory.proton.toml}"
export VICTORY_CACHE_DIR="${VICTORY_CACHE_DIR:-$DEFAULT_CACHE}"
export VICTORY_DATA_DIR="${VICTORY_DATA_DIR:-Z:\\home\\$USER\\.local\\share\\ztrx\\data}"

# RTX 3070 8 GB + 16 GB single-channel DDR5 + Proton tuning
export VICTORY_OWN_UPSCALER="${VICTORY_OWN_UPSCALER:-1}"
export VICTORY_NO_WATCHDOG="${VICTORY_NO_WATCHDOG:-1}"
export VICTORY_RENDER_SCALE="${VICTORY_RENDER_SCALE:-0.5}"
export VICTORY_RT_RESOLVE="${VICTORY_RT_RESOLVE:-0}"
export VICTORY_ACTIVATE_RAYS="${VICTORY_ACTIVATE_RAYS:-0}"
export VICTORY_PIPELINE_WAIT_MS="${VICTORY_PIPELINE_WAIT_MS:-500}"
export VICTORY_AMBIENT_STUB="${VICTORY_AMBIENT_STUB:-1}"
export VICTORY_AMBIENT_STUB_VALUE="${VICTORY_AMBIENT_STUB_VALUE:-0.25}"
export VICTORY_SHADOWMASK_STUB="${VICTORY_SHADOWMASK_STUB:-1}"
export VICTORY_EXPOSURE_STUB="${VICTORY_EXPOSURE_STUB:-1}"
export VICTORY_CARD_BUFFERS_MIN_MB="${VICTORY_CARD_BUFFERS_MIN_MB:-1}"
export VICTORY_CARD_BUFFERS_MB="${VICTORY_CARD_BUFFERS_MB:-1024}"
export VICTORY_CARD_WINDOWS_MB="${VICTORY_CARD_WINDOWS_MB:-512}"
export VICTORY_TEXTURE_ROOM_PERCENT="${VICTORY_TEXTURE_ROOM_PERCENT:-90}"
export VICTORY_CARD_VRAM_PERCENT="${VICTORY_CARD_VRAM_PERCENT:-94}"
export VICTORY_RELAY="${VICTORY_RELAY:-2}"
export VICTORY_LATE_WAIT="${VICTORY_LATE_WAIT:-3}"
export VICTORY_WIDE_BACK="${VICTORY_WIDE_BACK:-1}"
export VICTORY_COPY_BACK_ONLY_READBACK="${VICTORY_COPY_BACK_ONLY_READBACK:-0}"
export VICTORY_REBAR="${VICTORY_REBAR:-0}"
export VICTORY_LIBRARY_TRIM="${VICTORY_LIBRARY_TRIM:-0}"
export VICTORY_VSYNC="${VICTORY_VSYNC:-1}"

# WARMUP=1: the title waits for every host pipeline it asks for (slow frames, but the
# pipeline backlog of a new build/cache clears in minutes instead of leaving the 3D black).
if [[ "${WARMUP:-0}" == "1" ]]; then
    export VICTORY_PIPELINE_WAIT_MS=60000
fi

if [[ "${LOW_MEM_WINDOWS:-0}" == "1" ]]; then
    export VICTORY_WINDOW_KB="${VICTORY_WINDOW_KB:-512}"
    export VICTORY_WINDOW_TAILS="${VICTORY_WINDOW_TAILS:-1}"
fi

# Persist vkd3d-proton and NVIDIA Vulkan shader caches on NVMe
export VKD3D_SHADER_CACHE_PATH="$BASE_DIR/cache/vkd3d"
export __GL_SHADER_DISK_CACHE="1"
export __GL_SHADER_DISK_CACHE_PATH="$BASE_DIR/cache/nv"
export __GL_SHADER_DISK_CACHE_SKIP_CLEANUP="1"

mkdir -p "$LOG_DIR" "$CACHE_UNIX" "$BASE_DIR/cache/vkd3d" "$BASE_DIR/cache/nv" "$BASE_DIR/data"

[[ -x "$PROTON/proton" ]] || { echo "Proton not found at $PROTON" >&2; exit 1; }
[[ -f "$EXE" ]] || { echo "victory.exe not found at $EXE" >&2; exit 1; }

get_wexe() {
    local w
    w=$("$PROTON/proton" getcompatpath "$EXE" 2>/dev/null || true)
    if [[ -z "$w" ]]; then
        if [[ "$RUNTIME" == "ztrx" ]]; then
            w='Z:\home\$USER\ztrx\target\x86_64-pc-windows-gnu\release\victory.exe'
        elif [[ "$RUNTIME" == "fork" ]]; then
            w='Z:\home\$USER\victory-fork\target\x86_64-pc-windows-gnu\release\victory.exe'
        elif [[ "$RUNTIME" == "vitoriabr" ]]; then
            w='Z:\home\$USER\VItoriaBr\target\x86_64-pc-windows-gnu\release\victory.exe'
        else
            w='Z:\home\$USER\victory-perf\target\x86_64-pc-windows-gnu\release\victory.exe'
        fi
    fi
    printf '%s' "$w"
}

ensure_prefix() {
    if [[ ! -d "$STEAM_COMPAT_DATA_PATH/pfx" ]]; then
        "$PROTON/proton" waitforexitandrun cmd /c true >/dev/null 2>&1 || true
    fi
}

run_victory() {
    local wexe
    ensure_prefix
    cd "$BASE_DIR/data"
    wexe=$(get_wexe)
    "$PROTON/proton" runinprefix "$wexe" "$@"
}

preflight_check() {
    echo "=== Preflight System Check (16 GB 1-ch DDR5 + RTX 3070 8 GB) ==="
    free -h
    swapon --show
    local avail_mib vram_free_mib
    avail_mib=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)
    vram_free_mib=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -n1 | tr -d ' ' || echo "0")
    echo "Runtime: ${RUNTIME} | Console mode: ${CONSOLE_MODE} | Render scale: ${VICTORY_RENDER_SCALE}"
    echo "Available RAM: ${avail_mib} MiB | Free GPU VRAM: ${vram_free_mib} MiB"
    if (( avail_mib < 9216 )); then
        echo "WARNING: Available RAM (${avail_mib} MiB) is below 9 GiB. Consider closing browsers/heavy apps." >&2
    fi
    if (( vram_free_mib > 0 && vram_free_mib < 6656 )); then
        echo "WARNING: Free VRAM (${vram_free_mib} MiB) is below 6.5 GiB. Consider closing GPU-heavy apps." >&2
    fi
}

cmd="${1:-play}"
case "$cmd" in
    play)
        shift || true
        preflight_check
        ts=$(date +%Y%m%d-%H%M%S)
        logfile="$LOG_DIR/run-$ts.log"
        ln -sfn "$logfile" "$LOG_DIR/latest.log"
        echo "Logging to: $logfile"
        if command -v gamemoderun >/dev/null 2>&1; then
            ensure_prefix
            cd "$BASE_DIR/data"
            set +e
            gamemoderun "$PROTON/proton" runinprefix "$(get_wexe)" \
                run "$GAME_WIN" --execute --console "$CONSOLE_MODE" "$@" 2>&1 | tee "$logfile"
            rc=${PIPESTATUS[0]}
            set -e
            exit "$rc"
        else
            set +e
            run_victory run "$GAME_WIN" --execute --console "$CONSOLE_MODE" "$@" 2>&1 | tee "$logfile"
            rc=${PIPESTATUS[0]}
            set -e
            exit "$rc"
        fi
        ;;
    smoke)
        echo "=== [1/3] victory config ==="
        run_victory config
        echo "=== [2/3] victory inspect ==="
        run_victory inspect "$GAME_WIN"
        echo "=== [3/3] victory run (dry bind check, no --execute) ==="
        run_victory run "$GAME_WIN" --console "$CONSOLE_MODE"
        ;;
    *)
        run_victory "$@"
        ;;
esac
