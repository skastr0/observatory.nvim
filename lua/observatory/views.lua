-- Turns backend data into picker items and dashboard lines. Pure: no I/O, no windows.
local cli = require("observatory.cli")
local pulsar = require("observatory.pulsar")

local M = {}

local BAND_HL = { green = "DiagnosticOk", yellow = "DiagnosticWarn", amber = "DiagnosticWarn", red = "DiagnosticError" }
local SEVERITY_HL = { warn = "DiagnosticWarn", info = "DiagnosticHint" }

---@param readiness { score: number, status: string, band?: string }
---@return string
function M.band_hl(readiness)
  return BAND_HL[readiness.band or readiness.status] or "Comment"
end

---@param score number
---@return string
function M.score_hl(score)
  if score < 0.5 then
    return "DiagnosticError"
  elseif score < 0.8 then
    return "DiagnosticWarn"
  end
  return "DiagnosticOk"
end

---@param score number
---@param width integer
---@return string
local function bar(score, width)
  local filled = math.floor(score * width + 0.5)
  return ("█"):rep(filled) .. ("░"):rep(width - filled)
end

---@param s string
---@param width integer
---@return string
local function pad(s, width)
  local w = vim.fn.strdisplaywidth(s)
  if w > width then
    return vim.fn.strcharpart(s, 0, width - 1) .. "…"
  end
  return s .. (" "):rep(width - w)
end

---One-line summary of what a finding's signal says, for a finding preview.
---@param f observatory.Finding
---@return string
local function finding_preview(f)
  local code, name = pulsar.signal_name(f.signal)
  local lines = {
    "# " .. code .. " " .. name,
    "",
    f.message,
    "",
    ("signal score: %.2f   severity: %s"):format(f.score, f.severity),
  }
  for _, hint in ipairs(f.fix_hints) do
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Fix: " .. (hint.title or hint.kind or "")
    lines[#lines + 1] = hint.summary or ""
  end
  return table.concat(lines, "\n")
end

---@param root string
---@param f observatory.Finding
---@param with_file boolean
---@return observatory.Item
local function finding_item(root, f, with_file)
  local code = pulsar.signal_name(f.signal)
  local where = f.file and (with_file and f.file or "") .. (f.line and (":" .. f.line) or "") or "(repository)"
  local chunks = {
    { f.severity == "warn" and "▲ " or "· ", SEVERITY_HL[f.severity] },
    { pad(code, 18), "Identifier" },
    { f.message .. "  ", SEVERITY_HL[f.severity] },
    { where, "Comment" },
  }
  return {
    text = table.concat({ f.signal, f.message, f.file or "" }, " "),
    chunks = chunks,
    file = f.file and cli.abs(root, f.file) or nil,
    pos = f.file and { f.line or 1, (f.col or 1) - 1 } or nil,
    preview = not f.file and { text = finding_preview(f), ft = "markdown" } or nil,
  }
end

---Findings, most severe signals first.
---@param a observatory.Assessment
---@param opts? { file?: string, signal?: string }
---@return observatory.Item[]
function M.findings(a, opts)
  opts = opts or {}
  local list = opts.file and (a.by_file[opts.file] or {}) or a.findings
  local sorted = {}
  for _, f in ipairs(list) do
    if not opts.signal or f.signal == opts.signal then
      sorted[#sorted + 1] = f
    end
  end
  table.sort(sorted, function(x, y)
    if x.score ~= y.score then
      return x.score < y.score
    end
    if x.severity ~= y.severity then
      return x.severity == "warn"
    end
    return (x.file or "") .. (x.line or 0) < (y.file or "") .. (y.line or 0)
  end)
  return vim.tbl_map(function(f)
    return finding_item(a.root, f, not opts.file)
  end, sorted)
end

---The reading list: files ranked by how much reading them pays off.
---@param a observatory.Assessment
---@return observatory.Item[]
function M.hot_files(a)
  local files = pulsar.hot_files(a)
  local max = files[1] and files[1].heat or 0
  local items = {}
  for rank, entry in ipairs(files) do
    if entry.heat <= 0 then
      break
    end
    local code = pulsar.signal_name(entry.worst.signal)
    local line
    for _, f in ipairs(entry.findings) do
      if f.line and (not line or f.score < line.score) then
        line = f
      end
    end
    items[#items + 1] = {
      text = entry.file .. " " .. entry.worst.message,
      chunks = {
        { ("%2d "):format(rank), "Comment" },
        { bar(max > 0 and entry.heat / max or 0, 8) .. " ", M.score_hl(entry.worst.score) },
        { entry.file .. "  ", "Directory" },
        { ("%d findings · worst %s: "):format(#entry.findings, code), "Comment" },
        { entry.worst.message, SEVERITY_HL[entry.worst.severity] },
      },
      file = cli.abs(a.root, entry.file),
      pos = { line and line.line or 1, 0 },
    }
  end
  return items
end

---Signals with their score; confirming one lists its findings.
---@param a observatory.Assessment
---@param open_findings fun(signal: string)
---@return observatory.Item[]
function M.signals(a, open_findings)
  local ids = vim.tbl_keys(a.signals)
  table.sort(ids, function(x, y)
    local sx, sy = a.signals[x], a.signals[y]
    local ax, ay = sx.applicability == "applicable", sy.applicability == "applicable"
    if ax ~= ay then
      return ax
    end
    if sx.score ~= sy.score then
      return sx.score < sy.score
    end
    return x < y
  end)
  local items = {}
  for _, id in ipairs(ids) do
    local s = a.signals[id]
    local code, name = pulsar.signal_name(id)
    local applicable = s.applicability == "applicable"
    local detail = {}
    for _, d in ipairs(s.diagnostics or {}) do
      detail[#detail + 1] = "- " .. ((d.message or ""):gsub(vim.pesc(a.root .. "/"), ""))
    end
    items[#items + 1] = {
      text = id,
      chunks = {
        {
          applicable and (bar(s.score, 8) .. (" %.2f  "):format(s.score)) or pad("—", 15),
          applicable and M.score_hl(s.score) or "Comment",
        },
        { pad(code, 18), "Identifier" },
        { pad(name, 34), applicable and "Normal" or "Comment" },
        { applicable and ("%d findings"):format(s.emitted_count or 0) or (s.applicability:gsub("_", " ")), "Comment" },
      },
      preview = {
        text = ("# %s %s\n\nscore %.2f · %s · %d findings\n\n%s"):format(
          code,
          name,
          s.score,
          s.applicability,
          s.emitted_count or 0,
          table.concat(detail, "\n")
        ),
        ft = "markdown",
      },
      on_confirm = function()
        open_findings(id)
      end,
    }
  end
  return items
end

---Dashboard text for an assessment.
---@param a observatory.Assessment
---@return string[] lines, { [1]: integer, [2]: integer, [3]: integer, [4]: string }[] highlights
function M.dashboard(a)
  local lines, hls = {}, {}
  local function add(text, hl, from, to)
    lines[#lines + 1] = text
    if hl then
      hls[#hls + 1] = { #lines - 1, from or 0, to or #text, hl }
    end
  end
  local band = a.readiness.band or a.readiness.status or "unknown"
  add(
    ("  Readiness  %.2f  %s      hard gate: %s"):format(a.readiness.score, band:upper(), a.gate),
    M.band_hl(a.readiness),
    2,
    26
  )
  add(
    ("  weighted mean %.2f · %d applicable · %d insufficient evidence · %d not applicable"):format(
      a.weighted_mean,
      a.counts.applicable or 0,
      a.counts.insufficient_evidence or 0,
      a.counts.not_applicable or 0
    ),
    "Comment"
  )
  add("")
  add("  Categories", "Title")
  local cats = vim.tbl_keys(a.categories)
  table.sort(cats, function(x, y)
    return a.categories[x].score < a.categories[y].score
  end)
  for _, name in ipairs(cats) do
    local c = a.categories[name]
    add(("    %s %s %.2f"):format(pad(name, 24), bar(c.score, 20), c.score), M.score_hl(c.score), 29)
  end
  add("")
  add("  Weakest signals", "Title")
  local ids = {}
  for id, s in pairs(a.signals) do
    if s.applicability == "applicable" and s.score < 1 then
      ids[#ids + 1] = id
    end
  end
  table.sort(ids, function(x, y)
    return a.signals[x].score < a.signals[y].score
  end)
  for i = 1, math.min(6, #ids) do
    local code, name = pulsar.signal_name(ids[i])
    local s = a.signals[ids[i]]
    add(("    %.2f  %s %s"):format(s.score, pad(code, 18), name), M.score_hl(s.score), 4, 8)
  end
  add("")
  add("  Read first", "Title")
  local hot = pulsar.hot_files(a)
  for i = 1, math.min(6, #hot) do
    add(("    %d. %s  (%d findings)"):format(i, hot[i].file, #hot[i].findings))
  end
  add("")
  add(("  %d findings · scored %s · q to close"):format(#a.findings, os.date("%H:%M", a.at)), "Comment")
  return lines, hls
end

---Exported symbols, annotated with what pulsar knows about them and their file.
---@param root string
---@param symbols { name: string, kind: string, file: string, line: integer, package: string, isIndexExport: boolean }[]
---@param a? observatory.Assessment
---@return observatory.Item[]
function M.symbols(root, symbols, a)
  local unused = {}
  for _, f in ipairs(a and a.findings or {}) do
    if f.data and f.data.exportName and f.file then
      unused[f.file .. "\0" .. f.data.exportName] = f.data.classification or "unused"
    end
  end
  local items = {}
  for _, s in ipairs(symbols) do
    local file_findings = a and a.by_file[s.file] or nil
    local notes = {}
    if unused[s.file .. "\0" .. s.name] then
      notes[#notes + 1] = unused[s.file .. "\0" .. s.name]
    end
    if s.isIndexExport then
      notes[#notes + 1] = "public"
    end
    if file_findings then
      notes[#notes + 1] = ("file: %d findings"):format(#file_findings)
    end
    items[#items + 1] = {
      text = s.name .. " " .. s.kind .. " " .. s.file,
      chunks = {
        { pad(s.kind, 10), "Type" },
        { s.name .. "  ", "Function" },
        { s.file .. ":" .. s.line .. "  ", "Comment" },
        { table.concat(notes, " · "), unused[s.file .. "\0" .. s.name] and "DiagnosticWarn" or "DiagnosticHint" },
      },
      file = cli.abs(root, s.file),
      pos = { s.line, 0 },
    }
  end
  return items
end

---Declarations of one file with their resolved types and any findings on the same line.
---@param root string
---@param file string repository-relative
---@param declarations { name: string, kind: string, line: integer, exported: boolean, type?: string }[]
---@param a? observatory.Assessment
---@return observatory.Item[]
function M.outline(root, file, declarations, a)
  local by_line = {}
  for _, f in ipairs(a and a.by_file[file] or {}) do
    if f.line then
      by_line[f.line] = by_line[f.line] or {}
      table.insert(by_line[f.line], f)
    end
  end
  table.sort(declarations, function(x, y)
    return x.line < y.line
  end)
  local items = {}
  for _, d in ipairs(declarations) do
    local notes = {}
    for _, f in ipairs(by_line[d.line] or {}) do
      notes[#notes + 1] = f.message
    end
    items[#items + 1] = {
      text = d.name .. " " .. d.kind .. " " .. (d.type or ""),
      chunks = {
        { ("%4d "):format(d.line), "Comment" },
        { d.exported and "export " or "       ", "Keyword" },
        { pad(d.kind, 10), "Type" },
        { d.name .. "  ", "Function" },
        { pad(d.type or "", 70) .. " ", "Comment" },
        { table.concat(notes, " · "), "DiagnosticWarn" },
      },
      file = cli.abs(root, file),
      pos = { d.line, 0 },
    }
  end
  return items
end

---@param root string
---@param locations { file: string, line: integer, column?: integer, before?: string, symbol?: string, context?: string }[]
---@return observatory.Item[]
function M.locations(root, locations)
  local items = {}
  for _, l in ipairs(locations) do
    local snippet = vim.trim(l.before or ((l.symbol or "") .. (l.context and ("  (" .. l.context .. ")") or "")))
    items[#items + 1] = {
      text = l.file .. " " .. snippet,
      chunks = { { l.file .. ":" .. l.line .. "  ", "Directory" }, { snippet, "Normal" } },
      file = cli.abs(root, l.file),
      pos = { l.line, (l.column or 1) - 1 },
    }
  end
  return items
end

return M
