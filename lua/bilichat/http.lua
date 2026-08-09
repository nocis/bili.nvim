local config = require("bilichat.config")

local M = {}
local runtime = {}

local function schedule_callback(callback, err, body)
  vim.schedule(function()
    callback(err, body)
  end)
end

function M.setup(options)
  runtime = options or {}
end

local function url_encode(value)
  return tostring(value):gsub("[^%w%-_%.~]", function(char)
    return string.format("%%%02X", char:byte())
  end)
end

function M.url(base, params)
  local query = {}
  for key, value in pairs(params or {}) do
    if value ~= nil then
      query[#query + 1] = url_encode(key) .. "=" .. url_encode(value)
    end
  end
  if #query == 0 then
    return base
  end
  return base .. "?" .. table.concat(query, "&")
end

function M.request(method, url, options, callback)
  options = options or {}
  local command = {
    "curl",
    "--silent",
    "--show-error",
    "--location",
    "--compressed",
    "--max-time",
    tostring(options.timeout or runtime.curl_timeout or config.defaults.curl_timeout),
    "--user-agent",
    options.user_agent or runtime.user_agent or config.defaults.user_agent,
  }

  if method ~= "GET" then
    vim.list_extend(command, { "--request", method })
  end

  for name, value in pairs(options.headers or {}) do
    if value and value ~= "" then
      vim.list_extend(command, { "--header", name .. ": " .. tostring(value) })
    end
  end

  for key, value in pairs(options.form or {}) do
    vim.list_extend(command, { "--data-urlencode", tostring(key) .. "=" .. tostring(value) })
  end

  vim.list_extend(command, { url })

  local ok, handle = pcall(vim.system, command, { text = true }, function(result)
    local stdout = result.stdout or ""
    if result.code ~= 0 then
      local detail = vim.trim(result.stderr or "")
      if detail == "" then
        detail = "curl exited with status " .. tostring(result.code)
      end
      schedule_callback(callback, { message = detail, code = result.code }, nil)
      return
    end
    schedule_callback(callback, nil, stdout)
  end)

  if not ok then
    schedule_callback(callback, { message = tostring(handle), code = -1 }, nil)
    return nil
  end
  return handle
end

return M
