vim.opt.runtimepath:prepend(vim.fn.fnamemodify(".", ":p"))

local marimo = require("marimo")
local detect = require("marimo.detect")
local parser = require("marimo.parser")
local executor = require("marimo.executor")
local output = require("marimo.output")
local cell_renderer = require("marimo.cells")
local session = require("marimo.session")
local transport = require("marimo.transport")
local util = require("marimo.util")

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

local uv_project_dir = vim.fn.tempname()
vim.fn.mkdir(uv_project_dir, "p")
vim.fn.writefile({
  "[project]",
  'name = "marimo-test"',
  'version = "0.1.0"',
}, uv_project_dir .. "/pyproject.toml")
local uv_project_file = uv_project_dir .. "/nested/notebook.py"
vim.fn.mkdir(vim.fs.dirname(uv_project_file), "p")
vim.fn.writefile({ "import marimo" }, uv_project_file)

local original_command_exists = util.command_exists
util.command_exists = function(cmd)
  return cmd == "uv" or cmd == "uvx"
end

local uv_cmd = session._build_start_command(uv_project_file)
assert_equal(
  table.concat(uv_cmd, " "),
  table.concat({ "uv", "run", "--project", uv_project_dir, "marimo", "edit" }, " "),
  "expected uv projects to start marimo with uv run"
)

local uvx_cmd = session._build_start_command(script)
assert_equal(
  table.concat(uvx_cmd, " "),
  table.concat({ "uvx", "marimo", "edit" }, " "),
  "expected non-uv projects to fall back to uvx"
)

util.command_exists = original_command_exists

local decision = detect.heuristic_decision(notebook_buf)
assert_truthy(decision.strong_match, "expected notebook fixture to be detected as Marimo")

local script_decision = detect.heuristic_decision(script_buf)
assert_truthy(not script_decision.weak_match, "expected plain python fixture to stay disabled")

local cells = parser.parse_buffer(notebook_buf)
assert_equal(#cells, 4, "expected parser to find four cells")
assert_truthy(cells[1].code:match("print%(") ~= nil, "expected parser to sanitize cell body")
assert_equal(cells[1].index, 0, "expected cells to track a zero-based index")
assert_equal(cells[1].display_name, nil, "expected anonymous cell to have no display name")
assert_equal(cells[2].display_name, "named_cell", "expected non-placeholder function names to surface as display names")
assert_truthy(cells[3].code:match("^%s*return") == nil, "expected multiline return to be stripped from execution code")
assert_truthy(cells[3].code:match("final") ~= nil, "expected multiline return cell body to remain executable")
assert_equal(cells[4].body_start_line, cells[4].def_end_line + 1, "expected multiline def header to be skipped before body execution")
assert_truthy(cells[4].code:match("multiline args") ~= nil, "expected multiline def cell body to remain executable")

local original_ensure_connected = transport.ensure_connected
local original_ensure_instantiated = transport.ensure_instantiated
local original_get_cell_ids = transport.get_cell_ids
local original_send_run = transport.send_run

local last_request
local instantiate_calls = 0
transport.ensure_connected = function(bufnr, callback)
  callback(true, { bufnr = bufnr })
end

transport.ensure_instantiated = function(_, callback)
  instantiate_calls = instantiate_calls + 1
  callback(true)
end

transport.get_cell_ids = function()
  return { "cell-a", "cell-b", "cell-c", "cell-d" }
end

transport.send_run = function(_, cell_ids, codes, callback)
  last_request = {
    cell_ids = vim.deepcopy(cell_ids),
    codes = vim.deepcopy(codes),
  }
  callback(true, {
    touched = vim.deepcopy(cell_ids),
    cells = {
      ["cell-a"] = {
        console = {
          {
            channel = "stdout",
            mimetype = "text/plain",
            data = "hello from cell 1",
          },
        },
      },
      ["cell-b"] = {
        console = {
          {
            channel = "stdout",
            mimetype = "text/plain",
            data = "value: 3",
          },
        },
      },
      ["cell-c"] = {
        output = {
          mimetype = "application/vnd.marimo+traceback",
          data = "Traceback (most recent call last):\nboom",
        },
      },
      ["cell-d"] = {
        output = {
          mimetype = "image/png",
          data = {
            url = "memory://image",
          },
        },
      },
    },
  })
end

local completed = false
executor.run_all(notebook_buf, function(ok, result)
  assert_truthy(ok, "expected notebook execution to succeed")
  assert_equal(#result, 4, "expected four output payloads")
  assert_truthy(table.concat(result[1].lines, "\n"):match("hello from cell 1") ~= nil, "missing output for first cell")
  assert_truthy(table.concat(result[2].lines, "\n"):match("value: 3") ~= nil, "missing output for second cell")
  assert_equal(result[3].kind, "error", "expected traceback output to map to an error item")
  assert_truthy(table.concat(result[3].lines, "\n"):match("Traceback") ~= nil, "expected traceback lines for third cell")
  assert_truthy(table.concat(result[4].lines, "\n"):match("<marimo output: image/png>") ~= nil, "expected rich output placeholder for unsupported mimetypes")
  completed = true
end)

vim.wait(10000, function()
  return completed
end, 50)

assert_truthy(completed, "expected executor callback to complete")
assert_equal(instantiate_calls, 1, "expected executor to instantiate before running")
assert_equal(table.concat(last_request.cell_ids, ","), "cell-a,cell-b,cell-c,cell-d", "expected executor to send backend cell ids")
assert_truthy(last_request.codes[1]:match("hello from cell 1") ~= nil, "expected executor to send current buffer code")

local run_one_done = false
executor.run_cell(notebook_buf, 2, function(ok, result)
  assert_truthy(ok, "expected single-cell execution to succeed")
  assert_equal(#result, 1, "expected single-cell execution to return touched cells only")
  assert_equal(result[1].id, cells[2].id, "expected backend cell mapping to preserve local ids")
  run_one_done = true
end)
vim.wait(1000, function()
  return run_one_done
end, 20)
assert_truthy(run_one_done, "expected single-cell executor callback to complete")
assert_equal(table.concat(last_request.cell_ids, ","), "cell-b", "expected single-cell execution to target a single backend cell")

transport.get_cell_ids = function()
  return { "cell-a" }
end
local mismatch_done = false
executor.run_all(notebook_buf, function(ok, message)
  assert_truthy(not ok, "expected mismatch between local and backend cells to fail")
  assert_truthy(message:match("Notebook structure changed") ~= nil, "expected mismatch error message")
  mismatch_done = true
end)
vim.wait(1000, function()
  return mismatch_done
end, 20)
assert_truthy(mismatch_done, "expected mismatch executor callback to complete")

transport.ensure_connected = original_ensure_connected
transport.ensure_instantiated = original_ensure_instantiated
transport.get_cell_ids = original_get_cell_ids
transport.send_run = original_send_run

local parsed_startup = transport._parse_startup_line("\27[32m➜\27[0m  URL: http://127.0.0.1:2718/app?access_token=abc123")
assert_equal(parsed_startup.base_url, "http://127.0.0.1:2718/app", "expected startup line parsing to discover base url")
assert_equal(parsed_startup.access_token, "abc123", "expected startup line parsing to discover auth token")

local marimo_error_items = transport._snapshot_to_output_items(
  { "cell-a" },
  {
    ["cell-a"] = {
      output = {
        mimetype = "application/vnd.marimo+error",
        data = {
          { msg = "something went wrong" },
        },
      },
    },
  },
  {
    ["cell-a"] = 1,
  }
)
assert_equal(marimo_error_items[1].kind, "error", "expected marimo errors to map to error output items")
assert_truthy(marimo_error_items[1].lines[1]:match("something went wrong") ~= nil, "expected marimo error text to be preserved")

transport.reset(notebook_buf)
assert_truthy(transport.states[notebook_buf] == nil, "expected transport reset to clear cached session state")
transport.states[notebook_buf] = {
  connect_callbacks = {},
  cells = {},
  cell_ids = {},
}
transport._handle_message(notebook_buf, {
  op = "cell-op",
  data = {
    cell_id = "cell-a",
    status = "running",
    console = {},
  },
})
transport._handle_message(notebook_buf, {
  op = "cell-op",
  data = {
    cell_id = "cell-a",
    console = {
      channel = "stdout",
      mimetype = "text/plain",
      data = "hello ",
    },
  },
})
transport._handle_message(notebook_buf, {
  op = "cell-op",
  data = {
    cell_id = "cell-a",
    console = {
      channel = "stdout",
      mimetype = "text/plain",
      data = "from live message",
    },
  },
})
assert_equal(
  #transport.states[notebook_buf].cells["cell-a"].console,
  2,
  "expected live console outputs to be accumulated after a running reset"
)
assert_equal(
  transport.states[notebook_buf].cells["cell-a"].console[1].data,
  "hello ",
  "expected first streamed console chunk to be preserved"
)
assert_equal(
  transport.states[notebook_buf].cells["cell-a"].console[2].data,
  "from live message",
  "expected subsequent streamed console chunks to be appended"
)
transport.reset(notebook_buf)

vim.api.nvim_set_current_buf(notebook_buf)
marimo.enable(notebook_buf)
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
if #extmarks > 0 then
  assert_equal(#extmarks[#extmarks][4].virt_lines, 6, "expected reserved preview space to include inline float borders")

  local header_marks = vim.api.nvim_buf_get_extmarks(notebook_buf, cell_renderer.ns, 0, -1, { details = true })
  assert_equal(#header_marks, #cells, "expected one conceal mark per cell with multi-line headers")
  assert_equal(header_marks[1][2], cells[1].start_line - 1, "expected concealed header marks to begin at the @app.cell line")
  assert_equal(header_marks[2][4].conceal_lines, "", "expected rendered cell headers to conceal remaining decorator and def lines")

  local visible_header_marks = vim.api.nvim_buf_get_extmarks(notebook_buf, cell_renderer.header_ns, 0, -1, { details = true })
  assert_equal(#visible_header_marks, #cells, "expected one visible header mark per cell")
  assert_equal(visible_header_marks[1][2], cells[1].body_start_line - 1, "expected visible header marks to anchor above the first visible body line")
  assert_equal(visible_header_marks[2][2], cells[2].body_start_line - 1, "expected later visible header marks to anchor above each cell's body")
  assert_equal(visible_header_marks[1][4].virt_lines[1][1][1], "Cell ", "expected unnamed cells to render a fallback cell label")
  assert_equal(visible_header_marks[1][4].virt_lines[1][2][1], "0", "expected unnamed cell labels to use a zero-based index")
  assert_equal(visible_header_marks[2][4].virt_lines[1][2][1], "1", "expected named cell labels to use a zero-based index")
  assert_equal(visible_header_marks[2][4].virt_lines[1][4][1], "named_cell", "expected cell header to include display name")
  assert_equal(visible_header_marks[1][4].virt_lines_above, true, "expected visible cell headers to render above the concealed cell header")

  cell_renderer._mode_override = "i"
  cell_renderer.render(notebook_buf)
  assert_equal(#vim.api.nvim_buf_get_extmarks(notebook_buf, cell_renderer.ns, 0, -1, {}), 0, "expected concealed header marks to clear in insert mode")
  assert_equal(#vim.api.nvim_buf_get_extmarks(notebook_buf, cell_renderer.header_ns, 0, -1, {}), 0, "expected visible cell headers to clear in insert mode")

  cell_renderer._mode_override = "n"
  cell_renderer.render(notebook_buf)
  assert_equal(#vim.api.nvim_buf_get_extmarks(notebook_buf, cell_renderer.ns, 0, -1, {}), #cells, "expected concealed header marks to restore in normal mode")
  assert_equal(#vim.api.nvim_buf_get_extmarks(notebook_buf, cell_renderer.header_ns, 0, -1, {}), #cells, "expected visible cell headers to restore in normal mode")
  cell_renderer._mode_override = nil

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
end

print("marimo.nvim tests passed")
