if vim.g.loaded_bilichat then
  return
end
vim.g.loaded_bilichat = true

local function command(name, callback, opts)
  vim.api.nvim_create_user_command(name, callback, opts or {})
end

command("BiliChat", function(opts)
  require("bilichat").command_chat(opts.args, opts.bang)
end, { nargs = "?", bang = true, desc = "Toggle the BiliChat sidebar" })

command("BiliChatOpen", function(opts)
  require("bilichat").command_open(opts.args)
end, { nargs = "?", desc = "Open a room and cookie session" })

command("BiliChatAuth", function()
  require("bilichat").command_auth()
end, { desc = "Reset the current session cookie" })

command("BiliChatLogout", function()
  require("bilichat").command_logout()
end, { desc = "Make the current session anonymous" })

command("BiliChatList", function()
  require("bilichat").command_list()
end, { desc = "Choose an active BiliChat session" })

command("BiliChatKill", function(opts)
  require("bilichat").command_kill(opts.args)
end, { nargs = "?", desc = "Stop the active session or all sessions" })

command("BiliChatSend", function(opts)
  require("bilichat").command_send(opts.args)
end, { nargs = "+", desc = "Send a message to the active room" })

command("BiliChatNext", function()
  require("bilichat").command_next(1)
end, { desc = "Switch to the next BiliChat session" })

command("BiliChatPrev", function()
  require("bilichat").command_next(-1)
end, { desc = "Switch to the previous BiliChat session" })

command("BiliChatDebug", function(opts)
  require("bilichat").command_debug(opts.args)
end, { nargs = "?", desc = "Toggle debug mode or show session status" })

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("BiliChatLifecycle", { clear = true }),
  callback = function()
    require("bilichat").shutdown()
  end,
})
