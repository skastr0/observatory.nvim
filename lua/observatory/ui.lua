-- Presentation primitives: a picker (Snacks when available, quickfix otherwise) and a float.
local M = {}

---@class observatory.Item
---@field text string searchable text
---@field chunks { [1]: string, [2]?: string }[] rendered columns as { text, highlight } pairs
---@field file? string absolute path; enables file preview and jump
---@field pos? { [1]: integer, [2]: integer } 1-based line, 0-based column
---@field preview? { text: string, ft?: string } shown when the item has no file
---@field on_confirm? fun() overrides the default jump

---@param msg string
---@param level? integer
function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "Observatory" })
end

---@param items observatory.Item[]
---@param title string
local function to_quickfix(items, title)
  local qf = {}
  for _, item in ipairs(items) do
    if item.file then
      qf[#qf + 1] = {
        filename = item.file,
        lnum = item.pos and item.pos[1] or 1,
        col = item.pos and item.pos[2] + 1 or 1,
        text = item.text,
      }
    end
  end
  vim.fn.setqflist({}, " ", { title = title, items = qf })
  vim.cmd("copen")
end

---@param title string
---@param items observatory.Item[]
function M.pick(title, items)
  if #items == 0 then
    return M.notify(title .. ": nothing to show")
  end
  local snacks = package.loaded["snacks"] and require("snacks") or nil
  if not (snacks and snacks.picker) then
    return to_quickfix(items, title)
  end
  snacks.picker({
    title = title,
    items = items,
    format = function(item)
      return item.chunks
    end,
    preview = function(ctx)
      if ctx.item.file then
        return snacks.picker.preview.file(ctx)
      end
      return snacks.picker.preview.preview(ctx)
    end,
    confirm = function(picker, item)
      if item and item.on_confirm then
        picker:close()
        return item.on_confirm()
      end
      return snacks.picker.actions.jump(picker, item, { cmd = "edit" })
    end,
    actions = {
      observatory_qf = function(picker)
        local all = picker:items()
        picker:close()
        to_quickfix(all, title)
      end,
    },
    win = { input = { keys = { ["<c-q>"] = { "observatory_qf", mode = { "n", "i" } } } } },
  })
end

---Centered scratch float, closed with q or <esc>.
---@param title string
---@param lines string[]
---@param opts? { ft?: string, highlights?: { [1]: integer, [2]: integer, [3]: integer, [4]: string }[] } highlights are { line0, col_start, col_end, group }
---@return integer buf, integer win
function M.float(title, lines, opts)
  opts = opts or {}
  local width = 20
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width + 2, vim.o.columns - 6)
  local height = math.min(#lines, vim.o.lines - 6)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  if opts.ft then
    vim.bo[buf].filetype = opts.ft
  end
  local ns = vim.api.nvim_create_namespace("observatory_float")
  for _, h in ipairs(opts.highlights or {}) do
    vim.api.nvim_buf_set_extmark(buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
  })
  vim.wo[win].wrap = false
  for _, key in ipairs({ "q", "<esc>" }) do
    vim.keymap.set("n", key, function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end, { buffer = buf, nowait = true })
  end
  return buf, win
end

return M
