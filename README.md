# VIctory Linux / Proton Launcher & Benchmark Harness

Clean Linux (Wayland/X11) + Proton Experimental (`ntsync` + `vkd3d-proton`) launcher and benchmark scripts for the [`fork-proton`](../fork-proton) branch.

## Features
- Configures Proton Experimental (`PROTON_USE_NTSYNC=1`, `PROTON_ENABLE_WAYLAND=1`, isolated `WINEPREFIX`, warm shader/pipeline cache directories).
- Sets tuned `VICTORY_*` environment variables for Linux/Proton + 8 GB VRAM GPUs + 16 GB RAM systems (with `lz4` zram).
- Enables MangoHud (`MANGOHUD_ENABLE=1`) and disables `lsfg-vk` frame generation (`DISABLE_LSFGVK=1`) for pure native measurements.
- Includes `tools/bench.sh` and `tools/bench-summary.py` for reproducible timed runs with RSS/swap telemetry.

## Quick Start
1. Build `victory.exe` from the `fork-proton` branch (`cargo build --release --target x86_64-pc-windows-gnu --bin victory`).
2. Set `GAME_WIN` (and update `game_dir` in `victory.proton.toml`) to your local title directory.
3. Run:
   ```bash
   ./launch-scarlett.sh play
   ```

See `docs/linux-proton-optimizations.md` on the `fork-proton` branch for full technical details and benchmarks.
