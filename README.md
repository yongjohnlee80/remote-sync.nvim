# remote-sync.nvim

Local-first, git-backed remote-dev sync for Neovim. You edit locally with full
LSP / treesitter / DAP, then ship to a real VPS with one keypress. The plugin
wraps `rsync` for transport and uses a small git repo at the mirror root as
its **drift baseline** — so push refuses cleanly when the remote has changed
under you, and pull can leave you with a real merge instead of a silent
overwrite.

It's designed for the case where:

- The remote is a working server (Docker host, mailcow, nginx, …) — you
  can't run a development environment there, but you _can_ rsync into it.
- You may or may not be the only person/process touching the remote tree.
- You want editing to feel local, not "ssh + tmux + nano".

If you've ever lost an evening to "wait, did this config land on the box?
why is the service not picking it up? did someone else edit it?" — this
plugin is an attempt to fix the workflow underneath that.

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
