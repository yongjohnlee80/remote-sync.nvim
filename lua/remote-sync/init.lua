-- Remote-sync helper. Drives the local-first / git-backed-mirror workflow
-- defined in docs/design-decisions/2026-04-25-remote-dev-local-first-git-backed-sync.md.
--
-- The plugin runs against a "project root" — the nearest ancestor of the
-- current buffer's directory containing `.autovim-remote.json`. That JSON
-- file declares which remote (host + path) the project mirrors, what to
-- exclude, and whether `--delete-after` is allowed on push. No host →
-- every entry-point notifies and no-ops, so the keymaps are safe to mash
-- in any project.
--
-- Why git-backed: rsync alone can mirror state but can't detect concurrent
-- edits on the remote. The `<leader>rp` pull is also a `git commit` so the
-- repo's HEAD is the snapshot baseline; `<leader>rd` (precheck) compares
-- the remote against the working tree and surfaces drift before
-- `<leader>rs` clobbers it. Conflict resolution falls through to git's
-- normal merge — see the ADR for the workflow.
--
-- Async via `vim.system` with `text = true`. Long output captured in a
-- per-project state file and viewable via `<leader>rl` (the log float).

local M = {}

local CONFIG_FILE = ".autovim-remote.json"
-- Defaults are used when a project's .autovim-remote.json doesn't set its
-- own `exclude`. New configs written by `M.register` start with this list.
-- Patterns are rsync `--exclude` patterns: bare names match at any depth.
local DEFAULT_EXCLUDES = {
  -- Local-only metadata that has no business on the remote.
  ".git",
  ".autovim-remote.json",
  ".env",
  -- Build / dependency artifacts.
  "node_modules", "vendor", ".direnv", "target",
  -- Editor / OS noise.
  ".DS_Store",
  -- Cert / key material. Lives on the host that uses it; certbot etc.
  -- regenerate on the remote, so syncing locally either goes stale or
  -- (worse) round-trips a private key into local git history.
  -- File patterns cover most cases; `ssl` (the directory name) is added
  -- because cert dirs are sometimes locked down (mode 700) on the
  -- remote — rsync's recursive scan errors out trying to read them
  -- even when every file inside would be excluded by the patterns.
  "*.pem", "*.key", "*.crt", "*.cert", "*.p12", "*.pfx",
  "ssl",
}

-- Per-project `detection` field maps to rsync flags per operation. Design
-- captured in docs/design-decisions/2026-04-26-rsync-detection-modes.md.
-- Philosophy: push is intentional and re-runnable, so stat detection
-- (default rsync) is fine. Pull is destructive on conflict — silently
-- overwriting unpushed local edits is the failure mode we most want to
-- prevent — so checksum is worth the byte-read cost. Drift is the
-- accuracy gate that informs the push refusal; checksum eliminates
-- false positives from container-bumped mtimes (the original symptom
-- that motivated this whole design).
local DETECTION_MODES = {
  -- Trust mtime+size everywhere. Fastest. Vulnerable to phantom drift
  -- and silent overwrite on pull. Use only when you fully control both
  -- ends and no service is actively writing into the mirror tree.
  lazy = {
    push  = {},
    pull  = {},
    drift = {},
  },
  -- Default. Fast push, safe pull, accurate drift. Push trusts your
  -- intent; pull and drift compare content.
  safe = {
    push  = {},
    pull  = { "--checksum" },
    drift = { "--checksum" },
  },
  -- Content-compare everywhere, including push. Slowest. Use when
  -- size+mtime equality has been observed to lie about content (rare
  -- generators rewriting files in place with identical metadata).
  paranoid = {
    push  = { "--checksum" },
    pull  = { "--checksum" },
    drift = { "--checksum" },
  },
}
local DEFAULT_DETECTION_MODE = "safe"

local function detection_flags(cfg, op)
  local mode = cfg.detection or DEFAULT_DETECTION_MODE
  local resolved = DETECTION_MODES[mode]
  if not resolved then
    vim.notify(
      "[remote-sync] unknown detection mode '" .. tostring(mode) ..
        "', falling back to '" .. DEFAULT_DETECTION_MODE .. "'. " ..
        "Valid: lazy / safe / paranoid.",
      vim.log.levels.WARN
    )
    resolved = DETECTION_MODES[DEFAULT_DETECTION_MODE]
  end
  return resolved[op] or {}
end

local function state_dir()
  local d = vim.fn.stdpath("state") .. "/autovim-remote"
  vim.fn.mkdir(d, "p")
  return d
end

local function project_id(root)
  return vim.fn.sha256(root):sub(1, 16)
end

local function state_path(root)
  return state_dir() .. "/" .. project_id(root) .. ".json"
end

local function read_json(path)
  if vim.fn.filereadable(path) ~= 1 then return nil end
  local ok, data = pcall(vim.fn.readfile, path)
  if not ok then return nil end
  local ok2, parsed = pcall(vim.json.decode, table.concat(data, "\n"))
  if not ok2 then return nil end
  return parsed
end

local function write_json(path, tbl)
  local encoded = vim.json.encode(tbl)
  vim.fn.writefile(vim.split(encoded, "\n"), path)
end

-- Pretty-write a default .autovim-remote.json so the user can edit it
-- by hand without staring at single-line JSON. Same shape the README
-- documents; only host / remote_path are project-specific.
local function write_default_config(path, host, remote_path)
  local function jstr(s) return vim.json.encode(s) end
  local lines = {
    "{",
    "  \"host\": " .. jstr(host) .. ",",
    "  \"remote_path\": " .. jstr(remote_path) .. ",",
    "  \"exclude\": [",
  }
  for i, e in ipairs(DEFAULT_EXCLUDES) do
    local sep = (i < #DEFAULT_EXCLUDES) and "," or ""
    table.insert(lines, "    " .. jstr(e) .. sep)
  end
  vim.list_extend(lines, {
    "  ],",
    "  \"delete\": false,",
    "  \"detection\": \"" .. DEFAULT_DETECTION_MODE .. "\"",
    "}",
  })
  vim.fn.writefile(lines, path)
end

-- Append a single line to .gitignore at `root` (creating the file if it
-- doesn't exist). Idempotent: if the exact line is already present, no-op.
-- Used by the auto-bootstrap path so the host-specific .autovim-remote.json
-- stays out of the snapshot history.
local function ensure_in_gitignore(root, line)
  local path = root .. "/.gitignore"
  local lines = {}
  if vim.fn.filereadable(path) == 1 then
    lines = vim.fn.readfile(path)
    for _, l in ipairs(lines) do
      if l == line then return end
    end
  end
  table.insert(lines, line)
  vim.fn.writefile(lines, path)
end

-- Default local-mirror dirname for a remote_path, used by `M.register`.
-- Rule: take the last two path components and join with "-", lowercased.
-- Falls back to single-component basename when remote_path has only one
-- component (or to "remote" if empty). Examples:
--   /home/admin/Docker/test  → "docker-test"
--   /srv/mailcow/data/conf   → "data-conf"
--   /opt/forgejo             → "forgejo"
local function default_dest_name(remote_path)
  local parts = {}
  for part in (remote_path or ""):gmatch("[^/]+") do
    table.insert(parts, part)
  end
  if #parts == 0 then return "remote" end
  if #parts == 1 then return parts[1]:lower() end
  return (parts[#parts - 1] .. "-" .. parts[#parts]):lower()
end

--- Find the nearest ancestor of `start_dir` (default: cwd) that contains
--- `.autovim-remote.json`. Returns (root_dir, config_table) or (nil, err).
function M.find_project(start_dir)
  start_dir = start_dir or vim.fn.getcwd()
  local found = vim.fs.find(CONFIG_FILE, { upward = true, path = start_dir, type = "file" })[1]
  if not found then
    return nil, "no " .. CONFIG_FILE .. " found in or above " .. start_dir
  end
  local config = read_json(found)
  if not config then
    return nil, "could not parse " .. found
  end
  if type(config.host) ~= "string" or config.host == "" then
    return nil, found .. " is missing required 'host' field"
  end
  if type(config.remote_path) ~= "string" or config.remote_path == "" then
    return nil, found .. " is missing required 'remote_path' field"
  end
  config.exclude = config.exclude or DEFAULT_EXCLUDES
  if config.delete == nil then config.delete = false end
  local root = vim.fs.dirname(found)
  return root, config
end

--- Returns the persisted state for the given root: `{ ts, kind, exit, stderr_tail, stdout_tail }`,
--- or nil if no syncs have happened yet.
function M.status(root)
  if not root then
    local r = M.find_project()
    if not r then return nil end
    root = r
  end
  return read_json(state_path(root))
end

local function record(root, kind, exit, stdout, stderr)
  local function tail(s, n)
    if not s then return "" end
    local lines = vim.split(s, "\n", { plain = true })
    if #lines <= n then return s end
    return table.concat(vim.list_slice(lines, #lines - n + 1), "\n")
  end
  write_json(state_path(root), {
    ts = os.time(),
    ts_iso = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    kind = kind,
    exit = exit,
    stdout_tail = tail(stdout, 200),
    stderr_tail = tail(stderr, 200),
  })
end

local function exclude_args(excludes)
  local out = {}
  for _, e in ipairs(excludes) do
    table.insert(out, "--exclude=" .. e)
  end
  return out
end

-- Convert rsync exclude patterns to git pathspec exclusions for use with
-- `git add`. rsync patterns without a leading slash match at any depth
-- (e.g. `node_modules` skips it everywhere); git pathspec needs `**/` to
-- replicate that. We emit two forms per pattern so both directory entries
-- and their contents are filtered:
--
--   rsync `data`     → :(exclude,glob)**/data  AND  :(exclude,glob)**/data/**
--   rsync `*.pem`    → :(exclude,glob)**/*.pem (the /** form is harmless)
--   rsync `/foo`     → :(exclude,glob)foo      AND  :(exclude,glob)foo/**
--
-- These are passed as pathspecs to `git add`, which filters at file
-- selection time — independent of, and applied alongside, --force's
-- override of .gitignore. That combination is what aligns the snap
-- commit's scope with rsync's scope (see maybe_commit_snap below).
local function pathspec_excludes(excludes)
  local out = {}
  for _, e in ipairs(excludes or {}) do
    local anchored = e:sub(1, 1) == "/"
    local pat = anchored and e:sub(2) or ("**/" .. e)
    table.insert(out, ":(exclude,glob)" .. pat)
    table.insert(out, ":(exclude,glob)" .. pat .. "/**")
  end
  return out
end

local function source_spec(config)
  return config.host .. ":" .. config.remote_path .. "/"
end

local function dest_spec(root)
  return root .. "/"
end

local function notify(msg, level)
  vim.notify("[remote-sync] " .. msg, level or vim.log.levels.INFO)
end

local function run_async(cmd, on_done)
  vim.system(cmd, { text = true }, function(out)
    vim.schedule(function() on_done(out) end)
  end)
end

local function git(root, args, on_done)
  local cmd = vim.list_extend({ "git", "-C", root }, args)
  run_async(cmd, on_done or function() end)
end

-- Where does `root` sit relative to git?
--   "self"     — root is itself the top of a git working tree (has its own .git)
--   "ancestor" — root is inside some parent's git working tree (any depth above)
--   "none"     — no git working tree at or above root
-- Detection uses `git rev-parse --show-toplevel`, which walks all the way
-- up to the filesystem root looking for a `.git`. If found, comparing the
-- toplevel against `root` tells us self vs ancestor. The "ancestor" case
-- guards against polluting an unrelated parent repo's history with rsync'd
-- state — e.g. a `.autovim-remote.json` accidentally dropped under an
-- existing project tree.
local function git_state(root)
  local out = vim.fn.systemlist({ "git", "-C", root, "rev-parse", "--show-toplevel" })
  if vim.v.shell_error ~= 0 then return "none" end
  local toplevel = vim.fn.resolve(out[1] or "")
  local resolved = vim.fn.resolve(root)
  if toplevel == resolved then return "self" end
  return "ancestor"
end

--- Capture the working tree as a `snap <label> <iso>` commit if it
--- differs from HEAD. Bootstraps git on first call when state == "none".
--- Refuses to touch git when state == "ancestor" (would pollute the
--- parent repo's history). Calls `on_done()` exactly once when complete,
--- regardless of which branch ran. Used by both pull (post-rsync) and
--- push (pre-rsync) so HEAD always represents "last synced state in
--- either direction" — which makes it the right reference for drift
--- detection (compare remote vs HEAD, not vs working tree).
---
--- Scope alignment with rsync (the subtle bit):
--- The staged set must match what rsync syncs. Some projects ship a
--- vendored .gitignore (mailcow is the motivating example) that ignores
--- files we *do* sync to the VPS — `mailcow.conf`, `docker-compose.override.yml`,
--- etc. A plain `git add -A` honors that .gitignore, so HEAD ends up
--- missing those files, and drift then sees the remote's copies as
--- "files HEAD doesn't have" → phantom drift on every push, even when
--- nothing changed. Fix: stage with `--force` (overrides .gitignore)
--- plus pathspec exclusions derived from `cfg.exclude` (the
--- rsync-exclude list). End result: HEAD's tree == remote's tree minus
--- the rsync excludes, which is exactly what drift wants as a baseline.
---
--- Security implication: the project's .gitignore no longer protects
--- against committing secrets — the user's `.autovim-remote.json
--- exclude` list does. The default excludes already cover .env, *.pem,
--- *.key, *.crt, etc. so this is mostly transparent, but if a project
--- adds bespoke secret files it must list them in .autovim-remote.json
--- (which it'd need to anyway, or rsync would push them to the VPS).
local function maybe_commit_snap(root, cfg, label, on_done)
  on_done = on_done or function() end
  local state = git_state(root)

  if state == "ancestor" then
    notify("dir is inside an ancestor git repo — skipping snapshot commit (would pollute parent)", vim.log.levels.WARN)
    on_done()
    return
  end

  local function do_commit()
    -- Stage everything in the rsync scope. --force bypasses .gitignore;
    -- the pathspec exclusions reapply our own (rsync) exclude list.
    local add_args = vim.list_extend(
      { "add", "-A", "--force", "--" },
      pathspec_excludes(cfg.exclude)
    )
    -- Pathspec list might be empty (no excludes); add a no-op `.` so
    -- the trailing `--` is followed by at least one positional. Without
    -- this, `git add -A --force --` would error.
    if #add_args == 4 then table.insert(add_args, ".") end

    git(root, add_args, function(a)
      if a.code ~= 0 then
        notify("`git add` failed; snapshot skipped", vim.log.levels.WARN)
        on_done(); return
      end
      -- After staging, status --porcelain shows staged differences from
      -- HEAD. Empty here means: nothing in scope changed → skip commit.
      git(root, { "status", "--porcelain" }, function(s)
        if s.code ~= 0 then
          notify("`git status` failed; snapshot skipped", vim.log.levels.WARN)
          on_done(); return
        end
        if s.stdout == nil or s.stdout:gsub("%s+", "") == "" then
          on_done(); return
        end
        local msg = "snap " .. label .. " " .. os.date("!%Y-%m-%dT%H:%M:%SZ")
        git(root, { "commit", "-m", msg }, function(c)
          if c.code == 0 then
            notify("snapshot: " .. msg)
          else
            notify("snapshot commit failed", vim.log.levels.WARN)
          end
          on_done()
        end)
      end)
    end)
  end

  if state == "self" then
    do_commit()
  else  -- "none" → bootstrap
    git(root, { "init", "--quiet" }, function(i)
      if i.code ~= 0 then
        notify("git init failed; snapshot skipped", vim.log.levels.WARN)
        on_done(); return
      end
      notify("git init: snapshot tracking enabled in " .. root)
      do_commit()
    end)
  end
end

--- Pull from remote. After rsync, captures the resulting working tree
--- as a snap commit (via `maybe_commit_snap`) so HEAD reflects "current
--- remote state." That HEAD becomes the baseline for the next drift
--- comparison.
function M.pull(opts)
  opts = opts or {}
  local root, cfg = M.find_project()
  if not root then notify(cfg, vim.log.levels.WARN); return end

  if not opts.quiet then
    notify("pulling " .. cfg.host .. ":" .. cfg.remote_path .. " → " .. root)
  end
  -- -O: omit dir times (kills phantom drift from container-bumped parent
  -- mtimes). Detection flags per mode (lazy/safe/paranoid) layer on top.
  local cmd = vim.list_extend(
    { "rsync", "-az", "-O", "--no-owner", "--no-group", "--info=stats1" },
    detection_flags(cfg, "pull")
  )
  vim.list_extend(cmd, exclude_args(cfg.exclude))
  table.insert(cmd, source_spec(cfg))
  table.insert(cmd, dest_spec(root))

  run_async(cmd, function(out)
    record(root, "pull", out.code, out.stdout, out.stderr)
    if out.code ~= 0 then
      notify("pull failed (exit " .. out.code .. "). <leader>rl for log.", vim.log.levels.ERROR)
      if opts.on_done then opts.on_done(false) end
      return
    end
    maybe_commit_snap(root, cfg, "pull", function()
      if not opts.quiet then notify("pull complete") end
      if opts.on_done then opts.on_done(true) end
    end)
  end)
end

--- Register a new remote-sync project. Prompts for host, remote_path,
--- and dest_path (default: cwd / <last-two-of-remote-path joined by ->).
--- Creates dest_path if missing and writes a default .autovim-remote.json
--- there. Refuses to overwrite an existing config file. Does not pull —
--- run <leader>rp from inside the dest_path afterward.
function M.register()
  vim.ui.input({ prompt = "remote-sync: host (user@host or ssh alias) — " }, function(host)
    if not host or vim.trim(host) == "" then notify("register cancelled"); return end
    host = vim.trim(host)

    vim.ui.input({ prompt = "remote-sync: remote_path on " .. host .. " — " }, function(remote_path)
      if not remote_path or vim.trim(remote_path) == "" then notify("register cancelled"); return end
      remote_path = vim.trim(remote_path)

      local cwd = vim.fn.getcwd()
      local default_dest = cwd .. "/" .. default_dest_name(remote_path)
      vim.ui.input({ prompt = "remote-sync: local dest_path — ", default = default_dest, completion = "dir" }, function(dest_path)
        if not dest_path or vim.trim(dest_path) == "" then notify("register cancelled"); return end
        dest_path = vim.fn.expand(vim.trim(dest_path))

        if vim.fn.isdirectory(dest_path) == 0 then
          if vim.fn.mkdir(dest_path, "p") ~= 1 then
            notify("could not create " .. dest_path, vim.log.levels.ERROR); return
          end
        end
        local config_path = dest_path .. "/" .. CONFIG_FILE
        if vim.fn.filereadable(config_path) == 1 then
          notify(config_path .. " already exists — not overwriting", vim.log.levels.WARN); return
        end
        write_default_config(config_path, host, remote_path)
        notify(("registered → %s\n  host:        %s\n  remote_path: %s\nNext: :cd %s and <leader>rp"):format(dest_path, host, remote_path, dest_path))
      end)
    end)
  end)
end

--- Drift report. Compares the remote against `HEAD` of the local git
--- mirror (NOT against the working tree) — so unpushed local edits don't
--- register as drift. The 3-way reference is:
---
---   HEAD          = "what was last synced (pulled or pushed)"
---   working tree  = "current local state, with unpushed edits"
---   remote        = "what's on the VPS right now"
---
--- Drift means: remote ≠ HEAD. That is, *the remote* has changed since
--- our last sync — which is the only failure mode push needs to refuse
--- (it would silently overwrite changes we haven't seen).
---
--- Implementation: extract HEAD's tree to a temp dir, then run
--- `rsync -azni --dry-run` from remote to that temp dir. Any output is
--- real drift. Temp dir is cleaned up before the callback fires.
---
--- Falls back to the old "compare to working tree" behavior when the
--- mirror isn't a git repo (state == "none" pre-bootstrap, or
--- "ancestor"); in those cases we have no HEAD to use as baseline.
function M.drift(opts)
  opts = opts or {}
  local root, cfg = M.find_project()
  if not root then notify(cfg, vim.log.levels.WARN); return end

  local state = git_state(root)
  local compare_path = root .. "/"
  local cleanup = function() end

  if state == "self" then
    -- Materialize HEAD as a tree on disk so rsync can compare against
    -- it. `git archive HEAD | tar -x` gives us tracked files only —
    -- exactly what HEAD represents — without involving git's own
    -- file-format quirks.
    local tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    local rc = os.execute(string.format(
      "git -C %s archive HEAD 2>/dev/null | tar -x -C %s 2>/dev/null",
      vim.fn.shellescape(root), vim.fn.shellescape(tmpdir)
    ))
    if rc == 0 or rc == true then
      compare_path = tmpdir .. "/"
      cleanup = function() vim.fn.delete(tmpdir, "rf") end
    else
      -- HEAD doesn't exist yet (newly init'd repo with no commits)
      -- or git archive failed. Fall through to working-tree comparison.
      vim.fn.delete(tmpdir, "rf")
      notify("drift: no HEAD yet — comparing remote to working tree (fallback)", vim.log.levels.INFO)
    end
  end

  -- -O kills phantom dir-mtime drift universally (the original symptom
  -- that motivated detection modes). --checksum vs stat detection is
  -- per-mode; safe/paranoid layer it on, lazy doesn't.
  --
  -- --no-times + --no-perms: drift compares content, not metadata.
  --
  -- Critical for the HEAD-comparison path: `git archive HEAD | tar -x`
  -- extracts files with the CURRENT time as mtime and default perms
  -- (often 755 dirs / 644 files). Without these flags every comparison
  -- would show `.f..t......` and `.d...p.....` for every entry,
  -- drowning out real content drift.
  --
  -- Drift answers "did the content drift?" — mtime/perm differences
  -- don't represent that. The push/pull paths still preserve mtimes via
  -- the default `-a` flag set; only drift ignores them.
  local cmd = vim.list_extend(
    { "rsync", "-azni", "-O", "--no-owner", "--no-group", "--no-times", "--no-perms", "--dry-run" },
    detection_flags(cfg, "drift")
  )
  vim.list_extend(cmd, exclude_args(cfg.exclude))
  table.insert(cmd, source_spec(cfg))
  table.insert(cmd, compare_path)

  run_async(cmd, function(out)
    cleanup()
    record(root, "drift", out.code, out.stdout, out.stderr)
    if out.code ~= 0 then
      notify("drift check failed (exit " .. out.code .. "). <leader>rl for log.", vim.log.levels.ERROR)
      if opts.on_done then opts.on_done(false, out) end
      return
    end
    local lines = {}
    for _, l in ipairs(vim.split(out.stdout or "", "\n", { plain = true })) do
      if l ~= "" then table.insert(lines, l) end
    end
    if #lines == 0 then
      if not opts.quiet then notify("no drift — remote matches HEAD") end
      if opts.on_done then opts.on_done(true, out) end
    else
      notify(("drift: %d file(s) differ on remote vs HEAD. <leader>rl for details."):format(#lines), vim.log.levels.WARN)
      if opts.on_done then opts.on_done(false, out) end
    end
  end)
end

--- Push to remote. Three-phase flow:
---
---   1. Drift check (compare remote to HEAD). Refuses if remote has
---      changed since our last sync — unless `force = true`.
---   2. Commit working tree as a `snap pre-push <iso>` so HEAD captures
---      what we're about to push.
---   3. rsync working tree → remote, then trigger an internal pull
---      (quiet mode) so HEAD reflects post-push remote state and the
---      next drift check has a fresh baseline.
---
--- The pre-push commit is what makes the HEAD-based drift check work
--- across editing sessions: every successful push leaves HEAD ==
--- remote, so future edits won't trigger spurious drift.
function M.push(opts)
  opts = opts or {}
  local root, cfg = M.find_project()
  if not root then notify(cfg, vim.log.levels.WARN); return end

  local function do_rsync()
    notify("pushing " .. root .. " → " .. cfg.host .. ":" .. cfg.remote_path)
    -- -O universal; detection-mode flags layer on. Push defaults to
    -- stat detection (lazy/safe modes) since the user just edited and
    -- *wants* the bumped mtime to signal "send me." Only paranoid mode
    -- adds --checksum here.
    local cmd = vim.list_extend(
      { "rsync", "-az", "-O", "--no-owner", "--no-group", "--info=stats1" },
      detection_flags(cfg, "push")
    )
    vim.list_extend(cmd, exclude_args(cfg.exclude))
    if cfg.delete then table.insert(cmd, "--delete-after") end
    table.insert(cmd, dest_spec(root))
    table.insert(cmd, source_spec(cfg))
    run_async(cmd, function(out)
      record(root, "push", out.code, out.stdout, out.stderr)
      if out.code ~= 0 then
        notify("push failed (exit " .. out.code .. "). <leader>rl for log.", vim.log.levels.ERROR)
        return
      end
      notify("push complete")
      -- Quiet pull-after-push so HEAD reflects what's on remote post-push.
      -- This is mostly a no-op in the no-other-writer case (pre-push commit
      -- already left HEAD matching working-tree which == what we pushed),
      -- but catches the edge case of a concurrent writer that changed
      -- remote between our drift check and our push. Surfaces that as a
      -- new snap commit so the user notices.
      M.pull({ quiet = true })
    end)
  end

  local function pre_push_commit_then_push()
    maybe_commit_snap(root, cfg, "pre-push", function()
      do_rsync()
    end)
  end

  if opts.force then
    if not opts.silent_force then
      notify("FORCE push — drift gate skipped", vim.log.levels.WARN)
    end
    pre_push_commit_then_push()
    return
  end

  -- Quiet drift check (we report "no drift" via the success path's
  -- "pushing..." message instead of a separate notify).
  M.drift({
    quiet = true,
    on_done = function(clean)
      if clean then
        pre_push_commit_then_push()
      else
        notify(
          "push refused — remote has changes you haven't pulled.\n" ..
          "  <leader>rp  to pull and merge\n" ..
          "  <leader>rS  to force-push (drift gate skipped — only when you're sure)",
          vim.log.levels.WARN
        )
      end
    end,
  })
end

--- Run a project-configured remote command over ssh. Reads `commands`
--- (array of {name, cmd}) from .autovim-remote.json:
---
---   "commands": [
---     { "name": "restart", "cmd": "docker compose restart forgejo" },
---     { "name": "logs",    "cmd": "docker compose logs --tail=200 forgejo" }
---   ]
---
--- 0 entries → notify and return.
--- 1 entry  → run directly, no picker (smooth single-action case).
--- N > 1   → vim.ui.select picker by name.
function M.run_remote_cmd()
  local root, cfg = M.find_project()
  if not root then notify(cfg, vim.log.levels.WARN); return end

  local items = {}
  if type(cfg.commands) == "table" then
    for _, c in ipairs(cfg.commands) do
      if type(c) == "table" and type(c.name) == "string" and type(c.cmd) == "string" then
        table.insert(items, c)
      end
    end
  end
  if #items == 0 then
    notify("no commands configured (set 'commands' array in " .. CONFIG_FILE .. ")", vim.log.levels.WARN)
    return
  end

  local function run(item)
    notify("running on remote [" .. item.name .. "]: " .. item.cmd)
    run_async({ "ssh", cfg.host, item.cmd }, function(out)
      record(root, "remote_cmd:" .. item.name, out.code, out.stdout, out.stderr)
      if out.code ~= 0 then
        notify("'" .. item.name .. "' failed (exit " .. out.code .. "). <leader>rl for log.", vim.log.levels.ERROR)
      else
        notify("'" .. item.name .. "' done. <leader>rl for output.")
      end
    end)
  end

  if #items == 1 then run(items[1]); return end

  vim.ui.select(items, {
    prompt = "Remote command:",
    format_item = function(c) return c.name end,
  }, function(choice)
    if choice then run(choice) end
  end)
end

--- Open a floating window showing the last sync's full log (rsync /
--- ssh stdout + stderr tails). Read-only scratch buffer; `q` to close.
function M.show_log()
  local root, cfg = M.find_project()
  if not root then notify(cfg, vim.log.levels.WARN); return end
  local s = M.status(root)
  if not s then notify("no sync history yet for this project"); return end

  local lines = {
    ("# remote-sync log — %s"):format(root),
    ("kind: %s   exit: %d   ts: %s"):format(s.kind, s.exit, s.ts_iso or "?"),
    "",
    "## stdout (last 200 lines)",
    "",
  }
  for _, l in ipairs(vim.split(s.stdout_tail or "", "\n", { plain = true })) do
    table.insert(lines, l)
  end
  table.insert(lines, "")
  table.insert(lines, "## stderr (last 200 lines)")
  table.insert(lines, "")
  for _, l in ipairs(vim.split(s.stderr_tail or "", "\n", { plain = true })) do
    table.insert(lines, l)
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"

  local cols, lines_n = vim.o.columns, vim.o.lines
  local width = math.min(120, math.floor(cols * 0.8))
  local height = math.min(#lines + 2, math.floor(lines_n * 0.8))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((lines_n - height) / 2),
    col = math.floor((cols - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " remote-sync log ",
    title_pos = "center",
  })
  vim.wo[win].wrap = false
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", "<cmd>close<cr>", { buffer = buf, nowait = true })
end

-- ──────────────────────────────────────────────────────────────────────
-- Project navigation (<leader>gq / <leader>gQ)
-- ──────────────────────────────────────────────────────────────────────
--
-- Discovery: `find` walks up to 5 levels deep from a root, looking for
-- .autovim-remote.json. Root cascade (first one that exists wins):
--   1. ~/Source/Remote          — broadest useful scope; finds projects
--                                 across all VPS-grouping subdirs.
--   2. parent of current project — sibling discovery when (1) absent.
--   3. cwd                       — last resort.
--
-- Stack is in-memory and session-scoped (not persisted). `<leader>gq`
-- pushes current cwd before cd'ing; `<leader>gQ` pops + cd's back.
-- Mirrors worktree.nvim's gw/gW pattern within our own keyspace, without
-- coupling to worktree.nvim's internal nav stack.

local NAV_DEFAULT_ROOT = "~/Source/Remote"
local nav_stack = {}

local function pick_scan_root()
  local default = vim.fn.expand(NAV_DEFAULT_ROOT)
  if vim.fn.isdirectory(default) == 1 then return default end
  local cur = M.find_project()
  if cur then return vim.fs.dirname(cur) end
  return vim.fn.getcwd()
end

local function scan_for_projects()
  local root = pick_scan_root()
  local out = vim.fn.systemlist({
    "find", root, "-maxdepth", "5",
    "-name", CONFIG_FILE, "-type", "f",
  })
  if vim.v.shell_error ~= 0 then return {}, root end

  local projects = {}
  for _, path in ipairs(out) do
    local cfg = read_json(path)
    if cfg and type(cfg.host) == "string" and type(cfg.remote_path) == "string" then
      local proj_root = vim.fs.dirname(path)
      table.insert(projects, {
        root = proj_root,
        name = vim.fs.basename(proj_root),
        host = cfg.host,
        remote_path = cfg.remote_path,
      })
    end
  end
  table.sort(projects, function(a, b) return a.name < b.name end)
  return projects, root
end

--- Pick a remote project from the discovered list and `:cd` to it. Pushes
--- the current cwd onto an internal stack so `<leader>gQ` (M.navigate_back)
--- can return.
function M.navigate()
  local projects, scanned_root = scan_for_projects()
  if #projects == 0 then
    notify("no remote projects found under " .. scanned_root, vim.log.levels.WARN)
    return
  end

  local max_name = 0
  for _, p in ipairs(projects) do
    if #p.name > max_name then max_name = #p.name end
  end
  local fmt = "%-" .. max_name .. "s → %s:%s"

  vim.ui.select(projects, {
    prompt = "Remote project:",
    format_item = function(p) return string.format(fmt, p.name, p.host, p.remote_path) end,
  }, function(choice)
    if not choice then return end
    local cwd = vim.fn.getcwd()
    if vim.fn.resolve(cwd) == vim.fn.resolve(choice.root) then
      notify("already in " .. choice.name)
      return
    end
    table.insert(nav_stack, cwd)
    vim.cmd("cd " .. vim.fn.fnameescape(choice.root))
    notify("→ " .. choice.root)
  end)
end

--- Pop the last `<leader>gq` push and `:cd` back. No-op (with notify) if
--- the stack is empty.
function M.navigate_back()
  if #nav_stack == 0 then
    notify("no previous location to return to", vim.log.levels.WARN)
    return
  end
  local prev = table.remove(nav_stack)
  vim.cmd("cd " .. vim.fn.fnameescape(prev))
  notify("← " .. prev)
end

return M
