-- Windowed vs borderless (desktop) fullscreen.
--
-- Persisted as save.options.videoMode.  Applied from OptionsMenu and on
-- boot via Game:applyOptions.  No-ops on mobile and in headless stubs
-- that lack love.window.

local VideoMode = {}

VideoMode.MODES = { "windowed", "borderless" }
VideoMode.DEFAULT = "windowed"

local LABELS = {
  windowed = "WINDOWED",
  borderless = "BORDERLESS",
}

function VideoMode.normalize(mode)
  if mode == "borderless" then return "borderless" end
  return VideoMode.DEFAULT
end

function VideoMode.modeLabel(mode)
  return LABELS[VideoMode.normalize(mode)] or LABELS[VideoMode.DEFAULT]
end

function VideoMode.isMobile()
  if not love or not love.system or not love.system.getOS then return false end
  local osName = love.system.getOS()
  return osName == "Android" or osName == "iOS"
end

-- Cycle windowed <-> borderless (dir ignored; two modes).
function VideoMode.cycle(mode, _dir)
  return VideoMode.normalize(mode) == "borderless" and "windowed" or "borderless"
end

-- Push the mode into the live window.  Safe when love.window is missing.
function VideoMode.apply(mode)
  if VideoMode.isMobile() then return end
  if not love or not love.window or not love.window.setFullscreen then return end
  mode = VideoMode.normalize(mode)
  if mode == "borderless" then
    -- "desktop" = borderless fullscreen matching the display
    love.window.setFullscreen(true, "desktop")
  else
    love.window.setFullscreen(false)
  end
end

function VideoMode.applyOptions(opts)
  VideoMode.apply(opts and opts.videoMode)
end

return VideoMode
