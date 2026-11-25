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

### 1. Userspace `xmem` Placeholder & View-Region Fast Path (`VICTORY_PLACEHOLDER_FAST=1`)
**Problem**: Console physical-page views live inside ~23 `MEM_RESERVE_PLACEHOLDER`
virtual reservations (`xmem.rs`). On Wine/Proton, every `GetWriteWatch`,
`VirtualQuery`, and failing `VirtualProtect` against placeholder memory crosses
into ntdll’s VMA tree / wineserver — burning **~12,600 wasted Wine syscalls per
frame** across `watch::writes()`, `watch::guard()` absent-block probing,
`watch::protect_here()`, and `texture.rs::{committed, mapped_bytes}()`.

**Our solution** ([`crates/victory-hle/src/modules/xmem.rs`](../crates/victory-hle/src/modules/xmem.rs),
[`crates/victory-gpu/src/inplace.rs`](../crates/victory-gpu/src/inplace.rs),
[`crates/victory-gpu/src/watch.rs`](../crates/victory-gpu/src/watch.rs),
[`crates/victory-gpu/src/texture.rs`](../crates/victory-gpu/src/texture.rs)):
- Registers `MEM_RESERVE_PLACEHOLDER` reservations once at `XMemVirtualAlloc`
  via `victory_gpu::title_memory_placeholder(base, size)` into a lock-light
  `RwLock<BTreeMap<usize, usize>>`.
- `watch::writes(..., false)` returns `None` immediately in userspace for
  placeholders (skipping doomed `GetWriteWatch` syscalls).
- `watch::guard()` recognizes placeholder ranges without `GetWriteWatch` or
  `VirtualQuery`, skips `uncommitted_end()` queries on absent blocks (which
  only become mapped via `xmem::map` → `title_memory_remapped`), and
  `protect_here()` marks unmapped gaps directly from `VIEWS` while only
  calling `VirtualProtect` on contiguous mapped runs.
- `watch::protect()` looks up aliased pages across `[from, to)` in a single
  `VIEWS` lock (`aliased_pages_in`) instead of locking per 64 KiB block.
- `texture.rs::{committed, mapped_bytes}()` answer directly from the userspace
  `VIEWS` map inside placeholders (0 syscalls), slashing `heap_tex_pass`
  **107.8 ms → 22.8–38.6 ms (−79%)** and `copies` **243.6 ms → 115–127 ms (−53%)**.

### 2. 64-Block Bitset `BlockSet` & Same-Frame Adaptive Hot-Block Unguarding (`VICTORY_HOT_GUARD=1`)
**Problem**: `watch::Guards` tracked every 64 KiB block in per-block
`BTreeSet<usize>` trees (~200,000 entries), taking `19–61 ms/frame` just to
walk ranges, while dynamic ring/constant blocks written multiple times per
frame triggered `675–960` `VirtualProtect(PAGE_READONLY)` calls/frame
(`64–104 ms/frame` + cross-CPU TLB shootdowns + `SIGSEGV` VEH page faults on
the title’s own CPU threads).

**Our solution** ([`crates/victory-gpu/src/watch.rs`](../crates/victory-gpu/src/watch.rs)):
- Replaces `protected`, `clean`, `absent`, `viewed` with a compact `BlockSet`
  (`BTreeMap<usize, u64>`, 64 blocks = 4 MiB per `u64` word), turning `guard()`
  into an O(words) bitwise `!(clean | absent)` + `trailing_zeros()` scan with
  zero heap allocations and coalescing contiguous `VirtualProtect` runs in
  `open_here()`.
- Tracks same-frame write faults in the VEH handler: blocks faulting `>= 4`
  times within the *same* frame are left `PAGE_READWRITE` for a short bounded
  cooldown (`4 → 8` frames, then re-probed). Strictly conservative (`guard()`
  always reports them written so copies stay 100% fresh), cutting `guard_scan`
  to **`8.8 ms`**, `guard_prot` to **`36.5 ms / 425 vp`**, and total `watch`
  to **`41.1 ms`**.

### 3. Zero-Latency Character Bake Texture Flush & 8 GB VRAM `bake_room()`
**Problem**: On 8 GB GPUs, regular textures filled VRAM to 94–99% before
one-time `PS_BakeDecorations_*` character bakes ran, AND DirectStorage writes
into physical pages (`PAGE_WRITTEN`) were either ignored (default
`VICTORY_PAGE_WRITES=guards`) or delayed by 1–2 frames (`frame + 1` /
`frame + PAGE_WRITE_AFTER`) — causing `PS_BakeDecorations_*` to permanently
bake `#000000` zeros onto character faces and leave hair pale.

**Our solution** ([`crates/victory-gpu/src/resource.rs`](../crates/victory-gpu/src/resource.rs),
[`crates/victory-gpu/src/descriptor/host.rs`](../crates/victory-gpu/src/descriptor/host.rs),
[`crates/victory-gpu/src/draw.rs`](../crates/victory-gpu/src/draw.rs)):
- Adds `resource::bake_room()` (`used < 97%` of DXGI budget, ignoring long-term
  `card_room_kept()`/`targets_room_kept()` reserves during one-time bakes)
  paired with `VICTORY_TEXTURE_ROOM_PERCENT=88` to preserve ~650 MiB of bake
  headroom on 8 GB GPUs.
- Retains recent DirectStorage page-write ranges (`BAKE_PAGE_WRITTEN`) when
  continuous bit-2 re-uploads are off, and flushes `REMAPPED`, `PAGE_WRITTEN`,
  and recently-uploaded/partially-mapped queue slots (`texture_slots_bake_prepare`)
  with **0-frame delay (`due = frame`)** right before `PS_BakeDecorations_*`
  draws — fixing character face skin and dark hair without flooding mid-game
  streaming.

### 4. Full-Allocation Private In-Place Clamping & Reserved-Tail Commit (`VICTORY_INPLACE_CLAMP=1`)
**Problem**: Fixed 4 MiB loose windows that straddle a private `VirtualAlloc`
boundary or contain trailing `MEM_RESERVE` pages fail `private_whole()` and
fall back to pinned host copies.

**Our solution** ([`crates/victory-gpu/src/inplace.rs`](../crates/victory-gpu/src/inplace.rs)):
- Walks forward and backward within the same private `AllocationBase` inside
  each 4 MiB cell, committing reserved pages when `VICTORY_INPLACE_COMMIT=1`,
  and clamping to 64 KiB-aligned usable boundaries so `OpenExistingHeapFromAddress1`
  opens the whole private slice in place.

### 5. Wine/Proton IPC Elimination: `VICTORY_WRITE_PLAIN=1`, `VICTORY_COPY_PLAIN_MIN=4`, & `VirtualQuery` Page Probing
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

### 6. Critical-RAM Eviction Tier (`< 1 GiB → 500 ms`)
In [`crates/victory-gpu/src/host.rs`](../crates/victory-gpu/src/host.rs),
`ram_idle_ms()` adds a `< 1 GiB → 500 ms` reclaim tier (4× faster than the
2,000 ms floor) so idle loose windows, staging buffers, and unused host
textures are released aggressively before 16 GB systems thrash swap.

### 7. Linux/Proton & Series S Compatibility + Cross-Fork Visual Fixes
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
| `fork-opt-v3` (`223759`) | All 164 PSOs warm, `INPLACE_CLAMP`, 500 ms RAM sweep, `LIBRARY_TRIM=1`, `CARD_WINDOWS_MB=0` | `1.35` (2.0 peak) | `733 ms` | `339 / 56 ms` | `2,018` | `8–44 ms` |
| `fork-opt-v5` (`231530`) | `VICTORY_PLACEHOLDER_FAST=1` (~12.6k syscalls/frame skipped), `CARD_REHASH_RUNS=1` (−91% passes) | `1.60` (3.4 peak) | `629 ms` | `212 / 48 ms` | `~1,800` | `22.8 ms` |
| `fork-opt-v7` (`235753`) | `BlockSet` 64-block bitset, `HOT_GUARD=1`, immediate bake flush (character faces & dark hair fixed!) | `1.40` (**8.3** / 11 peak) | `738 ms` | `296 / 56 ms` | `1,342` | `~38 ms` |
| **`fork-opt-v8` (`001058`)** | Retained `BAKE_PAGE_WRITTEN`, same-frame `HOT_GUARD=1`, `TEXTURE_ROOM_PERCENT=88` + `bake_room()` | **`1.75`** (2.5 peak) | **`566 ms`** | **`193 / 31 ms`** | **`2,067`** | **`38.6 ms`** |
| **`fork-opt-v9b` (`005404`)** | `VICTORY_INPLACE_SECTIONS=1` (`OpenExistingHeapFromFileMapping` zero-copy section windows), lock-free `HostHeap::mirror` + cached `gpu_handle`, stack root constants, `VIEWS: RwLock`, Thin LTO | **`2.00`** (**14.9** peak) | **`498 ms`** | **`121 / 18 ms` (`copies 10 ms`!)** | `537` | `~25 ms` |
| **`fork-opt-v9c` (`005834`)** | Same with `VICTORY_INPLACE_SECTIONS=0` (isolating `HostHeap::mirror` + `VIEWS: RwLock` + Thin LTO) | **`2.10`** (4.8 peak) | **`473 ms`** | **`135 / 49 ms`** | `1,630` | `~19 ms` |
| **`fork-opt-v10` (`010417`)** | `VICTORY_INPLACE_SECTIONS=1` + default `VICTORY_LATE_WAIT_LISTS=256` (full 180s stability verified: 3,967 section windows opened, 406 MB live, 0 refused, 1,036 cleanly retired on remap, 0 exceptions) | `1.10` (3.1 peak; 1.8–1.9 non-swap, 16 GB RAM bound) | `900 ms` (513–567 non-swap) | `276 / 82 ms` | `2,855` | `~24 ms` |

### New in Round 2 (Zero-Copy Section Heaps, Lock-Free Descriptor Mirroring, `VIEWS: RwLock`, Thin LTO)
- **Zero-Copy Section-Heap Windows (`VICTORY_INPLACE_SECTIONS=1`)**: `crates/victory-gpu/src/inplace.rs` & `shadow.rs` open `SEC_COMMIT` physical-page sections once via `OpenExistingHeapFromFileMapping` (0 working-set lock, 0 pinned host copies) and place `CreatePlacedResource` buffers directly over maximal contiguous mapped runs inside 4 MiB cells (with strict `run_end == cell_end` / `longest_tail` invariant for unsized root views so later mappings are never truncated). Opened 3,967 zero-copy section windows across 1 heap (406–720 MB live, 0 refused, 1,036 cleanly retired on remap), cutting `copies` from `76–127 ms` down to `10 ms` and reducing peak swap by up to 5 GB before 16 GB system RAM saturation.
- **Lock-Free `HostHeap::mirror` Fast Path + Cached `gpu_handle` (`descriptor/host.rs`)**: atomic `made_fast: Vec<AtomicU64>` (Release/Acquire) avoids locking `self.made` on the ~98% cache-hit path (~50k locks/frame eliminated), and cached `gpu: u64` removes ~10k/frame `GetGPUDescriptorHandleForHeapStart` COM calls.
- **Zero-Alloc Root Constants (`draw.rs`)**: stack `[0u32; 64]` buffer replaces per-bind `vec![0u32; dwords]` heap allocations (~6k–10k allocs/frame).
- **`VIEWS: RwLock<Views>` (`inplace.rs`)**: allows concurrent lock-free reader access across `watch`, `texture`, and `shadow` paths without blocking on each other.
- **Thin LTO (`Cargo.toml`)**: enables cross-crate inlining in release builds (`lto = "thin"`).
- **Important stability finding**: Raising `VICTORY_LATE_WAIT_LISTS` to `512` caused a hang at ~100s when >256 lists remained in flight without settling; keeping the default `256` restored full 180s stability (0 exceptions).

*(Note: `VICTORY_HYBRID_WINDOWS=1` was tested in `fork-opt-v4` and disabled by default — overlapping 512 KiB/tail windows inside a 4 MiB cell saved ~2 GB swap but tripled `copies` and caused stalls; `VICTORY_WIDE_REFRESH=1` was tested in `fork-opt-v6` and disabled by default due to `JOURNAL`/`GUARDS` mutex contention and `WORKERS` pool collision with `relay_worker`.)*
