local State = {}

function State.new()
  return {
    data = nil,
    cat = nil,
    events = nil,
    save = nil,
    path = nil,
    dirty = false,
    loadError = false, -- true when the save file exists but failed to decode
    allowSave = true, -- false while loadError, until a successful Reload
    _quitArmed = false,
    tab = "party", -- party|boxes|items|events|map|dex
    status = "",
    selectedParty = 1,
    selectedBox = 1,
    selectedBoxSlot = 1,
    editingMon = nil, -- reference into party or box
    mapId = nil,
    mapCamX = 0,
    mapCamY = 0,
    mapZoom = 2,
  }
end

function State.markDirty(s)
  s.dirty = true
end

return State
