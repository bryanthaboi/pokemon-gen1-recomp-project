local SaveData = require("src.core.SaveData")

local SaveIO = {}

local function join(a, b)
  if a:sub(-1) == "/" or a:sub(-1) == "\\" then return a .. b end
  local sep = package.config:sub(1, 1)
  return a .. sep .. b
end

local function trim(value)
  return value and value:gsub("^%s+", ""):gsub("%s+$", "") or ""
end

local function commandOutput(command)
  local pipe = io.popen(command, "r")
  if not pipe then return nil end
  local result = pipe:read("*a")
  pipe:close()
  result = trim(result)
  return result ~= "" and result or nil
end

function SaveIO.defaultPath()
  local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
  local uname = io.popen and io.popen("uname -s 2>/dev/null")
  local sys = uname and uname:read("*l") or ""
  if uname then uname:close() end
  if sys == "Darwin" then
    -- LÖVE identity folder lives under Application Support/LOVE/
    return join(join(join(join(home, "Library"), "Application Support"), "LOVE"),
                join("pokemon-love2d", "save.lua"))
  end
  -- Linux LOVE default
  if home ~= "" and sys ~= "" then
    return join(join(join(home, ".local/share"), "love"),
                join("pokemon-love2d", "save.lua"))
  end
  -- Windows
  local appdata = os.getenv("APPDATA")
  if appdata then
    return join(join(appdata, "love"), join("pokemon-love2d", "save.lua"))
  end
  return join("pokemon-love2d", "save.lua")
end

-- Native file picker (same approach as RomImporter). Returns an absolute
-- path, or nil if the user cancelled / no dialog is available.
function SaveIO.choosePath()
  local platform = (love and love.system and love.system.getOS
                    and love.system.getOS()) or ""
  if platform == "OS X" then
    return commandOutput(
      [[osascript -e 'POSIX path of (choose file with prompt "Choose a Pokemon save.lua")' 2>/dev/null]])
  elseif platform == "Windows" then
    local script = table.concat({
      "Add-Type -AssemblyName System.Windows.Forms;",
      "$d=New-Object System.Windows.Forms.OpenFileDialog;",
      "$d.Title='Choose a Pokemon save.lua';",
      "$d.Filter='Save files (*.lua)|*.lua|All files (*.*)|*.*';",
      "if($d.ShowDialog() -eq 'OK'){[Console]::Write($d.FileName)}",
    })
    return commandOutput(
      'powershell -NoProfile -STA -Command "' .. script .. '"')
  elseif platform == "Linux" then
    local path = commandOutput(
      [[zenity --file-selection --title="Choose a Pokemon save.lua" --file-filter="Lua save | *.lua" 2>/dev/null]])
    if path then return path end
    return commandOutput(
      [[kdialog --getopenfilename "$HOME" "*.lua|Lua save" 2>/dev/null]])
  end
  return nil
end

function SaveIO.backupPath(path)
  local stamp = os.date("%Y%m%d-%H%M%S")
  return path .. ".bak-" .. stamp
end

function SaveIO.load(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, err end
  local body = f:read("*a")
  f:close()
  return SaveData.decode(body)
end

function SaveIO.save(path, data)
  local encoded = SaveData.encode(data)
  local existing = io.open(path, "rb")
  if existing then
    local prev = existing:read("*a")
    existing:close()
    local bak = SaveIO.backupPath(path)
    local bf, berr = io.open(bak, "wb")
    if not bf then return false, berr end
    local bwok, bwerr = bf:write(prev)
    if not bwok then
      bf:close()
      os.remove(bak)
      return false, bwerr
    end
    local bcok, bcerr = bf:close()
    if not bcok then
      os.remove(bak)
      return false, bcerr
    end
  end
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "wb")
  if not f then return false, err end
  local wok, werr = f:write(encoded)
  if not wok then
    f:close()
    os.remove(tmp)
    return false, werr
  end
  local cok, cerr = f:close()
  if not cok then
    os.remove(tmp)
    return false, cerr
  end
  local ok, rerr = os.rename(tmp, path)
  if not ok then
    -- Windows may need remove-first; try best-effort
    os.remove(path)
    ok, rerr = os.rename(tmp, path)
  end
  if not ok then return false, tostring(rerr) end
  return true
end

return SaveIO
