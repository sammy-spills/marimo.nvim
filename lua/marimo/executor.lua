local parser = require("marimo.parser")
local util = require("marimo.util")
local config = require("marimo.config")

local M = {}

local function python_command(root)
  if util.command_exists("uv") and util.file_exists(root .. "/pyproject.toml") then
    return { "uv", "run", "python" }
  end
  return { config.get().commands.python }
end

local function build_runner_script(cells, current_index)
  local payload = {}
  for index, cell in ipairs(cells) do
    table.insert(payload, {
      id = index,
      code = cell.code,
      capture = current_index == nil or index == current_index,
    })
  end
  local json = vim.json.encode(payload)
  return table.concat({
    "import contextlib",
    "import io",
    "import json",
    "import traceback",
    "",
    "cells = json.loads(" .. string.format("%q", json) .. ")",
    "env = {}",
    "results = []",
    "for cell in cells:",
    "    stdout = io.StringIO()",
    "    stderr = io.StringIO()",
    "    item = {'id': cell['id'], 'kind': 'text', 'lines': []}",
    "    try:",
    "        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):",
    "            exec(cell['code'], env, env)",
    "        combined = stdout.getvalue() + stderr.getvalue()",
    "        item['lines'] = combined.splitlines() if combined else ['<no output>']",
    "    except Exception:",
    "        item['kind'] = 'error'",
    "        item['lines'] = traceback.format_exc().splitlines()",
    "        results.append(item)",
    "        break",
    "    results.append(item)",
    "print(json.dumps(results))",
  }, "\n")
end

local function run_python(root, script, callback)
  local script_path = vim.fn.tempname() .. ".py"
  vim.fn.writefile(vim.split(script, "\n", { plain = true }), script_path)
  local cmd = python_command(root)
  table.insert(cmd, script_path)
  vim.system(cmd, { cwd = root, text = true }, function(result)
    vim.schedule(function()
      vim.fn.delete(script_path)
      callback(result)
    end)
  end)
end

function M.run_cell(bufnr, cell_index, callback)
  local cells = parser.parse_buffer(bufnr)
  local cell = cells[cell_index]
  if not cell then
    callback(false, "No Marimo cell under cursor")
    return
  end
  local root = util.find_root(util.buf_path(bufnr))
  run_python(root, build_runner_script(cells, cell_index), function(result)
    if result.code ~= 0 then
      callback(false, result.stderr ~= "" and result.stderr or result.stdout)
      return
    end
    local ok, decoded = pcall(vim.json.decode, result.stdout)
    if not ok then
      callback(false, "Failed to decode executor output")
      return
    end
    callback(true, decoded)
  end)
end

function M.run_all(bufnr, callback)
  local cells = parser.parse_buffer(bufnr)
  if #cells == 0 then
    callback(false, "No Marimo cells found")
    return
  end
  local root = util.find_root(util.buf_path(bufnr))
  run_python(root, build_runner_script(cells, nil), function(result)
    if result.code ~= 0 then
      callback(false, result.stderr ~= "" and result.stderr or result.stdout)
      return
    end
    local ok, decoded = pcall(vim.json.decode, result.stdout)
    if not ok then
      callback(false, "Failed to decode executor output")
      return
    end
    callback(true, decoded)
  end)
end

return M
