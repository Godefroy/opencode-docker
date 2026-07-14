// pm2-runtime process file for the opencode-docker box.
//
// Runs two long-lived web servers side by side, both restarted on crash:
//   - opencode web   (:OPENCODE_PORT)     AI TUI/web, HTTP basic auth
//   - code-server     (:CODE_SERVER_PORT)  full VS Code editor, password login
//
// Both inherit their credentials from the process env exported by
// entrypoint.sh (OPENCODE_SERVER_* and PASSWORD), which are all derived from
// the single WEB_USERNAME / WEB_PASSWORD source of truth.
const opencodePort = process.env.OPENCODE_PORT || "4096";
const codePort = process.env.CODE_SERVER_PORT || "4097";
const codeAuth = process.env.CODE_SERVER_AUTH || "password";

// pm2-runtime runs these box services under a dedicated PM2_HOME (see
// entrypoint.sh) so a user's `pm2 save` can't capture them. But a terminal
// opened *inside* these processes (code-server's integrated terminal, a shell
// spawned by opencode) inherits their env — including that box PM2_HOME. That
// would silently send the user's `pm2 start` / `pm2 save` to the box home
// instead of ~/.pm2, so nothing gets resurrected on restart.
//
// pm2 forces its own PM2_HOME onto the child env (the `env:` field can't win),
// so we reset it *inside* the wrapper shell, right before exec'ing the real
// service — from there on, the service and every terminal it spawns see the
// default home, which is where entrypoint.sh resurrects from.
const resetPm2Home = "export PM2_HOME=/root/.pm2;";

module.exports = {
  apps: [
    {
      name: "opencode",
      // interpreter "none" -> pm2 execs the binary directly instead of via node
      script: "/bin/bash",
      interpreter: "none",
      args: ["-c", `${resetPm2Home} exec opencode web --hostname 0.0.0.0 --port ${opencodePort}`],
      cwd: "/root/workspace",
      autorestart: true,
      max_restarts: 20,
    },
    {
      name: "code-server",
      script: "/bin/bash",
      interpreter: "none",
      args: [
        "-c",
        `${resetPm2Home} exec code-server --bind-addr 0.0.0.0:${codePort} --auth ${codeAuth} ` +
          `--disable-telemetry --disable-update-check /root/workspace`,
      ],
      cwd: "/root/workspace",
      autorestart: true,
      max_restarts: 20,
    },
  ],
};
