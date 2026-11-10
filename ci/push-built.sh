#!/usr/bin/env bash
# Pushes store paths to Cachix as soon as the Nix post-build hook appends
# them to QUEUE, so finished packages are available (and kept) even if the
# rest of the build is still running or later fails.
#
# A path is skipped if:
#   - it's a source (downloaded archive/checkout, a "fixed-output" path):
#     sources carry no license info (e.g. Steam's download archive) and can
#     always be fetched from upstream again, or
#   - anything in its closure is unfree: cachix pushes a path together with
#     its dependencies, and the cache is public.
#
# Stops when it reads a line "DONE".
# Usage: push-built.sh QUEUE CACHE UNFREE_REGEX
set -u
queue=$1 cache=$2 filter=$3

tail -n +1 -F "$queue" 2>/dev/null | while read -r path; do
  case "$path" in
    DONE) break ;;
    /nix/store/*) ;;
    *) continue ;;
  esac
  if nix path-info --json "$path" 2>/dev/null | grep -q '"ca":"fixed:'; then
    echo "skip (source): $path"
    continue
  fi
  if nix path-info --recursive "$path" | grep -qE "$filter"; then
    echo "skip (unfree in closure): $path"
    continue
  fi
  if cachix push "$cache" "$path"; then
    echo "pushed: $path"
  else
    echo "push failed (the final sweep retries): $path"
  fi
done
