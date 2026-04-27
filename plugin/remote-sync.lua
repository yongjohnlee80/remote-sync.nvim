-- remote-sync.nvim — plugin entry. Exposes user commands so callers who
-- prefer :RemoteSyncPush over a keymap can use either. Module is loaded
-- lazily on first command invocation.
--
-- Keymaps are intentionally NOT defined here. The plugin doesn't impose
-- a keyspace; users wire their own keys (see README) or call :RemoteSync*.

if vim.g.loaded_remote_sync == 1 then return end
vim.g.loaded_remote_sync = 1

local function user_cmd(name, fn, desc)
  vim.api.nvim_create_user_command(name, function()
    require("remote-sync")[fn]()
  end, { desc = desc })
end

user_cmd("RemoteSyncPull",     "pull",            "remote-sync: rsync remote → local + auto-snap commit")
user_cmd("RemoteSyncDrift",    "drift",           "remote-sync: drift report (read-only)")
user_cmd("RemoteSyncPush",     "push",            "remote-sync: rsync local → remote (refuses on drift)")
user_cmd("RemoteSyncRun",      "run_remote_cmd",  "remote-sync: run project-configured ssh command")
user_cmd("RemoteSyncLog",      "show_log",        "remote-sync: floating window with last sync output")
user_cmd("RemoteSyncRegister", "register",        "remote-sync: register a new project (host/remote_path/dest wizard)")
user_cmd("RemoteSyncPick",     "navigate",        "remote-sync: pick a registered project and :cd into it")
user_cmd("RemoteSyncBack",     "navigate_back",   "remote-sync: :cd back from a picked project")

-- Force-push is its own command because it bypasses the drift gate.
-- Confirms via vim.ui.select to discourage habitual use.
vim.api.nvim_create_user_command("RemoteSyncForcePush", function()
  vim.ui.select(
    { "no, cancel", "yes, force push" },
    { prompt = "Force push? Drift gate will be skipped — you may overwrite remote changes." },
    function(choice)
      if choice == "yes, force push" then
        require("remote-sync").push({ force = true })
      else
        vim.notify("[remote-sync] force push cancelled", vim.log.levels.INFO)
      end
    end
  )
end, { desc = "remote-sync: force push (skip drift gate; confirms first)" })
