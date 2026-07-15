#!/usr/bin/env bash
# Periodically `git pull --ff-only` every git repo in the home dir and the
# workspace. Driven by a single env var, GIT_AUTOPULL_INTERVAL (a sleep(1)
# duration: 1h / 30m / 3600). Empty/off means disabled — the ecosystem file
# only launches this script when it's enabled, so here we assume it should run.
set -uo pipefail

interval="${GIT_AUTOPULL_INTERVAL:-}"

log() { echo "[git-autopull] $*"; }

# Accept a bare number (seconds) or a coreutils suffix (s/m/h/d).
if ! [[ "${interval}" =~ ^[0-9]+[smhd]?$ ]]; then
  log "invalid GIT_AUTOPULL_INTERVAL='${interval}' — expected e.g. 1h, 30m or 3600. Not running."
  exit 0
fi

pull_all() {
  # Immediate children of $HOME and of the workspace that are git repos.
  # -maxdepth keeps us out of node_modules and deeply nested checkouts.
  {
    find "${HOME}"              -maxdepth 2 -type d -name .git 2>/dev/null
    find "${HOME}/workspace"    -maxdepth 2 -type d -name .git 2>/dev/null
  } | sort -u | while read -r gitdir; do
    repo="$(dirname "${gitdir}")"
    # Only repos on a branch that tracks an upstream; --ff-only never creates a
    # merge commit or leaves conflicts behind — safe to run unattended.
    if git -C "${repo}" rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
      if git -C "${repo}" pull --ff-only --quiet 2>/dev/null; then
        log "pulled ${repo}"
      else
        log "skipped ${repo} (not fast-forwardable or fetch failed)"
      fi
    fi
  done
}

log "auto-pull enabled — every ${interval}"
while true; do
  sleep "${interval}" || { log "sleep failed for interval='${interval}' — stopping"; exit 0; }
  pull_all
done
