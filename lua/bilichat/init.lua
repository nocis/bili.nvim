local config = require("bilichat.config")

local M = {
  _configured = false,
  _options = nil,
}

local function ensure_setup()
  if not M._configured then
    M.setup()
  end
end

function M.defaults()
  return vim.deepcopy(config.defaults)
end

function M.setup(options)
  if M._configured then
    return M._options
  end

  M._options = config.setup(options)
  M._configured = true

  require("bilichat.http").setup(M._options)
  require("bilichat.session").setup(M._options)
  require("bilichat.ui").setup(M._options)

  return M._options
end

function M.command_chat(args, bang)
  ensure_setup()
  local session = require("bilichat.session")

  if bang then
    require("bilichat.ui").hide()
    return
  end

  if args and args ~= "" then
    session.open_command(args)
    return
  end

  if #session.sessions() == 0 then
    session.open_command("")
    return
  end

  require("bilichat.ui").toggle()
end

function M.command_open(args)
  ensure_setup()
  require("bilichat.session").open_command(args)
end

function M.command_auth()
  ensure_setup()
  require("bilichat.session").reauth()
end

function M.command_logout()
  ensure_setup()
  require("bilichat.session").logout()
end

function M.command_list()
  ensure_setup()
  require("bilichat.session").pick()
end

function M.command_kill(args)
  ensure_setup()
  require("bilichat.session").kill_command(args)
end

function M.command_send(args)
  ensure_setup()
  require("bilichat.session").send(args)
end

function M.command_next(delta)
  ensure_setup()
  require("bilichat.session").next(delta or 1)
end

local util = require("bilichat.util")

local function apply_debug_handle_body(client)
  if client._debug_handle_body then
    return
  end
  client._orig_handle_body = client._handle_body
  client._debug_handle_body = true
  client._handle_body = function(self, version, operation, body)
    if operation == 5 and (version == 0 or version == 1) then
      local ok, dec = pcall(vim.json.decode, body)
      if ok and dec then
        local cmd = tostring(dec.cmd or "")
        if cmd:match("^DANMU_MSG") then
          local msg = util.live_message(dec)
          vim.notify(string.format("[DANMU_MSG] text=%s uid=%s -> %s",
            tostring(dec.info and dec.info[2] or "?"):sub(1, 60),
            tostring(dec.info and dec.info[3] and dec.info[3][1] or "?"),
            msg and "OK" or "NIL"))
          if msg then
            local s = require("bilichat.session").active()
            if s then
              local key = util.message_key(msg)
              vim.notify(string.format("[seen] key=%s blocked=%s",
                key:sub(1, 60), tostring(s.seen[key] ~= nil)))
            end
          end
        else
          vim.notify(string.format("[CMD] %s len=%d", cmd, #body))
        end
      end
    elseif operation == 5 and version == 2 then
      vim.notify(string.format("[COMPRESSED] %d bytes", #body))
    elseif operation == 8 then
      local ok, dec = pcall(vim.json.decode, body)
      vim.notify(string.format("[AUTH] code=%s", tostring(ok and dec and dec.code or "?")))
    end
    return self._orig_handle_body(self, version, operation, body)
  end
end

local function remove_debug_handle_body(client)
  if not client._debug_handle_body then
    return
  end
  client._handle_body = client._orig_handle_body
  client._orig_handle_body = nil
  client._debug_handle_body = nil
end

local debug_hooked = false
local function ensure_debug_hook()
  if debug_hooked then
    return
  end
  debug_hooked = true
  local danmaku = require("bilichat.danmaku")
  local orig_new = danmaku.new
  danmaku.new = function(opts)
    local client = orig_new(opts)
    if vim.g.bilichat_debug then
      apply_debug_handle_body(client)
    end
    return client
  end
end

function M.command_debug(args)
  ensure_setup()
  args = (args or ""):match("%S+") or ""
  if args == "status" then
    local session = require("bilichat.session")
    local s = session.active()
    if not s then
      vim.notify("BiliChat: no active session", vim.log.levels.WARN)
      return
    end
    local transport_kind = s.transport_kind or "none"
    local status = session.status(s)
    vim.notify(string.format(
      "BiliChat Debug:\n  room=%s\n  transport=%s\n  status=%s\n  messages=%d\n  pending=%d\n  history_loaded=%s\n  debug=%s",
      tostring(s.room_id), transport_kind, status,
      #(s.messages or {}), #(s.pending_messages or {}),
      tostring(s.history_loaded), tostring(vim.g.bilichat_debug or false)
    ), vim.log.levels.INFO)
    return
  end
  local was_on = vim.g.bilichat_debug
  vim.g.bilichat_debug = not vim.g.bilichat_debug
  ensure_debug_hook()

  local s = require("bilichat.session").active()
  if s and s.transport and s.transport._handle_body then
    if vim.g.bilichat_debug then
      apply_debug_handle_body(s.transport)
    else
      remove_debug_handle_body(s.transport)
    end
  end

  if vim.g.bilichat_debug then
    vim.notify("BiliChat debug mode ON", vim.log.levels.INFO)
  else
    vim.notify("BiliChat debug mode OFF", vim.log.levels.INFO)
  end
end

function M.shutdown()
  if not M._configured then
    return
  end
  require("bilichat.session").shutdown()
end

return M
