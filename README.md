# Deno 2.9 memory regression — minimal reproduction

Two independent memory regressions in Deno **2.9** vs **2.8.0**, on a realistic
npm-dominant module graph with a couple of `jsr:` deps mixed in (the shape of a
typical Deno backend). No application logic — the server only imports the deps
and idles.

Both regressions were introduced in **2.9.0** and are **still present, unchanged,
in the latest patch release 2.9.1** — the baseline and per-reload numbers for
2.9.1 are indistinguishable from 2.9.0 (see below).

1. **Startup baseline ~5× higher.** A plain `deno run server.ts`, sitting idle
   with zero reloads, uses far more RSS on 2.9 than on 2.8.
2. **`deno run --watch` per-reload leak.** Each hot-reload retains a large chunk
   of RSS that is never reclaimed, growing linearly with no plateau — related to
   [denoland/deno#35664](https://github.com/denoland/deno/issues/35664). The
   per-reload cost is an order of magnitude larger on 2.9 than on 2.8.

## Run it

Requires only Docker. Nothing is installed on the host; each Deno version runs in
its own container with a fresh cache, so the only variable is the Deno binary.

```bash
./bench.sh
# or: IMAGES="denoland/deno:2.8.0 denoland/deno:2.9.0 denoland/deno:2.9.1" RELOADS=8 SETTLE=12 ./bench.sh
```

## What it measures

For each version: baseline RSS of `deno run` (no watch), then RSS after each
reload of `deno run --watch` (a line is appended to `server.ts` to trigger each
reload). RSS is the sum of `VmRSS` across all processes in the (isolated)
container.

## Observed (Apple Silicon, Docker Desktop, aarch64 images)

| Metric | Deno 2.8.0 | Deno 2.9.0 | Deno 2.9.1 |
| --- | --- | --- | --- |
| baseline (plain `deno run`, idle) | 114 MB | 561 MB (**~4.9×**) | 561 MB (**~4.9×**) |
| `--watch` growth per reload | ~12 MB | ~470 MB (**~39×**) | ~470 MB (**~39×**) |
| RSS after 6 reloads | 184 MB | 3366 MB | 3367 MB |

2.9.1 is a dead heat with 2.9.0 — the patch release did **not** touch either
regression.

Full run (`RELOADS=6`), all three from a single machine, one run:

```
== denoland/deno:2.8.0 ==     == denoland/deno:2.9.0 ==     == denoland/deno:2.9.1 ==
  baseline .......  114 MB       baseline .......  561 MB       baseline .......  561 MB
  reload #0 ......  110 MB       reload #0 ......  559 MB       reload #0 ......  559 MB
  reload #1 ......  125 MB       reload #1 ...... 1032 MB       reload #1 ...... 1032 MB
  reload #2 ......  138 MB       reload #2 ...... 1504 MB       reload #2 ...... 1504 MB
  reload #3 ......  149 MB       reload #3 ...... 1975 MB       reload #3 ...... 1975 MB
  reload #4 ......  160 MB       reload #4 ...... 2401 MB       reload #4 ...... 2447 MB
  reload #5 ......  173 MB       reload #5 ...... 2893 MB       reload #5 ...... 2918 MB
  reload #6 ......  184 MB       reload #6 ...... 3366 MB       reload #6 ...... 3367 MB
```

All three `deno --version` report the **same V8 and TypeScript** (`v8 14.9.207.2-rusty`,
`typescript 6.0.3`) — 2.9.1 bumped neither — so this is Deno's own (Rust-side)
npm/node-compat module handling, not a V8 change.

> Numbers scale with graph size. A large real app (mostly `npm:`, plus `jsr:`
> deps) showed baseline 314 MB → 811 MB and ~540 MB retained *per reload* under
> `--watch` on 2.9, reaching 5 GB in 8 saves.

## Workarounds

- Pin back to Deno 2.8.0 (fixes the baseline; leaves a small ~12 MB/reload leak).
  Upgrading to 2.9.1 does **not** help — it carries the same regression as 2.9.0.
- For dev hot-reload, use a fresh-process reloader instead of `--watch`, e.g.
  `watchexec -r -e ts -- deno run --allow-all server.ts` — this eliminates the
  per-reload leak entirely on any version.
