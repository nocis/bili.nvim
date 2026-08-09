local api = require("bilichat.api")
local auth = require("bilichat.auth")
local config = require("bilichat.config")
local danmaku = require("bilichat.danmaku")
local poll = require("bilichat.poll")
local util = require("bilichat.util")

local uv = vim.uv or vim.loop
local M = {}
local state = {
  configured = false,
  options = nil,
  sessions = {},
  order = {},
  active_id = nil,
  next_id = 0,
  last_activity = os.time(),
  idle_timer = nil,
  ui = nil,
}

local function notify(message, level)
  vim.notify("BiliChat: " .. message, level or vim.log.levels.INFO)
end

local function session_title(session)
  local room = session.short_id or session.requested_id
  return string.format("Room %s @ %s", tostring(room), auth.label(session.identity))
end

local function session_status(session)
  local status = session.status or "starting"
  if session.popularity and session.popularity > 0 then
    return string.format("%s | %d viewers", status, session.popularity)
  end
  return status
end

local function set_status(session, status)
  session.status = status
  if state.ui then
    state.ui.on_session_updated(session)
  end
end

local function stop_reconnect_timer(session)
  if session.reconnect_timer then
    pcall(session.reconnect_timer.stop, session.reconnect_timer)
    pcall(session.reconnect_timer.close, session.reconnect_timer)
    session.reconnect_timer = nil
  end
end

local function stop_transport(session)
  session.transport_token = (session.transport_token or 0) + 1
  stop_reconnect_timer(session)
  if session.transport then
    if session.transport.close then
      session.transport:close()
    elseif session.transport.stop then
      session.transport:stop()
    end
    session.transport = nil
  end
end

local function sort_initial(messages)
  table.sort(messages, function(left, right)
    return (left.timestamp or 0) < (right.timestamp or 0)
  end)
end

local function receive(session, message, initial)
  if not session or session.closed or not message then
    return
  end

  if not initial and not session.history_loaded then
    session.pending_messages[#session.pending_messages + 1] = message
    return
  end

  local key = util.message_key(message)
  if session.seen[key] then
    return
  end
  session.seen[key] = true
  if session.identity and message.uid == session.identity.uid then
    message.is_self = true
  end

  session.messages[#session.messages + 1] = message
  while #session.messages > state.options.max_messages do
    local removed = table.remove(session.messages, 1)
    session.seen[util.message_key(removed)] = nil
  end

  local visible = state.ui and state.ui.is_session_visible(session)
  if not initial and not visible then
    session.unread = session.unread + 1
  end
  if state.ui then
    state.ui.on_session_message(session, message)
    state.ui.on_session_updated(session)
  end
end

local function receive_many(session, messages, initial)
  if initial then
    sort_initial(messages)
  end
  for _, message in ipairs(messages or {}) do
    receive(session, message, initial)
  end
end

local function start_poll(session, reason, revision)
  revision = revision or session.identity_revision
  if session.closed or revision ~= session.identity_revision then
    return
  end
  stop_transport(session)
  session.transport_kind = "poll"
  session.poll_error_reported = false
  set_status(session, reason and "polling (" .. reason .. ")" or "polling")

  local transport = poll.new({
    room_id = session.room_id,
    identity = session.identity,
    interval = state.options.poll_interval,
    max_seen = state.options.max_messages * 4,
    on_messages = function(messages)
      if session.closed or revision ~= session.identity_revision then
        return
      end
      session.poll_error_reported = false
      set_status(session, "polling")
      receive_many(session, messages, false)
    end,
    on_error = function(err)
      if session.closed or revision ~= session.identity_revision then
        return
      end
      if not session.poll_error_reported then
        session.poll_error_reported = true
        notify("history polling failed: " .. api.error_text(err), vim.log.levels.WARN)
      end
      set_status(session, "polling error")
    end,
  })
  transport:seed(session.messages)
  session.transport = transport
  transport:start()
end

local function start_live_transport(session, revision)
  revision = revision or session.identity_revision
  if session.closed or revision ~= session.identity_revision or not session.room_id then
    return
  end

  if not session.identity or state.options.transport == "poll" then
    start_poll(session, session.identity and nil or "anonymous", revision)
    return
  end

  set_status(session, "authorizing live stream")
  local identity = session.identity
  api.danmu_info(session.room_id, identity, function(err, response)
    if session.closed or revision ~= session.identity_revision then
      return
    end
    if err then
      notify("live stream authorization failed: " .. api.error_text(err), vim.log.levels.WARN)
      start_poll(session, "authorization fallback", revision)
      return
    end

    local data = response.data or {}
    if not data.token or not data.host_list or #data.host_list == 0 then
      start_poll(session, "no live stream host", revision)
      return
    end
    M._start_tcp(session, data, revision)
  end)
end

local function schedule_tcp_retry(session, err, revision)
  revision = revision or session.identity_revision
  if session.closed or revision ~= session.identity_revision or not session.identity then
    return
  end

  session.reconnect_attempt = session.reconnect_attempt + 1
  if session.reconnect_attempt > 3 then
    notify("live stream unavailable for " .. session_title(session) .. "; using history polling", vim.log.levels.WARN)
    start_poll(session, "TCP fallback", revision)
    return
  end

  local delay = 2 ^ (session.reconnect_attempt - 1)
  set_status(session, string.format("reconnecting in %ds", delay))
  stop_reconnect_timer(session)
  session.reconnect_timer = uv.new_timer()
  session.reconnect_timer:start(delay * 1000, 0, function()
    stop_reconnect_timer(session)
    if session.closed or revision ~= session.identity_revision or not session.identity then
      return
    end
    local identity = session.identity
    api.danmu_info(session.room_id, identity, function(info_error, response)
      if session.closed or revision ~= session.identity_revision then
        return
      end
      if info_error then
        schedule_tcp_retry(session, info_error, revision)
        return
      end
      local data = response.data or {}
      local hosts = data.host_list or {}
      if #hosts == 0 then
        schedule_tcp_retry(session, { message = "Bilibili returned no danmaku hosts" }, revision)
        return
      end
      M._start_tcp(session, data, revision)
    end)
  end)
end

function M._start_tcp(session, data, revision)
  revision = revision or session.identity_revision
  if session.closed or revision ~= session.identity_revision or not session.identity then
    return
  end
  stop_transport(session)
  session.transport_kind = "tcp"
  set_status(session, "connecting")

  local token = session.transport_token
  local identity = session.identity
  local ready = false
  local client = danmaku.new({
    room_id = session.room_id,
    uid = identity.uid,
    buvid = identity.cookies and identity.cookies.buvid3,
    token = data.token,
    hosts = data.host_list or {},
    protover = state.options.danmaku_protover,
    heartbeat_interval = state.options.danmaku_heartbeat,
    on_event = function(kind, value)
      if session.closed or revision ~= session.identity_revision or token ~= session.transport_token then
        return
      end
      if kind == "ready" then
        ready = true
        session.reconnect_attempt = 0
        set_status(session, "live")
      elseif kind == "heartbeat" then
        session.popularity = tonumber(value) or 0
        if state.ui then
          state.ui.on_session_updated(session)
        end
      elseif kind == "message" then
        receive(session, value)
      elseif kind == "compressed" then
        start_poll(session, "compressed stream")
      elseif kind == "decode_error" then
        set_status(session, "live decode warning")
      end
    end,
    on_close = function(err)
      if session.closed or revision ~= session.identity_revision or token ~= session.transport_token then
        return
      end
      session.transport = nil
      if not ready then
        local detail = err and err.message and (": " .. tostring(err.message)) or ""
        notify("live stream authentication closed" .. detail .. "; using history polling", vim.log.levels.WARN)
        start_poll(session, "TCP fallback", revision)
        return
      end
      schedule_tcp_retry(session, err, revision)
    end,
  })
  session.transport = client
  client:start()
end

local function start_room_transports(session)
  local revision = session.identity_revision
  api.history(session.room_id, session.identity, function(err, response)
    if session.closed then
      return
    end
    if err then
      notify("could not load chat history: " .. api.error_text(err), vim.log.levels.WARN)
    else
      receive_many(session, api.history_items(response), true)
    end
    session.history_loaded = true
    local pending = session.pending_messages
    session.pending_messages = {}
    receive_many(session, pending, false)
    if session.transport and session.transport.seed then
      session.transport:seed(session.messages)
    end
  end)
  start_live_transport(session, revision)
end

local function begin_session(session)
  set_status(session, "resolving room")
  api.room_init(session.requested_id, function(err, response)
    if session.closed then
      return
    end
    if err then
      set_status(session, "room error")
      notify("room lookup failed: " .. api.error_text(err), vim.log.levels.ERROR)
      return
    end

    local data = response.data or {}
    session.room_id = tonumber(data.room_id or session.requested_id)
    session.short_id = tonumber(data.short_id or session.requested_id) or session.requested_id
    session.title = session_title(session)
    if state.ui then
      state.ui.on_session_updated(session)
    end
    start_room_transports(session)
  end)
end

function M.setup(options)
  if state.configured then
    return
  end
  state.configured = true
  state.options = options or config.setup()
  state.idle_timer = uv.new_timer()
  state.idle_timer:start(60000, 60000, function()
    vim.schedule(function()
      if not state.ui or state.ui.is_visible() then
        return
      end
      if #state.order == 0 then
        return
      end
      if os.time() - state.last_activity >= state.options.idle_timeout then
        M.kill_all("idle timeout")
        notify("idle timeout reached; sessions and their in-memory cookies were cleared", vim.log.levels.WARN)
      end
    end)
  end)
end

function M.attach_ui(ui)
  state.ui = ui
end

function M.touch()
  state.last_activity = os.time()
end

function M.sessions()
  local result = {}
  for _, id in ipairs(state.order) do
    if state.sessions[id] then
      result[#result + 1] = state.sessions[id]
    end
  end
  return result
end

function M.get(id)
  return state.sessions[id]
end

function M.active()
  return state.sessions[state.active_id]
end

function M.focus(id)
  if not state.sessions[id] then
    return false
  end
  state.active_id = id
  state.sessions[id].unread = 0
  M.touch()
  if state.ui then
    state.ui.on_active_changed(state.sessions[id])
  end
  return true
end

function M.next(delta)
  local sessions = M.sessions()
  if #sessions == 0 then
    notify("no active sessions", vim.log.levels.WARN)
    return
  end

  local current = 1
  for index, session in ipairs(sessions) do
    if session.id == state.active_id then
      current = index
      break
    end
  end
  local target = ((current - 1 + delta) % #sessions) + 1
  M.focus(sessions[target].id)
  if state.ui then
    state.ui.show()
  end
end

function M.open(room_input, identity)
  local room, parse_error = util.parse_room(room_input)
  if not room then
    notify(parse_error, vim.log.levels.ERROR)
    return
  end

  state.next_id = state.next_id + 1
  local session = {
    id = "session-" .. tostring(state.next_id),
    requested_id = room.requested_id,
    short_id = room.requested_id,
    identity = identity,
    title = string.format("Room %s @ %s", tostring(room.requested_id), auth.label(identity)),
    status = "starting",
    messages = {},
    seen = {},
    history_loaded = false,
    pending_messages = {},
    unread = 0,
    closed = false,
    identity_revision = 0,
    auth_request = 0,
    reconnect_attempt = 0,
    transport_token = 0,
  }
  state.sessions[session.id] = session
  state.order[#state.order + 1] = session.id
  state.active_id = session.id
  M.touch()

  if state.ui then
    state.ui.on_session_created(session)
    state.ui.show()
  end
  begin_session(session)
  return session
end

local function set_identity(session, identity)
  if session.closed then
    return
  end

  session.identity_revision = session.identity_revision + 1
  stop_transport(session)
  auth.scrub(session.identity)
  session.identity = identity
  session.title = session_title(session)
  session.reconnect_attempt = 0
  session.popularity = nil
  session.poll_error_reported = false
  if state.ui then
    state.ui.on_session_updated(session)
  end
  start_live_transport(session, session.identity_revision)
end

function M.reauth()
  local session = M.active()
  if not session then
    notify("no active session", vim.log.levels.WARN)
    return
  end
  if not session.room_id then
    notify("room is still resolving", vim.log.levels.WARN)
    return
  end

  M.touch()
  session.auth_request = session.auth_request + 1
  local request = session.auth_request
  auth.prompt({
    prompt = "BiliChat Cookie for current session: ",
  }, function(err, identity)
    if session.closed or session.auth_request ~= request then
      return
    end
    if err then
      if not err.cancelled then
        notify("authentication failed: " .. api.error_text(err), vim.log.levels.ERROR)
      end
      return
    end
    set_identity(session, identity)
    notify("session authenticated as " .. auth.label(identity), vim.log.levels.INFO)
  end)
end

function M.logout()
  local session = M.active()
  if not session then
    notify("no active session", vim.log.levels.WARN)
    return
  end

  M.touch()
  session.auth_request = session.auth_request + 1
  set_identity(session, nil)
  notify("current session is now anonymous", vim.log.levels.INFO)
end

function M.open_command(args)
  M.touch()
  local value = util.trim(args)
  local function ask_cookie(room_input)
    auth.prompt({
      allow_anonymous = true,
      prompt = "Bilibili Cookie (Enter for anonymous): ",
    }, function(err, identity)
      if err then
        notify("session open failed: " .. api.error_text(err), vim.log.levels.ERROR)
        return
      end
      M.open(room_input, identity)
    end)
  end

  if value == "" then
    vim.ui.input({ prompt = "Bilibili room URL or ID: " }, function(input)
      if input and util.trim(input) ~= "" then
        ask_cookie(input)
      end
    end)
  else
    ask_cookie(value)
  end
end

function M.pick()
  M.touch()
  local sessions = M.sessions()
  if #sessions == 0 then
    notify("no active sessions; use :BiliChatOpen", vim.log.levels.WARN)
    return
  end

  vim.ui.select(sessions, {
    prompt = "BiliChat sessions",
    format_item = function(session)
      local unread = session.unread > 0 and string.format(" +%d", session.unread) or ""
      return string.format("%s [%s]%s", session.title, session_status(session), unread)
    end,
  }, function(choice)
    if choice then
      M.focus(choice.id)
      if state.ui then
        state.ui.show()
      end
    end
  end)
end

function M.kill(id)
  local session = state.sessions[id]
  if not session then
    return
  end
  session.closed = true
  stop_transport(session)
  auth.scrub(session.identity)
  session.identity = nil
  if state.ui then
    state.ui.on_session_removed(session)
  end
  state.sessions[id] = nil
  for index, session_id in ipairs(state.order) do
    if session_id == id then
      table.remove(state.order, index)
      break
    end
  end

  if state.active_id == id then
    state.active_id = state.order[1]
    if state.active_id then
      M.focus(state.active_id)
    elseif state.ui then
      state.ui.hide()
    end
  end
  M.touch()
end

function M.kill_all(reason)
  local ids = vim.deepcopy(state.order)
  for _, id in ipairs(ids) do
    M.kill(id)
  end
  if state.ui then
    state.ui.hide()
  end
  M.touch()
  if reason and reason ~= "idle timeout" then
    notify(reason, vim.log.levels.INFO)
  end
end

function M.kill_command(args)
  local value = util.trim(args):lower()
  if value == "all" then
    M.kill_all("all sessions stopped")
    return
  end
  local session = M.active()
  if not session then
    notify("no active session", vim.log.levels.WARN)
    return
  end
  M.kill(session.id)
end

function M.send(message)
  local session = M.active()
  message = util.trim(message)
  if not session then
    notify("no active session", vim.log.levels.WARN)
    return false
  end
  if not session.identity then
    notify("this anonymous session has no cookie; use :BiliChatAuth", vim.log.levels.WARN)
    return false
  end
  if message == "" then
    return false
  end
  if not session.room_id then
    notify("room is still resolving", vim.log.levels.WARN)
    return false
  end

  M.touch()
  api.send(session.room_id, session.identity, message, state.options.send, function(err)
    if err then
      notify("send failed: " .. api.error_text(err), vim.log.levels.ERROR)
      return
    end
    if state.ui then
      state.ui.on_session_updated(session)
    end
  end)
  return true
end

function M.status(session)
  return session_status(session)
end

function M.shutdown()
  if state.idle_timer then
    pcall(state.idle_timer.stop, state.idle_timer)
    pcall(state.idle_timer.close, state.idle_timer)
    state.idle_timer = nil
  end
  local ids = vim.deepcopy(state.order)
  for _, id in ipairs(ids) do
    M.kill(id)
  end
  state.sessions = {}
  state.order = {}
  state.active_id = nil
end

return M
