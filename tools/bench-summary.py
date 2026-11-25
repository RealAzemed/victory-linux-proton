#!/usr/bin/env python3
"""Summarise a victory run log: in-world frame-rate lines only.

Usage: bench-summary.py <run.log> [more logs...]

A frame line is counted as "in world" when it has at least MIN_DRAWS
draws/frame (menus and the intro draw ~4-20). Prints medians of fps and the
per-frame breakdown, plus dropped draws, so two runs can be compared.
"""
import re
import statistics as st
import sys

MIN_DRAWS = 300
ANSI = re.compile(r"\x1b\[[0-9;]*m")
FRAME = re.compile(
    r"(?P<fps>[\d.]+) fps, (?P<ms>[\d.]+) ms/frame \((?P<prep>[\d.]+) preparing: "
    r"copies (?P<copies>[\d.]+) ms (?P<copy_mb>[\d.]+) MB, textures (?P<tex>[\d.]+) ms [\d.]+ MB; "
    r"(?P<gpu>[\d.]+) on the GPU; (?P<back>[\d.]+) copying back [\d.]+ MB\), "
    r"(?P<draws>\d+) draws/frame, dropped (?P<dropped>\d+) without a host pipeline "
    r"\((?P<making>\d+) being made\) and (?P<indirect>\d+) indirect"
)
WAITS = re.compile(r"texture refreshes per frame, all threads: ([\d.]+) ms.*?([\d.]+) ms waiting for title memory to hold")
MEM = re.compile(r"^#mem (\d+) avail_mb=(\d+) swap_mb=(\d+) rss_mb=(\d+)(?: swpin=(\d+) swpout=(\d+))?")


def summarise(path):
    rows, still, mem = [], [], []
    with open(path, errors="replace") as f:
        for line in f:
            line = ANSI.sub("", line)
            m = FRAME.search(line)
            if m:
                d = {k: float(v) for k, v in m.groupdict().items()}
                if d["draws"] >= MIN_DRAWS:
                    rows.append(d)
                continue
            w = WAITS.search(line)
            if w and rows:
                still.append(float(w.group(2)))
            mm = MEM.match(line)
            if mm:
                mem.append(tuple(int(x) if x else 0 for x in mm.groups()))
    try:
        with open(path + ".mem") as f:
            for line in f:
                mm = MEM.match(line)
                if mm:
                    mem.append(tuple(int(x) if x else 0 for x in mm.groups()))
    except OSError:
        pass
    print(f"== {path}")
    if not rows:
        print("   no in-world frame lines (never reached the world?)")
        return
    med = lambda k: st.median(r[k] for r in rows)
    print(f"   in-world lines: {len(rows)}   fps median {med('fps'):.2f}  (best {max(r['fps'] for r in rows):.1f})")
    print(f"   ms/frame {med('ms'):.0f} = preparing {med('prep'):.0f} [copies {med('copies'):.0f}, textures {med('tex'):.0f}]"
          f" + GPU {med('gpu'):.0f} + copy-back {med('back'):.0f}")
    print(f"   draws/frame {med('draws'):.0f}  dropped {med('dropped'):.0f} (+{med('indirect'):.0f} indirect), being made {med('making'):.0f}")
    if still:
        print(f"   waiting for title memory to hold still: median {st.median(still):.0f} ms/frame")
    if mem:
        print(f"   RAM available min {min(m[1] for m in mem)} MB, swap max {max(m[2] for m in mem)} MB, game RSS max {max(m[3] for m in mem)} MB")
        sw = [m for m in mem if m[4]]
        if len(sw) > 1 and sw[-1][0] > sw[0][0]:
            secs = sw[-1][0] - sw[0][0]
            print(f"   swap traffic: in {(sw[-1][4]-sw[0][4])*4/1024/secs:.1f} MB/s, out {(sw[-1][5]-sw[0][5])*4/1024/secs:.1f} MB/s (average over {secs} s)")


for p in sys.argv[1:]:
    summarise(p)
