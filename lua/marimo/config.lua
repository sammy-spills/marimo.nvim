local M = {}

M.defaults = {
  detection = {
    enabled = true,
    weak_score = 2,
    strong_score = 4,
    async_check = true,
    debounce_ms = 150,
  },
  commands = {
    uv = "uv",
    uvx = "uvx",
    marimo = "marimo",
    python = "python3",
    curl = "curl",
    headless = true,
    check_format = "json",
  },
  output = {
    preview_lines = 8,
    min_height = 4,
    max_height = 16,
    border = "rounded",
    focusable = true,
    wrap = false,
  },
  lazyvim = {
    enable_keymaps = true,
  },
  notifications = {
    level = vim.log.levels.INFO,
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  return M.options
end

function M.get()
  return M.options
end

return M
