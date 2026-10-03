-- Observatory: repository health (pulsar) and compiler-grade symbol navigation (quartz) in Neovim.
local cli = require("observatory.cli")
local pulsar = require("observatory.pulsar")
local quartz = require("observatory.quartz")
local ui = require("observatory.ui")
local views = require("observatory.views")

local M = {}

---@class observatory.Config
local defaults = {
  -- Score a repository the first time one of its files is opened.
  auto_score = true,
  -- Re-score after saving. A run takes a few seconds and happens in the background.
  score_on_save = true,
  -- Filetypes that trigger scoring.
  filetypes = { "typescript", "typescriptreact", "javascript", "javascriptreact", "rust" },
  diagnostics = {
    enabled = true,
    -- Findings about a whole file have no line; pinning them to line 1 is noisy.
    file_level = false,
    -- Publish for every file with findings, not just open ones, so workspace views
    -- such as Trouble list the whole repository.
    workspace = true,
    -- Only findings at or above this severity get inline text; the rest show as signs.
    virtual_text_min = vim.diagnostic.severity.WARN,
  },
  -- Base ref for `:Observatory diff` when none is given.
  diff_base = "HEAD",
}

---@type observatory.Config
M.config = vim.deepcopy(defaults)

local ns = vim.api.nvim_create_namespace("observatory")
local SEVERITY = { warn = vim.diagnostic.severity.WARN, info = vim.diagnostic.severity.HINT }

---@param buf integer
local function publish(buf)
  if not M.config.diagnostics.enabled then
    return
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or vim.bo[buf].buftype ~= "" then
    return
  end
  local root = cli.root(buf)
  local a = pulsar.cache[root]
  if not a then
    return
  end
  -- An unloaded buffer reports zero lines; its positions are trusted as given.
  local last = vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_line_count(buf) or math.huge
  local diags = {}
  for _, f in ipairs(a.by_file[cli.rel(root, name)] or {}) do
    if f.line or M.config.diagnostics.file_level then
      local code = pulsar.signal_name(f.signal)
      local message = f.message
      if f.fix_hints[1] and f.fix_hints[1].title then
        message = message .. "\nfix: " .. f.fix_hints[1].title
      end
      diags[#diags + 1] = {
        lnum = math.min((f.line or 1), last) - 1,
        col = math.max((f.col or 1) - 1, 0),
        severity = SEVERITY[f.severity] or vim.diagnostic.severity.HINT,
        source = "pulsar",
        code = code,
        message = message,
      }
    end
  end
  vim.diagnostic.set(ns, buf, diags)
end

---@param a? observatory.Assessment when given, also covers its files that are not open yet
local function publish_all(a)
  if a and M.config.diagnostics.enabled and M.config.diagnostics.workspace then
    for file, findings in pairs(a.by_file) do
      for _, f in ipairs(findings) do
        if f.line or M.config.diagnostics.file_level then
          vim.fn.bufadd(cli.abs(a.root, file))
          break
        end
      end
    end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    publish(buf)
  end
end

---@param cb fun(a: observatory.Assessment, root: string)
---@param opts? { force?: boolean, quiet?: boolean }
local function with_assessment(cb, opts)
  opts = opts or {}
  local root = cli.root()
  if not pulsar.cache[root] and not opts.quiet then
    ui.notify("scoring " .. vim.fs.basename(root) .. "…")
  end
  pulsar.score(root, { force = opts.force }, function(err, a)
    if err then
      if not opts.quiet then
        ui.notify(err, vim.log.levels.ERROR)
      end
      return
    end
    publish_all(a)
    vim.cmd("redrawstatus")
    cb(a, root)
  end)
end

---Word under the cursor, or the argument if one was given.
---@param arg? string
---@return string?
local function symbol_arg(arg)
  local symbol = (arg and arg ~= "") and arg or vim.fn.expand("<cword>")
  if symbol == "" then
    ui.notify("no symbol under cursor", vim.log.levels.WARN)
    return nil
  end
  return symbol
end

---@type table<string, fun(arg?: string)>
M.commands = {}

function M.commands.score()
  with_assessment(function(a)
    local band = a.readiness.band or a.readiness.status
    ui.notify(("readiness %.2f (%s) · %d findings"):format(a.readiness.score, band, #a.findings))
  end, { force = true })
end

function M.commands.dashboard()
  with_assessment(function(a, root)
    local lines, hls = views.dashboard(a)
    ui.float("Observatory · " .. vim.fs.basename(root), lines, { highlights = hls })
  end)
end

function M.commands.files()
  with_assessment(function(a)
    ui.pick("Read first", views.hot_files(a))
  end)
end

---@param arg? string signal id to filter by
function M.commands.findings(arg)
  with_assessment(function(a)
    local signal = (arg and arg ~= "") and arg or nil
    ui.pick(signal and ("Findings · " .. signal) or "Findings", views.findings(a, { signal = signal }))
  end)
end

function M.commands.buffer()
  local file = cli.rel(cli.root(), vim.api.nvim_buf_get_name(0))
  with_assessment(function(a)
    ui.pick("Findings · " .. file, views.findings(a, { file = file }))
  end)
end

function M.commands.signals()
  with_assessment(function(a)
    ui.pick("Signals", views.signals(a, M.commands.findings))
  end)
end

---@param arg? string base ref
function M.commands.diff(arg)
  local root = cli.root()
  local base = (arg and arg ~= "") and arg or M.config.diff_base
  ui.notify(("scoring %s..WORKTREE…"):format(base))
  pulsar.diff(root, base, function(err, d)
    if err then
      return ui.notify(err, vim.log.levels.ERROR)
    end
    local level = d.status == "pass" and vim.log.levels.INFO
      or (d.status == "block" and vim.log.levels.ERROR or vim.log.levels.WARN)
    ui.notify(
      ("%s · %s · %d changed files\n%s"):format(d.status:upper(), d.range, #d.changed_files, d.reasons[1] or ""),
      level
    )
    if #d.introduced > 0 then
      local items = views.findings({ root = root, findings = d.introduced, by_file = {} })
      ui.pick(("Introduced · %s · %s"):format(d.status:upper(), d.range), items)
    end
  end)
end

function M.commands.symbols()
  local root = cli.root()
  quartz.symbols(root, nil, function(err, data)
    if err then
      return ui.notify(err, vim.log.levels.ERROR)
    end
    local title = ("Symbols · %d%s"):format(#data.symbols, data.truncated and (" of " .. data.total) or "")
    ui.pick(title, views.symbols(root, data.symbols, pulsar.cache[root]))
  end)
end

function M.commands.outline()
  local root = cli.root()
  local file = cli.rel(root, vim.api.nvim_buf_get_name(0))
  quartz.file(root, file, function(err, data)
    if err then
      return ui.notify(err, vim.log.levels.ERROR)
    end
    ui.pick("Outline · " .. file, views.outline(root, file, data.declarations, pulsar.cache[root]))
  end)
end

---@param arg? string
function M.commands.usages(arg)
  local symbol = symbol_arg(arg)
  if not symbol then
    return
  end
  local root = cli.root()
  quartz.usages(root, symbol, function(err, data)
    if err then
      return ui.notify(err, vim.log.levels.ERROR)
    end
    ui.pick(
      ("Usages · %s · %d"):format(symbol, data.totalLocations or #data.locations),
      views.locations(root, data.locations)
    )
  end)
end

---@param arg? string
function M.commands.related(arg)
  local symbol = symbol_arg(arg)
  if not symbol then
    return
  end
  local root = cli.root()
  quartz.related(root, symbol, function(err, data)
    if err then
      return ui.notify(err, vim.log.levels.ERROR)
    end
    local locations = {}
    for _, r in ipairs(data.referencedBy or {}) do
      r.context = "used by · " .. (r.context or "")
      locations[#locations + 1] = r
    end
    for _, r in ipairs(data.references or {}) do
      r.context = "uses · " .. (r.context or "")
      locations[#locations + 1] = r
    end
    ui.pick("Related · " .. symbol, views.locations(root, locations))
  end)
end

function M.commands.type()
  local root = cli.root()
  local file = cli.rel(root, vim.api.nvim_buf_get_name(0))
  local pos = vim.api.nvim_win_get_cursor(0)
  quartz.at_position(root, file, pos[1], pos[2] + 1, function(err, data)
    if err then
      return ui.notify(err, vim.log.levels.ERROR)
    end
    local lines = vim.split(data.expanded or data.type or "unknown", "\n")
    ui.float(data.nodeText or "type", lines, { ft = "typescript" })
  end)
end

---@param arg? string
function M.commands.expand(arg)
  local symbol = symbol_arg(arg)
  if not symbol then
    return
  end
  quartz.expand(cli.root(), symbol, function(err, data)
    if err then
      return ui.notify(err, vim.log.levels.ERROR)
    end
    local lines = { "type " .. data.original .. " = {" }
    for _, p in ipairs(data.properties or {}) do
      lines[#lines + 1] = ("  %s%s: %s"):format(p.name, p.optional and "?" or "", p.type)
    end
    lines[#lines + 1] = "}"
    if not data.properties then
      lines = vim.split(data.expanded, "\n")
    end
    ui.float(symbol, lines, { ft = "typescript" })
  end)
end

---Statusline component: readiness for the current buffer's repository, or "" when unknown.
---@return string
function M.status()
  local ok, root = pcall(cli.root)
  if not ok then
    return ""
  end
  local a = pulsar.cache[root]
  if pulsar.running(root) then
    return a and ("◌ %.2f"):format(a.readiness.score) or "◌"
  end
  return a and ("● %.2f"):format(a.readiness.score) or ""
end

---Highlight group matching the current readiness band.
---@return string?
function M.status_hl()
  local a = pulsar.cache[cli.root()]
  return a and views.band_hl(a.readiness) or nil
end

---@param opts? observatory.Config
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

  vim.diagnostic.config({
    virtual_text = { severity = { min = M.config.diagnostics.virtual_text_min }, source = false },
    severity_sort = true,
  }, ns)

  vim.api.nvim_create_user_command("Observatory", function(cmd)
    local name = cmd.fargs[1] or "dashboard"
    local handler = M.commands[name]
    if not handler then
      return ui.notify("unknown command: " .. name, vim.log.levels.ERROR)
    end
    handler(cmd.fargs[2])
  end, {
    nargs = "*",
    desc = "Repository health and symbol navigation",
    complete = function(lead)
      local names = vim.tbl_keys(M.commands)
      table.sort(names)
      return vim.tbl_filter(function(n)
        return n:sub(1, #lead) == lead
      end, names)
    end,
  })

  local group = vim.api.nvim_create_augroup("observatory", { clear = true })
  local function wanted(buf)
    return vim.bo[buf].buftype == "" and vim.tbl_contains(M.config.filetypes, vim.bo[buf].filetype)
  end
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = M.config.filetypes,
    callback = function(ev)
      if not wanted(ev.buf) then
        return
      end
      if pulsar.cache[cli.root(ev.buf)] then
        publish(ev.buf)
      elseif M.config.auto_score then
        vim.api.nvim_buf_call(ev.buf, function()
          with_assessment(function() end, { quiet = true })
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      if M.config.score_on_save and wanted(ev.buf) then
        vim.api.nvim_buf_call(ev.buf, function()
          with_assessment(function() end, { force = true, quiet = true })
        end)
      end
    end,
  })
end

return M
