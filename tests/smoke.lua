-- End-to-end smoke test against a real TypeScript repository.
--   OBSERVATORY_REPO=~/Projects/quartz OBSERVATORY_FILE=packages/engine/src/verification-operations.ts \
--     nvim --headless -c "set rtp+=." -c "luafile tests/smoke.lua"
-- Needs `pulsar` and `quartz` on PATH. Exits non-zero on the first failed check.

local repo = vim.fs.normalize(vim.env.OBSERVATORY_REPO or "")
local file = vim.env.OBSERVATORY_FILE or ""
local symbol = vim.env.OBSERVATORY_SYMBOL or "verifyContract"
assert(repo ~= "" and file ~= "", "set OBSERVATORY_REPO and OBSERVATORY_FILE")

local failures = 0
-- A script error would otherwise leave headless Neovim waiting forever.
vim.defer_fn(function()
  io.stdout:write("FAIL timed out\n")
  vim.cmd("cquit!")
end, 150000)
local function check(name, ok, detail)
  io.stdout:write(("%s %s%s\n"):format(ok and "ok  " or "FAIL", name, detail and ("  " .. detail) or ""))
  if not ok then
    failures = failures + 1
  end
end

---Block until `fn` has called its callback, then return what it was called with.
local function await(name, fn, timeout)
  local done, result = false, nil
  fn(function(...)
    done, result = true, { ... }
  end)
  vim.wait(timeout or 60000, function()
    return done
  end, 50)
  check(name .. " returned", done)
  return unpack(result or {})
end

local observatory = require("observatory")
observatory.setup({ auto_score = false, score_on_save = false })
local cli = require("observatory.cli")
local pulsar = require("observatory.pulsar")
local quartz = require("observatory.quartz")
local views = require("observatory.views")

vim.cmd.edit(repo .. "/" .. file)
local buf = vim.api.nvim_get_current_buf()
local root = cli.root()
check("root is the repository", root == repo, root)

-- pulsar
local err, a = await("pulsar.score", function(cb)
  pulsar.score(root, nil, cb)
end)
check("score has no error", err == nil, err)
check("score has findings", a and #a.findings > 0, a and (#a.findings .. " findings"))
check("readiness is a number", a and type(a.readiness.score) == "number")
check("no absolute paths in messages", a and not vim.iter(a.findings):any(function(f)
  return f.message:find(root, 1, true) ~= nil
end))
check("finding files are relative", a and not vim.iter(a.findings):any(function(f)
  return f.file and f.file:sub(1, 1) == "/"
end))

observatory.commands.score()
vim.wait(60000, function()
  return not pulsar.running(root)
end, 50)
vim.wait(200)
local with_line = vim.tbl_filter(function(f)
  return f.line ~= nil
end, a.by_file[file] or {})
local diags = vim.diagnostic.get(buf, { namespace = vim.api.nvim_get_namespaces().observatory })
check(
  "diagnostics match line-level findings",
  #diags == #with_line,
  ("%d diagnostics, %d findings"):format(#diags, #with_line)
)
check("status shows readiness", observatory.status():match("%d%.%d%d") ~= nil, observatory.status())

check("hot files ranked", #views.hot_files(a) > 0, #views.hot_files(a) .. " files")
check("signals listed", #views.signals(a, function() end) > 0)
check("dashboard renders", #views.dashboard(a) > 10)
check(
  "signal name splits",
  select(1, pulsar.signal_name("SHARED-COCHANGE-01-logical-coupling")) == "SHARED-COCHANGE-01"
)

local derr, d = await("pulsar.diff", function(cb)
  pulsar.diff(root, "HEAD", cb)
end)
check("diff has a verdict", derr == nil and d and d.status ~= nil, derr or (d and d.status))

-- quartz
local serr, symbols = await("quartz.symbols", function(cb)
  quartz.symbols(root, nil, cb)
end)
check("symbols listed", serr == nil and symbols and #symbols.symbols > 0, serr or (#symbols.symbols .. " symbols"))
check("symbol items built", serr == nil and #views.symbols(root, symbols.symbols, a) == #symbols.symbols)

local ferr, decls = await("quartz.file", function(cb)
  quartz.file(root, file, cb)
end)
check("outline has declarations", ferr == nil and decls and #decls.declarations > 0, ferr)
check("outline items built", ferr == nil and #views.outline(root, file, decls.declarations, a) == #decls.declarations)

local uerr, usages = await("quartz.usages", function(cb)
  quartz.usages(root, symbol, cb)
end)
check("usages found", uerr == nil and usages and #usages.locations > 0, uerr or (#usages.locations .. " locations"))

local terr, at = await("quartz.at_position", function(cb)
  quartz.at_position(root, file, decls.declarations[1].line, 14, cb)
end)
check("type at position", terr == nil and at and at.type ~= nil, terr or at.type)

-- views open without error
for _, name in ipairs({ "dashboard", "files", "findings", "buffer", "signals", "symbols", "outline" }) do
  local ok, e = pcall(observatory.commands[name])
  vim.wait((name == "symbols" or name == "outline") and 4000 or 800)
  check("command " .. name, ok, not ok and tostring(e) or nil)
  vim.cmd("silent! stopinsert")
  pcall(function()
    for _, p in ipairs(require("snacks").picker.get()) do
      p:close()
    end
  end)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

local messages = vim.api.nvim_exec2("messages", { output = true }).output
check(
  "no errors in :messages",
  not messages:match("E%d+:") and not messages:match("stack traceback"),
  messages:sub(1, 400)
)

io.stdout:write(failures == 0 and "\nall checks passed\n" or ("\n" .. failures .. " checks failed\n"))
vim.cmd(failures == 0 and "qall!" or "cquit!")
