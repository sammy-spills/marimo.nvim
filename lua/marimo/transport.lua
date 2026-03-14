local config = require("marimo.config")
local parser = require("marimo.parser")
local util = require("marimo.util")

local M = {
  states = {},
}

local function state_for(bufnr)
  M.states[bufnr] = M.states[bufnr] or {
    base_url = nil,
    base_path = "",
    startup_url = nil,
    access_token = nil,
    server_token = nil,
    session_id = nil,
    tcp = nil,
    connecting = false,
    ready = false,
    resumed = false,
    auto_instantiated = false,
    instantiated = false,
    handshake_complete = false,
    connect_callbacks = {},
    active_run = nil,
    read_buffer = "",
    cell_ids = {},
    cells = {},
  }
  return M.states[bufnr]
end

local function strip_ansi(text)
  return text:gsub("\27%[[0-9;?]*[ -/]*[@-~]", "")
end

local function generate_session_id()
  local alphabet = "abcdefghijklmnopqrstuvwxyz0123456789"
  local chars = {}
  local seed = tostring(vim.uv.hrtime())
  math.randomseed(tonumber(seed:sub(-9)) or os.time())
  for _ = 1, 6 do
    local index = math.random(#alphabet)
    chars[#chars + 1] = alphabet:sub(index, index)
  end
  return "s_" .. table.concat(chars)
end

local function parse_url(url)
  local scheme, hostport, path = url:match("^(https?)://([^/]+)(/.*)$")
  if not scheme then
    scheme, hostport = url:match("^(https?)://([^/]+)$")
    path = "/"
  end
  if not scheme or not hostport then
    return nil
  end

  local host
  local port
  if hostport:match("^%[") then
    host, port = hostport:match("^%[([^%]]+)%]:(%d+)$")
    if not host then
      host = hostport:match("^%[([^%]]+)%]$")
    end
  else
    host, port = hostport:match("^([^:]+):(%d+)$")
    if not host then
      host = hostport
    end
  end

  if not port then
    port = scheme == "https" and 443 or 80
  end

  local base_path = (path or "/"):gsub("%?.*$", "")
  if base_path == "/" then
    base_path = ""
  end
  base_path = base_path:gsub("/+$", "")

  return {
    scheme = scheme,
    host = host,
    port = tonumber(port),
    path = path or "/",
    base_path = base_path,
  }
end

local function resolve_host(host)
  if not host or host == "" then
    return nil
  end
  if host == "localhost" then
    return "127.0.0.1"
  end
  if host:match("^%d+%.%d+%.%d+%.%d+$") then
    return host
  end
  if host:find(":", 1, true) then
    return host
  end

  local ok, addresses = pcall(vim.uv.getaddrinfo, host, nil, { socktype = "stream" })
  if not ok or type(addresses) ~= "table" then
    return host
  end
  for _, entry in ipairs(addresses) do
    if entry and entry.addr then
      return entry.addr
    end
  end
  return host
end

local function make_http_url(state, path)
  local base = state.base_url or ""
  local clean_path = path:gsub("^/", "")
  return ("%s/%s"):format(base, clean_path)
end

local function add_auth_query(url, access_token)
  if not access_token or access_token == "" then
    return url
  end
  local separator = url:find("?", 1, true) and "&" or "?"
  return ("%s%saccess_token=%s"):format(url, separator, access_token)
end

local function curl_command()
  return config.get().commands.curl or "curl"
end

local function run_curl(args, callback)
  local cmd = { curl_command() }
  vim.list_extend(cmd, args)
  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      callback(result)
    end)
  end)
end

local function fetch_server_token(bufnr, callback)
  local state = state_for(bufnr)
  if state.server_token ~= nil then
    callback(true)
    return
  end
  if not util.command_exists(curl_command()) then
    callback(false, "`curl` is required for marimo server execution")
    return
  end
  if not state.startup_url then
    callback(false, "Marimo startup URL is not available")
    return
  end

  run_curl({ "-fsSL", state.startup_url }, function(result)
    if result.code ~= 0 then
      callback(false, result.stderr ~= "" and result.stderr or result.stdout)
      return
    end
    local token = result.stdout:match([["serverToken"%s*:%s*"([^"]*)"]])
    if token == nil then
      callback(false, "Failed to discover Marimo server token")
      return
    end
    state.server_token = token
    callback(true)
  end)
end

local function websocket_frame(payload, opcode)
  local mask = ""
  for _ = 1, 4 do
    mask = mask .. string.char(math.random(0, 255))
  end

  local masked = {}
  for i = 1, #payload do
    local payload_byte = payload:byte(i)
    local mask_byte = mask:byte(((i - 1) % 4) + 1)
    masked[i] = string.char(bit.bxor(payload_byte, mask_byte))
  end
  local masked_payload = table.concat(masked)

  local first = string.char(0x80 + (opcode or 0x1))
  local length = #payload
  local second
  local extra = ""
  if length < 126 then
    second = string.char(0x80 + length)
  elseif length < 65536 then
    second = string.char(0x80 + 126)
    extra = string.char(bit.rshift(length, 8), bit.band(length, 0xFF))
  else
    local bytes = {}
    local value = length
    for i = 8, 1, -1 do
      bytes[i] = string.char(bit.band(value, 0xFF))
      value = math.floor(value / 256)
    end
    second = string.char(0x80 + 127)
    extra = table.concat(bytes)
  end

  return first .. second .. extra .. mask .. masked_payload
end

local function websocket_key()
  local bytes = {}
  for _ = 1, 16 do
    bytes[#bytes + 1] = string.char(math.random(0, 255))
  end
  return vim.base64.encode(table.concat(bytes))
end

local function close_socket(state)
  if state.tcp then
    pcall(state.tcp.read_stop, state.tcp)
    pcall(state.tcp.close, state.tcp)
  end
  state.tcp = nil
  state.handshake_complete = false
  state.read_buffer = ""
  state.ready = false
  state.connecting = false
end

local function flush_connect_callbacks(state, ok, value)
  local callbacks = state.connect_callbacks
  state.connect_callbacks = {}
  for _, callback in ipairs(callbacks) do
    vim.schedule(function()
      callback(ok, value)
    end)
  end
end

local function ordered_touched_ids(state, touched)
  local ordered = {}
  for _, cell_id in ipairs(state.cell_ids or {}) do
    if touched[cell_id] then
      ordered[#ordered + 1] = cell_id
    end
  end
  return ordered
end

local function cancel_completion_timer(active_run)
  if active_run and active_run.completion_timer then
    pcall(active_run.completion_timer.stop, active_run.completion_timer)
    pcall(active_run.completion_timer.close, active_run.completion_timer)
    active_run.completion_timer = nil
  end
end

local function finalize_run(bufnr, ok, err)
  local state = state_for(bufnr)
  local active_run = state.active_run
  if not active_run then
    return
  end
  cancel_completion_timer(active_run)
  state.active_run = nil
  local payload_ok = ok
  local payload_err = err
  local payload = nil
  if ok then
    payload = {
      touched = ordered_touched_ids(state, active_run.touched),
      cells = vim.deepcopy(state.cells),
    }
  end

  vim.schedule(function()
    if not payload_ok then
      active_run.callback(false, payload_err or "Marimo execution failed")
      return
    end

    active_run.callback(true, payload)
  end)
end

local function schedule_run_finalization(bufnr, delay_ms)
  local state = state_for(bufnr)
  local active_run = state.active_run
  if not active_run then
    return
  end
  cancel_completion_timer(active_run)
  local timer = vim.uv.new_timer()
  active_run.completion_timer = timer
  timer:start(delay_ms or 50, 0, function()
    finalize_run(bufnr, true)
  end)
end

local function update_cell_state(state, payload)
  local cell = state.cells[payload.cell_id] or {}
  if payload.output ~= nil then
    cell.output = payload.output
  end
  if payload.console ~= nil then
    if vim.islist(payload.console) then
      cell.console = vim.deepcopy(payload.console)
    else
      local console = cell.console
      if not vim.islist(console) then
        console = console and { console } or {}
      end
      console[#console + 1] = payload.console
      cell.console = console
    end
  end
  if payload.status ~= nil then
    cell.status = payload.status
  end
  if payload.stale_inputs ~= nil then
    cell.stale_inputs = payload.stale_inputs
  end
  state.cells[payload.cell_id] = cell
end

local function handle_message(bufnr, decoded)
  if not decoded or type(decoded) ~= "table" then
    return
  end

  local state = state_for(bufnr)
  local op = decoded.op
  local payload = decoded.data
  if type(payload) ~= "table" then
    payload = {}
  end

  if op == "kernel-ready" then
    state.cell_ids = payload.cell_ids or {}
    state.resumed = payload.resumed == true
    state.auto_instantiated = payload.auto_instantiated == true
    state.instantiated = state.resumed or state.auto_instantiated
    state.ready = true
    flush_connect_callbacks(state, true, state)
    return
  end

  if op == "cell-op" then
    update_cell_state(state, payload)
    if state.active_run then
      state.active_run.touched[payload.cell_id] = true
    end
    return
  end

  if op == "completed-run" then
    schedule_run_finalization(bufnr, 60)
    return
  end

  if op == "interrupted" then
    finalize_run(bufnr, false, "Marimo execution was interrupted")
  end
end

local function parse_frames(buffer)
  local frames = {}
  local index = 1

  while true do
    if #buffer - index + 1 < 2 then
      break
    end

    local byte1 = buffer:byte(index)
    local byte2 = buffer:byte(index + 1)
    local opcode = bit.band(byte1, 0x0F)
    local masked = bit.band(byte2, 0x80) ~= 0
    local payload_length = bit.band(byte2, 0x7F)
    local frame_start = index + 2

    if payload_length == 126 then
      if #buffer - index + 1 < 4 then
        break
      end
      payload_length = buffer:byte(frame_start) * 256 + buffer:byte(frame_start + 1)
      frame_start = frame_start + 2
    elseif payload_length == 127 then
      if #buffer - index + 1 < 10 then
        break
      end
      payload_length = 0
      for i = frame_start, frame_start + 7 do
        payload_length = payload_length * 256 + buffer:byte(i)
      end
      frame_start = frame_start + 8
    end

    local mask_key
    if masked then
      if #buffer - index + 1 < (frame_start - index) + 4 then
        break
      end
      mask_key = buffer:sub(frame_start, frame_start + 3)
      frame_start = frame_start + 4
    end

    if #buffer - index + 1 < (frame_start - index) + payload_length - 1 then
      break
    end

    local payload = buffer:sub(frame_start, frame_start + payload_length - 1)
    if masked and mask_key then
      local unmasked = {}
      for i = 1, #payload do
        unmasked[i] = string.char(bit.bxor(payload:byte(i), mask_key:byte(((i - 1) % 4) + 1)))
      end
      payload = table.concat(unmasked)
    end

    frames[#frames + 1] = {
      opcode = opcode,
      payload = payload,
    }
    index = frame_start + payload_length
  end

  return frames, buffer:sub(index)
end

local function write_socket(state, payload, opcode)
  if not state.tcp then
    return
  end
  state.tcp:write(websocket_frame(payload or "", opcode or 0x1))
end

local function on_disconnect(bufnr, err)
  local state = state_for(bufnr)
  close_socket(state)
  if state.active_run then
    finalize_run(bufnr, false, err or "Marimo websocket disconnected")
  else
    flush_connect_callbacks(state, false, err or "Marimo websocket disconnected")
  end
end

local function connect_websocket(bufnr)
  local state = state_for(bufnr)
  local parsed = parse_url(state.base_url or "")
  if not parsed then
    state.connecting = false
    flush_connect_callbacks(state, false, "Invalid Marimo base URL")
    return
  end

  state.session_id = state.session_id or generate_session_id()

  local tcp = vim.uv.new_tcp()
  state.tcp = tcp
  local connect_host = resolve_host(parsed.host)
  if not connect_host or not parsed.port then
    state.connecting = false
    flush_connect_callbacks(state, false, "Failed to resolve Marimo server address")
    return
  end

  tcp:connect(connect_host, parsed.port, function(err)
    if err then
      on_disconnect(bufnr, err)
      return
    end

    local ws_path = (parsed.base_path ~= "" and parsed.base_path or "") .. "/ws"
    local query = ("session_id=%s"):format(state.session_id)
    if state.access_token and state.access_token ~= "" then
      query = query .. "&access_token=" .. state.access_token
    end

    local key = websocket_key()
    local request = table.concat({
      ("GET %s?%s HTTP/1.1"):format(ws_path, query),
      ("Host: %s:%d"):format(parsed.host, parsed.port),
      "Upgrade: websocket",
      "Connection: Upgrade",
      "Sec-WebSocket-Version: 13",
      "Sec-WebSocket-Key: " .. key,
      "",
      "",
    }, "\r\n")

    tcp:write(request)
    tcp:read_start(function(read_err, chunk)
      if read_err then
        on_disconnect(bufnr, read_err)
        return
      end
      if not chunk then
        on_disconnect(bufnr, "Marimo websocket closed")
        return
      end

      state.read_buffer = state.read_buffer .. chunk
      if not state.handshake_complete then
        local header_end = state.read_buffer:find("\r\n\r\n", 1, true)
        if not header_end then
          return
        end
        local header = state.read_buffer:sub(1, header_end + 3)
        local status_line = header:match("^(.-)\r\n") or header
        if not header:match("^HTTP/1%.1 101") then
          on_disconnect(bufnr, ("Failed to establish Marimo websocket session: %s"):format(status_line))
          return
        end
        state.handshake_complete = true
        state.read_buffer = state.read_buffer:sub(header_end + 4)
      end

      local frames
      frames, state.read_buffer = parse_frames(state.read_buffer)
      for _, frame in ipairs(frames) do
        if frame.opcode == 0x1 then
          local ok, decoded = pcall(vim.json.decode, frame.payload)
          if ok then
            handle_message(bufnr, decoded)
          end
        elseif frame.opcode == 0x8 then
          on_disconnect(bufnr, "Marimo websocket closed")
          return
        elseif frame.opcode == 0x9 then
          write_socket(state, frame.payload, 0xA)
        end
      end
    end)
  end)
end

local function bootstrap_connection(bufnr)
  local state = state_for(bufnr)
  if state.ready then
    flush_connect_callbacks(state, true, state)
    return
  end
  if state.connecting then
    return
  end
  if not state.base_url then
    return
  end

  state.connecting = true
  fetch_server_token(bufnr, function(ok, err)
    if not ok then
      state.connecting = false
      flush_connect_callbacks(state, false, err)
      return
    end
    connect_websocket(bufnr)
  end)
end

function M.observe_server_output(bufnr, data)
  if not data then
    return
  end
  local state = state_for(bufnr)
  for _, raw_line in ipairs(data) do
    if raw_line and raw_line ~= "" then
      local line = strip_ansi(raw_line)
      local url = line:match("https?://%S+")
      if url then
        local parsed = parse_url(url:gsub("%?.*$", ""))
        state.startup_url = url
        state.base_url = url:gsub("%?.*$", ""):gsub("/+$", "")
        state.access_token = url:match("[?&]access_token=([^&]+)")
        state.base_path = parsed and parsed.base_path or ""
        bootstrap_connection(bufnr)
      end
    end
  end
end

function M.ensure_connected(bufnr, callback)
  local state = state_for(bufnr)
  if state.ready then
    callback(true, state)
    return
  end

  state.connect_callbacks[#state.connect_callbacks + 1] = callback
  if not state.base_url then
    return
  end
  bootstrap_connection(bufnr)
end

function M.get_cell_ids(bufnr)
  return vim.deepcopy(state_for(bufnr).cell_ids or {})
end

function M.ensure_instantiated(bufnr, callback)
  local state = state_for(bufnr)
  if not state.ready then
    callback(false, "Marimo session is not ready yet")
    return
  end
  if state.instantiated then
    callback(true)
    return
  end
  if not util.command_exists(curl_command()) then
    callback(false, "`curl` is required for marimo server execution")
    return
  end

  local cells = parser.parse_buffer(bufnr)
  local backend_ids = state.cell_ids or {}
  if #cells ~= #backend_ids then
    callback(false, ("Notebook structure changed: local cells=%d, marimo cells=%d"):format(#cells, #backend_ids))
    return
  end

  local codes = {}
  for index, backend_id in ipairs(backend_ids) do
    codes[backend_id] = cells[index].code
  end

  local url = add_auth_query(make_http_url(state, "/api/kernel/instantiate"), state.access_token)
  local request = vim.json.encode({
    objectIds = {},
    values = {},
    autoRun = false,
    codes = codes,
  })

  run_curl({
    "-fsS",
    "-X",
    "POST",
    "-H",
    "Content-Type: application/json",
    "-H",
    "Marimo-Session-Id: " .. state.session_id,
    "-H",
    "Marimo-Server-Token: " .. (state.server_token or ""),
    "--data-raw",
    request,
    url,
  }, function(result)
    if result.code ~= 0 then
      callback(false, result.stderr ~= "" and result.stderr or result.stdout)
      return
    end
    state.instantiated = true
    callback(true)
  end)
end

function M.send_run(bufnr, cell_ids, codes, callback)
  local state = state_for(bufnr)
  if not state.ready then
    callback(false, "Marimo session is not ready yet")
    return
  end
  if state.active_run then
    callback(false, "A Marimo run is already in progress")
    return
  end
  if not util.command_exists(curl_command()) then
    callback(false, "`curl` is required for marimo server execution")
    return
  end

  local url = add_auth_query(make_http_url(state, "/api/kernel/run"), state.access_token)
  local request = vim.json.encode({
    cellIds = cell_ids,
    codes = codes,
  })

  local touched = {}
  for _, cell_id in ipairs(cell_ids) do
    touched[cell_id] = true
  end
  state.active_run = {
    touched = touched,
    callback = callback,
  }

  run_curl({
    "-fsS",
    "-X",
    "POST",
    "-H",
    "Content-Type: application/json",
    "-H",
    "Marimo-Session-Id: " .. state.session_id,
    "-H",
    "Marimo-Server-Token: " .. (state.server_token or ""),
    "--data-raw",
    request,
    url,
  }, function(result)
    if result.code ~= 0 then
      finalize_run(bufnr, false, result.stderr ~= "" and result.stderr or result.stdout)
    end
  end)
end

function M.reset(bufnr)
  local state = state_for(bufnr)
  close_socket(state)
  if state.active_run then
    finalize_run(bufnr, false, "Marimo session was reset")
  end
  M.states[bufnr] = nil
end

function M._parse_startup_line(line)
  local clean = strip_ansi(line or "")
  local url = clean:match("https?://%S+")
  if not url then
    return nil
  end
  local parsed = parse_url(url:gsub("%?.*$", ""))
  return {
    base_url = url:gsub("%?.*$", ""):gsub("/+$", ""),
    access_token = url:match("[?&]access_token=([^&]+)"),
    startup_url = url,
    base_path = parsed and parsed.base_path or "",
  }
end

function M._handle_message(bufnr, decoded)
  handle_message(bufnr, decoded)
end

function M._snapshot_to_output_items(backend_cell_ids, snapshot, local_by_backend)
  local items = {}
  for _, backend_id in ipairs(backend_cell_ids) do
    local local_id = local_by_backend[backend_id]
    local cell = snapshot[backend_id] or {}
    if local_id then
      local lines = {}
      local kind = "text"

      local console = cell.console
      if console and not vim.islist(console) then
        console = { console }
      end
      for _, output in ipairs(console or {}) do
        if type(output) == "table" and type(output.data) == "string" then
          vim.list_extend(lines, vim.split(output.data, "\n", { plain = true, trimempty = false }))
        end
      end

      if type(cell.output) == "table" then
        if cell.output.mimetype == "application/vnd.marimo+error" and vim.islist(cell.output.data) then
          kind = "error"
          for _, error in ipairs(cell.output.data) do
            if type(error) == "table" then
              lines[#lines + 1] = error.msg or error.description or vim.inspect(error)
            else
              lines[#lines + 1] = vim.inspect(error)
            end
          end
        elseif cell.output.mimetype == "application/vnd.marimo+traceback" and type(cell.output.data) == "string" then
          kind = "error"
          vim.list_extend(lines, vim.split(cell.output.data:gsub("<[^>]+>", ""), "\n", { plain = true, trimempty = false }))
        elseif type(cell.output.data) == "string" and cell.output.mimetype == "text/plain" then
          vim.list_extend(lines, vim.split(cell.output.data, "\n", { plain = true, trimempty = false }))
        elseif cell.output.data ~= nil then
          lines[#lines + 1] = ("<marimo output: %s>"):format(cell.output.mimetype or "unknown")
        end
      end

      while #lines > 0 and lines[#lines] == "" do
        table.remove(lines, #lines)
      end
      if #lines == 0 then
        lines = { "<no output>" }
      end

      items[#items + 1] = {
        id = local_id,
        kind = kind,
        lines = lines,
      }
    end
  end
  return items
end

return M
