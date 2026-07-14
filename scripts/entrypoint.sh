#!/usr/bin/env bash
# Entrypoint for the opencode-docker per-user sandbox.
#   1. start the in-container Docker daemon (DinD)
#   2. wire up GitHub / git credentials from env
#   3. generate opencode config for the chosen Claude mode (api | max)
#   4. launch `opencode web`
set -euo pipefail

log() { echo "[entrypoint] $*"; }

# ---------------------------------------------------------------------------
# 1. Docker-in-Docker
# ---------------------------------------------------------------------------
if [ "${ENABLE_DIND:-true}" = "true" ]; then
  if [ -S /var/run/docker.sock ] && docker info >/dev/null 2>&1; then
    log "docker socket already available (host socket mounted?) — not starting dockerd"
  else
    log "starting dockerd..."
    # A prior run can leave a stale /var/run/docker.pid (e.g. after
    # `docker compose restart`, which reuses the same container filesystem).
    # The new daemon then refuses to start — "process with PID N is still
    # running" — because a different process now holds that recycled PID. Clear
    # it first. Harmless on a fresh container (file absent).
    rm -f /var/run/docker.pid
    # Needs --privileged. Storage lives on the /var/lib/docker volume (ext4),
    # avoiding overlay-on-overlay issues.
    dockerd \
      --host=unix:///var/run/docker.sock \
      >/var/log/dockerd.log 2>&1 &

    tries=0
    until docker info >/dev/null 2>&1; do
      tries=$((tries + 1))
      if [ "$tries" -gt 60 ]; then
        log "dockerd did not become ready in time. Last logs:"
        tail -n 40 /var/log/dockerd.log || true
        log "If you see cgroup/iptables errors, make sure the container runs with --privileged."
        exit 1
      fi
      sleep 1
    done
    log "dockerd ready ($(docker --version))"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Git / GitHub credentials
# ---------------------------------------------------------------------------
if [ -n "${GITHUB_PAT:-}" ]; then
  log "configuring GitHub credentials from GITHUB_PAT"
  git config --global credential.helper store
  printf 'https://x-access-token:%s@github.com\n' "${GITHUB_PAT}" > "${HOME}/.git-credentials"
  chmod 600 "${HOME}/.git-credentials"
  # gh CLI reads GH_TOKEN; make it available to opencode/claude subprocesses too
  export GH_TOKEN="${GITHUB_PAT}"
  # Refresh the GH_TOKEN line in .bashrc on every boot (interactive shells source
  # it). NOT a conditional append: a stale token persisted in the home volume
  # would otherwise linger and override the correct container-level GH_TOKEN,
  # breaking `gh` in the terminal.
  touch "${HOME}/.bashrc"
  sed -i '/export GH_TOKEN=/d' "${HOME}/.bashrc"
  echo "export GH_TOKEN='${GITHUB_PAT}'" >> "${HOME}/.bashrc"

  # Auto-derive git identity from the PAT when not explicitly provided.
  if [ -z "${GIT_USER_NAME:-}" ] || [ -z "${GIT_USER_EMAIL:-}" ]; then
    # Use the "token" auth scheme — works for both classic (ghp_) and
    # fine-grained (github_pat_) PATs; "Bearer" 401s on some fine-grained ones.
    user_json="$(curl -fsSL \
        -H "Authorization: token ${GITHUB_PAT}" \
        -H "Accept: application/vnd.github+json" \
        https://api.github.com/user 2>/dev/null || true)"
    if [ -n "${user_json}" ]; then
      gh_login="$(echo "${user_json}" | jq -r '.login // empty')"
      gh_name="$(echo "${user_json}"  | jq -r '.name  // empty')"
      gh_id="$(echo "${user_json}"    | jq -r '.id    // empty')"
      gh_email="$(echo "${user_json}" | jq -r '.email // empty')"
      if [ -n "${gh_login}" ]; then
        : "${GIT_USER_NAME:=${gh_name:-$gh_login}}"
        if [ -z "${GIT_USER_EMAIL:-}" ]; then
          # If the public email is hidden, try /user/emails for the primary
          # verified address (needs the "Email addresses: Read" permission).
          if [ -z "${gh_email}" ]; then
            emails_json="$(curl -fsSL \
                -H "Authorization: token ${GITHUB_PAT}" \
                -H "Accept: application/vnd.github+json" \
                https://api.github.com/user/emails 2>/dev/null || true)"
            gh_email="$(echo "${emails_json}" | jq -r '
                if type=="array"
                then (map(select(.primary and .verified)) | .[0].email) // empty
                else empty end' 2>/dev/null)"
          fi
          if [ -n "${gh_email}" ]; then
            GIT_USER_EMAIL="${gh_email}"
          elif [ -n "${gh_id}" ]; then
            # GitHub noreply address — works even when the email is hidden
            GIT_USER_EMAIL="${gh_id}+${gh_login}@users.noreply.github.com"
          fi
        fi
        log "git identity from PAT: ${GIT_USER_NAME} <${GIT_USER_EMAIL}>"
      fi
    else
      log "could not reach api.github.com to derive git identity (using fallback)"
    fi
  fi
fi

git config --global user.name  "${GIT_USER_NAME:-opencode}"
git config --global user.email "${GIT_USER_EMAIL:-opencode@localhost}"
git config --global init.defaultBranch main
git config --global --add safe.directory '*'

# ---------------------------------------------------------------------------
# 3. opencode config — Claude mode
#    CLAUDE_AUTH_MODE = max     -> Claude Max via the opencode-with-claude plugin
#                                  (writes opencode.json + needs `claude auth login`)
#                     = manual  -> leave opencode.json untouched; configure the
#                                  provider yourself in the opencode web UI (/connect).
#    Default: max.
# ---------------------------------------------------------------------------
OPENCODE_CONFIG_DIR="${HOME}/.config/opencode"
OPENCODE_CONFIG="${OPENCODE_CONFIG_DIR}/opencode.json"
mkdir -p "${OPENCODE_CONFIG_DIR}"

mode="${CLAUDE_AUTH_MODE:-max}"
can_write() { [ ! -f "${OPENCODE_CONFIG}" ] || [ "${OPENCODE_FORCE_CONFIG:-false}" = "true" ]; }

if [ "$mode" = "max" ]; then
  if can_write; then
    log "opencode config -> Claude Max mode (opencode-with-claude plugin)"
    cat > "${OPENCODE_CONFIG}" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "plugin": ["opencode-with-claude"],
  "provider": {
    "anthropic": {
      "options": {
        "baseURL": "http://127.0.0.1:3456",
        "apiKey": "dummy"
      }
    }
  }
}
JSON
  else
    log "opencode config kept (max mode; set OPENCODE_FORCE_CONFIG=true to regenerate)"
  fi
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    log "Claude authenticated via CLAUDE_CODE_OAUTH_TOKEN"
  elif [ ! -f "${HOME}/.claude/.credentials.json" ] && [ ! -d "${HOME}/.claude/projects" ]; then
    log "NOTE: Claude Max mode is not authenticated yet. Either:"
    log "  - set CLAUDE_CODE_OAUTH_TOKEN in .env (generate once: make claude-token), or"
    log "  - log in interactively: make claude-login"
  fi
else
  log "manual mode: leaving opencode config untouched —"
  log "configure the provider from the opencode web UI (or run 'opencode' and /connect)."
fi

# ---------------------------------------------------------------------------
# 4. Web credentials — one source of truth for BOTH web UIs
#    WEB_USERNAME / WEB_PASSWORD protect opencode web AND code-server with the
#    same login/password. We fan them out to each server's own env var here.
#      - opencode web : HTTP basic auth (OPENCODE_SERVER_USERNAME/PASSWORD)
#      - code-server  : password login form (PASSWORD; username not used)
#    The password is only ever passed via env — never written to disk in the
#    persisted home volume.
# ---------------------------------------------------------------------------
: "${OPENCODE_PORT:=4096}"
: "${CODE_SERVER_PORT:=4097}"
: "${WEB_USERNAME:=opencode}"
export OPENCODE_PORT CODE_SERVER_PORT

export OPENCODE_SERVER_USERNAME="${WEB_USERNAME}"
export OPENCODE_SERVER_PASSWORD="${WEB_PASSWORD:-}"
export PASSWORD="${WEB_PASSWORD:-}"   # code-server

if [ -z "${WEB_PASSWORD:-}" ]; then
  # code-server refuses to serve with `--auth password` and an empty password,
  # so drop it to no-auth too — matching opencode's unauthenticated behaviour.
  export CODE_SERVER_AUTH=none
  log "WARNING: WEB_PASSWORD is not set — opencode web AND code-server will be UNAUTHENTICATED."
  log "         Fine for local use; set it before exposing this box to a network."
else
  export CODE_SERVER_AUTH=password
fi

# opencode/code-server both open this dir as the workspace — a dedicated dir,
# NOT $HOME (opening $HOME breaks opencode's project picker / recent-projects).
mkdir -p /root/workspace
cd /root/workspace

# Allow overriding the launched command (e.g. keep the box up for `exec`)
if [ "$#" -gt 0 ]; then
  log "running custom command: $*"
  exec "$@"
fi

# ---------------------------------------------------------------------------
# 5. Two disjoint pm2 namespaces so box services and your project processes
#    never step on each other — no dedup, no app names hardcoded here.
#
#    - Your projects use the DEFAULT pm2 home (~/.pm2). In a project shell:
#        pm2 start "pnpm dev" --name foo   &&   pm2 save
#      `pm2 save` snapshots them to ~/.pm2/dump.pm2 (persisted in the home
#      volume); we `pm2 resurrect` that dump here so they survive box restarts.
#      Opt out with PM2_RESURRECT=false.
#
#    - The box's own services (opencode, code-server, …) run under a SEPARATE
#      pm2 home (PM2_HOME below), straight from the ecosystem file — the single
#      source of truth. Because it's a different home, a user `pm2 save` can
#      never capture them, so box services stay authoritative and you can add
#      or remove them by editing only ecosystem.config.js.
#      Inspect them with:  PM2_HOME=/root/.pm2-box pm2 ls
# ---------------------------------------------------------------------------
if [ "${PM2_RESURRECT:-true}" = "true" ] && [ -f "${HOME}/.pm2/dump.pm2" ]; then
  log "resurrecting saved pm2 project processes from ~/.pm2/dump.pm2"
  pm2 resurrect || log "pm2 resurrect failed — continuing without saved processes"
fi

log "starting opencode web on :${OPENCODE_PORT} + code-server on :${CODE_SERVER_PORT} (mode: ${mode}, auth: ${CODE_SERVER_AUTH})"
export PM2_HOME=/root/.pm2-box
exec pm2-runtime start /opt/opencode-docker/ecosystem.config.js
