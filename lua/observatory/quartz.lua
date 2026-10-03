-- Quartz backend: TypeScript symbols, declarations, usages and types from the compiler.
local cli = require("observatory.cli")

local M = {}

---Run one quartz command. Quartz wraps everything in `{ ok, command, data | error }`.
---@param root string
---@param command string
---@param payload table
---@param cb fun(err?: string, data?: table)
local function call(root, command, payload, cb)
  cli.json({ "quartz", command, vim.json.encode(payload) }, root, function(err, doc)
    if err then
      return cb(err)
    end
    if not doc.ok then
      local e = doc.error or {}
      return cb(e.message or ("quartz " .. command .. " failed"))
    end
    cb(nil, doc.data)
  end)
end

---Exported symbols across the repository.
---@param root string
---@param opts? { pattern?: string, kind?: string, file?: string, limit?: integer }
---@param cb fun(err?: string, data?: { symbols: { name: string, kind: string, file: string, line: integer, package: string, isIndexExport: boolean }[], total: integer, truncated: boolean })
function M.symbols(root, opts, cb)
  call(root, "symbols", vim.tbl_extend("keep", opts or {}, { limit = 5000 }), cb)
end

---Every declaration in one file, with its resolved type.
---@param root string
---@param file string repository-relative path
---@param cb fun(err?: string, data?: { declarations: { name: string, kind: string, line: integer, exported: boolean, type?: string }[], total: integer })
function M.file(root, file, cb)
  call(root, "file", { file = file, includePrivate = true }, cb)
end

---Usages of a symbol. Quartz has no find-references command; a rename preview visits
---exactly the same locations, so a throwaway rename is used to enumerate them.
---@param root string
---@param symbol string
---@param cb fun(err?: string, data?: { locations: { file: string, line: integer, column: integer, before: string }[], totalLocations: integer })
function M.usages(root, symbol, cb)
  call(root, "refactor-preview", { symbol = symbol, to = symbol .. "__observatory" }, cb)
end

---Resolved type at a position (1-based line and column).
---@param root string
---@param file string
---@param line integer
---@param column integer
---@param cb fun(err?: string, data?: { type: string, expanded: string, nodeKind: string, nodeText: string })
function M.at_position(root, file, line, column, cb)
  call(root, "at-position", { file = file, line = line, column = column }, cb)
end

---Members of an exported type, fully resolved.
---@param root string
---@param symbol string
---@param cb fun(err?: string, data?: { original: string, expanded: string, properties?: { name: string, type: string, optional?: boolean, from?: string }[] })
function M.expand(root, symbol, cb)
  call(root, "expand", { symbol = symbol }, cb)
end

---Types that reference, or are referenced by, an exported type.
---@param root string
---@param symbol string
---@param cb fun(err?: string, data?: { referencedBy: { symbol: string, context: string, file: string, line: integer }[], references: { symbol: string, context: string, file: string, line: integer }[] })
function M.related(root, symbol, cb)
  call(root, "related", { symbol = symbol }, cb)
end

---Functions that convert `from` into `to` (either side may be omitted).
---@param root string
---@param from? string
---@param to? string
---@param cb fun(err?: string, data?: { results: { name: string, signature: string, file: string, line: integer, verification: { status: string } }[] })
function M.transforms(root, from, to, cb)
  call(root, "transform-search", { from = from, to = to, limit = 50 }, cb)
end

return M
