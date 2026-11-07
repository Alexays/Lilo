"""Medians and interquartile ranges of `make page-bench` lines, by host and variant."""
import collections
import statistics
import sys

loads = collections.defaultdict(list)
for line in open(sys.argv[1]):
    _, variant, host, *values = line.split()
    loads[host, variant].append([int(value) for value in values])

# KB counts only what Resource Timing exposes: a cross-origin response without Timing-Allow-Origin shows 0.
print("median (IQR)    fcp ms      dcl ms      load ms     requests    KB          cpu ms      loads")
for host in dict.fromkeys(host for host, _ in loads):
    print(host)
    for variant in ("plain", "rules", "lilo"):
        rows = loads[host, variant]
        cells = []
        for column in zip(*rows):
            # -1 is a page that never loaded, or CPU the process could not report.
            values = [value for value in column if value >= 0]
            if len(values) < 2:
                cells.append("-".ljust(11))
                continue
            quartiles = statistics.quantiles(values, n=4)
            cells.append(f"{statistics.median(values):.0f} ({quartiles[2] - quartiles[0]:.0f})".ljust(11))
        print(f"  {variant:<13} " + " ".join(cells) + " " + str(len(rows)))
