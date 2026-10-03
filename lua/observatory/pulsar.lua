-- Pulsar backend: whole-repo assessment, per-file findings, diff verdicts.
local cli = require("observatory.cli")

local M = {}

---@class observatory.Finding
---@field signal string
---@field severity "warn"|"info"
---@field score number score of the signal that emitted it (0 = worst, 1 = healthy)
---@field message string
---@field file? string path relative to the repository root
---@field line? integer 1-based
---@field col? integer 1-based
---@field fix_hints table[]
---@field data? table

---@class observatory.Assessment
---@field root string
---@field at integer
---@field readiness { score: number, status: string, band?: string }
---@field gate string
---@field weighted_mean number
---@field counts table<string, integer>
---@field categories table<string, { score: number, applicable_signals: integer }>
---@field signals table<string, { score: number, applicability: string, emitted_count: integer }>
---@field findings observatory.Finding[]
---@field by_file table<string, observatory.Finding[]>

---@type table<string, observatory.Assessment>
M.cache = {}
---@type table<string, fun(err?: string, a?: observatory.Assessment)[]>
local pending = {}

---@param root string
---@param raw table finding/diagnostic envelope as emitted by pulsar
---@return observatory.Finding
local function normalize(root, raw)
  local diag = raw.diagnostic or raw
  local loc = raw.location or diag.location or {}
  local prefix = root .. "/"
  return {
    signal = raw.signal_id,
    severity = raw.severity or diag.severity or "info",
    score = raw.score or 1,
    -- Pulsar messages embed absolute paths; they are noise next to the file column.
    message = ((raw.message or diag.message or ""):gsub(vim.pesc(prefix), "")),
    file = loc.file and cli.rel(root, loc.file) or nil,
    line = loc.line,
    col = loc.column,
    fix_hints = raw.fix_hints or diag.fixHints or {},
    data = diag.data,
  }
end

---@param root string
---@param result table `result` of `pulsar agent score`
---@return observatory.Assessment
local function build(root, result)
  local a = result.assessment
  local findings, by_file = {}, {}
  for _, raw in ipairs(result.findings or {}) do
    local f = normalize(root, raw)
    findings[#findings + 1] = f
    if f.file then
      by_file[f.file] = by_file[f.file] or {}
      table.insert(by_file[f.file], f)
    end
  end
  return {
    root = root,
    at = os.time(),
    readiness = a.readiness,
    gate = a.hard_gate_status,
    weighted_mean = a.weighted_mean,
    counts = a.counts,
    categories = a.categories,
    signals = result.signals or {},
    findings = findings,
    by_file = by_file,
  }
end

---Assess the whole repository. Concurrent callers for one root share a single run.
---@param root string
---@param opts? { force?: boolean }
---@param cb fun(err?: string, a?: observatory.Assessment)
function M.score(root, opts, cb)
  opts = opts or {}
  if M.cache[root] and not opts.force then
    return cb(nil, M.cache[root])
  end
  if pending[root] then
    table.insert(pending[root], cb)
    return
  end
  pending[root] = { cb }
  cli.json({ "pulsar", "agent", "score", "--full", "--", root }, root, function(err, doc)
    local waiters = pending[root]
    pending[root] = nil
    local assessment
    if not err then
      if doc.status == "completed" and doc.result and doc.result.assessment then
        assessment = build(root, doc.result)
        M.cache[root] = assessment
      else
        err = "pulsar: " .. vim.inspect(doc.error or doc.status):sub(1, 300)
      end
    end
    for _, waiter in ipairs(waiters) do
      waiter(err, assessment)
    end
  end)
end

---@param root string
---@return boolean
function M.running(root)
  return pending[root] ~= nil
end

---Score a change. `base` is any git ref; the head is always the working tree.
---@param root string
---@param base string
---@param cb fun(err?: string, diff?: { status: string, reasons: string[], range: string, changed_files: string[], introduced: observatory.Finding[], resolved: observatory.Finding[], category_changes: table })
function M.diff(root, base, cb)
  local cmd = { "pulsar", "score", "--diff", base .. "..WORKTREE", "--changed-only", "--json", "--no-progress", root }
  cli.json(cmd, root, function(err, doc)
    if err then
      return cb(err)
    end
    if not doc.gate_decision then
      return cb("pulsar: no gate decision in diff output")
    end
    local function many(list)
      return vim.tbl_map(function(raw)
        return normalize(root, raw)
      end, list or {})
    end
    cb(nil, {
      status = doc.gate_decision.status,
      reasons = doc.gate_decision.reasons or {},
      range = doc.diff.range,
      changed_files = doc.diff.changed_files or {},
      introduced = many(doc.introduced_diagnostics),
      resolved = many(doc.resolved_diagnostics),
      category_changes = doc.category_changes or {},
    })
  end)
end

---How much a file deserves reading: findings weighted by how unhealthy their signal is.
---@param findings observatory.Finding[]
---@return number
function M.heat(findings)
  local heat = 0
  for _, f in ipairs(findings) do
    heat = heat + (1 - f.score) * (f.severity == "warn" and 1 or 0.25)
  end
  return heat
end

---Files ranked hottest first.
---@param a observatory.Assessment
---@return { file: string, heat: number, findings: observatory.Finding[], worst: observatory.Finding }[]
function M.hot_files(a)
  local files = {}
  for file, findings in pairs(a.by_file) do
    local worst = findings[1]
    for _, f in ipairs(findings) do
      if f.score < worst.score or (f.score == worst.score and f.severity == "warn" and worst.severity ~= "warn") then
        worst = f
      end
    end
    files[#files + 1] = { file = file, heat = M.heat(findings), findings = findings, worst = worst }
  end
  table.sort(files, function(x, y)
    if x.heat ~= y.heat then
      return x.heat > y.heat
    end
    return x.file < y.file
  end)
  return files
end

---Strip the taxonomy prefix: "TS-LD-02-function-size-distribution" -> "TS-LD-02", "function size distribution".
---@param id string
---@return string code, string name
function M.signal_name(id)
  local code, name = id:match("^(.-)%-(%l.*)$")
  if not code then
    return id, ""
  end
  return code, (name:gsub("%-", " "))
end

return M
