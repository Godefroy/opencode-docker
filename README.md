# opencode-docker

A deployable **per-user dev sandbox** in a single Docker image. One box per user,
with the AI coding agents preinstalled and its **own Docker daemon inside** so each
user can spin up their own `docker compose` projects and expose their ports.

Each box ships:

- **git** + **GitHub CLI** (`gh`), authenticated from a PAT
- **[opencode](https://opencode.ai)** — exposed as a web UI (`opencode web`)
- **[code-server](https://github.com/coder/code-server)** — full **VS Code in the browser**, behind the same password as opencode web
- **[Claude Code](https://github.com/anthropics/claude-code)** (`claude`)
- **[opencode-with-claude](https://github.com/ianjwhite99/opencode-with-claude)** — plugin to drive opencode with your **Claude Max** subscription
- **Node.js 22** (+ `pnpm`, `yarn`, `pm2`) **+ Python 3 + uv**, `vim`
- **Playwright + Chromium** for browser automation / e2e (launch with `args:['--no-sandbox']` — the box runs as root; browsers live in `/ms-playwright`)
- **Docker-in-Docker** — run other containers/`docker compose` projects from inside the box, with their ports chained out to the host

Test it locally, deploy it on **Dokploy** or any Docker host.

---

## Architecture

```
                 host / hosting platform (Dokploy, VPS, ...)
  ┌──────────────────────────────────────────────────────────────┐
  │  opencode-box (privileged)                                     │
  │                                                                │
  │   opencode web  ──:4096──────────────────────────────────►  published (auth: password)
  │   code-server   ──:4097──────────────────────────────────►  published (auth: same password)
  │   claude / opencode CLI                                        │
  │                                                                │
  │   dockerd (DinD)  ── your projects ──┐                         │
  │      └─ front  :3000 ────────────────┼──:3000──────────────►  published
  │      └─ back   :3001 ────────────────┼──:3001──────────────►  published
  │      └─ nginx  :8080 ────────────────┘──:8080──────────────►  published
  │                                                                │
  │   volumes:  /root (code+config)   /var/lib/docker (DinD data)  │
  └──────────────────────────────────────────────────────────────┘
```

- The **agents run in the box**; the projects they build run in **nested containers** (DinD), fully isolated per user (no access to the host daemon).
- A nested container that publishes `-p 3000:3000` binds the box's own interface; the box republishes that port to the host. So a project port is reachable end-to-end **as long as that port is published in `docker-compose.yml`**.

---

## Quickstart (local)

Requires Docker (Docker Desktop is fine — privileged/DinD works inside its VM).

```bash
git clone <this-repo> opencode-docker && cd opencode-docker
cp .env.example .env
# edit .env: set WEB_PASSWORD, pick a Claude mode, add GITHUB_PAT...
make up
```

Two web UIs, both behind the same `WEB_PASSWORD`:
- **opencode web** — http://localhost:4096 (user = `WEB_USERNAME`, password from `.env`)
- **code-server** (VS Code in the browser) — http://localhost:4097 (password from `.env`)

Common commands:

```bash
make up            # build + start
make logs          # follow logs
make shell         # bash inside the box
make claude-login  # one-time Claude Max login (mode=max)
make down          # stop (keeps volumes)
make nuke          # stop + delete all volumes (destructive)
```

---

## Configuration (`.env`)

| Variable | Default | Purpose |
|---|---|---|
| `WEB_PASSWORD` | — | **One** password for BOTH opencode web and code-server. **Empty = no auth** (local only). |
| `WEB_USERNAME` | `opencode` | Login for opencode web's basic auth (code-server's form is password-only). |
| `OPENCODE_PORT` | `4096` | Port for opencode web |
| `CODE_SERVER_PORT` | `4097` | Port for code-server (VS Code in the browser) |
| `CLAUDE_AUTH_MODE` | `max` | `max` (opencode-with-claude plugin) or `manual` (configure in the UI). See below. |
| `GITHUB_PAT` | — | GitHub token for `git` over HTTPS and `gh` |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | auto | git identity — auto-derived from the PAT (GitHub `/user` API) if left empty; set to override |
| `ENABLE_DIND` | `true` | Start the in-box Docker daemon. `false` = expect a mounted host socket. |
| `OPENCODE_FORCE_CONFIG` | `false` | Regenerate `opencode.json` from env on every boot |

### Claude: two modes

**`max` mode (default)** — use your **Claude Max** subscription via the
`opencode-with-claude` plugin (it runs the local *Meridian* proxy on `:3456` and bridges
opencode → Claude Agent SDK → your Claude session). The box generates
`~/.config/opencode/opencode.json` wiring opencode's Anthropic provider to
`http://127.0.0.1:3456`. Authenticate Claude one of two ways:

**A. Token in `.env` (recommended)** — a long-lived OAuth token authenticates every box
and survives `make nuke`/recreate with no interactive step.

Generate it on a machine that has Claude + a browser (e.g. your laptop):
```bash
claude setup-token        # authorize in the browser -> prints an sk-ant-oat01-... token
```
Paste the **full** `sk-ant-oat01-...` value into `CLAUDE_CODE_OAUTH_TOKEN` in `.env`, then
`make up`. No Claude on your machine? Use interactive login (option B) instead.

**B. Interactive login in the box** — stored in the home volume (must be redone after a
`make nuke`):

- From the opencode web UI: open **http://localhost:4096**, select the **`/`** project,
  **Cmd/Ctrl + K → Terminal**, run `claude auth login`, authorize, paste the code, and
  answer **Yes, trust this folder** if asked.
- Or from your host shell: `make claude-login`.

**`manual` mode** — the box **doesn't touch** the opencode config. Configure the provider
yourself from the opencode web UI (the `/connect` flow: API key, another provider,
whatever). Your choice is saved in the home volume, so it survives restarts.

```env
CLAUDE_AUTH_MODE=manual
```

No `ANTHROPIC_API_KEY` / model env var is required either way — set it in the UI if you
want the API path.

### Getting a GitHub token (PAT)

The box uses `GITHUB_PAT` for `git` over HTTPS, the `gh` CLI, and to auto-fill your git
identity. Both token types work (the box authenticates with the `token` scheme).

**Classic token (recommended)** — <https://github.com/settings/tokens> → *Generate new
token (classic)*. One token covers **every repo you can reach — your own *and* your orgs'**.
Check these scopes:

- **`repo`** — clone + push, personal **and** organization repositories
- **`read:org`** — read org membership/resources (some org repos and `gh` need it)
- **`workflow`** — push changes to GitHub Actions workflows *(optional)*
- **`user:email`** — auto-fill your **real** commit email *(optional; else the GitHub
  `noreply` address is used, or set `GIT_USER_EMAIL` in `.env`)*

Copy the `ghp_…` value into `GITHUB_PAT` in `.env`.

> For SSO-protected orgs, click **Configure SSO** on the token and authorize it, otherwise
> pushes to those repos are rejected.

**Fine-grained token (alternative)** — <https://github.com/settings/personal-access-tokens>.
More granular, but **each org must have opted in** to fine-grained tokens and be selected as
the token's *resource owner* — which is why classic is the simpler default for multi-org
access. Set:

- **Resource owner**: your account, or the org whose repos you need
- **Repository access**: *All repositories* or *Only select repositories*
- **Repository permissions**: **Contents** *Read and write*, **Metadata** *Read-only* (auto);
  optionally **Pull requests** / **Workflows** *Read and write*
- *(optional)* **Account permissions → Email addresses** *Read-only* — auto-fill your real
  commit email

Copy the `github_pat_…` value into `GITHUB_PAT`.

> Keep the token secret — `.env` is git-ignored.

> ⚠️ Using a Claude Pro/Max subscription through opencode plugins is discouraged by
> Anthropic/opencode. Use `manual` mode with an API key if you want to stay strictly within terms.

---

## Dev ports for your projects

Declare the ports you want reachable from the host in **`docker-compose.yml`**, under the
`opencode-box` service's `ports:` list. Single ports and ranges both work:

```yaml
    ports:
      - "${OPENCODE_PORT:-4096}:${OPENCODE_PORT:-4096}"   # opencode web
      - "3000-3010:3000-3010"                             # your dev ports
      - "8080:8080"
```

Recreate the box after editing (`make up`). Then, from inside the box, bind your project's
services to ports **within** that set:

```bash
make shell
cd ~/workspace/hello-project     # projects live in ~/workspace (what opencode opens)
docker compose up -d       # publishes 8080 -> reachable at http://localhost:8080
```

See [`examples/hello-project`](examples/hello-project).

### Securing dev ports (read this before adding auth)

Basic auth is **per-origin** (`scheme://host:port`). A login on `:3000` is **never**
reused by the browser for a request to `:3001`. So putting a password on each dev port
**breaks any front→back app** (the front's `fetch()` to the API origin goes out without
credentials → 401), no matter where the proxy lives (in-box Caddy, or Traefik/Dokploy
with a subdomain per service — still cross-origin).

What actually works:

1. **Leave dev ports open** (default) and gate access at the **network layer** —
   Tailscale, an SSH tunnel, or an IP allowlist on the host.
2. **Single origin**: serve front on `/` and back on `/api` behind one port, then one
   basic-auth realm covers both. (Per-project reverse proxy.)
3. **Platform auth** in production: Dokploy/Traefik `forward-auth` / OAuth per domain
   (fine for standalone tools; same cross-origin caveat for split front/back).

Per-port passwords only make sense for a **standalone tool** (adminer, a dashboard, a
docs site) that makes no cross-origin calls. Open an issue if you want the optional
"one shared password for the whole box" Caddy gate added — it's deliberately not on the
default path.

---

## Persisting project data

When you run a project's `docker compose` **inside** the box, any named volumes it
creates (Postgres data, uploads, …) are stored by the in-box Docker daemon under
`/var/lib/docker`, i.e. in the **`docker-data`** host volume.

- **They already persist** across `make up`, `restart`, and box recreation. They are only
  destroyed by `make nuke` (`docker compose down -v`) or removing the `docker-data` volume.
- So keep the `docker-data` volume around — despite the name, it holds real data, not just
  cache.

**For backups**, don't copy the whole `docker-data` volume (it's mostly rebuildable images
and is fragile to restore across Docker versions). Instead, one of:

1. **Bind-mount into `~/workspace`** (simplest — everything valuable ends up in the single
   `home` volume). In your project's compose:
   ```yaml
   services:
     db:
       volumes:
         - ./pgdata:/var/lib/postgresql/data   # ./ resolves under ~/workspace/<project>/
   ```
2. **Export a specific named volume** into `~/workspace` (so it lands in the `home` volume):
   ```bash
   docker exec opencode-box docker run --rm \
     -v <project>_<volume>:/v -v /root/workspace/.backups:/b \
     alpine tar czf /b/<volume>.tar.gz -C /v .
   ```

---

## Deploying

### Dokploy

1. Create an application from this repo (Compose or Dockerfile).
2. Enable **Swarm/Compose privileged** (required for DinD) — the compose already sets
   `privileged: true`.
3. Set the env vars from `.env.example` in the Dokploy UI.
4. Map **domains** to service ports `4096` (opencode web) and `4097` (code-server) —
   Traefik gives you TLS. Keep `WEB_PASSWORD` set; it guards both.
5. For project dev ports, either map extra domains/ports in Dokploy, or reach them over
   a network gate (see above). Keep **both** volumes persistent: `home` (code + config)
   and `docker-data` (nested images + your projects' volumes/databases). See
   [Persisting project data](#persisting-project-data) for backups.

### Any Docker host / VPS

```bash
cp .env.example .env   # fill it in
make up
```
Put a reverse proxy (Caddy/Traefik/nginx) with TLS in front of `OPENCODE_PORT`. Restrict
the dev ports at the firewall or behind a VPN.

> **DinD needs `--privileged`.** If your platform forbids privileged containers, set
> `ENABLE_DIND=false` and mount the host socket (`/var/run/docker.sock:/var/run/docker.sock`).
> That removes per-user isolation (projects become siblings on the host daemon) — only do
> this in trusted single-tenant setups.

---

## How it fits together

| Concern | Choice |
|---|---|
| Nested containers | **Docker-in-Docker** (privileged), isolated per user |
| Storage | `docker-data` volume on `/var/lib/docker` — nested images + **your project volumes** (ext4-backed, avoids overlay-on-overlay) |
| Persistence | single `home` volume on `/root` — projects in `/root/workspace` (what opencode opens) + agent auth + git creds + history. Back up this one. |
| Web editor | **code-server** (VS Code in the browser) on `:4097` |
| Web auth | one `WEB_PASSWORD` for both opencode web (basic auth) and code-server (login form) |
| Dev-port auth | none by default (per-origin basic-auth caveat) — gate at network/platform |
| Zombie reaping | `tini` as PID 1 |

---

## Troubleshooting

- **`dockerd did not become ready` / cgroup or iptables errors** → the container isn't
  privileged. Ensure `privileged: true` (compose) or `--privileged` (docker run).
- **`failed to mount ... fstype: overlay ... invalid argument`** when running a nested
  container → `/var/lib/docker` is on the container's own overlay filesystem
  (overlay-on-overlay). Mount the `docker-data` **named volume** there (the provided
  `docker-compose.yml` already does). With plain `docker run`, add
  `-v some-vol:/var/lib/docker`.
- **web unauthenticated warning** → set `WEB_PASSWORD` (guards both opencode web and code-server).
- **`max` mode not using Claude** → run `make claude-login` once; check the Meridian
  proxy started (opencode logs) and that `/root` is a persistent volume.
- **A project port isn't reachable** → it must be published in `docker-compose.yml`; add it
  and recreate the box, and bind the service to that exact port inside the box.

## License

MIT — see [LICENSE](LICENSE).
