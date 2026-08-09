local util = require("bilichat.util")

local M = {}
local state = {
  configured = false,
  options = nil,
  message_win = nil,
  input_win = nil,
  origin_win = nil,
  active_id = nil,
  closing = false,
  namespace = nil,
  empty_buf = nil,
}

local function set_win_option(win, name, value)
  if util.is_valid_window(win) then
    pcall(vim.api.nvim_set_option_value, name, value, { win = win })
  end
end

local function set_buf_option(buf, name, value)
  if util.is_valid_buffer(buf) then
    pcall(vim.api.nvim_set_option_value, name, value, { buf = buf })
  end
end

local function configure_message_window(win)
  set_win_option(win, "number", false)
  set_win_option(win, "relativenumber", false)
  set_win_option(win, "signcolumn", "no")
  set_win_option(win, "wrap", true)
  set_win_option(win, "linebreak", true)
  set_win_option(win, "cursorline", false)
  set_win_option(win, "foldenable", false)
  set_win_option(win, "winfixwidth", true)
  set_win_option(win, "winhl", "Normal:Normal")
end

local function configure_input_window(win)
  set_win_option(win, "number", false)
  set_win_option(win, "relativenumber", false)
  set_win_option(win, "signcolumn", "no")
  set_win_option(win, "wrap", false)
  set_win_option(win, "cursorline", true)
  set_win_option(win, "winfixheight", true)
  set_win_option(win, "winhl", "Normal:BiliChatInput")
  set_win_option(win, "winbar", "")
end

local function configure_message_buffer(buf, session)
  set_buf_option(buf, "buftype", "nofile")
  set_buf_option(buf, "bufhidden", "hide")
  set_buf_option(buf, "swapfile", false)
  set_buf_option(buf, "modifiable", true)
  set_buf_option(buf, "readonly", false)
  pcall(vim.api.nvim_buf_set_name, buf, "bilichat://" .. session.id .. "/messages")
end

local function configure_input_buffer(buf, session)
  set_buf_option(buf, "buftype", "nofile")
  set_buf_option(buf, "bufhidden", "hide")
  set_buf_option(buf, "swapfile", false)
  set_buf_option(buf, "modifiable", true)
  set_buf_option(buf, "readonly", false)
  set_buf_option(buf, "filetype", "bilichat-input")
  pcall(vim.api.nvim_buf_set_name, buf, "bilichat://" .. session.id .. "/input")
end

local function session_index(session)
  local sessions = require("bilichat.session").sessions()
  for index, item in ipairs(sessions) do
    if item.id == session.id then
      return index, #sessions
    end
  end
  return 1, #sessions
end

local function winbar(session, input)
  local index, total = session_index(session)
  local unread = session.unread > 0 and string.format(" +%d", session.unread) or ""
  local text
  if input then
    text = " BiliChat input | <CR> send | <C-n>/<C-p> switch "
  else
    text = string.format(
      " BiliChat [%d/%d] %s | %s%s ",
      index,
      total,
      session.title or "room",
      require("bilichat.session").status(session),
      unread
    )
  end
  return text:gsub("%%", "%%%%")
end

local function user_group(uid)
  return "BiliChatUser" .. tostring((tonumber(uid) or 0) % 8 + 1)
end

local function clean_text(text)
  return tostring(text or ""):gsub("\r?\n", " "):gsub("%z", "")
end

function M.render_buffer(session)
  if not util.is_valid_buffer(session.message_buf) then
    return
  end

  local lines = {}
  for _, message in ipairs(session.messages or {}) do
    local time = os.date("%H:%M", message.timestamp or os.time())
    local uname = clean_text(message.uname)
    lines[#lines + 1] = string.format("[%s] %s: %s", time, uname, clean_text(message.text))
  end
  if #lines == 0 then
    lines[1] = "Waiting for chat messages..."
  end

  set_buf_option(session.message_buf, "modifiable", true)
  pcall(vim.api.nvim_buf_set_lines, session.message_buf, 0, -1, false, lines)
  set_buf_option(session.message_buf, "modifiable", false)
  set_buf_option(session.message_buf, "readonly", true)
  vim.api.nvim_buf_clear_namespace(session.message_buf, state.namespace, 0, -1)

  for index, message in ipairs(session.messages or {}) do
    local line = index - 1
    vim.api.nvim_buf_add_highlight(session.message_buf, state.namespace, "BiliChatTime", line, 0, 7)
    local uname = clean_text(message.uname)
    local group = message.is_self and "BiliChatSelf" or user_group(message.uid)
    vim.api.nvim_buf_add_highlight(session.message_buf, state.namespace, group, line, 8, 8 + #uname)
  end
end

local function set_current_input(session)
  if not util.is_valid_window(state.input_win) or not util.is_valid_buffer(session.input_buf) then
    return
  end
  vim.api.nvim_win_set_buf(state.input_win, session.input_buf)
  configure_input_window(state.input_win)
end

local function set_current_message(session)
  if not util.is_valid_window(state.message_win) or not util.is_valid_buffer(session.message_buf) then
    return
  end
  vim.api.nvim_win_set_buf(state.message_win, session.message_buf)
  configure_message_window(state.message_win)
  set_win_option(state.message_win, "winbar", winbar(session, false))
  M.render_buffer(session)
end

local function focus_bottom(session)
  if not util.is_valid_window(state.message_win) or not util.is_valid_buffer(session.message_buf) then
    return
  end
  local count = vim.api.nvim_buf_line_count(session.message_buf)
  pcall(vim.api.nvim_win_set_cursor, state.message_win, { math.max(1, count), 0 })
end

function M.is_visible()
  return util.is_valid_window(state.message_win) and util.is_valid_window(state.input_win)
end

function M.is_session_visible(session)
  return M.is_visible() and state.active_id == session.id
end

function M.on_session_created(session)
  session.message_buf = vim.api.nvim_create_buf(false, true)
  session.input_buf = vim.api.nvim_create_buf(false, true)
  session.follow = true
  configure_message_buffer(session.message_buf, session)
  configure_input_buffer(session.input_buf, session)
  vim.api.nvim_buf_set_lines(session.input_buf, 0, -1, false, { "" })

  vim.keymap.set("n", "q", function()
    M.hide()
  end, { buffer = session.message_buf, silent = true, desc = "Hide BiliChat" })
  vim.keymap.set("n", "<Tab>", function()
    require("bilichat.session").next(1)
  end, { buffer = session.message_buf, silent = true, desc = "Next BiliChat session" })
  vim.keymap.set("n", "<S-Tab>", function()
    require("bilichat.session").next(-1)
  end, { buffer = session.message_buf, silent = true, desc = "Previous BiliChat session" })
  vim.keymap.set("n", "gs", function()
    require("bilichat.session").pick()
  end, { buffer = session.message_buf, silent = true, desc = "Choose BiliChat session" })
  vim.keymap.set({ "n", "i" }, "<CR>", function()
    if util.is_valid_window(state.input_win) then
      vim.api.nvim_set_current_win(state.input_win)
      vim.cmd("startinsert")
    end
  end, { buffer = session.message_buf, silent = true, desc = "Focus BiliChat input" })

  local function send_input()
    local lines = vim.api.nvim_buf_get_lines(session.input_buf, 0, -1, false)
    local message = util.trim(table.concat(lines, "\n"))
    if message == "" then
      return
    end
    if require("bilichat.session").send(message) then
      vim.api.nvim_buf_set_lines(session.input_buf, 0, -1, false, { "" })
    end
  end

  vim.keymap.set("i", "<CR>", send_input, {
    buffer = session.input_buf,
    silent = true,
    desc = "Send BiliChat message",
  })
  vim.keymap.set("n", "<CR>", function()
    vim.cmd("startinsert")
  end, { buffer = session.input_buf, silent = true })
  vim.keymap.set("n", "q", function()
    M.hide()
  end, { buffer = session.input_buf, silent = true, desc = "Hide BiliChat" })
  vim.keymap.set("i", "<C-n>", function()
    require("bilichat.session").next(1)
  end, { buffer = session.input_buf, silent = true, desc = "Next BiliChat session" })
  vim.keymap.set("i", "<C-p>", function()
    require("bilichat.session").next(-1)
  end, { buffer = session.input_buf, silent = true, desc = "Previous BiliChat session" })
end

function M.on_session_message(session)
  local at_bottom = true
  if M.is_session_visible(session) and util.is_valid_buffer(session.message_buf) then
    local cursor = vim.api.nvim_win_get_cursor(state.message_win)
    at_bottom = cursor[1] >= vim.api.nvim_buf_line_count(session.message_buf)
    session.follow = at_bottom
  end

  M.render_buffer(session)
  if M.is_session_visible(session) and session.follow then
    focus_bottom(session)
  end
end

function M.on_session_updated(session)
  if state.active_id == session.id and M.is_visible() then
    set_win_option(state.message_win, "winbar", winbar(session, false))
  end
end

function M.on_active_changed(session)
  state.active_id = session.id
  if not M.is_visible() then
    return
  end
  set_current_message(session)
  set_current_input(session)
  focus_bottom(session)
end

function M.on_session_removed(session)
  if M.is_visible() and state.active_id == session.id then
    local empty = state.empty_buf
    if not util.is_valid_buffer(empty) then
      empty = vim.api.nvim_create_buf(false, true)
      state.empty_buf = empty
    end
    vim.api.nvim_win_set_buf(state.message_win, empty)
    vim.api.nvim_win_set_buf(state.input_win, empty)
  end
  if util.is_valid_buffer(session.message_buf) then
    pcall(vim.api.nvim_buf_delete, session.message_buf, { force = true })
  end
  if util.is_valid_buffer(session.input_buf) then
    pcall(vim.api.nvim_buf_delete, session.input_buf, { force = true })
  end
end

function M.show()
  local session = require("bilichat.session").active()
  if not session then
    vim.notify("BiliChat: no session; use :BiliChatOpen", vim.log.levels.WARN)
    return
  end

  if not M.is_visible() then
    if util.is_valid_window(state.message_win) or util.is_valid_window(state.input_win) then
      M.hide()
    end
    state.origin_win = vim.api.nvim_get_current_win()
    vim.cmd("botright vsplit")
    state.message_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(state.message_win, state.options.width)
    configure_message_window(state.message_win)

    vim.cmd("belowright split")
    state.input_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_height(state.input_win, 1)
    configure_input_window(state.input_win)
  end

  state.active_id = session.id
  require("bilichat.session").focus(session.id)
  set_current_message(session)
  set_current_input(session)
  require("bilichat.session").touch()
  vim.api.nvim_set_current_win(state.input_win)
  vim.cmd("startinsert")
end

function M.hide()
  if not M.is_visible() then
    local origin = state.origin_win
    state.closing = true
    if util.is_valid_window(state.input_win) then
      pcall(vim.api.nvim_win_close, state.input_win, true)
    end
    if util.is_valid_window(state.message_win) then
      pcall(vim.api.nvim_win_close, state.message_win, true)
    end
    state.closing = false
    state.message_win = nil
    state.input_win = nil
    state.origin_win = nil
    require("bilichat.session").touch()
    if util.is_valid_window(origin) then
      pcall(vim.api.nvim_set_current_win, origin)
    end
    return
  end

  local origin = state.origin_win
  state.closing = true
  if util.is_valid_window(state.input_win) then
    pcall(vim.api.nvim_win_close, state.input_win, true)
  end
  if util.is_valid_window(state.message_win) then
    pcall(vim.api.nvim_win_close, state.message_win, true)
  end
  state.closing = false
  state.input_win = nil
  state.message_win = nil
  state.origin_win = nil
  require("bilichat.session").touch()
  if util.is_valid_window(origin) then
    pcall(vim.api.nvim_set_current_win, origin)
  end
end

function M.toggle()
  if M.is_visible() then
    M.hide()
  else
    M.show()
  end
end

function M.setup(options)
  if state.configured then
    return
  end
  state.configured = true
  state.options = options
  state.namespace = vim.api.nvim_create_namespace("bilichat")
  require("bilichat.session").attach_ui(M)

  vim.api.nvim_set_hl(0, "BiliChatTime", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "BiliChatInput", { link = "Pmenu", default = true })
  vim.api.nvim_set_hl(0, "BiliChatTitle", { link = "Title", default = true })
  vim.api.nvim_set_hl(0, "BiliChatSelf", { link = "Special", default = true })
  for index, group in ipairs({ "Identifier", "String", "Constant", "Function", "Type", "Special", "Keyword", "Number" }) do
    vim.api.nvim_set_hl(0, "BiliChatUser" .. tostring(index), { link = group, default = true })
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    group = vim.api.nvim_create_augroup("BiliChatUI", { clear = true }),
    callback = function(args)
      if state.closing then
        return
      end
      local closed = tonumber(args.match)
      if closed == state.message_win or closed == state.input_win then
        M.hide()
      end
    end,
  })
end

return M
