local M = {}

local root_markers = {
  "pyproject.toml",
  "uv.lock",
  "requirements.txt",
  ".python-version",
  ".venv",
}

local uv_project_markers = {
  "pyproject.toml",
  "uv.lock",
}

function M.notify(message, level)
  vim.schedule(function()
    vim.notify(message, level or vim.log.levels.INFO, { title = "marimo.nvim" })
  end)
end

function M.buf_path(bufnr)
  return vim.api.nvim_buf_get_name(bufnr)
end

function M.is_python_buffer(bufnr)
  return vim.bo[bufnr].filetype == "python"
end

function M.read_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

function M.file_exists(path)
  return path ~= "" and vim.uv.fs_stat(path) ~= nil
end

function M.find_root(path)
  local start = path
  if start == "" then
    return vim.uv.cwd()
  end
  local stat = vim.uv.fs_stat(start)
  if stat and stat.type == "file" then
    start = vim.fs.dirname(start)
  end
  local root = vim.fs.root(start, root_markers)
  return root or start or vim.uv.cwd()
end

function M.find_uv_project_root(path)
  local start = path
  if start == "" then
    start = vim.uv.cwd()
  end
  local stat = vim.uv.fs_stat(start)
  if stat and stat.type == "file" then
    start = vim.fs.dirname(start)
  end
  return vim.fs.root(start, uv_project_markers)
end

function M.command_exists(cmd)
  return vim.fn.executable(cmd) == 1
end

function M.has_which_key()
  local ok, _ = pcall(require, "which-key")
  return ok
end

function M.shellescape(arg)
  return vim.fn.shellescape(arg)
end

function M.join(lines)
  return table.concat(lines, "\n")
end

function M.trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.dedent(lines)
  local indent
  for _, line in ipairs(lines) do
    if line:match("%S") then
      local current = #(line:match("^(%s*)") or "")
      indent = indent and math.min(indent, current) or current
    end
  end
  if not indent or indent == 0 then
    return vim.deepcopy(lines)
  end
  local dedented = {}
  for _, line in ipairs(lines) do
    if line:match("^%s+$") then
      table.insert(dedented, "")
    else
      table.insert(dedented, line:sub(indent + 1))
    end
  end
  return dedented
end

function M.list_slice(lines, first, last)
  local slice = {}
  for i = first, last do
    table.insert(slice, lines[i])
  end
  return slice
end

function M.tbl_keys(tbl)
  local keys = {}
  for key, _ in pairs(tbl) do
    table.insert(keys, key)
  end
  table.sort(keys)
  return keys
end

return M
