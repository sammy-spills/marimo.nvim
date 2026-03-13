local parser = require("marimo.parser")
local util = require("marimo.util")

local M = {
	ns = vim.api.nvim_create_namespace("marimo-cells"),
	header_ns = vim.api.nvim_create_namespace("marimo-cells-header"),
	window_state = {},
}

local function setup_highlights()
	vim.api.nvim_set_hl(0, "MarimoCellHeader", { default = true, link = "Title" })
	vim.api.nvim_set_hl(0, "MarimoCellHeaderMuted", { default = true, link = "Comment" })
	vim.api.nvim_set_hl(0, "MarimoCellHeaderAccent", { default = true, link = "Special" })
end

local function mode_allows_rendering()
	local mode = M._mode_override or vim.api.nvim_get_mode().mode
	local prefix = mode:sub(1, 1)
	return prefix ~= "i"
		and prefix ~= "v"
		and prefix ~= "V"
		and prefix ~= "\22"
		and prefix ~= "R"
		and prefix ~= "s"
		and prefix ~= "S"
		and prefix ~= "t"
end

local function header_chunks(cell)
	local chunks = {
		{ "Cell ", "MarimoCellHeaderMuted" },
		{ tostring(cell.index), "MarimoCellHeaderAccent" },
	}

	if cell.display_name then
		table.insert(chunks, { "  ", "MarimoCellHeaderMuted" })
		table.insert(chunks, { cell.display_name, "MarimoCellHeader" })
	end

	return chunks
end

function M.setup()
	setup_highlights()
end

local function visible_windows(bufnr)
	local wins = {}
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
			table.insert(wins, win)
		end
	end
	return wins
end

function M.configure_windows(bufnr)
	M.window_state[bufnr] = M.window_state[bufnr] or {}

	for _, win in ipairs(visible_windows(bufnr)) do
		if not M.window_state[bufnr][win] then
			M.window_state[bufnr][win] = {
				conceallevel = vim.api.nvim_get_option_value("conceallevel", { win = win }),
				concealcursor = vim.api.nvim_get_option_value("concealcursor", { win = win }),
			}
		end

		vim.api.nvim_set_option_value("conceallevel", 3, { win = win })
		vim.api.nvim_set_option_value("concealcursor", "n", { win = win })
	end
end

function M.restore_windows(bufnr)
	local state = M.window_state[bufnr]
	if not state then
		return
	end

	for win, opts in pairs(state) do
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_set_option_value("conceallevel", opts.conceallevel, { win = win })
			vim.api.nvim_set_option_value("concealcursor", opts.concealcursor, { win = win })
		end
	end

	M.window_state[bufnr] = nil
end

function M.clear(bufnr)
	vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
	vim.api.nvim_buf_clear_namespace(bufnr, M.header_ns, 0, -1)
end

function M.render(bufnr)
	M.configure_windows(bufnr)
	M.clear(bufnr)

	if not mode_allows_rendering() then
		return
	end

	local cells = parser.parse_buffer(bufnr)
	for _, cell in ipairs(cells) do
		local header_row = math.max(cell.start_line - 2, 0)
		vim.api.nvim_buf_set_extmark(bufnr, M.header_ns, header_row, 0, {
			virt_lines = {
				header_chunks(cell),
			},
			virt_lines_above = true,
			priority = 201,
		})
		if cell.start_line < cell.def_end_line then
			vim.api.nvim_buf_set_extmark(bufnr, M.ns, cell.start_line - 1, 0, {
				end_row = cell.def_end_line - 1,
				end_col = 0,
				conceal_lines = "",
				priority = 200,
			})
		end
	end
end

return M
