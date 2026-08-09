local api = require("bilichat.api")
local util = require("bilichat.util")
local wbi = require("bilichat.wbi")

local M = {}

local function parse_cookie(raw)
  raw = util.trim(raw):gsub("[\r\n]", ""):gsub("^[Cc]ookie:%s*", "")
  if raw == "" then
    return nil, "cookie input was empty"
  end

  local values = {}
  local parts = {}
  for part in raw:gmatch("[^;]+") do
    local key, value = util.trim(part):match("^([^=]+)=(.*)$")
    if key and value then
      key = util.trim(key)
      value = util.trim(value)
      if key ~= "" then
        values[key] = value
        parts[#parts + 1] = key .. "=" .. value
      end
    end
  end

  if not values.SESSDATA or values.SESSDATA == "" then
    return nil, "cookie is missing SESSDATA"
  end
  if not values.bili_jct or values.bili_jct == "" then
    return nil, "cookie is missing bili_jct"
  end

  return {
    values = values,
    header = table.concat(parts, "; "),
  }
end

local function identity_from_cookie(parsed)
  return {
    cookie_header = parsed.header,
    cookies = parsed.values,
    csrf = parsed.values.bili_jct,
    uid = tonumber(parsed.values.DedeUserID or 0) or 0,
    uname = "unknown",
    label = "unknown",
  }
end

function M.parse(raw)
  return parse_cookie(raw)
end

function M.create(raw, callback)
  local parsed, parse_error = parse_cookie(raw)
  if not parsed then
    callback({ code = -1, message = parse_error })
    return
  end

  local identity = identity_from_cookie(parsed)
  api.nav(identity, function(err, response)
    if err then
      callback(err)
      return
    end

    local data = response.data or {}
    if data.isLogin == false then
      callback({ code = -101, message = "Bilibili says this cookie is not logged in" })
      return
    end

    identity.uid = tonumber(data.mid or identity.uid or 0) or 0
    identity.uname = tostring(data.uname or "unknown")
    if identity.uid < 1 then
      callback({ code = -101, message = "Bilibili did not return a logged-in user ID" })
      return
    end

    local keys, key_error = wbi.keys_from_nav(data)
    if not keys then
      callback({ code = -1, message = key_error })
      return
    end
    identity.wbi_keys = keys
    identity.label = string.format("%s (%d)", identity.uname, identity.uid)
    callback(nil, identity)
  end)
end

function M.prompt(options, callback)
  options = options or {}
  local raw = vim.fn.inputsecret(options.prompt or "Bilibili Cookie header: ")
  vim.cmd("redraw")

  if not raw or util.trim(raw) == "" then
    if options.allow_anonymous then
      callback(nil, nil)
    else
      callback({ code = -2, message = "authentication cancelled", cancelled = true })
    end
    return
  end

  M.create(raw, callback)
end

function M.label(identity)
  if not identity then
    return "anonymous"
  end
  return identity.label or tostring(identity.uid or "unknown")
end

function M.scrub(identity)
  if not identity then
    return
  end
  identity.cookie_header = nil
  identity.cookies = nil
  identity.csrf = nil
  identity.wbi_keys = nil
end

return M
