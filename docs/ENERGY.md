# Energy: Lilo, Safari, Chrome and Firefox

Lilo runs on WebKit, the engine inside macOS, so it uses about as little energy as Safari. With the same tabs on the same Mac, Chrome draws about 3 times Lilo's power and Firefox about 10 times.

## Results

MacBook Pro (M4 Pro, 48 GB), macOS 27.0.1, plugged in. Lilo 0.11.0 (`93e8173e`), Safari 27.0.1, Chrome 156.0.8078.49, Firefox 159.0. Medians of 3 rounds of 60 s each, measured on 2026-10-29.

**Idle**: five static pages, the first one visible.

| Browser | Power above idle Mac | CPU | Energy impact |
|---------|---------------------:|----:|--------------:|
| Lilo    |   6 mW | 0.11 % |  0.04 |
| Safari  |   3 mW | 0.14 % |  0.11 |
| Chrome  |  62 mW | 1.25 % | 10.33 |
| Firefox |  45 mW | 1.09 % | 46.29 |

**Active**: a visible page with a CSS animation and a clock ticking every second, and four background tabs whose timers update the page four times a second.

| Browser | Power above idle Mac | CPU | Energy impact |
|---------|---------------------:|----:|--------------:|
| Lilo    |  37 mW |  1.38 % |  0.54 |
| Safari  |  34 mW |  1.22 % |  0.49 |
| Chrome  | 102 mW | 14.70 % | 69.12 |
| Firefox | 370 mW | 26.85 % | 72.88 |

- **Power above idle Mac** is the whole Mac's CPU and GPU power during the run, minus a sample taken with no browser open at the start of each round (53 to 68 mW). Idle readings under about 15 mW are within that noise: Lilo and Safari are indistinguishable from an idle Mac.
- **CPU** sums every process of the browser's coalition: the app, its helpers, and its web, GPU and network processes. 100 % is one core.
- **Energy impact** is the macOS score Activity Monitor shows. It weighs CPU, GPU and wakeups, and suits comparing browsers on one Mac better than reading as an absolute. Chrome's idle score moved between 10 and 62 from one round to the next.

## Method

`make energy-browsers` runs [scripts/energy_browsers.sh](../scripts/energy_browsers.sh):

1. A local server serves the pages, so the network plays no part.
2. Each browser except Safari gets a throwaway profile, opened once for a minute so first-run work (component downloads, filter lists) is done, then copied for every run. Lilo is the Release build of the checkout. Safari has a single profile, the real one.
3. Each run opens the five tabs with the first one visible, brings the browser to the front, waits 30 s, then samples it once a second for 60 s with `powermetrics`. The run is kept only if the browser stayed frontmost.
4. Each round starts with a sample with no browser open, and rotates the order of the browsers so drift over the run hits each alike.

No extension and no content blocker runs in any browser; on local pages, Lilo's default filter lists have nothing to block.

To reproduce, quit other apps (Safari included), plug the Mac in, and leave it alone for about 45 minutes:

```bash
make energy-browsers
```

`BROWSERS`, `ROUNDS`, `DURATION` and `APP` change what is measured. The medians land in `build/energy-browsers/summary.tsv` and every run in `runs.tsv`, with the processes measured.
