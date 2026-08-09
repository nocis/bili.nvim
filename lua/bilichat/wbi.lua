local bit = require("bit")

local band = bit.band
local bor = bit.bor
local bxor = bit.bxor
local bnot = bit.bnot
local rol = bit.rol
local tobit = bit.tobit

local M = {}

local shifts = {
  7, 12, 17, 22,
  5, 9, 14, 20,
  4, 11, 16, 23,
  6, 10, 15, 21,
}

local permutation = {
  46, 47, 18, 2, 53, 8, 23, 32,
  15, 50, 10, 31, 58, 3, 45, 35,
  27, 43, 5, 49, 33, 9, 42, 19,
  29, 28, 14, 39, 12, 38, 41, 13,
  37, 48, 7, 54, 40, 6, 22, 4,
  36, 26, 34, 24, 55, 17, 21, 1,
  44, 30, 16, 0, 20, 11, 25, 51,
  52, 56, 57, 59, 60, 61, 62, 63,
}

local function little_endian_word(data, offset)
  local a, b, c, d = data:byte(offset, offset + 3)
  return tobit(a + b * 256 + c * 65536 + d * 16777216)
end

local function little_endian(value)
  if value < 0 then
    value = value + 4294967296
  end
  return string.char(
    value % 256,
    math.floor(value / 256) % 256,
    math.floor(value / 65536) % 256,
    math.floor(value / 16777216) % 256
  )
end

local function md5_constants()
  local result = {}
  for index = 1, 64 do
    result[index] = tobit(math.floor(math.abs(math.sin(index)) * 4294967296))
  end
  return result
end

local constants = md5_constants()

function M.md5(input)
  input = tostring(input or "")
  local bit_length = #input * 8
  local padded = input .. string.char(128)

  while (#padded % 64) ~= 56 do
    padded = padded .. string.char(0)
  end

  local low = bit_length % 4294967296
  local high = math.floor(bit_length / 4294967296)
  padded = padded .. little_endian(tobit(low)) .. little_endian(tobit(high))

  local a0 = tobit(0x67452301)
  local b0 = tobit(0xefcdab89)
  local c0 = tobit(0x98badcfe)
  local d0 = tobit(0x10325476)

  for chunk_start = 1, #padded, 64 do
    local words = {}
    for index = 0, 15 do
      words[index] = little_endian_word(padded, chunk_start + index * 4)
    end

    local a, b, c, d = a0, b0, c0, d0
    for index = 0, 63 do
      local f, g
      if index < 16 then
        f = bor(band(b, c), band(bnot(b), d))
        g = index
      elseif index < 32 then
        f = bor(band(d, b), band(bnot(d), c))
        g = (5 * index + 1) % 16
      elseif index < 48 then
        f = bxor(b, bxor(c, d))
        g = (3 * index + 5) % 16
      else
        f = bxor(c, bor(b, bnot(d)))
        g = (7 * index) % 16
      end

      local round = index % 4
      local shift = shifts[round + 1 + math.floor(index / 16) * 4]
      local sum = tobit(a + f + constants[index + 1] + words[g])
      local next_b = tobit(b + rol(sum, shift))
      a, b, c, d = d, next_b, b, c
    end

    a0 = tobit(a0 + a)
    b0 = tobit(b0 + b)
    c0 = tobit(c0 + c)
    d0 = tobit(d0 + d)
  end

  local digest = (little_endian(a0) .. little_endian(b0) .. little_endian(c0) .. little_endian(d0)):gsub(
    ".",
    function(char)
      return string.format("%02x", char:byte())
    end
  )
  return digest
end

local function url_encode(value)
  return tostring(value):gsub("[^%w%-_%.~]", function(char)
    return string.format("%%%02X", char:byte())
  end)
end

local function extract_key(url)
  return tostring(url or ""):match("([^/]+)%.png") or ""
end

function M.keys_from_nav(data)
  local image = data and data.wbi_img or data
  if type(image) ~= "table" then
    return nil, "nav response did not contain WBI image keys"
  end

  local img_key = extract_key(image.img_url or image.img)
  local sub_key = extract_key(image.sub_url or image.sub)
  if img_key == "" or sub_key == "" then
    return nil, "nav response contained empty WBI image keys"
  end
  return { img_key = img_key, sub_key = sub_key }
end

function M.mixin_key(keys)
  if not keys or not keys.img_key or not keys.sub_key then
    return nil, "WBI keys are missing"
  end

  local raw = keys.img_key .. keys.sub_key
  local result = {}
  for index = 1, 32 do
    result[index] = raw:sub(permutation[index] + 1, permutation[index] + 1)
  end
  return table.concat(result)
end

function M.sign(params, keys, timestamp)
  local mixin, err = M.mixin_key(keys)
  if not mixin then
    return nil, err
  end

  local values = {}
  for key, value in pairs(params or {}) do
    values[#values + 1] = { key = tostring(key), value = tostring(value) }
  end
  values[#values + 1] = { key = "wts", value = tostring(tonumber(timestamp) or os.time()) }
  table.sort(values, function(left, right)
    return left.key < right.key
  end)

  local query = {}
  for _, item in ipairs(values) do
    local value = item.value:gsub("[!'()*]", "")
    query[#query + 1] = url_encode(item.key) .. "=" .. url_encode(value)
  end

  local unsigned = table.concat(query, "&")
  local signed = unsigned .. "&w_rid=" .. M.md5(unsigned .. mixin)
  return signed
end

return M
