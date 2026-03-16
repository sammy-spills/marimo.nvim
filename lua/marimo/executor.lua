local parser = require("marimo.parser")
local transport = require("marimo.transport")

local M = {}

local function backend_mapping(bufnr)
  local cells = parser.parse_buffer(bufnr)
  local backend_ids = transport.get_cell_ids(bufnr)
  if #cells ~= #backend_ids then
    return nil, nil, ("Notebook structure changed: local cells=%d, marimo cells=%d"):format(#cells, #backend_ids)
  end

  local local_by_backend = {}
  for index, backend_id in ipairs(backend_ids) do
    local_by_backend[backend_id] = cells[index].id
  end
  return cells, local_by_backend
end

local function convert_result(bufnr, touched_backend_ids, snapshot)
  local _, local_by_backend, err = backend_mapping(bufnr)
  if err then
    return nil, err
  end
  return transport._snapshot_to_output_items(touched_backend_ids, snapshot, local_by_backend)
end

local function execute(bufnr, selected_indexes, callback)
  local cells = parser.parse_buffer(bufnr)
  if #cells == 0 then
    callback(false, "No Marimo cells found")
    return
  end

  transport.ensure_connected(bufnr, function(ok, result)
    if not ok then
      callback(false, result or "Failed to connect to Marimo server")
      return
    end

    transport.ensure_instantiated(bufnr, function(instantiated_ok, instantiate_err)
      if not instantiated_ok then
        callback(false, instantiate_err or "Failed to instantiate Marimo notebook")
        return
      end

      local backend_ids = transport.get_cell_ids(bufnr)
      if #cells ~= #backend_ids then
        callback(false, ("Notebook structure changed: local cells=%d, marimo cells=%d"):format(#cells, #backend_ids))
        return
      end

      local request_backend_ids = {}
      local request_codes = {}
      for _, index in ipairs(selected_indexes) do
        local cell = cells[index]
        if not cell then
          callback(false, "No Marimo cell under cursor")
          return
        end
        request_backend_ids[#request_backend_ids + 1] = backend_ids[index]
        request_codes[#request_codes + 1] = cell.code
      end

      transport.send_run(bufnr, request_backend_ids, request_codes, function(run_ok, payload)
        if not run_ok then
          callback(false, payload)
          return
        end

        local items, convert_err = convert_result(bufnr, payload.touched, payload.cells)
        if not items then
          callback(false, convert_err)
          return
        end
        callback(true, items)
      end)
    end)
  end)
end

function M.run_cell(bufnr, cell_index, callback)
  local cells = parser.parse_buffer(bufnr)
  if not cells[cell_index] then
    callback(false, "No Marimo cell under cursor")
    return
  end
  execute(bufnr, { cell_index }, callback)
end

function M.run_all(bufnr, callback)
  local cells = parser.parse_buffer(bufnr)
  if #cells == 0 then
    callback(false, "No Marimo cells found")
    return
  end
  local indexes = {}
  for index = 1, #cells do
    indexes[#indexes + 1] = index
  end
  execute(bufnr, indexes, callback)
end

return M
