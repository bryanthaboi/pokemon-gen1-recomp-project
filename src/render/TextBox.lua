-- The lower dialogue box: bordered 20x6-tile window, typewriter effect,
-- two visible text lines, A to advance.
--
-- Text markers (from the extractor): \n = second line, \v = scroll one
-- line up, \f = page break (wait for A, clear).  {PLAYER}/{RIVAL} etc. are
-- substituted before display.  Pushed on the state stack; pops itself when
-- the text is exhausted and A is pressed, then calls onDone.

local Font = require("src.render.Font")

local TextBox = {}
TextBox.__index = TextBox

local BOX_TX, BOX_TY, BOX_TW, BOX_TH = 0, 12, 20, 6
local LINE1_Y, LINE2_Y = (BOX_TY + 2) * 8, (BOX_TY + 4) * 8
local TEXT_X = 8
local MAX_COLS = 18

-- opts.choice: when the last page has typed out, a YES/NO ChoiceBox pops
-- up over the still-visible text (YesNoChoicePokeCenter and friends);
-- the box then closes and choice(yes) runs instead of onDone.
-- opts.defaultNo starts the cursor on NO.
-- opts.auto: texts with no `prompt` (a text_asm/text_end tail, like
-- _UsedStrengthText) never wait for a button: once the last page has
-- typed out, auto.sound() runs (returning an audio source blocks like
-- WaitForSoundToFinish; nil headless), then auto.delay frames pass
-- (default 3, Delay3) and the box pops itself + calls onDone.  No
-- blinking cursor, no Press_AB beep.
function TextBox.new(game, text, onDone, opts)
  local self = setmetatable({}, TextBox)
  self.game = game
  self.onDone = onDone
  self.choice = opts and opts.choice
  self.defaultNo = opts and opts.defaultNo
  self.auto = opts and opts.auto
  text = TextBox.substitute(game, text)
  self.pages = TextBox.paginate(text)
  self.pageIndex = 1
  self.lineIndex = 1
  self.charIndex = 0
  self.shown = {} -- visible lines (max 2), each a list of glyph codes
  self.waiting = false
  self.done = false
  self.blink = 0
  self:beginLine()
  return self
end

function TextBox.substitute(game, text)
  local save = game.save
  text = text:gsub("{PLAYER}", save.player.name or "RED")
  text = text:gsub("{RIVAL}", save.player.rival or "BLUE")
  -- wStringBuffer: give_item copies the item name here, like GiveItem ->
  -- CopyToStringBuffer (home/give.asm); "received item!" texts read it
  -- (staying set afterwards mirrors pokered's stale-buffer semantics)
  if game.stringBuffer then
    text = text:gsub("{RAM:wStringBuffer}", game.stringBuffer)
  end
  text = text:gsub("{[%w_:]+}", "") -- other runtime tokens: drop visibly-empty
  return text
end

-- Split marked-up text into pages of lines.  \v-scrolled lines become
-- additional lines on the same page (the box scrolls them).
function TextBox.paginate(text)
  local pages = {}
  for pageText in (text .. "\f"):gmatch("(.-)\f") do
    if pageText ~= "" then
      local lines = {}
      for chunk in (pageText .. "\n"):gmatch("(.-)[\n\v]") do
        local line = chunk
        -- wrap long lines defensively (the source rarely needs it)
        while #line > MAX_COLS do
          local cut = MAX_COLS
          for i = MAX_COLS, 1, -1 do
            if line:sub(i, i) == " " then cut = i break end
          end
          table.insert(lines, line:sub(1, cut))
          line = line:sub(cut + 1)
        end
        table.insert(lines, line)
      end
      -- drop trailing empty line from the final gmatch round
      if lines[#lines] == "" then table.remove(lines) end
      if #lines > 0 then table.insert(pages, lines) end
    end
  end
  if #pages == 0 then pages = { { "" } } end
  return pages
end

function TextBox:currentLine()
  return self.pages[self.pageIndex][self.lineIndex]
end

function TextBox:beginLine()
  self.charIndex = 0
  self.codes = Font.encode(self:currentLine())
  if #self.shown >= 2 then
    table.remove(self.shown, 1)
    self.scrollPx = 8 -- pixel scroll-up (ScrollTextUpOneLine)
  end
  table.insert(self.shown, {})
end

function TextBox:update(dt)
  local input = self.game.input
  self.blink = (self.blink + 1) % 60
  if self.done then
    if self.auto then
      if not self.autoStarted then
        self.autoStarted = true
        self.autoSrc = self.auto.sound and self.auto.sound() or nil
        self.autoTimer = 0
      end
      if self.autoSrc and self.autoSrc.isPlaying and self.autoSrc:isPlaying() then
        return -- the cry is still sounding (WaitForSoundToFinish)
      end
      self.autoTimer = self.autoTimer + 1
      local delay = self.auto.delay or 3
      -- auto.onOverlap: fired once when the delay elapses but before the
      -- box closes, so an overlay (the Pallet "!" bubble) can appear
      -- while the box is still on screen; the box then lingers
      -- auto.overlap more frames before popping (scripts/PalletTown.asm
      -- PalletTownOakText: DelayFrames 10 then EmotionBubble over the
      -- still-shown "Hey! Wait!" box).
      if self.auto.onOverlap and not self.overlapFired
         and self.autoTimer >= delay then
        self.overlapFired = true
        self.auto.onOverlap()
      end
      if self.autoTimer >= delay + (self.auto.overlap or 0) then
        self.game.stack:pop()
        if self.onDone then self.onDone() end
      end
      return
    end
    if self.choice then
      if not self.choicePushed then
        self.choicePushed = true
        local ChoiceBox = require("src.ui.ChoiceBox")
        self.game.stack:push(ChoiceBox.new(self.game, function(yes)
          self.game.stack:pop() -- this text box, under the choice
          self.choice(yes)
        end, { defaultNo = self.defaultNo }))
      end
      return
    end
    if input:wasPressed("a") or input:wasPressed("b") then
      require("src.core.Sound").play(self.game.data, "Press_AB")
      self.game.stack:pop()
      if self.onDone then self.onDone() end
    end
    return
  end
  if self.waiting then
    if input:wasPressed("a") or input:wasPressed("b") then
      require("src.core.Sound").play(self.game.data, "Press_AB")
      self.waiting = false
      self.shown = {}
      self.pageIndex = self.pageIndex + 1
      self.lineIndex = 1
      self:beginLine()
    end
    return
  end
  -- typewriter cadence: one character every N frames, N = the OPTION
  -- text speed (TextSpeedOptionData frame delays 1/3/5); holding A/B
  -- prints every frame like the original's held-button fast path
  local delay = (self.game.save.options and self.game.save.options.textSpeed) or 3
  if delay ~= 1 and delay ~= 3 and delay ~= 5 then delay = 3 end
  if input:isDown("a") or input:isDown("b") then delay = 1 end
  self.charTimer = (self.charTimer or 0) + 1
  while self.charTimer >= delay do
    self.charTimer = self.charTimer - delay
    if self.charIndex < #self.codes then
      self.charIndex = self.charIndex + 1
      local line = self.shown[#self.shown]
      line[#line + 1] = self.codes[self.charIndex]
    else
      -- line finished
      local page = self.pages[self.pageIndex]
      if self.lineIndex < #page then
        self.lineIndex = self.lineIndex + 1
        self:beginLine()
      elseif self.pageIndex < #self.pages then
        self.waiting = true
      else
        self.done = true
      end
      break
    end
  end
end

function TextBox:draw()
  Font.drawBox(BOX_TX, BOX_TY, BOX_TW, BOX_TH)
  love.graphics.setColor(0, 0, 0, 1)
  if self.scrollPx and self.scrollPx > 0 then
    self.scrollPx = self.scrollPx - 2
    if self.scrollPx <= 0 then self.scrollPx = nil end
  end
  local off = self.scrollPx or 0
  local ys = { LINE1_Y, LINE2_Y }
  for i, line in ipairs(self.shown) do
    local y = (ys[i] or LINE2_Y) + off
    for j, code in ipairs(line) do
      Font.drawCode(code, TEXT_X + (j - 1) * 8, y)
    end
  end
  if (self.waiting or (self.done and not self.choice and not self.auto))
     and self.blink < 30 then
    -- page-advance cursor: glyph $EE, the blinking down arrow the original
    -- prints via `ld a, "▼"` (home/text.asm)
    Font.drawCode(0xEE, 18 * 8, (BOX_TY + 5) * 8 - 4)
  end
  love.graphics.setColor(1, 1, 1, 1)
end

return TextBox
