vim.opt.runtimepath:prepend(vim.fn.fnamemodify(".", ":p"))

local marimo = require("marimo")
local detect = require("marimo.detect")
local parser = require("marimo.parser")
local executor = require("marimo.executor")
local output = require("marimo.output")

local function assert_truthy(value, message)
  if not value then
    error(message)
  end
end

local function assert_equal(left, right, message)
  if left ~= right then
    error(message .. (" (expected %s, got %s)"):format(vim.inspect(right), vim.inspect(left)))
  end
end

marimo.setup({
  detection = {
    async_check = false,
  },
})

local notebook = vim.fn.fnamemodify("tests/fixtures/notebook.py", ":p")
local script = vim.fn.fnamemodify("tests/fixtures/script.py", ":p")

local notebook_buf = vim.fn.bufadd(notebook)
vim.fn.bufload(notebook_buf)
vim.bo[notebook_buf].filetype = "python"

local script_buf = vim.fn.bufadd(script)
vim.fn.bufload(script_buf)
vim.bo[script_buf].filetype = "python"

local decision = detect.heuristic_decision(notebook_buf)
assert_truthy(decision.strong_match, "expected notebook fixture to be detected as Marimo")

local script_decision = detect.heuristic_decision(script_buf)
assert_truthy(not script_decision.weak_match, "expected plain python fixture to stay disabled")

local cells = parser.parse_buffer(notebook_buf)
assert_equal(#cells, 4, "expected parser to find four cells")
assert_truthy(cells[1].code:match("print%(") ~= nil, "expected parser to sanitize cell body")
assert_truthy(cells[3].code:match("^%s*return") == nil, "expected multiline return to be stripped from execution code")
assert_truthy(cells[3].code:match("final") ~= nil, "expected multiline return cell body to remain executable")
assert_equal(cells[4].body_start_line, cells[4].def_end_line + 1, "expected multiline def header to be skipped before body execution")
assert_truthy(cells[4].code:match("multiline args") ~= nil, "expected multiline def cell body to remain executable")

local completed = false
executor.run_all(notebook_buf, function(ok, result)
  assert_truthy(ok, "expected notebook execution to succeed")
  assert_equal(#result, 4, "expected four output payloads")
  assert_truthy(table.concat(result[1].lines, "\n"):match("hello from cell 1") ~= nil, "missing output for first cell")
  assert_truthy(table.concat(result[2].lines, "\n"):match("value: 3") ~= nil, "missing output for second cell")
  assert_truthy(table.concat(result[3].lines, "\n"):match("final: 6") ~= nil, "missing output for multiline return cell")
  assert_truthy(table.concat(result[4].lines, "\n"):match("multiline args: 9") ~= nil, "missing output for multiline def cell")
  completed = true
end)

vim.wait(10000, function()
  return completed
end, 50)

assert_truthy(completed, "expected executor callback to complete")

vim.api.nvim_set_current_buf(notebook_buf)
vim.cmd("resize 6")

local current_win = vim.api.nvim_get_current_win()
local last_cell = cells[#cells]
vim.api.nvim_win_set_cursor(current_win, { last_cell.start_line, 0 })
local original_view = vim.fn.winsaveview()

output.set_outputs(notebook_buf, {
  {
    id = last_cell.id,
    kind = "text",
    lines = {
      "line 1",
      "line 2",
      "line 3",
      "line 4",
    },
  },
})

vim.wait(1000, function()
  return vim.fn.winsaveview().topline ~= original_view.topline
end, 50)

local adjusted_view = vim.fn.winsaveview()
assert_truthy(adjusted_view.topline > original_view.topline, "expected viewport to scroll when cursor is in final cell")

local extmarks = vim.api.nvim_buf_get_extmarks(notebook_buf, output.ns, 0, -1, { details = true })
assert_truthy(#extmarks > 0, "expected output renderer to reserve space for inline floats")
assert_equal(#extmarks[#extmarks][4].virt_lines, 6, "expected reserved preview space to include inline float borders")

local inline_window_state = output.inline_floats[notebook_buf] and output.inline_floats[notebook_buf][current_win]
assert_truthy(inline_window_state ~= nil, "expected inline output floats to be tracked per source window")
local inline_float = inline_window_state and inline_window_state[last_cell.id]
assert_truthy(inline_float ~= nil and vim.api.nvim_win_is_valid(inline_float.win), "expected inline float window for the last cell")
assert_equal(vim.api.nvim_win_get_width(inline_float.win), vim.api.nvim_win_get_width(current_win) - 2, "expected inline float to use the full source window width")
assert_equal(vim.api.nvim_win_get_height(inline_float.win), 4, "expected inline float height to match reserved padding")

vim.api.nvim_win_set_buf(current_win, script_buf)
output.sync_visibility(notebook_buf)
assert_truthy(not vim.api.nvim_win_is_valid(inline_float.win), "expected inline float to close when its buffer is no longer visible")
assert_truthy(output.outputs[notebook_buf][last_cell.id] ~= nil, "expected cached output to remain after hiding the buffer")

vim.api.nvim_win_set_buf(current_win, notebook_buf)
output.set_outputs(notebook_buf, {
  {
    id = cells[1].id,
    kind = "text",
    lines = { "first cell output" },
  },
  {
    id = cells[2].id,
    kind = "text",
    lines = { "second cell output" },
  },
})
vim.fn.winrestview({ topline = cells[2].start_line })
output.render(notebook_buf)

local scrolled_state = output.inline_floats[notebook_buf] and output.inline_floats[notebook_buf][current_win]
assert_truthy(scrolled_state ~= nil, "expected inline floats to re-render after returning to the notebook")
assert_truthy(scrolled_state[cells[1].id] == nil, "expected off-screen first cell float to stay hidden after scrolling")
assert_truthy(scrolled_state[cells[2].id] ~= nil and vim.api.nvim_win_is_valid(scrolled_state[cells[2].id].win), "expected visible cell float to remain rendered")

print("marimo.nvim tests passed")
