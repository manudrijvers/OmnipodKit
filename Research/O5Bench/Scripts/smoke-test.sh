#!/usr/bin/env bash
# Test fixture generation only. The product has no run-all control or physical transport.
set -euo pipefail
bench_root="$(cd "$(dirname "$0")/.." && pwd)"
bench_work="$(mktemp -d "${TMPDIR:-/tmp}/o5-bench-smoke.XXXXXX")"
trap 'rm -rf "$bench_work"' EXIT
bench_binary="$bench_root/.build/debug/o5-bench"
bench_session="$bench_work/session.private"
bench_destination="${1:-$bench_work/sharing}"
"$bench_binary" "$bench_session" init
"$bench_binary" "$bench_session" arm --confirm-off-body
"$bench_binary" "$bench_session" baseline "$bench_work/baseline"
"$bench_binary" "$bench_session" reconnect
"$bench_binary" "$bench_session" targetProfile
"$bench_binary" "$bench_session" dia
"$bench_binary" "$bench_session" enable
"$bench_binary" "$bench_session" provision
"$bench_binary" "$bench_session" observe
"$bench_binary" "$bench_session" reconnectReception
"$bench_binary" "$bench_session" feed ok ok
"$bench_binary" "$bench_session" alarm "Synthetic operator observation after reception"
"$bench_binary" "$bench_session" export "$bench_destination"
