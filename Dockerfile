# opencode-docker — a per-user dev sandbox with opencode + Claude Code + Docker-in-Docker
#
# Base: Node 22 (Debian bookworm) — opencode & claude-code ship via npm, and
# most web/AI projects are Node-based. Python + uv are added for the rest.
FROM node:22-bookworm-slim

# ---------------------------------------------------------------------------
# System packages: git, python, docker engine (for Docker-in-Docker), tooling
# ---------------------------------------------------------------------------
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg lsb-release \
        git openssh-client \
        python3 python3-pip python3-venv \
        iptables uidmap \
        tini procps sudo jq vim; \
    # Docker needs iptables-legacy inside a container on bookworm
    update-alternatives --set iptables /usr/sbin/iptables-legacy || true; \
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy || true; \
    rm -rf /var/lib/apt/lists/*

# ---- Docker Engine + Compose plugin (Docker-in-Docker) --------------------
RUN set -eux; \
    install -m 0755 -d /etc/apt/keyrings; \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc; \
    chmod a+r /etc/apt/keyrings/docker.asc; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian bookworm stable" \
        > /etc/apt/sources.list.d/docker.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; \
    rm -rf /var/lib/apt/lists/*; \
    # Back-compat shim: many projects/scripts still call `docker-compose` (v1).
    printf '#!/bin/sh\nexec docker compose "$@"\n' > /usr/local/bin/docker-compose; \
    chmod +x /usr/local/bin/docker-compose

# ---- GitHub CLI (handy for the agents; uses GITHUB_PAT) -------------------
RUN set -eux; \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli.gpg; \
    chmod a+r /etc/apt/keyrings/githubcli.gpg; \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends gh; \
    rm -rf /var/lib/apt/lists/*

# ---- Python fast tooling: uv -----------------------------------------------
RUN pip install --no-cache-dir --break-system-packages uv

# ---- AI coding agents ------------------------------------------------------
#  opencode-ai            -> `opencode` (TUI + `opencode web`)
#  @anthropic-ai/claude-code -> `claude`
#  opencode-with-claude   -> opencode plugin bridging opencode <-> Claude Max
#                            (runs the local "Meridian" proxy on :3456)
#                            https://github.com/ianjwhite99/opencode-with-claude
RUN npm install -g \
        opencode-ai \
        @anthropic-ai/claude-code \
        opencode-with-claude \
    && npm cache clean --force

# ---- JS package managers (pnpm, yarn) + process manager (pm2) --------------
#  pnpm/yarn via corepack (ships with Node) — respects each project's
#  "packageManager" field; versions are pre-cached at build time.
#  pm2 via npm for keeping long-running dev processes alive.
RUN corepack enable \
    && corepack prepare pnpm@latest --activate \
    && corepack prepare yarn@stable --activate \
    && npm install -g pm2 \
    && npm cache clean --force

# ---- Playwright + Chromium (browser automation / e2e testing) --------------
#  Browsers install to /ms-playwright (NOT under /root), so the home volume
#  doesn't shadow them at runtime. `--with-deps` pulls the required system libs.
#  Note: Chromium runs as root here, so launch it with args:['--no-sandbox'].
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN npm install -g playwright \
    && playwright install --with-deps chromium \
    && npm cache clean --force \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Runtime layout
# ---------------------------------------------------------------------------
# /root            : the user's home — a single volume here backs up projects +
#                    all agent config/auth.
# /root/workspace  : where projects live and what opencode opens (opencode wants
#                    a workspace dir that is NOT $HOME). Also reachable as
#                    /workspace via a symlink.
# /var/lib/docker  : DinD storage (mount a separate volume; do NOT back this up).
RUN mkdir -p /root/workspace && ln -s /root/workspace /workspace
WORKDIR /root/workspace

# Headless: `opencode web` tries to open a browser via xdg-open, which doesn't
# exist here. Provide a no-op shim so it doesn't spam ENOENT errors.
RUN printf '#!/bin/sh\necho "[xdg-open] (headless, ignored) $*" >&2\nexit 0\n' \
      > /usr/local/bin/xdg-open \
    && chmod +x /usr/local/bin/xdg-open

COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# opencode web (default) + a sample dev-port range. Actual published ports are
# controlled at run time via docker-compose (see docker-compose.yml / DEV_PORTS).
EXPOSE 4096
EXPOSE 3000-3010

# tini reaps zombies (dockerd + child dev containers spawn many short-lived procs)
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/entrypoint.sh"]
