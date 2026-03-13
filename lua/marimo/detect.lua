local config = require("marimo.config")
local util = require("marimo.util")

local M = {
  state = {},
}

local heuristic_patterns = {
  { pattern = "^%s*import%s+marimo", score = 2 },
  { pattern = "^%s*from%s+marimo%s+import", score = 2 },
  { pattern = "marimo%.App%s*%(", score = 2 },
  { pattern = "^%s*@app%.cell", score = 3 },
  { pattern = "^%s*app%s*=%s*marimo%.App", score = 3 },
}

local function score_lines(lines)
  local score = 0
  for _, line in ipairs(lines) do
    for _, entry in ipairs(heuristic_patterns) do
      if line:match(entry.pattern) then
        score = score + entry.score
      end
    end
  end
  return score
end

function M.score_buffer(bufnr)
  return score_lines(util.read_lines(bufnr))
end

function M.is_enabled(bufnr)
  return vim.b[bufnr].marimo_enabled == true
end

function M.set_enabled(bufnr, enabled, reason)
  vim.b[bufnr].marimo_enabled = enabled and true or false
  vim.b[bufnr].marimo_reason = reason
end

function M.heuristic_decision(bufnr)
  local opts = config.get().detection
  local score = M.score_buffer(bufnr)
  return {
    score = score,
    weak_match = score >= opts.weak_score,
    strong_match = score >= opts.strong_score,
  }
end

function M.confirm_async(bufnr, callback)
  local opts = config.get()
  local path = util.buf_path(bufnr)
  if path == "" or not util.file_exists(path) or not util.command_exists(opts.commands.uvx) then
    callback(false, "missing-path-or-uvx")
    return
  end
  vim.system(
    {
      opts.commands.uvx,
      opts.commands.marimo,
      "check",
      "--format",
      opts.commands.check_format,
      path,
    },
    { text = true },
    function(result)
      local ok = result.code == 0
      callback(ok, ok and "marimo-check" or (result.stderr ~= "" and result.stderr or result.stdout))
    end
  )
end

function M.detect(bufnr, callback)
  if not util.is_python_buffer(bufnr) then
    M.set_enabled(bufnr, false, "not-python")
    if callback then
      callback(false, "not-python")
    end
    return
  end
  local decision = M.heuristic_decision(bufnr)
  if decision.strong_match then
    M.set_enabled(bufnr, true, "heuristic-strong")
    if callback then
      callback(true, "heuristic-strong")
    end
    if config.get().detection.async_check then
      M.confirm_async(bufnr, function(ok, reason)
        M.state[bufnr] = { confirmed = ok, reason = reason }
      end)
    end
    return
  end
  if decision.weak_match and config.get().detection.async_check then
    M.confirm_async(bufnr, function(ok, reason)
      M.set_enabled(bufnr, ok, reason)
      M.state[bufnr] = { confirmed = ok, reason = reason }
      if callback then
        callback(ok, reason)
      end
    end)
    return
  end
  M.set_enabled(bufnr, false, "heuristic-miss")
  if callback then
    callback(false, "heuristic-miss")
  end
end

return M
