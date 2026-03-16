local config = require("marimo.config")
local output = require("marimo.output")
local executor = require("marimo.executor")
local parser = require("marimo.parser")
local transport = require("marimo.transport")
local util = require("marimo.util")

local M = {
  buffers = {},
}

local function session_for(bufnr)
  M.buffers[bufnr] = M.buffers[bufnr] or {
    status = "inactive",
    mode = nil,
    job = nil,
    root = util.find_root(util.buf_path(bufnr)),
    file = util.buf_path(bufnr),
  }
  return M.buffers[bufnr]
end

local function start_job(bufnr, mode)
  local session = session_for(bufnr)
  local cmd = M._build_start_command(session.file)

  if not cmd then
    session.status = "failed"
    util.notify("Neither `uv` nor `uvx` is available on PATH", vim.log.levels.ERROR)
    return false
  end

  if mode == "watch" then
    table.insert(cmd, "--watch")
  end
  if config.get().commands.headless then
    table.insert(cmd, "--headless")
  end
  table.insert(cmd, session.file)

  session.status = "starting"
  session.mode = mode
  session.root = util.find_root(session.file)

  session.job = vim.fn.jobstart(cmd, {
    cwd = session.root,
    detach = false,
    on_stdout = function(_, data)
      transport.observe_server_output(bufnr, data)
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        transport.reset(bufnr)
        session.status = code == 0 and "inactive" or "failed"
        if code ~= 0 then
          util.notify(("Marimo %s session exited with code %d"):format(mode, code), vim.log.levels.WARN)
        end
      end)
    end,
    on_stderr = function(_, data)
      if data and #data > 0 then
        local line = util.trim(table.concat(data, "\n"))
        if line ~= "" then
          vim.schedule(function()
            util.notify(line, vim.log.levels.DEBUG)
          end)
        end
      end
    end,
  })

  if session.job <= 0 then
    session.status = "failed"
    util.notify("Failed to start Marimo server", vim.log.levels.ERROR)
    return false
  end

  session.status = "running"
  util.notify(("Started Marimo %s server"):format(mode))
  return true
end

function M._build_start_command(path)
  local opts = config.get()
  local uv_project_root = util.find_uv_project_root(path)

  if uv_project_root and util.command_exists(opts.commands.uv) then
    return {
      opts.commands.uv,
      "run",
      "--project",
      uv_project_root,
      opts.commands.marimo,
      "edit",
    }
  end

  if util.command_exists(opts.commands.uvx) then
    return {
      opts.commands.uvx,
      opts.commands.marimo,
      "edit",
    }
  end

  return nil
end

function M.start(bufnr, mode)
  local session = session_for(bufnr)
  if session.status == "running" and session.mode == mode and session.job and vim.fn.jobwait({ session.job }, 0)[1] == -1 then
    util.notify(("Marimo %s server already running"):format(mode))
    return true
  end
  session.file = util.buf_path(bufnr)
  return start_job(bufnr, mode)
end

function M.stop(bufnr)
  local session = session_for(bufnr)
  if session.job and vim.fn.jobwait({ session.job }, 0)[1] == -1 then
    vim.fn.jobstop(session.job)
  end
  transport.reset(bufnr)
  session.status = "inactive"
  session.job = nil
  session.mode = nil
end

function M.restart_kernel(bufnr)
  local session = session_for(bufnr)
  session.status = "restarting"
  output.clear(bufnr)
  transport.reset(bufnr)
  session.last_run = nil
  session.status = session.job and "running" or "inactive"
  util.notify("Kernel state reset for current notebook")
end

function M.run_cell(bufnr)
  local cell, index, cells = parser.cell_at_cursor(bufnr)
  if not cell or not index or #cells == 0 then
    util.notify("No Marimo cell under cursor", vim.log.levels.WARN)
    return
  end
  executor.run_cell(bufnr, index, function(ok, result)
    vim.schedule(function()
      if not ok then
        util.notify(result, vim.log.levels.ERROR)
        output.set_outputs(bufnr, {
          {
            id = index,
            kind = "error",
            lines = vim.split(result, "\n", { plain = true }),
          },
        })
        return
      end
      output.set_outputs(bufnr, result)
      util.notify(("Executed cell %d"):format(index))
    end)
  end)
end

function M.run_all(bufnr)
  local cells = parser.parse_buffer(bufnr)
  if #cells == 0 then
    util.notify("No Marimo cells found", vim.log.levels.WARN)
    return
  end
  executor.run_all(bufnr, function(ok, result)
    vim.schedule(function()
      if not ok then
        util.notify(result, vim.log.levels.ERROR)
        return
      end
      output.set_outputs(bufnr, result)
      util.notify(("Executed %d cells"):format(#result))
    end)
  end)
end

function M.install(bufnr, packages)
  packages = packages or {}
  if #packages == 0 then
    util.notify("Usage: :MarimoInstall <package ...>", vim.log.levels.WARN)
    return
  end
  local session = session_for(bufnr)
  local root = util.find_root(session.file)
  local cmd
  if util.command_exists("uv") and util.file_exists(root .. "/pyproject.toml") then
    cmd = { "uv", "add" }
  else
    cmd = { config.get().commands.python, "-m", "pip", "install" }
  end
  vim.list_extend(cmd, packages)
  util.notify("Installing dependencies: " .. table.concat(cmd, " "))
  vim.system(cmd, { cwd = root, text = true }, function(result)
    vim.schedule(function()
      if result.code == 0 then
        util.notify("Dependencies installed")
      else
        util.notify(result.stderr ~= "" and result.stderr or result.stdout, vim.log.levels.ERROR)
      end
    end)
  end)
end

function M.prompt_install(bufnr)
  vim.ui.input({ prompt = "Marimo packages: " }, function(input)
    if not input or util.trim(input) == "" then
      return
    end
    M.install(bufnr, vim.split(util.trim(input), "%s+", { trimempty = true }))
  end)
end

function M.enter_output(bufnr)
  local _, index = parser.cell_at_cursor(bufnr)
  if not index then
    util.notify("Move the cursor into a Marimo cell first", vim.log.levels.WARN)
    return
  end
  output.focus_output(bufnr, index)
end

function M.exit_output(bufnr)
  output.exit_output(bufnr)
end

function M.next_cell(bufnr)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  for _, cell in ipairs(parser.parse_buffer(bufnr)) do
    if cell.start_line > line then
      vim.api.nvim_win_set_cursor(0, { cell.start_line, 0 })
      return
    end
  end
end

function M.prev_cell(bufnr)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local target
  for _, cell in ipairs(parser.parse_buffer(bufnr)) do
    if cell.start_line < line then
      target = cell.start_line
    else
      break
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(0, { target, 0 })
  end
end

return M
