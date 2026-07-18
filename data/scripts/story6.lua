-- Sixth batch of hand-ported map scripts (parity sweep 2026-07-12):
-- the Pokémon Mansion statue switches, the Cinnabar Gym quiz doors,
-- and the Indigo Plateau lobby's Elite Four rematch reset.  Each cites
-- its pokered source.

local M = {}

local function text(game) return game.data.text end

local function push(game, s, done)
  local TextBox = require("src.render.TextBox")
  game.stack:push(TextBox.new(game, s, done))
end

local function ask(game, s, cb)
  local ChoiceBox = require("src.ui.ChoiceBox")
  push(game, s, function() game.stack:push(ChoiceBox.new(game, cb)) end)
end

-- -------------------------------------------------------------------
-- Pokémon Mansion switches (scripts/PokemonMansion1F/2F/3F/B1F.asm):
-- one shared toggle, EVENT_MANSION_SWITCH_ON, flips door/wall blocks
-- on all four floors.  Each floor's Mansion*CheckReplaceSwitchDoorBlocks
-- runs on map load, so the state persists purely through the event
-- flag; pressing a switch toggles it (CheckAndSetEvent/ResetEvent) and
-- reapplies the current floor's blocks.
-- Block ids: $2d horizontal gate (1F/B1F "door" wall), $54 horizontal
-- gate, $5f vertical gate, $e open floor.  Coords below are
-- ReplaceTileBlock's (X, Y) block coordinates (asm passes b=Y, c=X).
-- -------------------------------------------------------------------

-- per floor: { bx, by, offBlock, onBlock }
local MANSION_BLOCKS = {
  POKEMON_MANSION_1F = {
    { 12,  6, 0x0e, 0x2d },
    {  8,  3, 0x2d, 0x0e },
    { 10,  8, 0x2d, 0x0e },
    { 13, 13, 0x2d, 0x0e },
  },
  POKEMON_MANSION_2F = {
    {  4,  2, 0x0e, 0x5f },
    {  9,  4, 0x54, 0x0e },
    {  3, 11, 0x5f, 0x0e },
  },
  POKEMON_MANSION_3F = {
    {  7,  2, 0x0e, 0x5f },
    {  7,  5, 0x5f, 0x0e },
  },
  POKEMON_MANSION_B1F = {
    { 13,  8, 0x0e, 0x2d },
    {  6, 11, 0x0e, 0x5f },
    {  4,  3, 0x5f, 0x0e },
    {  8,  8, 0x54, 0x0e },
  },
}

local function applyMansionBlocks(game, ow)
  local rows = MANSION_BLOCKS[ow.map.id]
  if not rows then return end
  local on = game.save.flags.EVENT_MANSION_SWITCH_ON
  for _, r in ipairs(rows) do
    ow:replaceBlock(r[1], r[2], on and r[4] or r[3])
  end
end

-- switch statues (data/events/hidden_events.asm Mansion*Script_Switches,
-- all facing up); 2F/3F/B1F reuse the 2F switch text in pokered
local function mansionFloor(switchCoords, textPrefix)
  return {
    onEnter = applyMansionBlocks,
    onInteract = function(game, ow, fx, fy)
      if ow.player.facing ~= "up" then return false end
      local hit = false
      for _, c in ipairs(switchCoords) do
        if fx == c[1] and fy == c[2] then hit = true break end
      end
      if not hit then return false end
      local t = text(game)
      ask(game, t[textPrefix .. "SwitchText"] or "A secret switch!\fPress it?",
        function(yes)
          if not yes then
            push(game, t[textPrefix .. "SwitchNotPressedText"]
              or "Not quite yet!")
            return
          end
          local f = game.save.flags
          if f.EVENT_MANSION_SWITCH_ON then
            f.EVENT_MANSION_SWITCH_ON = nil
          else
            f.EVENT_MANSION_SWITCH_ON = true
          end
          require("src.core.Sound").play(game.data, "Go_Inside")
          applyMansionBlocks(game, ow)
          push(game, t[textPrefix .. "SwitchPressedText"] or "Who wouldn't?")
        end)
      return true
    end,
  }
end

M.POKEMON_MANSION_1F = mansionFloor({ { 2, 5 } }, "_PokemonMansion1F")
M.POKEMON_MANSION_2F = mansionFloor({ { 2, 11 } }, "_PokemonMansion2F")
M.POKEMON_MANSION_3F = mansionFloor({ { 10, 5 } }, "_PokemonMansion2F")
M.POKEMON_MANSION_B1F = mansionFloor({ { 20, 3 }, { 18, 25 } },
                                     "_PokemonMansion2F")

-- 3F floor holes (PokemonMansion3FDefaultScript.holeCoords +
-- data/maps/special_warps.asm DungeonWarpData): stepping on a hole
-- drops the player -- (16,14)/(17,14) land on 1F at (16,14), the only
-- way into the sealed basement-stairs room; (19,14) lands on 2F at
-- (18,14).
local MANSION_HOLES = {
  { 16, 14, "POKEMON_MANSION_1F", 16, 14 },
  { 17, 14, "POKEMON_MANSION_1F", 16, 14 },
  { 19, 14, "POKEMON_MANSION_2F", 18, 14 },
}

M.POKEMON_MANSION_3F.onStep = function(game, ow, x, y)
  for _, h in ipairs(MANSION_HOLES) do
    if x == h[1] and y == h[2] then
      ow:startWarpTo(h[3], h[4], h[5], ow.player.facing)
      return true
    end
  end
  return false
end

-- -------------------------------------------------------------------
-- Cinnabar Gym quiz doors (engine/events/hidden_events/
-- cinnabar_gym_quiz.asm + scripts/CinnabarGym.asm): six quiz machines;
-- a correct answer opens that room's gate block, a wrong one plays
-- SFX_DENIED and sics the room's trainer on you.  Beating the trainer
-- (via the quiz or by talking to him) also opens the gate
-- (CinnabarGymOpenGateScript).  Gates persist via per-door event flags.
-- -------------------------------------------------------------------

local GYM_OPEN_BLOCK = 0x0e

-- machine i: quiz tile (x,y), whether YES is correct (answer nibble
-- FALSE = menu item 0 = YES), the gate's block (x,y,closed id) from
-- CinnabarGymGateCoords, and the guarding trainer's object index
-- (wOpponentAfterWrongAnswer = gate index + 2 = SUPER_NERD(i+1))
local GYM_MACHINES = {
  { x = 15, y =  7, yes = true,  gate = { 9, 3, 0x54 }, npc = 3 },
  { x = 10, y =  1, yes = false, gate = { 6, 3, 0x54 }, npc = 4 },
  { x =  9, y =  7, yes = false, gate = { 6, 6, 0x54 }, npc = 5 },
  { x =  9, y = 13, yes = false, gate = { 3, 8, 0x5f }, npc = 6 },
  { x =  1, y = 13, yes = true,  gate = { 2, 6, 0x54 }, npc = 7 },
  { x =  1, y =  7, yes = false, gate = { 2, 3, 0x54 }, npc = 8 },
}

local function gymGateFlag(i)
  return "EVENT_CINNABAR_GYM_GATE" .. (i - 1) .. "_UNLOCKED"
end

local function applyGymGates(game, ow)
  for i, m in ipairs(GYM_MACHINES) do
    local open = game.save.flags[gymGateFlag(i)]
                 or game.save.defeatedTrainers["CINNABAR_GYM_obj_" .. m.npc]
    ow:replaceBlock(m.gate[1], m.gate[2], open and GYM_OPEN_BLOCK or m.gate[3])
  end
end

-- beating a guardian opens his gate like CinnabarGymOpenGateScript
local function syncGymGatesAfterBattle(game, ow)
  for i, m in ipairs(GYM_MACHINES) do
    if game.save.defeatedTrainers["CINNABAR_GYM_obj_" .. m.npc]
       and not game.save.flags[gymGateFlag(i)] then
      game.save.flags[gymGateFlag(i)] = true
      require("src.core.Sound").play(game.data, "Go_Inside")
    end
  end
  applyGymGates(game, ow)
end

M.CINNABAR_GYM = {
  onEnter = applyGymGates,
  onVictory = syncGymGatesAfterBattle,
  onInteract = function(game, ow, fx, fy)
    if ow.player.facing ~= "up" then return false end
    local index, machine
    for i, m in ipairs(GYM_MACHINES) do
      if fx == m.x and fy == m.y then index, machine = i, m break end
    end
    if not machine then return false end
    local t = text(game)
    local Sound = require("src.core.Sound")
    push(game, t._CinnabarGymQuizIntroText
      or "POKéMON Quiz!\fGet it right and\nthe door opens!", function()
      ask(game, t["_CinnabarQuizQuestionsText" .. index] or "Well?",
        function(yes)
          if yes == machine.yes then
            -- CinnabarGymQuizCorrectText: item jingle, then the gate
            -- slides open (SFX_GO_INSIDE) if it was still locked
            Sound.play(game.data, "Get_Item1")
            push(game, t._CinnabarGymQuizCorrectText
              or "You're absolutely\ncorrect!\fGo on through!", function()
              if not game.save.flags[gymGateFlag(index)] then
                game.save.flags[gymGateFlag(index)] = true
                Sound.play(game.data, "Go_Inside")
              end
              applyGymGates(game, ow)
            end)
            return
          end
          Sound.play(game.data, "Denied")
          push(game, t._CinnabarGymQuizIncorrectText or "Sorry! Bad call!",
            function()
              local npc = ow:npcByIndex(machine.npc)
              if npc and not ow:trainerDefeated(npc) then
                ow:engageTrainer(npc, function() end)
              end
            end)
        end)
    end)
    return true
  end,
}

-- -------------------------------------------------------------------
-- Indigo Plateau lobby: the Elite Four rematch reset
-- (scripts/IndigoPlateauLobby.asm: on entry, ResetEvent
-- EVENT_VICTORY_ROAD_1_BOULDER_ON_SWITCH; then, if BIT_STARTED_ELITE_4
-- is set, clear it and ResetEventRange INDIGO_PLATEAU_EVENTS_START ..
-- EVENT_LANCES_ROOM_LOCK_DOOR so the whole league can be re-fought.
-- BIT_STARTED_ELITE_4 is set whenever Lorelei's room loads
-- (LoreleiShowOrHideExitBlock).
-- -------------------------------------------------------------------

-- constants/event_constants.asm $8E0..EVENT_LANCES_ROOM_LOCK_DOOR
local E4_RESET_FLAGS = {
  "EVENT_BEAT_LORELEIS_ROOM_TRAINER_0", "EVENT_AUTOWALKED_INTO_LORELEIS_ROOM",
  "EVENT_BEAT_BRUNOS_ROOM_TRAINER_0", "EVENT_AUTOWALKED_INTO_BRUNOS_ROOM",
  "EVENT_BEAT_AGATHAS_ROOM_TRAINER_0", "EVENT_AUTOWALKED_INTO_AGATHAS_ROOM",
  "EVENT_BEAT_LANCES_ROOM_TRAINER_0", "EVENT_BEAT_LANCE",
  "EVENT_LANCES_ROOM_LOCK_DOOR",
  -- port-side: the run-scoped champion gate (EVENT_BEAT_CHAMPION_RIVAL
  -- itself stays set, like pokered's out-of-range flag)
  "EVENT_BEAT_CHAMPION_RIVAL_THIS_RUN",
}

local E4_TRAINER_KEYS = {
  "LORELEIS_ROOM_obj_1", "BRUNOS_ROOM_obj_1",
  "AGATHAS_ROOM_obj_1", "LANCES_ROOM_obj_1",
}

M.INDIGO_PLATEAU_LOBBY = {
  onEnter = function(game, ow)
    local f = game.save.flags
    f.EVENT_VICTORY_ROAD_1_BOULDER_ON_SWITCH = nil
    -- old saves from before EVENT_STARTED_ELITE_4 existed derive it
    -- from the run's progress flags
    local started = f.EVENT_STARTED_ELITE_4
    if not started then
      for _, flag in ipairs(E4_RESET_FLAGS) do
        if f[flag] then started = true break end
      end
    end
    if not started then return end
    f.EVENT_STARTED_ELITE_4 = nil
    for _, flag in ipairs(E4_RESET_FLAGS) do f[flag] = nil end
    for _, key in ipairs(E4_TRAINER_KEYS) do
      game.save.defeatedTrainers[key] = nil
    end
  end,
}

-- Lorelei's room load marks the challenge as started (the wElite4Flags
-- bit in LoreleiShowOrHideExitBlock); the exit-seal onEnter from
-- story4.lua still runs
local loreleisRoom = require("data.scripts.story4").LORELEIS_ROOM
local loreleiSeal = loreleisRoom.onEnter
M.LORELEIS_ROOM = {
  onEnter = function(game, ow)
    game.save.flags.EVENT_STARTED_ELITE_4 = true
    loreleiSeal(game, ow)
  end,
}

return M
