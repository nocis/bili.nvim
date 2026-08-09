local http = require("bilichat.http")
local util = require("bilichat.util")
local wbi = require("bilichat.wbi")

local M = {}

local LIVE_API = "https://api.live.bilibili.com"
local MAIN_API = "https://api.bilibili.com"

local function headers(identity, referer)
  local result = {
    Accept = "application/json, text/plain, */*",
    ["Accept-Language"] = "en-US,en;q=0.9,zh-CN;q=0.8,zh;q=0.7",
    Referer = referer or "https://live.bilibili.com/",
  }
  if identity and identity.cookie_header then
    result.Cookie = identity.cookie_header
  end
  return result
end

local function error_object(response, fallback)
  local code = response and response.code
  local message = response and (response.message or response.msg)
  if not message or message == "" then
    message = fallback or "Bilibili returned an unknown error"
  end
  return {
    code = tonumber(code) or -1,
    message = tostring(message),
  }
end

local function request_json(method, url, options, callback)
  http.request(method, url, options, function(err, body)
    if err then
      callback(err)
      return
    end

    local response, decode_error = util.decode_json(body)
    if not response then
      callback({
        code = -1,
        message = "invalid JSON from Bilibili: " .. tostring(decode_error),
      })
      return
    end

    if tonumber(response.code or 0) ~= 0 then
      callback(error_object(response, response.message or response.msg))
      return
    end
    callback(nil, response)
  end)
end

function M.error_text(err)
  if not err then
    return "unknown error"
  end
  if err.code and err.code ~= -1 then
    return string.format("[%s] %s", tostring(err.code), tostring(err.message))
  end
  return tostring(err.message or err)
end

function M.nav(identity, callback)
  request_json("GET", MAIN_API .. "/x/web-interface/nav", {
    headers = headers(identity, "https://www.bilibili.com/"),
  }, callback)
end

function M.room_init(requested_id, callback)
  request_json("GET", http.url(LIVE_API .. "/room/v1/Room/room_init", {
    id = requested_id,
  }), {
    headers = headers(nil),
  }, callback)
end

function M.history(room_id, identity, callback)
  request_json("GET", http.url(LIVE_API .. "/xlive/web-room/v1/dM/gethistory", {
    roomid = room_id,
    room_type = 0,
  }), {
    headers = headers(identity, "https://live.bilibili.com/" .. tostring(room_id)),
  }, callback)
end

function M.danmu_info(room_id, identity, callback)
  if not identity or not identity.wbi_keys then
    callback({ code = -1, message = "an authenticated identity with WBI keys is required" })
    return
  end

  local query, sign_error = wbi.sign({
    id = room_id,
    type = 0,
    web_location = "444.8",
  }, identity.wbi_keys)
  if not query then
    callback({ code = -1, message = sign_error })
    return
  end

  request_json("GET", LIVE_API .. "/xlive/web-room/v1/index/getDanmuInfo?" .. query, {
    headers = headers(identity, "https://live.bilibili.com/" .. tostring(room_id)),
  }, callback)
end

function M.send(room_id, identity, message, options, callback)
  if not identity or not identity.csrf then
    callback({ code = -1, message = "an authenticated identity is required to send chat" })
    return
  end

  options = options or {}
  local query, sign_error = wbi.sign({
    web_location = "444.8",
  }, identity.wbi_keys)
  if not query then
    callback({ code = -1, message = sign_error })
    return
  end

  local send_options = {
    headers = headers(identity, "https://live.bilibili.com/" .. tostring(room_id)),
    form = {
      bubble = 0,
      msg = message,
      color = options.color or 16777215,
      mode = options.mode or 1,
      room_type = options.room_type or 0,
      jumpfrom = options.jumpfrom or 84001,
      reply_mid = 0,
      reply_attr = 0,
      replay_dmid = "",
      statistics = vim.json.encode({ appId = 100, platform = 5 }),
      reply_type = 0,
      reply_uname = "",
      data_extend = vim.json.encode({ trackid = "-99998" }),
      fontsize = options.fontsize or 25,
      rnd = os.time(),
      roomid = room_id,
      csrf = identity.csrf,
      csrf_token = identity.csrf,
    },
  }

  request_json("POST", LIVE_API .. "/msg/send?" .. query, send_options, callback)
end

function M.history_items(response)
  local data = response and response.data or {}
  local items = data.room or {}
  local result = {}
  for _, item in ipairs(items) do
    local message = util.history_message(item)
    if message then
      result[#result + 1] = message
    end
  end
  return result
end

return M
