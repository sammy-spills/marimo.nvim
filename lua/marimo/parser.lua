local util = require("marimo.util")

local M = {}

local function is_decorator(line)
  return line:match("^%s*@app%.cell") ~= nil
end

local function is_def(line)
  return line:match("^%s*def%s+[%w_]+%s*%(") ~= nil
end

local function parse_function_name(line)
  return line:match("^%s*def%s+([%w_]+)%s*%(")
end

local function parse_decorator_name(lines)
  local text = table.concat(lines, "\n")
  return text:match('name%s*=%s*"([^"]+)"') or text:match("name%s*=%s*'([^']+)'")
end

local function display_name_for_cell(decorator_lines, def_line)
  local decorator_name = parse_decorator_name(decorator_lines)
  if decorator_name and decorator_name ~= "" then
    return decorator_name
  end

  local function_name = parse_function_name(def_line)
  if function_name and function_name ~= "__" then
    return function_name
  end

  return nil
end

local function find_def_end(lines, def_line)
  local balance = 0
  local saw_open_paren = false

  for line_no = def_line, #lines do
    local line = lines[line_no]
    local opens = select(2, line:gsub("%(", ""))
    local closes = select(2, line:gsub("%)", ""))
    if opens > 0 then
      saw_open_paren = true
    end
    balance = balance + opens - closes

    if saw_open_paren then
      if balance <= 0 and line:match("%)%s*:%s*$") then
        return line_no
      end
    elseif line:match(":%s*$") then
      return line_no
    end
  end

  return def_line
end

local function sanitize_exec_lines(lines)
  local sanitized = {}
  local skipping_return = false
  local balance = 0

  local function update_balance(line)
    local opens = select(2, line:gsub("[%(%[%{]", ""))
    local closes = select(2, line:gsub("[%)%]%}]", ""))
    return opens - closes
  end

  for _, line in ipairs(lines) do
    if skipping_return then
      balance = balance + update_balance(line)
      if balance <= 0 and not line:match("\\%s*$") then
        skipping_return = false
        balance = 0
      end
    elseif line:match("^return%s*$") then
      -- Marimo cells return values from inside a function body; top-level exec should skip that.
    elseif line:match("^return%s+") then
      local remainder = line:gsub("^return%s+", "", 1)
      local delta = update_balance(remainder)
      if delta > 0 or remainder:match("\\%s*$") then
        skipping_return = true
        balance = delta
      end
    else
      table.insert(sanitized, line)
    end
  end
  while #sanitized > 0 and sanitized[#sanitized] == "" do
    table.remove(sanitized, #sanitized)
  end
  return sanitized
end

function M.parse_lines(lines)
  local cells = {}
  local i = 1
  while i <= #lines do
    if is_decorator(lines[i]) then
      local decorator_line = i
      local def_line = i + 1
      while def_line <= #lines and not is_def(lines[def_line]) do
        def_line = def_line + 1
      end
      if def_line > #lines then
        break
      end
      local def_end_line = find_def_end(lines, def_line)
      local body_start = def_end_line + 1
      local def_indent = #(lines[def_line]:match("^(%s*)") or "")
      local decorator_lines = util.list_slice(lines, decorator_line, def_line - 1)
      local function_name = parse_function_name(lines[def_line])
      local display_name = display_name_for_cell(decorator_lines, lines[def_line])
      local body_end = body_start - 1
      local scan = body_start
      while scan <= #lines do
        local line = lines[scan]
        if line:match("^%s*$") then
          body_end = scan
          scan = scan + 1
        else
          local current_indent = #(line:match("^(%s*)") or "")
          if current_indent <= def_indent then
            break
          end
          body_end = scan
          scan = scan + 1
        end
      end
      local end_line = body_end
      local body_lines = {}
      if body_end >= body_start then
        body_lines = util.list_slice(lines, body_start, body_end)
      end
      local dedented = util.dedent(body_lines)
      local exec_lines = sanitize_exec_lines(dedented)
      table.insert(cells, {
        id = #cells + 1,
        index = #cells,
        start_line = decorator_line,
        def_line = def_line,
        def_end_line = def_end_line,
        end_line = end_line,
        decorator_lines = decorator_lines,
        function_name = function_name,
        display_name = display_name,
        body_start_line = body_start,
        body_end_line = body_end,
        body_lines = dedented,
        exec_lines = exec_lines,
        code = table.concat(exec_lines, "\n"),
      })
      i = math.max(scan, i + 1)
    else
      i = i + 1
    end
  end
  return cells
end

function M.parse_buffer(bufnr)
  return M.parse_lines(util.read_lines(bufnr))
end

function M.cell_at_cursor(bufnr, cursor_line)
  local cells = M.parse_buffer(bufnr)
  local line = cursor_line or vim.api.nvim_win_get_cursor(0)[1]
  for index, cell in ipairs(cells) do
    if line >= cell.start_line and line <= cell.end_line then
      return cell, index, cells
    end
  end
  return nil, nil, cells
end

return M
