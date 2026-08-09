local api = require("bilichat.api")
local util = require("bilichat.util")

local uv = vim.uv or vim.loop
local M = {}
local Poll = {}
Poll.__index = Poll

function Poll.new(options)
  return setmetatable({
    room_id = options.room_id,
    identity = options.identity,
    interval = options.interval or 3,
    on_messages = options.on_messages,
    on_error = options.on_error,
    seen = {},
    seen_order = {},
    max_seen = options.max_seen or 2000,
    timer = nil,
    running = false,
    busy = false,
  }, Poll)
end

function Poll:_remember(key)
  if self.seen[key] then
    return false
  end
  self.seen[key] = true
  self.seen_order[#self.seen_order + 1] = key
  while #self.seen_order > self.max_seen do
    local oldest = table.remove(self.seen_order, 1)
    self.seen[oldest] = nil
  end
  return true
end

function Poll:seed(messages)
  for _, message in ipairs(messages or {}) do
    self:_remember(util.message_key(message))
  end
end

function Poll:fetch()
  if not self.running or self.busy then
    return
  end
  self.busy = true
  api.history(self.room_id, self.identity, function(err, response)
    self.busy = false
    if not self.running then
      return
    end
    if err then
      if self.on_error then
        self.on_error(err)
      end
      return
    end

    local fresh = {}
    for _, message in ipairs(api.history_items(response)) do
      local key = util.message_key(message)
      if self:_remember(key) then
        fresh[#fresh + 1] = message
      end
    end
    if #fresh > 0 and self.on_messages then
      self.on_messages(fresh)
    end
  end)
end

function Poll:start()
  if self.running then
    return
  end
  self.running = true
  self.timer = uv.new_timer()
  self.timer:start(self.interval * 1000, self.interval * 1000, function()
    self:fetch()
  end)
  self:fetch()
end

function Poll:stop()
  self.running = false
  self.busy = false
  if self.timer then
    pcall(self.timer.stop, self.timer)
    pcall(self.timer.close, self.timer)
    self.timer = nil
  end
end

function M.new(options)
  return Poll.new(options)
end

return M
