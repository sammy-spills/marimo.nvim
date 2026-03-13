local detect = require("marimo.detect")
local session = require("marimo.session")
local output = require("marimo.output")

local M = {}

local function bufnr()
  return vim.api.nvim_get_current_buf()
end

function M.enable(force)
  detect.set_enabled(bufnr(), true, force and "manual" or "auto")
end

function M.disable()
  detect.set_enabled(bufnr(), false, "manual-disable")
  output.clear(bufnr())
  session.stop(bufnr())
end

function M.create()
  vim.api.nvim_create_user_command("MarimoStartEdit", function()
    session.start(bufnr(), "edit")
  end, {})

  vim.api.nvim_create_user_command("MarimoStartWatch", function()
    session.start(bufnr(), "watch")
  end, {})

  vim.api.nvim_create_user_command("MarimoRunCell", function()
    session.run_cell(bufnr())
  end, {})

  vim.api.nvim_create_user_command("MarimoRunAll", function()
    session.run_all(bufnr())
  end, {})

  vim.api.nvim_create_user_command("MarimoRestartKernel", function()
    session.restart_kernel(bufnr())
  end, {})

  vim.api.nvim_create_user_command("MarimoInstall", function(opts)
    if #opts.fargs == 0 then
      session.prompt_install(bufnr())
      return
    end
    session.install(bufnr(), opts.fargs)
  end, { nargs = "*" })

  vim.api.nvim_create_user_command("MarimoEnable", function()
    M.enable(true)
  end, {})

  vim.api.nvim_create_user_command("MarimoDisable", function()
    M.disable()
  end, {})

  vim.api.nvim_create_user_command("MarimoEnterOutput", function()
    session.enter_output(bufnr())
  end, {})

  vim.api.nvim_create_user_command("MarimoExitOutput", function()
    session.exit_output(bufnr())
  end, {})
end

return M
