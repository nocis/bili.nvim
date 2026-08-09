local util = require("bilichat.util")

local uv = vim.uv or vim.loop
local M = {}
local Client = {}
Client.__index = Client

local ffi
local zlib
local ffi_ok, ffi_module = pcall(require, "ffi")
if ffi_ok then
  ffi = ffi_module
  pcall(ffi.cdef, [[
    int uncompress(unsigned char *dest, unsigned long *dest_len,
      const unsigned char *source, unsigned long source_len);
  ]])
  for _, library in ipairs({ "z", "libz.so.1", "libz.dylib", "zlib1.dll" }) do
    local ok, handle = pcall(ffi.load, library)
    if ok then
      zlib = handle
      break
    end
  end
end

local function u16(value)
  return string.char(
    math.floor(value / 256) % 256,
    value % 256
  )
end

local function u32(value)
  return string.char(
    math.floor(value / 16777216) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 256) % 256,
    value % 256
  )
end

local function read_u16(value, offset)
  local first, second = value:byte(offset, offset + 1)
  return first * 256 + second
end

local function read_u32(value, offset)
  local first, second, third, fourth = value:byte(offset, offset + 3)
  return first * 16777216 + second * 65536 + third * 256 + fourth
end

local function packet(version, operation, body)
  local header_length = 16
  local total_length = header_length + #body
  return u32(total_length) .. u16(header_length) .. u16(version) .. u32(operation) .. u32(1) .. body
end

local function inflate_zlib(data)
  if not zlib then
    return nil, "system zlib is unavailable"
  end

  local source = ffi.new("unsigned char[?]", #data)
  ffi.copy(source, data, #data)
  local size = math.max(#data * 4, 65536)
  for _ = 1, 8 do
    local output = ffi.new("unsigned char[?]", size)
    local output_length = ffi.new("unsigned long[1]", size)
    local result = zlib.uncompress(output, output_length, source, #data)
    if result == 0 then
      return ffi.string(output, tonumber(output_length[0]))
    end
    if result ~= -5 then
      return nil, "zlib inflate failed with code " .. tostring(result)
    end
    size = size * 2
  end
  return nil, "zlib inflate output is too large"
end

local function is_ip(str)
  if type(str) ~= "string" then
    return false
  end
  local a, b, c, d = str:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then
    return false
  end
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  return a and b and c and d
    and a >= 0 and a <= 255
    and b >= 0 and b <= 255
    and c >= 0 and c <= 255
    and d >= 0 and d <= 255
end

local function schedule(callback, ...)
  if not callback then
    return
  end
  local arguments = { ... }
  vim.schedule(function()
    callback(unpack(arguments))
  end)
end

function Client.new(options)
  return setmetatable({
    room_id = options.room_id,
    uid = options.uid or 0,
    buvid = options.buvid,
    token = options.token,
    hosts = options.hosts or {},
    protover = options.protover or 1,
    heartbeat_interval = options.heartbeat_interval or 30,
    on_event = options.on_event,
    on_close = options.on_close,
    buffer = "",
    host_index = 0,
    host_errors = {},
    running = false,
    closed = false,
    close_notified = false,
    tcp = nil,
    heartbeat_timer = nil,
  }, Client)
end

function Client:_notify_close(err)
  if self.close_notified then
    return
  end
  self.close_notified = true
  schedule(self.on_close, err)
end

function Client:_close_tcp()
  if not self.tcp then
    return
  end
  local tcp = self.tcp
  self.tcp = nil
  pcall(tcp.read_stop, tcp)
  if not tcp:is_closing() then
    tcp:close()
  end
end

function Client:_stop_timer()
  if self.heartbeat_timer then
    pcall(self.heartbeat_timer.stop, self.heartbeat_timer)
    pcall(self.heartbeat_timer.close, self.heartbeat_timer)
    self.heartbeat_timer = nil
  end
end

function Client:_fail(err)
  if self.closed then
    return
  end
  self.closed = true
  self.running = false

  if err and #self.hosts > 0 then
    local parts = {}
    for i, host in ipairs(self.hosts) do
      parts[#parts + 1] = string.format(
        "%s:%s => %s", host.host, host.port or 2243, self.host_errors[i] or "?"
      )
    end
    local msg = err.message or "connection failed"
    err.message = msg .. " | " .. table.concat(parts, ", ")
  end

  self:_stop_timer()
  self:_close_tcp()
  self:_notify_close(err or { message = "danmaku connection closed" })
end

function Client:_write(data)
  if not self.tcp or self.closed then
    return
  end
  local tcp = self.tcp
  local ok, err = pcall(tcp.write, tcp, data, function(write_error)
    if write_error then
      self:_fail({ message = tostring(write_error) })
    end
  end)
  if not ok then
    self:_fail({ message = tostring(err) })
  end
end

function Client:_send_auth()
  local body = vim.json.encode({
    uid = self.uid,
    roomid = self.room_id,
    protover = self.protover,
    platform = "web",
    type = 2,
    key = self.token,
    buvid = self.buvid,
  })
  self:_write(packet(1, 7, body))
end

function Client:_send_heartbeat()
  self:_write(packet(1, 2, "[object Object]"))
end

function Client:_start_heartbeat()
  self:_stop_timer()
  self.heartbeat_timer = uv.new_timer()
  self.heartbeat_timer:start(
    self.heartbeat_interval * 1000,
    self.heartbeat_interval * 1000,
    function()
      if self.running and not self.closed then
        self:_send_heartbeat()
      end
    end
  )
end

function Client:_handle_body(version, operation, body)
  if operation == 3 then
    local popularity = #body >= 4 and read_u32(body, 1) or 0
    schedule(self.on_event, "heartbeat", popularity)
    return
  end

  if operation == 8 then
    local response = util.decode_json(body)
    if response and tonumber(response.code or 0) == 0 then
      self:_start_heartbeat()
      schedule(self.on_event, "ready", response)
    else
      self:_fail({
        code = response and response.code or -1,
        message = response and (response.message or "danmaku authentication failed") or "invalid danmaku authentication response",
      })
    end
    return
  end

  if operation ~= 5 then
    return
  end

  if version == 2 then
    local inflated, inflate_error = inflate_zlib(body)
    if not inflated then
      schedule(self.on_event, "compressed", inflate_error)
      self:_fail({ message = inflate_error })
      return
    end
    self.buffer = inflated .. self.buffer
    self:_consume()
    return
  end

  if version == 3 then
    schedule(self.on_event, "compressed", version)
    self:_fail({ message = "Bilibili sent compressed danmaku data" })
    return
  end

  local response, decode_error = util.decode_json(body)
  if not response then
    schedule(self.on_event, "decode_error", decode_error)
    return
  end

  local command = tostring(response.cmd or "")
  if command:match("^DANMU_MSG") then
    local message = util.live_message(response)
    if message then
      schedule(self.on_event, "message", message)
    end
  end
end

function Client:_consume()
  while #self.buffer >= 16 do
    local total_length = read_u32(self.buffer, 1)
    local header_length = read_u16(self.buffer, 5)
    if total_length < header_length or header_length < 16 or total_length > 16 * 1024 * 1024 then
      self:_fail({ message = "invalid danmaku packet length" })
      return
    end
    if #self.buffer < total_length then
      return
    end

    local version = read_u16(self.buffer, 7)
    local operation = read_u32(self.buffer, 9)
    local body = self.buffer:sub(header_length + 1, total_length)
    self.buffer = self.buffer:sub(total_length + 1)
    self:_handle_body(version, operation, body)
    if self.closed then
      return
    end
  end
end

function Client:_connect_to_ip(ip, port)
  local tcp = uv.new_tcp()
  self.tcp = tcp
  local ok_connect, connect_result = pcall(tcp.connect, tcp, ip, port, function(connect_error)
    if self.closed then
      return
    end
    if connect_error then
      self.host_errors[self.host_index] = tostring(connect_error)
      self:_close_tcp()
      self:_connect_host()
      return
    end

    self.running = true
    local read_ok, read_error = pcall(tcp.read_start, tcp, function(read_error_inner, data)
      if read_error_inner then
        self:_fail({ message = tostring(read_error_inner) })
        return
      end
      if not data then
        self:_fail({ message = "danmaku server closed the connection" })
        return
      end
      self.buffer = self.buffer .. data
      self:_consume()
    end)
    if not read_ok then
      self:_fail({ message = tostring(read_error) })
      return
    end
    self:_send_auth()
  end)
  if not ok_connect then
    self.host_errors[self.host_index] = tostring(connect_result)
    self:_close_tcp()
    self:_connect_host()
  elseif connect_result == false then
    self.host_errors[self.host_index] = "rejected"
    self:_close_tcp()
    self:_connect_host()
  end
end

function Client:_connect_host()
  if self.closed then
    return
  end

  self.host_index = self.host_index + 1
  local host = self.hosts[self.host_index]
  if not host then
    self:_fail({ message = "all Bilibili danmaku hosts failed" })
    return
  end

  if is_ip(host.host) then
    self:_connect_to_ip(host.host, host.port or 2243)
    return
  end

  uv.getaddrinfo(host.host, tostring(host.port or 2243), { family = "inet" }, function(resolve_err, addresses)
    if self.closed then
      return
    end
    if resolve_err or not addresses or #addresses == 0 then
      self.host_errors[self.host_index] = tostring(resolve_err or "no addresses")
      self:_close_tcp()
      self:_connect_host()
      return
    end
    self:_connect_to_ip(addresses[1].addr, host.port or 2243)
  end)
end

function Client:start()
  if self.closed or self.running then
    return
  end
  if #self.hosts == 0 then
    self:_fail({ message = "Bilibili returned no danmaku hosts" })
    return
  end
  self.host_index = 0
  self.host_errors = {}
  self.buffer = ""
  self:_connect_host()
end

function Client:close()
  if self.closed then
    return
  end
  self.closed = true
  self.running = false
  self:_stop_timer()
  self:_close_tcp()
end

function M.new(options)
  return Client.new(options)
end

return M
