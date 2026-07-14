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

module.exports = {
  apps: [
    {
      name: "opencode",
      // interpreter "none" -> pm2 execs the binary directly instead of via node
      script: "/bin/bash",
      interpreter: "none",
      args: ["-c", `exec opencode web --hostname 0.0.0.0 --port ${opencodePort}`],
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
        `exec code-server --bind-addr 0.0.0.0:${codePort} --auth ${codeAuth} ` +
          `--disable-telemetry --disable-update-check /root/workspace`,
      ],
      cwd: "/root/workspace",
      autorestart: true,
      max_restarts: 20,
    },
  ],
};
