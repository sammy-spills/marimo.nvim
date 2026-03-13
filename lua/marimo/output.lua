local config = require("marimo.config")
local parser = require("marimo.parser")
local util = require("marimo.util")

local M = {
  ns = vim.api.nvim_create_namespace("marimo-output"),
  outputs = {},
  inline_floats = {},
  detail_float_by_buf = {},
}

local function border_extra_height(border)
  if not border or border == "none" then
    return 0
  end
  return 2
end

local function preview_lines(lines)
  local max_lines = config.get().output.preview_lines
  local preview = {}
  for i = 1, math.min(#lines, max_lines) do
    table.insert(preview, { { lines[i], "Normal" } })
  end
  if #lines > max_lines then
    table.insert(preview, { { ("… %d more lines (press <leader>mo)"):format(#lines - max_lines), "Comment" } })
  end
  return preview
end

local function blank_preview_height(height)
  local preview = {}
  for _ = 1, height do
    table.insert(preview, { { " ", "Normal" } })
  end
  return preview
end

local function close_detail_float(bufnr)
  local state = M.detail_float_by_buf[bufnr]
  if state and state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  M.detail_float_by_buf[bufnr] = nil
end

local function close_inline_floats(bufnr)
  local by_window = M.inline_floats[bufnr]
  if not by_window then
    return
  end
  for _, floats in pairs(by_window) do
    for _, state in pairs(floats) do
      if state.win and vim.api.nvim_win_is_valid(state.win) then
        vim.api.nvim_win_close(state.win, true)
      end
      if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
        vim.api.nvim_buf_delete(state.buf, { force = true })
      end
    end
  end
  M.inline_floats[bufnr] = nil
end

local function close_inline_floats_for_window(bufnr, win)
  local by_window = M.inline_floats[bufnr]
  local floats = by_window and by_window[win]
  if not floats then
    return
  end
  for _, state in pairs(floats) do
    if state.win and vim.api.nvim_win_is_valid(state.win) then
      vim.api.nvim_win_close(state.win, true)
    end
    if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
      vim.api.nvim_buf_delete(state.buf, { force = true })
    end
  end
  by_window[win] = nil
  if vim.tbl_isempty(by_window) then
    M.inline_floats[bufnr] = nil
  end
end

local function calculate_float_size(lines, source_win)
  local width = math.max(24, vim.api.nvim_win_get_width(source_win) - 2)
  local height = math.max(config.get().output.min_height, math.min(config.get().output.max_height, #lines))
  return width, height
end

local function cell_is_visible_in_window(cell, win)
  local info = vim.fn.getwininfo(win)[1]
  if not info then
    return false
  end
  return cell.end_line >= info.topline and cell.start_line <= info.botline
end

local function open_inline_float(bufnr, source_win, cell, output_lines, output_kind)
  local width, height = calculate_float_size(output_lines, source_win)
  local float_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[float_buf].buftype = "nofile"
  vim.bo[float_buf].bufhidden = "wipe"
  vim.bo[float_buf].swapfile = false
  vim.bo[float_buf].modifiable = true
  vim.bo[float_buf].filetype = output_kind == "error" and "python" or "markdown"
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, output_lines)
  if #output_lines < height then
    local filler = {}
    for _ = 1, height - #output_lines do
      table.insert(filler, "")
    end
    vim.api.nvim_buf_set_lines(float_buf, -1, -1, false, filler)
  end
  vim.bo[float_buf].modifiable = false

  local float_win = vim.api.nvim_open_win(float_buf, false, {
    relative = "win",
    win = source_win,
    bufpos = { cell.end_line - 1, 0 },
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = config.get().output.border,
    focusable = false,
    noautocmd = true,
    zindex = 20,
  })
  vim.wo[float_win].wrap = config.get().output.wrap
  vim.wo[float_win].winhighlight = "NormalFloat:NormalFloat,FloatBorder:FloatBorder"

  M.inline_floats[bufnr] = M.inline_floats[bufnr] or {}
  M.inline_floats[bufnr][source_win] = M.inline_floats[bufnr][source_win] or {}
  M.inline_floats[bufnr][source_win][cell.id] = {
    win = float_win,
    buf = float_buf,
  }
end

local function ensure_last_output_visible(bufnr, cell, preview_size)
  if not cell or preview_size <= 0 then
    return
  end
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      local cursor = vim.api.nvim_win_get_cursor(win)
      local cursor_line = cursor[1]
      if cursor_line < cell.start_line or cursor_line > cell.end_line then
        goto continue
      end
      if cursor_line < cell.end_line then
        vim.api.nvim_win_set_cursor(win, { cell.end_line, cursor[2] })
      end
      local info = vim.fn.getwininfo(win)[1]
      if info then
        local visible_room = info.botline - cell.end_line
        if visible_room < preview_size then
          local shortage = preview_size - visible_room
          local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
          view.topline = math.max(1, view.topline + shortage)
          vim.api.nvim_win_call(win, function()
            vim.fn.winrestview(view)
          end)
        end
      end
    end
    ::continue::
  end
end

function M.clear(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  M.outputs[bufnr] = {}
  close_inline_floats(bufnr)
  close_detail_float(bufnr)
end

function M.set_outputs(bufnr, items)
  M.outputs[bufnr] = M.outputs[bufnr] or {}
  for _, item in ipairs(items) do
    M.outputs[bufnr][item.id] = {
      lines = item.lines or { "<no output>" },
      kind = item.kind or "text",
    }
  end
  M.render(bufnr, { ensure_last_visible = true })
end

function M.sync_visibility(bufnr)
  if not M.inline_floats[bufnr] and not M.detail_float_by_buf[bufnr] then
    return
  end

  local visible = {}
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      visible[win] = true
    end
  end

  local tracked = M.inline_floats[bufnr]
  if tracked then
    for win, _ in pairs(tracked) do
      if not visible[win] then
        close_inline_floats_for_window(bufnr, win)
      end
    end
  end

  if vim.tbl_isempty(visible) then
    close_detail_float(bufnr)
  end
end

function M.render(bufnr, opts)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  opts = opts or {}
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  close_inline_floats(bufnr)
  local cells = parser.parse_buffer(bufnr)
  local outputs = M.outputs[bufnr] or {}
  local last_cell = cells[#cells]
  local last_preview_size = 0
  local source_wins = vim.tbl_filter(vim.api.nvim_win_is_valid, vim.fn.win_findbuf(bufnr))
  local fallback_win = vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(fallback_win) then
    fallback_win = source_wins[1]
  end
  for _, cell in ipairs(cells) do
    local output = outputs[cell.id]
    if output then
      local preview = preview_lines(output.lines)
      local rendered = {}
      for _, chunks in ipairs(preview) do
        table.insert(rendered, chunks[1][1])
      end
      local height = 0
      for _, win in ipairs(source_wins) do
        local _, win_height = calculate_float_size(rendered, win)
        height = math.max(height, win_height)
      end
      if height == 0 and fallback_win and vim.api.nvim_win_is_valid(fallback_win) then
        local _, fallback_height = calculate_float_size(rendered, fallback_win)
        height = fallback_height
      end
      local blank_lines = blank_preview_height(height + border_extra_height(config.get().output.border))
      if last_cell and cell.id == last_cell.id then
        last_preview_size = #blank_lines
      end
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, cell.end_line - 1, 0, {
        virt_lines = blank_lines,
        virt_lines_above = false,
        hl_mode = "combine",
      })
    end
  end
  for _, win in ipairs(source_wins) do
    for _, cell in ipairs(cells) do
      local output = outputs[cell.id]
      if output and cell_is_visible_in_window(cell, win) then
        local lines = preview_lines(output.lines)
        local rendered = {}
        for _, chunks in ipairs(lines) do
          table.insert(rendered, chunks[1][1])
        end
        open_inline_float(bufnr, win, cell, rendered, output.kind)
      end
    end
  end
  if opts.ensure_last_visible then
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        ensure_last_output_visible(bufnr, last_cell, last_preview_size)
      end
    end)
  end
end

function M.focus_output(bufnr, cell_index)
  local outputs = M.outputs[bufnr] or {}
  local output = outputs[cell_index]
  if not output then
    util.notify("No output for current cell", vim.log.levels.WARN)
    return
  end
  close_detail_float(bufnr)
  local lines = vim.deepcopy(output.lines)
  if #lines == 0 then
    lines = { "<no output>" }
  end
  local float_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[float_buf].buftype = "nofile"
  vim.bo[float_buf].bufhidden = "wipe"
  vim.bo[float_buf].swapfile = false
  vim.bo[float_buf].filetype = output.kind == "error" and "python" or "markdown"
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)

  local win = vim.api.nvim_get_current_win()
  local width = math.max(40, math.floor(vim.api.nvim_win_get_width(win) * 0.75))
  local height = math.max(
    config.get().output.min_height,
    math.min(config.get().output.max_height, #lines)
  )
  local float_win = vim.api.nvim_open_win(float_buf, true, {
    relative = "win",
    win = win,
    row = 2,
    col = 2,
    width = math.min(width, vim.api.nvim_win_get_width(win) - 4),
    height = math.min(height, vim.api.nvim_win_get_height(win) - 4),
    style = "minimal",
    border = config.get().output.border,
    focusable = config.get().output.focusable,
    title = (" Marimo Output [%d] "):format(cell_index),
    title_pos = "center",
  })
  vim.wo[float_win].wrap = config.get().output.wrap
  M.detail_float_by_buf[bufnr] = {
    win = float_win,
    buf = float_buf,
    return_win = win,
    cell_index = cell_index,
  }
  vim.keymap.set("n", "q", function()
    M.exit_output(bufnr)
  end, { buffer = float_buf, silent = true })
  vim.keymap.set("n", "<Esc>", function()
    M.exit_output(bufnr)
  end, { buffer = float_buf, silent = true })
end

function M.exit_output(bufnr)
  local state = M.detail_float_by_buf[bufnr]
  if not state then
    return
  end
  local return_win = state.return_win
  close_detail_float(bufnr)
  if return_win and vim.api.nvim_win_is_valid(return_win) then
    vim.api.nvim_set_current_win(return_win)
  end
end

function M.has_focus(bufnr)
  local state = M.detail_float_by_buf[bufnr]
  return state and state.win and vim.api.nvim_get_current_win() == state.win or false
end

return M
