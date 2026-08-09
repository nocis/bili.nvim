local M = {}

M.defaults = {
  width = 42,
  poll_interval = 3,
  idle_timeout = 30 * 60,
  max_messages = 500,
  transport = "auto",
  curl_timeout = 20,
  user_agent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36",
  danmaku_protover = 2,
  danmaku_heartbeat = 30,
  send = {
    color = 16777215,
    mode = 1,
    room_type = 0,
    jumpfrom = 84001,
    fontsize = 25,
  },
}

local function merge_into(target, source)
  for key, value in pairs(source or {}) do
    if type(value) == "table" and type(target[key]) == "table" then
      merge_into(target[key], value)
    else
      target[key] = value
    end
  end
end

function M.setup(options)
  local result = vim.deepcopy(M.defaults)
  merge_into(result, options or {})
  return result
end

return M
