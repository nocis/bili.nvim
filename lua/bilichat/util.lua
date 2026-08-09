local M = {}

function M.trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.is_valid_buffer(buf)
  return buf and buf > 0 and vim.api.nvim_buf_is_valid(buf)
end

function M.is_valid_window(win)
  return win and win > 0 and vim.api.nvim_win_is_valid(win)
end

function M.decode_json(value)
  local ok, result = pcall(vim.json.decode, value)
  if not ok then
    return nil, result
  end
  return result
end

function M.encode_json(value)
  return vim.json.encode(value)
end

function M.parse_room(value)
  local input = M.trim(value)
  if input == "" then
    return nil, "a room URL or numeric room ID is required"
  end

  local id = input:match("live%.bilibili%.com/(%d+)")
    or input:match("room_id=(%d+)")
    or input:match("^(%d+)$")

  id = tonumber(id)
  if not id or id < 1 then
    return nil, "could not find a numeric Bilibili room ID in " .. input
  end

  return {
    input = input,
    requested_id = id,
  }
end

function M.unix_time(value)
  if type(value) == "number" then
    if value > 100000000000 then
      return math.floor(value / 1000)
    end
    return math.floor(value)
  end

  local year, month, day, hour, minute, second = tostring(value or ""):match(
    "^(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d):(%d%d)"
  )
  if year then
    return os.time({
      year = tonumber(year),
      month = tonumber(month),
      day = tonumber(day),
      hour = tonumber(hour),
      min = tonumber(minute),
      sec = tonumber(second),
    })
  end

  return os.time()
end

function M.history_message(item)
  if type(item) ~= "table" then
    return nil
  end

  local uid = tonumber(item.uid or item.mid or 0) or 0
  local text = item.text or item.msg or item.message or ""
  local nickname = item.nickname or item.uname or item.username or tostring(uid)

  return {
    id = item.id,
    uid = uid,
    uname = tostring(nickname),
    text = tostring(text),
    timestamp = M.unix_time(item.timeline or item.timestamp),
    rnd = item.rnd,
    is_self = false,
  }
end

function M.message_key(message)
  if message.id and tostring(message.id) ~= "" then
    return "id:" .. tostring(message.id)
  end

  local parts = {
    tostring(message.uid or 0),
    tostring(message.timestamp or 0),
  }
  local rnd = message.rnd
  if rnd and rnd ~= 0 and tostring(rnd) ~= "" then
    parts[#parts + 1] = tostring(rnd)
  end
  parts[#parts + 1] = tostring(message.text or "")
  return table.concat(parts, "\31")
end

function M.live_message(packet)
  if type(packet) ~= "table" then
    return nil
  end

  local info = packet.info
  if type(info) ~= "table" then
    return nil
  end

  local base = type(info[1]) == "table" and info[1] or {}
  local text = type(info[2]) == "string" and info[2] or ""
  local user = type(info[3]) == "table" and info[3] or {}

  -- A few older servers omit the leading metadata array.
  if text == "" and type(info[1]) == "string" then
    text = info[1]
    user = type(info[2]) == "table" and info[2] or {}
  end

  local message = {
    uid = tonumber(user[1] or 0) or 0,
    uname = tostring(user[2] or "unknown"),
    text = tostring(text),
    timestamp = M.unix_time(base[4]),
    id = nil,
    rnd = base[5],
    is_self = false,
  }

  if message.text == "" then
    return nil
  end
  return message
end

return M
