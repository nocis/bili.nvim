# bilichat.nvim

A small Neovim chat client for Bilibili live rooms.

## Requirements

- Neovim 0.10 or newer
- `curl` available on `PATH`
- Network access to Bilibili HTTPS APIs and, for live push, TCP port 2243

The plugin has no Lua dependencies. It uses the Bilibili live danmaku protocol over TCP when possible and falls back to `gethistory` polling when anonymous, TCP is unavailable, system zlib is unavailable, or the server sends unsupported Brotli packets.

## Setup

```lua
require("bilichat").setup({
  width = 42,
  poll_interval = 3,
  idle_timeout = 30 * 60,
})
```

Setup is optional. Commands lazy-load the plugin with the defaults.

## LazyVim

This spec uses the built-in defaults and lazy.nvim calls `require("bilichat").setup(opts)` automatically:

```lua
return {
  {
    "nocis/bili.nvim",
    main = "bilichat",
    cmd = {
      "BiliChat",
      "BiliChatOpen",
      "BiliChatAuth",
      "BiliChatLogout",
      "BiliChatList",
      "BiliChatKill",
      "BiliChatSend",
      "BiliChatNext",
      "BiliChatPrev",
    },
    keys = {
      { "<leader>,", group = "BiliChat" },
      { "<leader>,o", "<cmd>BiliChatOpen<cr>", desc = "Open room session" },
      { "<leader>,l", "<cmd>BiliChatList<cr>", desc = "List sessions" },
      { "<leader>,n", "<cmd>BiliChatNext<cr>", desc = "Next session" },
      { "<leader>,p", "<cmd>BiliChatPrev<cr>", desc = "Previous session" },
      { "<leader>,k", "<cmd>BiliChatKill<cr>", desc = "Kill session" },
      { "<leader>,K", "<cmd>BiliChatKill all<cr>", desc = "Kill all sessions" },
    },
    opts = {},
  },
}
```

LazyVim may already use `<leader>,` for buffer switching. If that mapping conflicts, disable the existing mapping or choose another prefix.

Override only what you need:

```lua
opts = {
  width = 48,
  poll_interval = 5,
}
```

The complete default table is available through `require("bilichat").defaults()`.

## Session Authentication

Every `:BiliChatOpen` creates one independent in-memory session containing a room and its cookie. There is no global identity registry and no cookie file.

The command asks for a room URL or ID, then asks for a masked Cookie header. Press Enter at the cookie prompt to open an anonymous read-only session using history polling. Cookies are never written to disk.

- `:BiliChatAuth` replaces the cookie for the current session.
- `:BiliChatLogout` removes the current session cookie and switches it to anonymous browsing.
- Cancelling `:BiliChatAuth` leaves the current cookie unchanged.

## Commands

| Command | Purpose |
| --- | --- |
| `:BiliChat` | Toggle the sidebar; opens a session if none exists |
| `:BiliChatOpen [url\|id]` | Create a new room-cookie session |
| `:BiliChatAuth` | Reset the current session cookie |
| `:BiliChatLogout` | Make the current session anonymous |
| `:BiliChatList` | Pick a session to show |
| `:BiliChatKill` | Stop and scrub the active session |
| `:BiliChatKill all` | Stop and scrub every session |
| `:BiliChatSend {text}` | Send chat from the active session |
| `:BiliChatNext` / `:BiliChatPrev` | Switch sessions |

The sidebar is a right vertical split with a message pane and one-line input pane. Press `<CR>` in the input to send, `<C-n>`/`<C-p>` to switch sessions, `gs` to open the picker, and `q` to hide the sidebar. Hiding keeps sessions, drafts, transcripts, and transports alive.

When the sidebar is hidden for 30 minutes without interaction, all sessions, transports, buffers, and their in-memory cookies are cleared automatically.
