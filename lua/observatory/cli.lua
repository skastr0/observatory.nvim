-- Async JSON runner shared by the pulsar and quartz backends.
local M = {}

---Repository root for a buffer: nearest ancestor containing `.git`, else cwd.
---@param buf? integer
---@return string
function M.root(buf)
  local name = vim.api.nvim_buf_get_name(buf or 0)
  local start = (name ~= "" and vim.uv.fs_stat(name)) and vim.fs.dirname(name) or vim.uv.cwd()
  local git = vim.fs.find(".git", { path = start, upward = true })[1]
  return vim.fs.normalize(git and vim.fs.dirname(git) or vim.uv.cwd())
end

---Path relative to root; absolute paths outside root are returned unchanged.
---@param root string
---@param path string
---@return string
function M.rel(root, path)
  path = vim.fs.normalize(path)
  if path:sub(1, #root + 1) == root .. "/" then
    return path:sub(#root + 2)
  end
  return path
end

---@param root string
---@param path string
---@return string
function M.abs(root, path)
  if path:sub(1, 1) == "/" then
    return vim.fs.normalize(path)
  end
  return root .. "/" .. path
end

---Run a command that prints one JSON document on stdout.
---Both CLIs exit non-zero while still printing a valid document (pulsar: 2 = blocked,
---3 = incomplete evidence; quartz: 1 = error envelope), so the exit code is passed through.
---@param cmd string[]
---@param cwd string
---@param cb fun(err?: string, doc?: table, code?: integer)
function M.json(cmd, cwd, cb)
  local ok, err = pcall(vim.system, cmd, { cwd = cwd, text = true }, function(res)
    local decoded_ok, doc = pcall(vim.json.decode, res.stdout or "", { luanil = { object = true, array = true } })
    vim.schedule(function()
      if decoded_ok and type(doc) == "table" then
        cb(nil, doc, res.code)
      else
        local detail = vim.trim(res.stderr or ""):sub(-300)
        cb(("%s exited %d without JSON%s"):format(cmd[1], res.code, detail ~= "" and (": " .. detail) or ""))
      end
    end)
  end)
  if not ok then
    cb(("could not start %s: %s"):format(cmd[1], err))
  end
end

return M
