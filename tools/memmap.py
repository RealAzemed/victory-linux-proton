#!/usr/bin/env python3
"""Where the title process's memory is: /proc/<pid>/smaps summed by kind.

Usage: memmap.py [pid]   (default: the victory.exe process with the largest RSS)

Kinds: anonymous private memory (title memory, our heaps, host copies made by
the runtime), shared memory (memfd/shm: Wine/vkd3d host-visible GPU memory,
DXGI shared), the NVIDIA device mappings, mapped files (cache files, DLLs),
by size bucket so the big regions stand out.
"""
import collections
import os
import re
import sys


def victory_pid():
    best = (0, None)
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            cmd = open(f"/proc/{pid}/cmdline", "rb").read().replace(b"\0", b" ")
            if b"victory.exe" not in cmd:
                continue
            rss = int(re.search(rb"VmRSS:\s+(\d+)", open(f"/proc/{pid}/status", "rb").read()).group(1))
            best = max(best, (rss, int(pid)))
        except (OSError, AttributeError):
            pass
    return best[1]


def main():
    pid = int(sys.argv[1]) if len(sys.argv) > 1 else victory_pid()
    if not pid:
        sys.exit("no victory.exe process")
    head = re.compile(r"^([0-9a-f]+)-([0-9a-f]+) (\S+) \S+ \S+ \d+\s*(.*)$")
    kinds = collections.defaultdict(lambda: [0, 0, 0, 0])  # rss, swap, size, count
    big = []
    cur = None
    for line in open(f"/proc/{pid}/smaps"):
        m = head.match(line)
        if m:
            start, end, perms, name = m.groups()
            size = (int(end, 16) - int(start, 16)) // 1024
            name = name.strip()
            if not name:
                kind = "anon private" if "p" in perms else "anon shared"
            elif name.startswith("/memfd:") or name.startswith("/dev/shm") or "(deleted)" in name:
                kind = "shared memfd/shm: " + re.sub(r"\s*\(deleted\)", "", name.split("/")[-1])[:40]
            elif name.startswith("/dev/nvidia"):
                kind = "nvidia device " + name
            elif name.startswith("["):
                kind = name
            else:
                kind = "file " + ("cache" if "/ztrx/cache" in name else os.path.splitext(name)[1] or name[-30:])
            cur = [kind, size, 0, 0, start]
            kinds[kind][2] += size
            kinds[kind][3] += 1
            continue
        if cur and line.startswith("Rss:"):
            v = int(line.split()[1]); kinds[cur[0]][0] += v; cur[2] = v
        elif cur and line.startswith("Swap:"):
            v = int(line.split()[1]); kinds[cur[0]][1] += v; cur[3] = v
            if cur[2] + cur[3] > 256 * 1024:
                big.append((cur[2] + cur[3], cur[0], cur[1], cur[2], cur[3], cur[4]))
    tot_rss = sum(v[0] for v in kinds.values()); tot_swap = sum(v[1] for v in kinds.values())
    print(f"pid {pid}: RSS {tot_rss//1024} MB + swap {tot_swap//1024} MB = {(tot_rss+tot_swap)//1024} MB")
    print(f"{'kind':48} {'RSS MB':>8} {'swap MB':>8} {'mapped MB':>10} {'regions':>8}")
    for k, (rss, swap, size, n) in sorted(kinds.items(), key=lambda kv: -(kv[1][0] + kv[1][1]))[:18]:
        if rss + swap < 8 * 1024:
            continue
        print(f"{k[:48]:48} {rss//1024:8} {swap//1024:8} {size//1024:10} {n:8}")
    print("\nregions over 256 MB resident+swapped:")
    for tot, kind, size, rss, swap, start in sorted(big, reverse=True)[:15]:
        print(f"  {start:>14} {size//1024:7} MB mapped  {rss//1024:6} MB RSS {swap//1024:6} MB swap  {kind[:50]}")


main()
