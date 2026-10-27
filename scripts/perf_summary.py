#!/usr/bin/env python3
"""Summarize a Lilo performance recording (Help > Diagnostics > Record), or compare two.

    perf_summary.py FILE
    perf_summary.py compare BEFORE AFTER
"""
import json
import sys
from collections import defaultdict


def load(path):
    with open(path, encoding="utf-8") as file:
        return json.load(file)


def percentile(values, p):
    ordered = sorted(values)
    return ordered[round((len(ordered) - 1) * p)] if ordered else 0.0


def summarize(trace):
    events = trace.get("traceEvents", [])
    names = {e["pid"]: e["args"]["name"] for e in events if e.get("ph") == "M" and e.get("name") == "process_name"}
    intervals = defaultdict(list)
    instants = defaultdict(int)
    counters = defaultdict(lambda: defaultdict(list))
    hangs = []
    main_intervals = []
    dropped_frames = 0
    for e in events:
        ph, key = e.get("ph"), f"{e.get('cat')}/{e.get('name')}"
        if ph == "X":
            duration = e.get("dur", 0) / 1000
            if key == "main/hang":
                hangs.append((e["ts"], duration))
            else:
                intervals[key].append(duration)
                if e.get("tid") == 1:
                    main_intervals.append((e["ts"], e["ts"] + e.get("dur", 0), key))
        elif ph == "i":
            instants[key] += 1
            if key == "frames/drop":
                dropped_frames += int(e.get("args", {}).get("detail", "0") or 0)
        elif ph == "C":
            counters[names.get(e["pid"], str(e["pid"]))][e["name"]].append(e["args"]["value"])

    return {
        "metadata": trace.get("metadata", {}),
        "intervals": {
            key: {"count": len(v), "p50": percentile(v, 0.5), "p95": percentile(v, 0.95), "max": max(v), "total": sum(v)}
            for key, v in intervals.items()
        },
        "hangs": [
            {
                "atMs": ts / 1000,
                "durationMs": duration,
                "during": sorted({k for start, end, k in main_intervals if start < ts + duration * 1000 and end > ts}),
            }
            for ts, duration in sorted(hangs, key=lambda h: -h[1])
        ],
        "processes": {
            name: {
                "cpuAvg": sum(c["cpu %"]) / len(c["cpu %"]) if c["cpu %"] else 0.0,
                "cpuMax": max(c["cpu %"], default=0.0),
                "footprintMaxMB": max(c["footprint MB"], default=0.0),
                "footprintEndMB": c["footprint MB"][-1] if c["footprint MB"] else 0.0,
                "wakeupsAvg": sum(c["wakeups/s"]) / len(c["wakeups/s"]) if c["wakeups/s"] else 0.0,
                "diskWriteKBAvg": sum(c["disk write KB/s"]) / len(c["disk write KB/s"]) if c["disk write KB/s"] else 0.0,
                "powerAvgMW": sum(c["power mW"]) / len(c["power mW"]) if c["power mW"] else 0.0,
            }
            for name, c in counters.items()
        },
        "events": dict(instants),
        "droppedFrames": dropped_frames,
    }


def print_summary(summary, limit=20):
    meta = summary["metadata"]
    print(f"Lilo {meta.get('liloVersion', '?')} ({meta.get('liloBuild', '?')}) on {meta.get('macModel', '?')}, {meta.get('macOS', '?')}")
    print(
        f"{meta.get('durationSeconds', 0):.0f} s, {meta.get('windows', 0)} windows, {meta.get('tabs', 0)} tabs "
        f"({meta.get('liveTabs', 0)} live), {meta.get('extensions', 0)} extensions, dropped events: {meta.get('droppedEvents', 0)}"
    )

    print("\nIntervals by total time (ms)")
    print(f"{'name':<36}{'count':>7}{'p50':>9}{'p95':>9}{'max':>9}{'total':>10}")
    for key, s in sorted(summary["intervals"].items(), key=lambda item: -item[1]["total"])[:limit]:
        print(f"{key:<36}{s['count']:>7}{s['p50']:>9.1f}{s['p95']:>9.1f}{s['max']:>9.1f}{s['total']:>10.0f}")

    hangs = summary["hangs"]
    print(f"\nMain-thread hangs: {len(hangs)}, {sum(h['durationMs'] for h in hangs):.0f} ms in all; dropped frames: {summary['droppedFrames']}")
    for hang in hangs[:limit]:
        during = ", ".join(hang["during"]) or "no signpost: see metadata.metricKit for stacks"
        print(f"  {hang['durationMs']:>7.0f} ms at {hang['atMs'] / 1000:>7.1f} s  {during}")

    print("\nProcesses")
    print(f"{'process':<16}{'cpu avg':>9}{'cpu max':>9}{'MB max':>9}{'MB end':>9}{'wake/s':>9}{'write KB/s':>12}{'mW':>8}")
    for name, p in sorted(summary["processes"].items(), key=lambda item: -item[1]["cpuAvg"]):
        print(
            f"{name:<16}{p['cpuAvg']:>9.1f}{p['cpuMax']:>9.1f}{p['footprintMaxMB']:>9.0f}{p['footprintEndMB']:>9.0f}"
            f"{p['wakeupsAvg']:>9.1f}{p['diskWriteKBAvg']:>12.1f}{p['powerAvgMW']:>8.0f}"
        )

    print("\nEvents")
    for key, count in sorted(summary["events"].items(), key=lambda item: -item[1])[:limit]:
        print(f"{count:>8}  {key}")

    payloads = meta.get("metricKit") or []
    hang_diagnostics = sum(len(p.get("hangDiagnostics", [])) for p in payloads if isinstance(p, dict))
    if hang_diagnostics:
        print(f"\nMetricKit: {hang_diagnostics} hang diagnostics with call stacks in metadata.metricKit;")
        print("symbolicate with: atos -o Lilo.app.dSYM/Contents/Resources/DWARF/Lilo -l <loadAddress> <address>")


def print_comparison(before, after, limit=25):
    def delta(old, new):
        return f"{(new - old) / old * 100:+.0f}%" if old else "new"

    print("Intervals p50 / p95 (ms)")
    print(f"{'name':<36}{'before':>16}{'after':>16}{'p95':>8}")
    keys = sorted(set(before["intervals"]) | set(after["intervals"]),
                  key=lambda k: -max(before["intervals"].get(k, {}).get("total", 0), after["intervals"].get(k, {}).get("total", 0)))
    for key in keys[:limit]:
        b, a = before["intervals"].get(key), after["intervals"].get(key)
        fmt = lambda s: f"{s['p50']:.1f} / {s['p95']:.1f}" if s else "-"
        print(f"{key:<36}{fmt(b):>16}{fmt(a):>16}{delta(b['p95'], a['p95']) if a and b else '':>8}")

    hangs = lambda s: sum(h["durationMs"] for h in s["hangs"])
    print(f"\nHangs: {len(before['hangs'])} ({hangs(before):.0f} ms) to {len(after['hangs'])} ({hangs(after):.0f} ms); "
          f"dropped frames: {before['droppedFrames']} to {after['droppedFrames']}")

    print("\nProcess averages: cpu %, wakeups/s, mW")
    for name in sorted(set(before["processes"]) | set(after["processes"])):
        b, a = before["processes"].get(name), after["processes"].get(name)
        fmt = lambda p: f"{p['cpuAvg']:.1f}, {p['wakeupsAvg']:.0f}, {p['powerAvgMW']:.0f}" if p else "-"
        print(f"{name:<16}{fmt(b):>20}{fmt(a):>20}{delta(b['cpuAvg'], a['cpuAvg']) if a and b else '':>8}")


def main(argv):
    if len(argv) == 2:
        print_summary(summarize(load(argv[1])))
    elif len(argv) == 4 and argv[1] == "compare":
        print_comparison(summarize(load(argv[2])), summarize(load(argv[3])))
    else:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
