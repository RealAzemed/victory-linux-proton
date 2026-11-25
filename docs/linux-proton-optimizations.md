# Linux / Proton & Constrained-RAM Optimizations (`fork-proton`)

This branch builds on `fxceless/victory-fork` (`465b94f`) and adds Linux/Proton
(`vkd3d-proton` + Wine/ntsync) compatibility, Series S dual-plane presentation,
cross-fork visual fixes, and original systems-level optimizations engineered
specifically for **16 GB system RAM + 8 GB VRAM** on Linux.

All measurements below were captured on:
- **CPU**: AMD Ryzen 5 7500F (6C / 12T)
- **RAM**: 16 GB single-channel DDR5 + 15.2 GB `lz4` zram
- **GPU**: NVIDIA RTX 3070 8 GB (ReBAR enabled, DXGI budget ~7.0 GB)
- **OS / Runtime**: CachyOS Linux (Wayland), Proton Experimental (`ntsync`), `vkd3d-proton`
- **Target mode**: Series S (`0.5` render scale), warm shader/pipeline cache

---

## What This Fork Does That Others Don’t

### 1. Hybrid In-Place + Sparse-View Window Sizing (`VICTORY_HYBRID_WINDOWS=1`)
**Problem**: On 16 GB machines, `shadow.rs` allocates 4 MiB pinned host buffers
(`/dev/nvidiactl`, unswappable) for every loose window outside registered title
buffers. Profiling `Shape::Crosses` rejections on Linux revealed that nearly
every rejected 4 MiB cell (~800–1,200 windows, **4–5.4 GB of pinned RAM**) is a
sparse `xmem` virtual placeholder with **0.8–2.8 MiB of leading `MEM_RESERVE`
dead holes** before a handful of 64 KiB `MEM_MAPPED` views. Setting a global
small window grid (`VICTORY_WINDOW_KB=512`) regresses performance because it
also fragments private `VICTORY_INPLACE=1` windows (cutting in-place coverage
from ~370 MB down to ~151 MB).

**Our solution** ([`crates/victory-gpu/src/shadow.rs`](../crates/victory-gpu/src/shadow.rs)):
- Keeps full **4 MiB cells** for private `OpenExistingHeapFromAddress1` in-place
  windows (preserving 100% of zero-copy private coverage).
- Shrinks **only** non-in-place sparse view fallbacks to `VICTORY_HYBRID_WINDOW_KB`
  (default **512 KiB**) for sized asks and 256 KiB-aligned `tail_of` windows for
  unsized root views—eliminating the 0.8–2.8 MiB leading reserved dead zones
  from unswappable pinned RAM and cutting unmapped-page copy faults.

### 2. Full-Allocation Private In-Place Clamping & Reserved-Tail Commit (`VICTORY_INPLACE_CLAMP=1`)
**Problem**: Fixed 4 MiB loose windows that straddle a private `VirtualAlloc`
boundary or contain trailing `MEM_RESERVE` pages fail `private_whole()` and
fall back to pinned host copies.

**Our solution** ([`crates/victory-gpu/src/inplace.rs`](../crates/victory-gpu/src/inplace.rs)):
- Walks forward and backward within the same private `AllocationBase` inside
  each 4 MiB cell, committing reserved pages when `VICTORY_INPLACE_COMMIT=1`,
  and clamping to 64 KiB-aligned usable boundaries so `OpenExistingHeapFromAddress1`
  opens the whole private slice in place.

### 3. Wine/Proton IPC Elimination: `VICTORY_WRITE_PLAIN=1`, `VICTORY_COPY_PLAIN_MIN=4`, & `VirtualQuery` Page Probing
**Problem**: On native Windows, `ReadProcessMemory` and `NtWriteVirtualMemory`
are fast syscalls, whereas `VirtualQuery` walks page tables slowly. On
Linux/Wine/Proton, the cost profile is **inverted**:
- Every `ReadProcessMemory` / `NtWriteVirtualMemory` crosses `wineserver` IPC.
  Upstream’s `LEAST = 256` threshold left ~29,500 small reads/frame on IPC, and
  `K32QueryWorkingSetEx` fallback in `texture.rs::readable()` fired another
  ~10,000 1-byte `ReadProcessMemory` IPC calls/frame.
- Conversely, Wine’s `VirtualQuery` (`NtQueryVirtualMemory`) queries an in-memory
  RB-tree of VMAs in O(log N) per contiguous region.

**Our solutions**:
- **Guarded in-process copy-back (`VICTORY_WRITE_PLAIN=1`)** and lowered copy
  threshold (`VICTORY_COPY_PLAIN_MIN=4`) in
  [`crates/victory-gpu/src/plaincopy.rs`](../crates/victory-gpu/src/plaincopy.rs):
  assembly `victory_write_guarded` + VEH fault handler + 2 s per-block fault
  backoff cuts copy-back time **206 ms → 56 ms (−73%)** with 0 write faults.
- **Safe `VirtualQuery` path (`VICTORY_COMMITTED_QUERY=1`)** in
  [`crates/victory-gpu/src/texture.rs`](../crates/victory-gpu/src/texture.rs):
  guards against `PAGE_NOACCESS | PAGE_GUARD`, slashing 1-byte IPC probes from
  **10,383 → 12–21 / frame (−99.8%)**.
- **Full-VRAM `heap_textures` stall fix** in
  [`crates/victory-gpu/src/draw.rs`](../crates/victory-gpu/src/draw.rs):
  gates the 3× catchup multiplier on `room` so an 8 GB GPU doesn’t burn
  627–1,016 ms/pass spinning on waiting texture slots after VRAM fills.
  Combined with `VICTORY_COMMITTED_QUERY=1`, `heap_textures` dropped from
  **627–1,016 ms → 8–44 ms (−94%)**.

### 4. Critical-RAM Eviction Tier (`< 1 GiB → 500 ms`)
In [`crates/victory-gpu/src/host.rs`](../crates/victory-gpu/src/host.rs),
`ram_idle_ms()` adds a `< 1 GiB → 500 ms` reclaim tier (4× faster than the
2,000 ms floor) so idle loose windows, staging buffers, and unused host
textures are released aggressively before 16 GB systems thrash swap.

### 5. Linux/Proton & Series S Compatibility + Cross-Fork Visual Fixes
- **MinGW cross-build (`cargo win`) + `vkd3d-proton` fixes**: null-blob
  `CreatePipelineLibrary` fix, integer render-target blending stripped
  (`pipeline/host.rs`, eliminating `vkd3d-proton` `E_INVALIDARG` rejections on
  `R8_UINT` G-buffer/wall mesh pipelines), triple buffering, and `VICTORY_VSYNC`.
- **Series S dual-plane present (`over.rs`)** wired through `VICTORY_ASYNC_PRESENT`
  + loader hooks (`VICTORY_OWN_UPSCALER`, `VICTORY_RENDER_SCALE`,
  `VICTORY_NO_WATCHDOG`).
- **Depth-shaded ambient post-pass (`ambient.rs`, ported from Belobug `cd9f78c`)**:
  replaces the unlit GI resolve output with warm, 16-tap depth-occluded ambient
  shading (`VICTORY_AMBIENT=0.6`, `VICTORY_AMBIENT_SHADE`), giving characters
  and interiors natural skin tones and crease shading without ray-tracing cost.
- **Shader fixes**: 9-bit mesh-shader primitive corner mask (`0x1FF`) and
  pixel helper-lane `v_readfirstlane` / quad reads (`isHelperLane`, Belobug
  `f520772`, `03629f3`).

---

## Measured Progression (Same 16 GB / RTX 3070 8 GB Linux Machine)

| Run | Key Changes | In-World Median FPS | Frame Time | Preparing / Copy-Back | Draws/Frame | `heap_textures` |
|---|---|---:|---:|---:|---:|---:|
| Baseline (`162759`) | `fxceless` warm, switches off | `0.90` | `1,146 ms` | `450 / 206 ms` | ~750 | — |
| Speed switches (`163634`) | `ASYNC_SUBMIT`, `QUEUE2`, `INDIRECT_WINDOW` | `0.95` | `1,044 ms` | `— / 110 ms` | ~800 | — |
| + In-place (`164535`) | `VICTORY_INPLACE=1` (340 MB in place) | `1.10` | `915 ms` | `— / 180 ms` | ~850 | — |
| `fork-opt-v1` (`193355`) | Rebase `0b0074e`, `COPY_PLAIN_MIN=4`, `WRITE_PLAIN=1` | `1.20` (12.8 peak) | `816 ms` | `426 / 74 ms` | ~900 | `627–1,016 ms` |
| `fork-opt-v2` (`221031`) | Rebase `465b94f`, integer-blend fix, depth-shaded `ambient.rs`, `COMMITTED_QUERY=1`, `lz4` zram | `1.20` (2.0 non-swap) | `831 ms` (430–533 non-swap) | `432 / 56 ms` | `1,490` (164 new PSOs compiling) | `31–44 ms` |
| `fork-opt-v3` (`223759`) | All 164 PSOs warm, `INPLACE_CLAMP`, 500 ms RAM sweep, `LIBRARY_TRIM=1`, `CARD_WINDOWS_MB=0` | **`1.35`** | **`733 ms`** | **`339 / 56 ms`** | **`2,018`** | **`8–44 ms`** |
