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
# 4. Launch opencode web
# ---------------------------------------------------------------------------
: "${OPENCODE_PORT:=4096}"
export OPENCODE_PORT

if [ -z "${OPENCODE_SERVER_PASSWORD:-}" ]; then
  log "WARNING: OPENCODE_SERVER_PASSWORD is not set — opencode web will be UNAUTHENTICATED."
  log "         Fine for local use; set it before exposing this box to a network."
fi

# Allow overriding the launched command (e.g. keep the box up for `exec`)
if [ "$#" -gt 0 ]; then
  log "running custom command: $*"
  exec "$@"
fi

log "starting opencode web on 0.0.0.0:${OPENCODE_PORT} (mode: ${mode})"
# opencode opens its cwd as the workspace — use a dedicated dir, NOT $HOME
# (opening $HOME breaks opencode's project picker / recent-projects display).
mkdir -p /root/workspace
cd /root/workspace
exec opencode web --hostname 0.0.0.0 --port "${OPENCODE_PORT}"
