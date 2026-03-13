local config = require("marimo.config")
local detect = require("marimo.detect")
local parser = require("marimo.parser")
local session = require("marimo.session")
local commands = require("marimo.commands")
local output = require("marimo.output")
local cells = require("marimo.cells")
local util = require("marimo.util")

local M = {
  _did_setup = false,
}

local group = vim.api.nvim_create_augroup("MarimoNvim", { clear = true })

local function set_buffer_keymaps(bufnr)
  if vim.b[bufnr].marimo_keymaps_set or not config.get().lazyvim.enable_keymaps then
    return
  end
  local opts = { buffer = bufnr, silent = true }
  vim.keymap.set("n", "<leader>me", "<cmd>MarimoStartEdit<cr>", opts)
  vim.keymap.set("n", "<leader>mw", "<cmd>MarimoStartWatch<cr>", opts)
  vim.keymap.set("n", "<leader>mc", "<cmd>MarimoRunCell<cr>", opts)
  vim.keymap.set("n", "<leader>ma", "<cmd>MarimoRunAll<cr>", opts)
  vim.keymap.set("n", "<leader>mr", "<cmd>MarimoRestartKernel<cr>", opts)
  vim.keymap.set("n", "<leader>mi", function()
    session.prompt_install(bufnr)
  end, opts)
  vim.keymap.set("n", "<leader>mo", "<cmd>MarimoEnterOutput<cr>", opts)
  vim.keymap.set("n", "<leader>mO", "<cmd>MarimoExitOutput<cr>", opts)
  vim.keymap.set("n", "]m", function()
    session.next_cell(bufnr)
  end, opts)
  vim.keymap.set("n", "[m", function()
    session.prev_cell(bufnr)
  end, opts)
  vim.b[bufnr].marimo_keymaps_set = true
end

local function on_detected(bufnr, enabled)
  if enabled then
    set_buffer_keymaps(bufnr)
    cells.render(bufnr)
    output.render(bufnr)
  else
    cells.clear(bufnr)
    cells.restore_windows(bufnr)
    output.clear(bufnr)
  end
end

function M.maybe_enable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  detect.detect(bufnr, function(enabled)
    vim.schedule(function()
      on_detected(bufnr, enabled)
    end)
  end)
end

function M.setup(opts)
  config.setup(opts)
  if M._did_setup then
    return
  end
  M._did_setup = true
  commands.create()
  cells.setup()
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
    group = group,
    pattern = "*.py",
    callback = function(args)
      M.maybe_enable(args.buf)
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWinEnter" }, {
    group = group,
    pattern = "*.py",
    callback = function(args)
      if detect.is_enabled(args.buf) then
        cells.render(args.buf)
        output.render(args.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    pattern = "*",
    callback = function()
      local bufnr = vim.api.nvim_get_current_buf()
      if detect.is_enabled(bufnr) then
        cells.render(bufnr)
      end
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      cells.setup()
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWinLeave", "BufHidden" }, {
    group = group,
    pattern = "*.py",
    callback = function(args)
      vim.schedule(function()
        output.sync_visibility(args.buf)
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized", "VimResized" }, {
    group = group,
    callback = function()
      local seen = {}
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) then
          local ok, bufnr = pcall(vim.api.nvim_win_get_buf, win)
          if ok and bufnr and not seen[bufnr] and detect.is_enabled(bufnr) then
            seen[bufnr] = true
            output.render(bufnr)
          end
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    callback = function(args)
      cells.clear(args.buf)
      output.clear(args.buf)
    end,
  })
end

function M.bootstrap()
  M.setup({})
end

function M.lazy_keys()
  return {
    { "<leader>m", desc = "Marimo" },
    { "<leader>me", "<cmd>MarimoStartEdit<cr>", desc = "Start edit server", ft = "python" },
    { "<leader>mw", "<cmd>MarimoStartWatch<cr>", desc = "Start watch server", ft = "python" },
    { "<leader>mc", "<cmd>MarimoRunCell<cr>", desc = "Run cell", ft = "python" },
    { "<leader>ma", "<cmd>MarimoRunAll<cr>", desc = "Run all", ft = "python" },
    { "<leader>mr", "<cmd>MarimoRestartKernel<cr>", desc = "Restart kernel", ft = "python" },
    { "<leader>mi", function()
      session.prompt_install(vim.api.nvim_get_current_buf())
    end, desc = "Install dependency", ft = "python" },
    { "<leader>mo", "<cmd>MarimoEnterOutput<cr>", desc = "Enter output", ft = "python" },
    { "<leader>mO", "<cmd>MarimoExitOutput<cr>", desc = "Exit output", ft = "python" },
    { "]m", function()
      session.next_cell(vim.api.nvim_get_current_buf())
    end, desc = "Next Marimo cell", ft = "python" },
    { "[m", function()
      session.prev_cell(vim.api.nvim_get_current_buf())
    end, desc = "Previous Marimo cell", ft = "python" },
  }
end

function M.cells(bufnr)
  return parser.parse_buffer(bufnr or vim.api.nvim_get_current_buf())
end

function M.enable(bufnr)
  detect.set_enabled(bufnr or vim.api.nvim_get_current_buf(), true, "manual")
  on_detected(bufnr or vim.api.nvim_get_current_buf(), true)
end

function M.disable(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  detect.set_enabled(bufnr, false, "manual")
  cells.clear(bufnr)
  cells.restore_windows(bufnr)
  output.clear(bufnr)
end

function M.status(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return {
    enabled = detect.is_enabled(bufnr),
    reason = vim.b[bufnr].marimo_reason,
    path = util.buf_path(bufnr),
  }
end

return M
