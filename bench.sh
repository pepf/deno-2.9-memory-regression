#!/usr/bin/env bash
#
# Reproduce the Deno 2.9 memory regressions on a clean-room npm+jsr graph.
#
# Measures, for each Deno version, two things:
#   1. BASELINE  — steady-state RSS of `deno run server.ts` (no --watch, 0 reloads)
#   2. WATCH LEAK — RSS after each hot-reload of `deno run --watch server.ts`
#                   (append a line to server.ts -> deno reloads -> measure)
#
# Everything runs in Docker. Each version gets a fresh cache, so the only
# variable is the Deno binary. Requires: docker. Nothing is installed on the host.
#
# Usage:
#   ./bench.sh                       # defaults: 2.8.0 vs 2.9.0, 6 reloads
#   IMAGES="denoland/deno:2.8.0 denoland/deno:2.9.0" RELOADS=8 ./bench.sh
set -euo pipefail

IMAGES="${IMAGES:-denoland/deno:2.8.0 denoland/deno:2.9.0}"
RELOADS="${RELOADS:-6}"
SETTLE="${SETTLE:-12}"     # seconds to settle after a (re)start before sampling
SShere="$(cd "$(dirname "$0")" && pwd)"

# Sum VmRSS (kB) of every process in a container — it's isolated, so this is the
# whole Deno runtime footprint.
rss() {
  docker exec "$1" sh -c 'tot=0; for p in /proc/[0-9]*; do
    r=$(awk "/^VmRSS/{print \$2}" "$p/status" 2>/dev/null); [ -n "$r" ] && tot=$((tot+r));
  done; echo "$tot"'
}

mb() { awk "BEGIN{printf \"%.0f\", $1/1024}"; }

wait_listen() { # container  expected_count
  local c=$1 want=$2
  for _ in $(seq 1 90); do
    [ "$(docker logs "$c" 2>&1 | grep -c 'running on')" -ge "$want" ] && return 0
    docker ps -a --filter name="$c" --format '{{.Status}}' | grep -qi exited && {
      echo "  ! container $c exited early:"; docker logs "$c" 2>&1 | tail -8; return 1; }
    sleep 2
  done
  echo "  ! timed out waiting for listen #$want"; return 1
}

run_arm() { # image
  local img=$1
  local cname="denorepro"
  local app_vol="denorepro_app" nm_vol="denorepro_nm" dc_vol="denorepro_dc"
  docker rm -f "$cname" >/dev/null 2>&1 || true
  docker volume rm "$app_vol" "$nm_vol" "$dc_vol" >/dev/null 2>&1 || true
  docker volume create "$app_vol" >/dev/null
  docker volume create "$nm_vol"  >/dev/null
  docker volume create "$dc_vol"  >/dev/null

  echo "== $img =="

  # ---- 1) BASELINE (plain `deno run`, no reloads) ----
  docker run -d --name "$cname" \
    -v "$app_vol":/app -v "$nm_vol":/app/node_modules -v "$dc_vol":/deno_cache \
    -e DENO_DIR=/deno_cache \
    -v "$SShere":/src:ro "$img" \
    bash -lc 'set -e; cp -a /src/server.ts /src/deno.json /app/; cd /app;
              deno cache server.ts >/dev/null 2>&1;
              exec deno run --allow-all server.ts' >/dev/null
  wait_listen "$cname" 1 || { docker rm -f "$cname" >/dev/null 2>&1; return 1; }
  sleep "$SETTLE"
  local base; base=$(rss "$cname")
  printf "  baseline (plain run) .......... %5s MB\n" "$(mb "$base")"
  docker rm -f "$cname" >/dev/null 2>&1

  # ---- 2) WATCH LEAK (append -> reload -> measure) ----
  docker run -d --name "$cname" \
    -v "$app_vol":/app -v "$nm_vol":/app/node_modules -v "$dc_vol":/deno_cache \
    -e DENO_DIR=/deno_cache \
    -v "$SShere":/src:ro "$img" \
    bash -lc 'set -e; cp -a /src/server.ts /src/deno.json /app/; cd /app;
              exec deno run --watch --allow-all server.ts' >/dev/null
  wait_listen "$cname" 1 || { docker rm -f "$cname" >/dev/null 2>&1; return 1; }
  sleep "$SETTLE"
  printf "  watch reload #0 (initial) ..... %5s MB\n" "$(mb "$(rss "$cname")")"
  local n
  for n in $(seq 1 "$RELOADS"); do
    docker exec "$cname" sh -c "printf '\n// reload %s\n' '$n' >> /app/server.ts"
    wait_listen "$cname" "$((n+1))" || break
    sleep "$SETTLE"
    printf "  watch reload #%-2s ............... %5s MB\n" "$n" "$(mb "$(rss "$cname")")"
  done

  docker rm -f "$cname" >/dev/null 2>&1
  docker volume rm "$app_vol" "$nm_vol" "$dc_vol" >/dev/null 2>&1 || true
  echo
}

echo "Deno memory repro — baseline + --watch reload leak"
echo "reloads=$RELOADS settle=${SETTLE}s"
echo
for img in $IMAGES; do
  run_arm "$img"
done
echo "Done."
