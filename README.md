# remote-sync.nvim

Local-first, git-backed remote-dev sync for Neovim. You edit locally with full
LSP / treesitter / DAP, then ship to a real machine with one keypress. The
plugin wraps `rsync` for transport and uses a small git repo at the mirror
root as its **drift baseline** — push refuses cleanly when the remote has
changed under you, and pull can leave you with a real merge instead of a
silent overwrite.

If you've ever lost an evening to "wait, did this config land on the box?
why is the service not picking it up? did someone else edit it?" — this
plugin is an attempt to fix the workflow underneath that.

---

## What this is for

Two real-world use cases drive the design:

### 1. Editing production configuration on a VPS

You run mailcow / forgejo / nginx / vaultwarden / postgres on a server you
can't develop on directly, but you can rsync into. Edit the configs locally
(with full LSP, treesitter, dotfiles, AI tooling), ship with `<leader>rs`,
optionally trigger a service reload over ssh via a project-configured
command. The drift gate stops you from clobbering changes another admin
made after your last pull.

### 2. Coding from an iPad / second laptop into your real workstation

Mirror a project tree from your workstation to a tablet's lightweight
Neovim, edit there, push back. Single-user station? Set
`"detection": "lazy"` for the fastest path — mtime-based, no checksum
overhead. The exclude list should drop binaries, build outputs, and the
heavy ephemera (`node_modules`, `target`, `dist`, `.direnv`, `vendor`);
everything else (source, configs, dotfiles) syncs at acceptable speed.

Pull/push will still take longer on big repos than over LAN file-sharing —
this is rsync over ssh, not magic. For the tablet side to feel *good*,
pair it with a configured Neovim distribution like
[autovim](https://github.com/yongjohnlee80/autovim) (LSP, treesitter, DAP,
fuzzy finders, status line — all the things that make a tablet keyboard
into a real editor). Vanilla Neovim works but is bare.

---

## What this is NOT

- **Not a version-control system for your code.** For real code projects,
  use git on its own — branches, history, code review, the whole thing.
  The `.git` this plugin maintains at each mirror root is a *sync-state
  ledger*: it captures "what the remote looked like the last time we
  agreed" so drift detection has a baseline. It's not for code history,
  branches, or collaboration.
- **Don't commit production-config mirrors to a public git remote.** Those
  trees contain server config, hostnames, internal topology, and
  occasionally secrets that slipped past the exclude list. The local
  `.git` is meant to *stay local*. If you want snapshots off-machine,
  push to a private bare repo on a host you trust — never to a public
  GitHub. Production configuration is not for sharing, full stop.
- **Not a backup tool.** Production *state* — Postgres data directories,
  mail spools, attachments, container volumes — should be excluded from
  sync, full stop. The defaults cover `.git`, `.env`, certs (`*.pem`,
  `*.key`, …), and the usual build-output suspects (`node_modules`,
  `vendor`, `.direnv`, `target`), but they do **not** know what your
  project calls its runtime-state directory — that's project-specific
  (`data`, `db`, `var`, `volumes`, `storage`, …). You must add those
  names to `.autovim-remote.json`'s `exclude` list yourself. Back state
  up with [restic](https://restic.net/),
  [borgmatic](https://torsion.org/borgmatic/), or your provider's
  snapshot tooling. **This plugin moves *configuration*, not state.**

---

## Install

### lazy.nvim

```lua
{
  "yongjohnlee80/remote-sync.nvim",
  -- No setup() required. Plugin self-registers user commands on load.
  -- Bind your own keys (suggested defaults below) or use the :RemoteSync*
  -- commands directly.
  keys = {
    { "<leader>rp", function() require("remote-sync").pull() end, desc = "Remote: pull" },
    { "<leader>rd", function() require("remote-sync").drift() end, desc = "Remote: drift report" },
    { "<leader>rs", function() require("remote-sync").push() end, desc = "Remote: push" },
    { "<leader>rS", "<cmd>RemoteSyncForcePush<cr>",                desc = "Remote: FORCE push" },
    { "<leader>rc", function() require("remote-sync").run_remote_cmd() end, desc = "Remote: run remote command" },
    { "<leader>rl", function() require("remote-sync").show_log() end, desc = "Remote: show last sync log" },
    { "<leader>rR", function() require("remote-sync").register() end, desc = "Remote: register new project" },
    { "<leader>gq", function() require("remote-sync").navigate() end, desc = "Remote: pick a project" },
    { "<leader>gQ", function() require("remote-sync").navigate_back() end, desc = "Remote: cd back" },
  },
}
```

### Requirements

- Neovim 0.10+ (uses `vim.system`, `vim.fs.find`, `vim.json`).
- `rsync`, `git`, `ssh`, `tar` on PATH.
- An ssh setup that can reach the host non-interactively (alias in
  `~/.ssh/config` or a key already added to ssh-agent).

---

## Quick start

```vim
:cd ~/Source/Remote/<vps>/<service>     " any directory you want as the mirror root
:RemoteSyncRegister                     " wizard: host, remote_path, dest_path
:cd <dest_path>                         " into the freshly-created mirror dir
:RemoteSyncPull                         " first sync — populates the dir, makes initial snap commit
" edit files...
:RemoteSyncDrift                        " optional: see if remote moved under you
:RemoteSyncPush                         " ship local edits to remote
```

Each mirror is rooted by an `.autovim-remote.json` file. The plugin walks
upward from the current buffer's directory looking for one; without it,
every command notifies and no-ops — safe to bind to keys you mash everywhere.

---

## How it works

```
   ┌──────────────────┐  rsync push  ┌──────────────────┐
   │  working tree    │ ───────────▶ │  remote (VPS)    │
   │  (edit here)     │              │                  │
   │                  │ ◀─────────── │                  │
   └────────┬─────────┘  rsync pull  └──────────────────┘
            │
       git commit
            ▼
   ┌──────────────────┐
   │  HEAD (snapshot) │  ◀─── drift compares the remote against THIS,
   │  baseline        │       not against the working tree
   └──────────────────┘
```

Three trees, one critical reference.

- **Working tree** — what you're editing. Has unpushed changes.
- **Remote** — what's actually on the VPS right now.
- **HEAD** — last known synced state (after the most recent successful pull
  or push). The plugin auto-commits a `snap pull <iso>` after every pull
  and a `snap pre-push <iso>` before every push, so HEAD always represents
  "the last thing both sides agreed on."

**Drift** is then defined precisely: `remote ≠ HEAD`. Push refuses on drift —
because pushing without seeing the remote's changes would silently overwrite
them. Drift does **not** care whether your working tree is clean (it's never
clean — that's the whole point of editing locally). This decoupling is what
makes the workflow ergonomic across hundreds of small edits per session.

### Detection modes

Per-project, set `"detection": "<mode>"` in `.autovim-remote.json`:

| Mode      | Push      | Pull       | Drift      | When to use                                          |
| --------- | --------- | ---------- | ---------- | ---------------------------------------------------- |
| `lazy`    | mtime     | mtime      | mtime      | You fully control both ends; no concurrent writers   |
| `safe` ✅ | mtime     | checksum   | checksum   | **Default.** Fast push, accurate drift / safe pull   |
| `paranoid`| checksum  | checksum   | checksum   | Generators rewrite files in place with same metadata |

`safe` is the right default for almost everyone. Push trusts your intent
(you just edited, of course you want to send it); drift and pull compare
content because their failure modes are silent overwrites.

### Why a vendored .gitignore won't break it

The snap commits stage with `git add -A --force` plus pathspec exclusions
derived from `.autovim-remote.json`'s exclude list. That means a project's
own `.gitignore` (e.g. mailcow's vendored one, which excludes `mailcow.conf`)
does **not** prevent rsync-scope files from landing in HEAD. The single
source of truth for "what's in scope" is `.autovim-remote.json`'s
`exclude` field — same list rsync uses, no double-bookkeeping.

> ⚠️ One implication: because `--force` bypasses `.gitignore`, that file no
> longer protects against committing secrets. The plugin's default excludes
> already cover `.env`, `*.pem`, `*.key`, `*.crt`, `*.cert`, `*.p12`,
> `*.pfx`. If your project has bespoke secret files, list them in
> `.autovim-remote.json` — which they need to be in anyway, or rsync would
> push them to the VPS.

---

## Permissions, Docker, and the runtime-state directory

rsync runs as your ssh user on the remote. App-level config dirs
(`/srv/<service>/`, `/home/<user>/Docker/<service>/`, etc.) are usually
owned by *that* user — pushing into them works. The runtime-state
directory next to those configs is a different story.

Most Docker images run their container processes as a non-root user
*inside* the container — `999` for postgres, `33` for nginx, `911` for
many linuxserver images, `1000` for forgejo, and so on. The bind-mounted
state directory on the host is owned by *that* uid, not yours. Symptoms
when this collides with a push:

- `rsync: failed to set permissions on "<path>": Operation not permitted`
- `rsync: chown failed`
- The push appears to succeed but the container fails to read its own
  files on next start, because rsync rewrote ownership underneath it.

**Rule of thumb: exclude your project's runtime-state directory from
`.autovim-remote.json`.** What that directory is called varies by
project: `data`, `db`, `var`, `volumes`, `storage`, `pgdata`, `mysql`,
service-named dirs (`mailcow-data/`, …). Find them once per project and
list them in `exclude`. The plugin's defaults intentionally don't guess
at this name — there's no universal convention.

The destination directory itself — where compose files, `.env`, app
configs (e.g. `app.ini`, `nginx.conf`, `mailcow.conf`) live — must be
readable+writable by your ssh user. That's the part you sync. Never
fight rsync into pushing into the runtime-state dir; if you genuinely
need to edit something inside it, ssh in and do the edit as the
container's uid (`sudo`, `docker exec`, or briefly chowning via the
service's own tooling).

---

## `.autovim-remote.json`

```json
{
  "host": "admin@my-vps",
  "remote_path": "/srv/myservice",
  "exclude": [
    ".git",
    ".autovim-remote.json",
    ".env",
    "node_modules",
    "vendor",
    ".direnv",
    "target",
    ".DS_Store",
    "*.pem", "*.key", "*.crt", "*.cert", "*.p12", "*.pfx",
    "data",
    "ssl"
  ],
  "delete": false,
  "detection": "safe",
  "commands": [
    { "name": "restart", "cmd": "cd /srv/myservice && docker compose restart" },
    { "name": "logs",    "cmd": "cd /srv/myservice && docker compose logs --tail=200" }
  ]
}
```

| Field         | Type    | Default  | Notes                                                                  |
| ------------- | ------- | -------- | ---------------------------------------------------------------------- |
| `host`        | string  | required | `user@host` or any ssh alias                                           |
| `remote_path` | string  | required | Absolute path on the remote                                            |
| `exclude`     | array   | defaults | rsync `--exclude` patterns (bare names match at any depth)             |
| `delete`      | bool    | `false`  | Pass `--delete-after` on push (one-way mirror; tread carefully)        |
| `detection`   | string  | `"safe"` | `lazy` / `safe` / `paranoid`                                           |
| `commands`    | array   | optional | Project-scoped ssh commands invoked via `RemoteSyncRun` / picker       |

The wizard (`RemoteSyncRegister`) writes a default config with sane
excludes; edit by hand to add `commands` or tighten the list.

---

## Commands

Every public function is exposed as a `:RemoteSync*` command and as a
Lua function on `require("remote-sync")`. Bind whichever you prefer.

| Command                | Lua                                    | What it does                                                                 |
| ---------------------- | -------------------------------------- | ---------------------------------------------------------------------------- |
| `:RemoteSyncPull`      | `pull()`                               | rsync remote → local; auto `git commit` snapshot baseline                    |
| `:RemoteSyncDrift`     | `drift()`                              | dry-run rsync; report files where remote differs from HEAD                   |
| `:RemoteSyncPush`      | `push()`                               | drift check → snap commit → rsync local → remote → quiet pull-after          |
| `:RemoteSyncForcePush` | `push({force = true})`                 | bypass drift gate (confirms first via `vim.ui.select`)                       |
| `:RemoteSyncRun`       | `run_remote_cmd()`                     | run a configured `commands[].cmd` over ssh (picker if more than one)         |
| `:RemoteSyncLog`       | `show_log()`                           | floating window with last sync's stdout/stderr tails                         |
| `:RemoteSyncRegister`  | `register()`                           | wizard: host / remote_path / dest_path; creates dir + default config         |
| `:RemoteSyncPick`      | `navigate()`                           | scan for `.autovim-remote.json` projects; pick one and `:cd`                 |
| `:RemoteSyncBack`      | `navigate_back()`                      | pop the last `:RemoteSyncPick` push                                          |

---

## Recovery cheatsheet

**"Push refused — remote has changes you haven't pulled."**
Someone (or some process) wrote to the remote. Run `:RemoteSyncPull` —
the new state lands in your working tree as a `snap pull` commit, and
git's normal merge tooling kicks in if there's a conflict with your
unpushed edits. Then push again.

**"Drift report shows files I haven't touched."**
First run after install — initial snap commit is being created. After one
pull or push, drift goes quiet. If it persists, the remote has files
your `.autovim-remote.json` exclude list lets through but somebody
edited them on the VPS — pull, inspect, decide.

**"I edited the wrong file and pushed it."**
The pre-push snap commit is your insurance. `git log` in the mirror
root, find the `snap pre-push <iso>` before yours, `git checkout <hash>
-- path/to/file`, push. Or `:RemoteSyncForcePush` if you want to roll the
remote all the way back.

**"`rsync: failed to set permissions` / `Operation not permitted`."**
Your ssh user doesn't own (or can't chown) something rsync is trying to
write. Almost always a runtime-state directory owned by a container's
uid. Add the directory name (`data`, `db`, `volumes`, …) to your
`.autovim-remote.json` `exclude` list and re-push. See the *Permissions*
section above for the full picture.

---

## Status

Working and used in anger across a dozen mirrors (mailcow, forgejo,
nginx, vaultwarden, …). API is stable but pre-1.0 — no breaking
changes planned, but the version stays at `0.x` until I've watched
it survive a year of real use.

Issues / PRs welcome. Bugs especially — drift detection has been
through three rewrites; if you find a fourth failure mode, please open
an issue with the `<leader>rl` log output.

---

## License

MIT — see [LICENSE](./LICENSE). Free to use, modify, and redistribute;
attribution required (the copyright notice must remain in copies and
substantial portions).

Authored by [John Lee (@yongjohnlee80)](https://github.com/yongjohnlee80).
