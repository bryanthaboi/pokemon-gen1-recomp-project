-- "Pallet Rain": a two-pulse loop authored in the ChipAsm note-event DSL
-- (13-audio-modding.md).  ChipAsm is on the loader's supported-require
-- list, so authoring a song needs no permissions.
--
-- The assembler is the validator: an out-of-range length or an unknown
-- note name raises here, at load, naming the channel and event index --
-- not silently at playback.
local ChipAsm = require("src.audio.ChipAsm")

return ChipAsm.song{
  tempo = 0x120,
  channels = {
    -- lead: a four-bar descending figure that loops forever
    { hw = 1, program = {
      { duty = 2 },
      { notetype = { speed = 12, volume = 11, fade = 2 } },
      { octave = 4 },
      { label = "lead" },
      { note = "E", len = 6 }, { note = "D", len = 2 },
      { note = "C", len = 6 }, { rest = 2 },
      { note = "A", len = 4 }, { note = "G", len = 4 },
      { note = "C", len = 8 },
      { note = "E", len = 6 }, { note = "G", len = 2 },
      { note = "A", len = 8 },
      { rest = 8 },
      { loop = { count = 0, to = "lead" } },
    } },
    -- counter-line: same length, one octave down, softer
    { hw = 2, program = {
      { duty = 1 },
      { notetype = { speed = 12, volume = 7, fade = 1 } },
      { octave = 3 },
      { label = "bass" },
      { note = "C", len = 8 }, { note = "G", len = 8 },
      { note = "A", len = 8 }, { note = "F", len = 8 },
      { note = "C", len = 8 }, { note = "G", len = 8 },
      { loop = { count = 0, to = "bass" } },
    } },
  },
}
