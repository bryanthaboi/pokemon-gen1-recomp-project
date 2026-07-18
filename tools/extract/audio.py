"""Convert pret/pokered music into playable WAV files.

Sources:
  audio/headers/musicheaders*.asm -> song -> channel command streams
  audio/music/*.asm               -> the note/command data
  audio/notes.asm                 -> pitch table
  audio/wave_samples.asm          -> channel-3 wave instruments
  data/maps/songs.asm             -> map -> song assignment
  audio/engine_1.asm              -> timing/frequency semantics (ported)

Semantics ported from the sound engine (asm refs are audio/engine_1.asm):
  note delay frames   = length * speed * tempo / 0x100   (60 fps)
  frequency register  = (pitches[note] asr (octaveArg - 1)) & 0x7FF
  square channels     f = 131072 / (2048 - reg)
  wave channel (ch3)  f = 65536 / (2048 - reg)
  envelope            note_type volume/fade like NRx2 (step = fade/64s)

  vibrato delay, depth, rate (Audio1_vibrato l.384, apply l.88-142):
    after `delay` frames from each note start the frequency register LOW
    byte alternates between reg+above and reg-below where
    above = depth/2 + depth%2, below = depth/2 (clamped to 0..$ff, high
    byte untouched), toggling once every rate+1 frames.  Approximations:
    the engine's rate counter persists across notes; we restart it per
    note (first toggle at frame delay+rate, then every rate+1 frames).

  pitch_slide length, octave, note (Audio1_pitch_slide l.432,
    Audio1_InitPitchSlideVars l.1140, Audio1_ApplyPitchSlide l.1036):
    the next note's frequency register ramps linearly from its own value
    to the target note's register over (noteFrames - (length-1)) frames
    (min 1) and then holds the target.  The engine steps by
    ceil(diff/duration) per frame (and has a borrow bug for increasing
    slides); we use an exact linear ramp instead.

  duty_cycle_pattern a,b,c,d (Audio1_duty_cycle_pattern l.530,
    Audio1_ApplyDutyCyclePattern l.1239): the pulse width cycles
    a,b,c,d,a,... one step per 60 Hz frame.  Approximation: the engine's
    2-bit rotation is aligned to the global frame counter; we align the
    cycle to each note's start.

  wave instruments (Audio1_note_type l.328-368,
    Audio1_ApplyWavePatternAndFrequency l.906, audio/wave_samples.asm):
    on ch3 note_type's second byte is (volume << 4) | instrument; the
    low nibble selects one of the 32x4-bit wave RAM instruments and
    (volume & 3) maps to output level 0/100%/50%/25% like NR32.  Waves
    0-4 are parsed from audio/wave_samples.asm; instruments 5-8 point at
    garbage ("reads from sfx data") whose effective per-engine contents
    are documented in that file's comments and hardcoded here (engine 1
    is used by Lavender Town, engine 3 by Pokemon Tower).  The engine
    bank (1/2/3) is taken from the header file the song came from.

  toggle_perfect_pitch (Audio1_toggle_perfect_pitch l.372, apply l.831):
    while enabled every note's frequency register is incremented by 1.

  stereo_panning left, right (Audio1_stereo_panning l.505,
    Audio1_EnableChannelOutput l.844): writes an NR51-style mask
    (high nibble = left enables, low nibble = right enables, bit n =
    channel n+1, default $ff).  Songs are rendered as stereo WAVs; each
    note event is placed left/right per the mask in effect at its start
    time (the engine also re-applies at note starts).  The mask is
    global; pan events from any channel affect all channels.  SFX and
    cries stay mono (none of them pan).

  global tempo (Audio1_tempo l.476): wMusicTempo is shared by all four
    music channels but the commands appear only on Ch1; every song is
    interpreted with a shared tempo timeline built from a first pass
    (periodically extended for tempo changes inside a loop body, e.g.
    Dungeon3's accelerando).  On sfx channels the engine overwrites
    wSfxTempo on every note (Audio1_SetSfxTempo l.957), making tempo
    commands in sfx data inert -- they are ignored, and a cry's tempo
    modifier is not applied to its noise channel (CHAN8 skips
    SetSfxTempo, l.714).

  seamless loops: channel time is tracked in exact integer ticks
    (1/15360 s = 1/256 frame), so loop bodies and sample placement have
    no float drift.  A song with an infinite sound_loop is rendered as
    two files, <song>.wav (the intro: everything before the global loop
    point) and <song>_loop.wav (one loop body whose length is the exact
    LCM of all channels' body lengths, so every channel realigns at the
    seam).  Per channel the loop starts at the loop target label if the
    first traversal already matches the second, otherwise the first
    traversal is absorbed into the intro (engine state carried into the
    loop, verified event-by-event over three probe traversals).
    One-shot channels (e.g. Dungeon3 drums) push the loop point past
    their end.  audio.lua song entries carry file/seconds/loopFile/
    loopSeconds and intro = true when a separate intro file exists;
    zero-length intros collapse to a single seamlessly looping file.
    If bodies cannot align (unsteady state, LCM beyond MAX_SECONDS, or
    a loop length that is not a whole number of samples: 512 ticks =
    735 samples) the song falls back to the old single-file whole
    render with a warning (Lavender, CinnabarMansion, Dungeon3 and
    SilphCo fall back).

Cry engine: PlayCry loads the species' pitch into wFrequencyModifier
(added to every frequency register write, Audio1_ApplyFrequencyModifier
l.978) and its length into wTempoModifier (sfx tempo = $80 + length,
Audio1_SetSfxTempo l.957).  The frequency modifier is now also applied
to `note` commands (execute_music cries), not just square_note.

Still approximated / not honored:
  - noise channel: white-noise bursts with a fixed decay instead of the
    GB LFSR noise instruments (drum_note instruments all sound alike)
  - pitch_sweep (NR10 hardware sweep, SFX only) is ignored
  - master `volume` command (always 7,7 in practice) is ignored
  - vibrato is suppressed while a pitch slide is active (engine-correct)
    but the engine's cross-note vibrato phase is not kept
  - duty pattern rotation phase is per-note, not global
  - envelopes restart per note event; hardware length counters ignored

Determinism: no wall clock and no shared RNG state; noise bursts are
seeded per-event from (volume, sample count) so identical events render
identically (this also keeps loop bodies periodic).

Output:
  assets/generated/audio/music/<song>.wav       (22050 Hz stereo 16-bit)
  assets/generated/audio/music/<song>_loop.wav  (loop body, if any)
  assets/generated/audio/sfx/<name>.wav         (mono)
  assets/generated/audio/cries/<species>.wav    (mono)
  data/generated/audio.lua
"""

import math
import os
import re
import wave

import numpy as np

from . import util
from .util import parse_number, read_asm, split_args, warn

SAMPLE_RATE = 22050
FRAME = 1.0 / 60.0
MAX_SECONDS = 150

# All engine note durations are integer multiples of 1/256 frame
# (length * speed * tempo / 0x100 frames at 60 fps), so channel time is
# tracked in integer "ticks" of 1/15360 s.  This keeps loop bodies and
# sample placement exact -- no float drift across loop iterations.
TICKS_PER_SECOND = 256 * 60
FRAME_TICKS = 256
MAX_TICKS = MAX_SECONDS * TICKS_PER_SECOND


def snap(ticks):
    """Tick time -> sample index (round half up), in exact integer math:
    samples = ticks * 22050 / 15360 = ticks * 735 / 512."""
    return (ticks * 735 + 256) // 512

PITCHES = [0xF82C, 0xF89D, 0xF907, 0xF96B, 0xF9CA, 0xFA23,
           0xFA77, 0xFAC7, 0xFB12, 0xFB58, 0xFB9B, 0xFBDA]
NOTE_INDEX = {n: i for i, n in enumerate(
    ["C_", "C#", "D_", "D#", "E_", "F_", "F#", "G_", "G#", "A_", "A#", "B_"])}

DUTY = {0: 0.125, 1: 0.25, 2: 0.5, 3: 0.75}

# NR32-style wave channel output level: (note_type volume & 3)
WAVE_LEVEL = {0: 0.0, 1: 1.0, 2: 0.5, 3: 0.25}

# Effective contents of ".wave5" (instrument indexes 5-8) per audio
# engine bank; the pointers target sfx data, the values below are the
# ones documented in audio/wave_samples.asm's comments.
WAVE5 = {
    1: [2, 1, 14, 2, 3, 3, 2, 8, 14, 1, 2, 2, 15, 15, 14, 10,
        1, 0, 1, 4, 13, 12, 1, 0, 14, 3, 4, 1, 5, 1, 7, 3],
    2: [14, 12, 0, 2, 2, 0, 9, 1, 0, 7, 12, 0, 2, 0, 8, 1,
        0, 7, 13, 0, 2, 0, 9, 1, 0, 7, 12, 0, 2, 12, 10, 1],
    3: [2, 1, 14, 2, 3, 3, 2, 8, 14, 1, 2, 2, 15, 15, 2, 2,
        15, 7, 2, 4, 2, 2, 15, 7, 3, 4, 2, 4, 15, 7, 4, 4],
}


def parse_wave_instruments(pokered):
    """audio/wave_samples.asm -> bank (1..3) -> list of 9 waveforms,
    each a float32 array of 32 samples in [-1, 1]."""
    base_waves = []
    path = os.path.join(pokered, "audio/wave_samples.asm")
    for lineno, line in read_asm(path):
        s = line.strip()
        m = re.match(r"dn\s+(.*)$", s)
        if m:
            vals = [parse_number(v) for v in split_args(m.group(1))]
            if len(vals) == 32:
                base_waves.append(vals)
    if len(base_waves) < 5:
        warn("audio: wave_samples.asm: expected 5 wave instruments, "
             f"got {len(base_waves)}")
        while len(base_waves) < 5:
            base_waves.append(list(range(0, 16)) + list(range(15, -1, -1)))

    def to_signal(nibbles):
        return np.array([(v - 7.5) / 7.5 for v in nibbles], dtype=np.float32)

    banks = {}
    for bank in (1, 2, 3):
        waves = [to_signal(w) for w in base_waves[:5]]
        waves += [to_signal(WAVE5[bank])] * 4  # indexes 5-8 all alias wave5
        banks[bank] = waves
    return banks


def parse_headers(pokered, prefix="musicheaders", label_prefix="Music_"):
    """Music_X / SFX_X -> (ordered channel labels, bank number)."""
    songs = {}
    banks = {}
    hdr_dir = os.path.join(pokered, "audio/headers")
    for fname in sorted(os.listdir(hdr_dir)):
        if not fname.startswith(prefix):
            continue
        m = re.search(r"(\d+)\.asm$", fname)
        bank = int(m.group(1)) if m else 1
        current = None
        for lineno, line in read_asm(os.path.join(hdr_dir, fname)):
            s = line.strip()
            m = re.match(rf"({label_prefix}\w+)::?\s*$", s)
            if m:
                current = m.group(1)
                songs[current] = []
                banks[current] = bank
                continue
            m = re.match(r"channel\s+(\d+),\s*(\w+)", s)
            if m and current:
                songs[current].append((int(m.group(1)), m.group(2)))
    return songs, banks


def parse_music_files_dir(path_or_file):
    """Parse one asm file of audio command streams."""
    streams = {}
    current = None
    for lineno, line in read_asm(path_or_file):
        s = line.strip()
        if not s:
            continue
        m = re.match(r"(\w+)::?\s*$", s)
        if m:
            current = m.group(1)
            streams[current] = []
            continue
        m = re.match(r"\.(\w+):?\s*$", s)
        if m and current:
            streams[current].append(("label", f"{current}.{m.group(1)}"))
            continue
        m = re.match(r"(\w+)(?:\s+(.*))?$", s)
        if m and current:
            args = [a.strip() for a in split_args(m.group(2) or "") if a.strip()]
            streams[current].append((m.group(1), args))
    return streams


def parse_music_files(pokered):
    """All command streams: label -> list of (cmd, args); local .labels are
    stored as ("label", "GlobalLabel.local")."""
    streams = {}   # label -> command list (with label markers inline)
    music_dir = os.path.join(pokered, "audio/music")
    for fname in sorted(os.listdir(music_dir)):
        if not fname.endswith(".asm"):
            continue
        streams.update(parse_music_files_dir(os.path.join(music_dir, fname)))
    return streams


def signed_nibble(raw):
    """Assemble a fade/instrument arg the way the macros do: negative n
    becomes %1000 | -n (signed magnitude)."""
    return (0b1000 | -raw) if raw < 0 else raw


class Channel:
    """Interprets one channel's command stream into note events.

    All times/durations are integer ticks (1/15360 s).  freq_offset /
    frame_ticks implement the cry engine: PlayCry loads the species'
    pitch into wFrequencyModifier (added to every frequency register,
    Audio1_ApplyFrequencyModifier) and its length into wTempoModifier
    (sfx tempo = $80 + length ticks per frame, Audio1_SetSfxTempo).
    """

    def __init__(self, streams, label, is_wave, is_noise,
                 freq_offset=0, frame_ticks=FRAME_TICKS,
                 tempo_timeline=None, is_sfx=False):
        self.streams = streams
        self.label = label
        self.is_wave = is_wave
        self.is_noise = is_noise
        self.freq_offset = freq_offset
        # ticks per sfx frame: 256 nominally, 0x80 + cry length for cries
        self.frame_ticks = frame_ticks
        # wMusicTempo is global: usually only Ch1 issues tempo commands
        # but they drive every music channel.  A channel run with a
        # tempo_timeline follows it; one run without records its own
        # tempo commands into tempo_events so the timeline can be built.
        self.tempo_timeline = tempo_timeline
        self.tempo_events = []
        self._tempo_idx = 0
        # the engine resets wSfxTempo on every sfx-channel note
        # (Audio1_SetSfxTempo), so tempo commands in sfx data are inert
        self.is_sfx = is_sfx
        self.events = []       # list of event dicts (see emit_tone)
        self.time = 0          # integer ticks (1/15360 s)
        self.tempo = 0x100
        self.speed = 12
        self.volume = 12
        self.fade = 0
        self.duty = 0.5        # float, or 4-tuple for duty_cycle_pattern
        self.octave = 4
        self.wave_inst = 0     # ch3 instrument (note_type low nibble)
        self.wave_level = 1.0  # ch3 output level (note_type volume & 3)
        self.perfect_pitch = False
        self.vib = None        # (delay_frames, above, below, rate)
        self.pending_slide = None  # (length_arg, target_reg)
        self.pan_events = []   # (time, left_mask, right_mask)
        self.label_times = {}  # label -> time of first crossing
        self.loop_time = None        # time when the infinite sound_loop runs
        self.loop_start_time = None  # first crossing of its target label
        self.infinite_times = []     # time at each infinite sound_loop hit

    def note_ticks(self, length):
        tl = self.tempo_timeline
        if tl:
            while self._tempo_idx < len(tl) \
                    and tl[self._tempo_idx][0] <= self.time:
                self.tempo = tl[self._tempo_idx][1]
                self._tempo_idx += 1
        # length * speed * tempo / 256 frames = length * speed * tempo ticks
        return length * self.speed * self.tempo

    def emit_tone(self, dur, reg, vol=None, fade=None):
        ev = {
            "t": self.time, "dur": dur, "reg": reg,
            "vol": self.volume if vol is None else vol,
            "fade": self.fade if fade is None else fade,
            "duty": self.duty,
            "vib": None if self.pending_slide else self.vib,
            "slide": None,
            "wave_inst": self.wave_inst,
            "wave_level": self.wave_level,
        }
        if self.pending_slide:
            length_arg, target = self.pending_slide
            note_frames = dur / FRAME_TICKS
            slide_frames = max(1.0, note_frames - (length_arg - 1))
            ev["slide"] = (target, slide_frames)
            self.pending_slide = None
        self.events.append(ev)

    def emit_noise(self, dur, vol):
        self.events.append({"t": self.time, "dur": dur, "reg": None,
                            "vol": vol, "fade": 2, "duty": None,
                            "vib": None, "slide": None,
                            "wave_inst": 0, "wave_level": 0.0})

    def run(self, target_time=None, iterations=2, max_ticks=MAX_TICKS):
        """Interpret until the infinite loop completes `iterations` times
        (or the stream ends).  If target_time (ticks) is set, keep
        looping the body until reaching it instead."""
        prog, labels = self.flatten()
        pc = 0
        call_stack = []
        loop_counts = {}
        infinite_seen = 0
        last_loop_time = -1
        guard = 0
        while pc < len(prog) and self.time < max_ticks:
            guard += 1
            if guard > 5_000_000:
                warn(f"audio: {self.label}: runaway stream")
                break
            cmd, args = prog[pc]
            pc += 1
            if cmd == "label":
                self.label_times.setdefault(args, self.time)
                continue
            if cmd == "square_note":
                # sfx: length (frames-1), volume, fade, raw frequency register
                dur = (parse_number(args[0]) + 1) * self.frame_ticks
                reg = (parse_number(args[3]) + self.freq_offset) & 0x7FF
                self.emit_tone(dur, reg, vol=parse_number(args[1]),
                               fade=parse_number(args[2]))
                self.time += dur
                continue
            if cmd == "noise_note":
                dur = (parse_number(args[0]) + 1) * self.frame_ticks
                self.emit_noise(dur, parse_number(args[1]))
                self.time += dur
                continue
            if cmd == "tempo":
                if self.is_sfx or self.tempo_timeline is not None:
                    pass  # inert on sfx; music follows the shared timeline
                else:
                    self.tempo = parse_number(args[0])
                    self.tempo_events.append((self.time, self.tempo))
            elif cmd == "note_type":
                self.speed = parse_number(args[0])
                if self.is_wave:
                    # ch3: volume & 3 -> NR32 level, low nibble -> instrument
                    self.wave_level = WAVE_LEVEL[parse_number(args[1]) & 3]
                    self.wave_inst = signed_nibble(parse_number(args[2])) & 0xF
                else:
                    self.volume = parse_number(args[1])
                    self.fade = parse_number(args[2])
            elif cmd == "drum_speed":
                self.speed = parse_number(args[0])
            elif cmd == "octave":
                self.octave = parse_number(args[0])
            elif cmd == "duty_cycle":
                self.duty = DUTY.get(parse_number(args[0]), 0.5)
            elif cmd == "duty_cycle_pattern":
                self.duty = tuple(DUTY.get(parse_number(a) & 3, 0.5)
                                  for a in args[:4])
            elif cmd == "vibrato":
                delay = parse_number(args[0])
                depth = parse_number(args[1]) & 0xF
                rate = parse_number(args[2]) & 0xF
                if depth == 0:
                    self.vib = None
                else:
                    above = (depth >> 1) + (depth & 1)
                    below = depth >> 1
                    self.vib = (delay, above, below, rate)
            elif cmd == "pitch_slide":
                # pitch_slide length, octave, note -> applies to next note
                length_arg = parse_number(args[0])
                idx = NOTE_INDEX.get(args[2])
                if idx is not None:
                    target = self.freq_reg(idx, octave=parse_number(args[1]))
                    self.pending_slide = (max(1, length_arg), target)
            elif cmd == "toggle_perfect_pitch":
                self.perfect_pitch = not self.perfect_pitch
            elif cmd == "stereo_panning":
                self.pan_events.append((self.time,
                                        parse_number(args[0]) & 0xF,
                                        parse_number(args[1]) & 0xF))
            elif cmd == "note":
                dur = self.note_ticks(parse_number(args[1]))
                idx = NOTE_INDEX.get(args[0])
                if idx is not None and not self.is_noise:
                    self.emit_tone(dur, self.freq_reg(idx))
                elif self.is_noise:
                    self.emit_noise(dur, self.volume)
                self.time += dur
            elif cmd == "drum_note":
                dur = self.note_ticks(parse_number(args[1]))
                self.emit_noise(dur, 13)
                self.time += dur
            elif cmd == "rest":
                self.time += self.note_ticks(parse_number(args[0]))
            elif cmd == "sound_loop":
                count = parse_number(args[0])
                target = args[1]
                if count == 0:
                    if self.loop_time is None:
                        self.loop_time = self.time
                        self.loop_start_time = self.label_times.get(target)
                    self.infinite_times.append(self.time)
                    infinite_seen += 1
                    progressing = self.time > last_loop_time
                    last_loop_time = self.time
                    if target_time is not None:
                        if self.time < target_time and progressing \
                           and target in labels:
                            pc = labels[target]
                        # else: fall through (stop)
                    elif infinite_seen < iterations and progressing \
                            and target in labels:
                        pc = labels[target]
                    # else: fall through (stop)
                else:
                    key = pc
                    loop_counts.setdefault(key, count)
                    loop_counts[key] -= 1
                    if loop_counts[key] > 0:
                        pc = labels[target]
                    else:
                        del loop_counts[key]
            elif cmd == "sound_call":
                call_stack.append(pc)
                pc = labels[args[0]]
            elif cmd == "sound_ret":
                if call_stack:
                    pc = call_stack.pop()
                else:
                    break
            elif cmd in ("volume", "execute_music", "pitch_sweep",
                         "sfx_note", "unknownsfx0x20", "set_instrument",
                         "unknownmusic0xef"):
                pass  # unsupported nuances; documented in module docstring
            else:
                warn(f"audio: {self.label}: unhandled command {cmd}")
        return self.events

    def freq_reg(self, note_idx, octave=None):
        pitch = PITCHES[note_idx]
        # arithmetic shift right (oct - 1) times on a signed 16-bit value
        val = pitch - 0x10000  # negative
        shifts = max(0, (self.octave if octave is None else octave) - 1)
        val >>= shifts  # python >> on negative = arithmetic
        reg = val & 0x7FF
        if self.perfect_pitch:
            reg = (reg + 1) & 0x7FF
        # cry frequency modifier (Audio1_ApplyFrequencyModifier)
        return (reg + self.freq_offset) & 0x7FF

    def flatten(self):
        """Inline program: own stream; labels map name -> pc.  sound_call /
        sound_loop targets may live in other global labels of the file."""
        prog = []
        labels = {}
        seen = set()

        def add_stream(name):
            if name in seen or name not in self.streams:
                return
            seen.add(name)
            labels[name] = len(prog)
            prog.append(("label", name))
            for cmd, args in self.streams[name]:
                if cmd == "label":
                    labels[args] = len(prog)
                    prog.append(("label", args))
                else:
                    prog.append((cmd, args))
            prog.append(("sound_ret", []))

        add_stream(self.label)
        # add any referenced global labels (subroutine sharing)
        changed = True
        while changed:
            changed = False
            for cmd, args in list(prog):
                if cmd in ("sound_call", "sound_loop"):
                    target = args[-1]
                    base = target.split(".")[0]
                    if not target.startswith(".") and base not in seen \
                       and base in self.streams:
                        add_stream(base)
                        changed = True
        # fix references: sound_loop/sound_call args ".x" -> "Label.x"
        fixed = []
        cur_global = self.label
        for cmd, args in prog:
            if cmd == "label" and "." not in args:
                cur_global = args
            if cmd in ("sound_call", "sound_loop"):
                args = list(args)
                if args[-1].startswith("."):
                    args[-1] = f"{cur_global}{args[-1]}"
                fixed.append((cmd, args))
            else:
                fixed.append((cmd, args))
        return fixed, labels


def _tone_signal(ev, is_wave, waves, count):
    """Per-sample signal for one tone event (before envelope/level)."""
    base = ev["reg"]
    duty = ev["duty"]
    tt = np.arange(count, dtype=np.float64) / SAMPLE_RATE
    need_frames = (ev["vib"] is not None or ev["slide"] is not None
                   or isinstance(duty, tuple))
    frames = None
    if need_frames:
        frames = np.floor(tt * 60.0).astype(np.int64)
        reg = np.full(count, float(base))
        if ev["slide"] is not None:
            target, slide_frames = ev["slide"]
            reg = base + (target - base) * np.minimum(
                1.0, frames / max(1.0, slide_frames))
        elif ev["vib"] is not None:
            delay, above, below, rate = ev["vib"]
            lo = base & 0xFF
            hi = base & 0x700
            up = hi | min(0xFF, lo + above)
            dn = hi | max(0, lo - below)
            toggles = np.maximum(0, frames - delay + 1) // (rate + 1)
            reg = np.where(toggles == 0, float(base),
                           np.where(toggles % 2 == 1, float(up), float(dn)))
        freq = 131072.0 / (2048.0 - np.minimum(reg, 2047.0))
        if is_wave:
            freq *= 0.5
        phase = np.cumsum(freq) / SAMPLE_RATE
        phase -= phase[0]  # start at phase 0 like the constant path
    else:
        freq = 131072.0 / (2048 - base)
        if is_wave:
            freq *= 0.5
        phase = tt * freq
    pfrac = phase % 1.0
    if is_wave:
        wf = waves[min(ev["wave_inst"], len(waves) - 1)] if waves else None
        if wf is None:  # no wave table: triangle fallback
            sig = (2.0 * np.abs(2.0 * pfrac - 1.0) - 1.0)
        else:
            idx = np.minimum((pfrac * 32).astype(np.int64), 31)
            sig = wf[idx].astype(np.float64)
    else:
        if isinstance(duty, tuple):
            dc = np.asarray(duty, dtype=np.float64)[frames % 4]
        else:
            dc = duty
        sig = np.where(pfrac < dc, 1.0, -1.0)
    return sig.astype(np.float32), tt.astype(np.float32)


def synthesize(events, is_wave, is_noise, total_ticks,
               waves=None, pans=None):
    """Render events to a float32 buffer (times/durations in ticks).

    pans: optional list of (gainL, gainR) parallel to events; when given
    the result is (n, 2) stereo, otherwise (n,) mono.
    """
    n = snap(total_ticks)
    stereo = pans is not None
    out = np.zeros((n, 2) if stereo else n, dtype=np.float32)

    def add(start, count, sig, gains):
        if stereo:
            gl, gr = gains
            if gl:
                out[start:start + count, 0] += sig * gl
            if gr:
                out[start:start + count, 1] += sig * gr
        else:
            out[start:start + count] += sig

    for i, ev in enumerate(events):
        t, dur, reg, vol = ev["t"], ev["dur"], ev["reg"], ev["vol"]
        start = snap(t)
        count = snap(t + dur) - start  # events butt with no gap/overlap
        if start >= n or count <= 0:
            continue
        count = min(count, n - start)
        gains = pans[i] if stereo else None
        if reg is None:  # noise burst (per-event deterministic seed)
            rng = np.random.default_rng(0x9E3779B1 ^ (vol * 1000003 + count))
            tt = np.arange(count, dtype=np.float32) / SAMPLE_RATE
            sig = rng.uniform(-1, 1, count).astype(np.float32)
            dur_s = dur / TICKS_PER_SECOND
            env = np.maximum(0.0, 1.0 - tt / max(1e-3, min(dur_s, 0.18)))
            add(start, count, 0.35 * sig * env * (vol / 15.0), gains)
            continue
        if reg >= 2048:
            continue
        sig, tt = _tone_signal(ev, is_wave, waves, count)
        if is_wave:
            add(start, count, 0.55 * ev["wave_level"] * sig, gains)
            continue
        # NRx2-style envelope: volume steps down (or up) every fade/64 s
        fade = ev["fade"]
        env = np.full(count, vol / 15.0, dtype=np.float32)
        if fade and fade > 0:
            step = fade / 64.0
            env = np.maximum(0.0, (vol - np.floor(tt / step)) / 15.0) \
                .astype(np.float32)
        elif fade and fade < 0:
            step = -fade / 64.0
            env = (np.minimum(15.0, (vol + np.floor(tt / step)))
                   .astype(np.float32) / 15.0)
        add(start, count, 0.5 * sig * env, gains)
    return out


def write_wav(path, data):
    """data: (n,) mono or (n, 2) stereo float32 in [-1, 1]."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    peak = np.max(np.abs(data)) if data.size else 1.0
    if peak > 1.0:
        data = data / peak
    pcm = (data * 32000).astype(np.int16)
    with wave.open(path, "wb") as f:
        f.setnchannels(2 if pcm.ndim == 2 else 1)
        f.setsampwidth(2)
        f.setframerate(SAMPLE_RATE)
        f.writeframes(pcm.tobytes())


def pan_gains(pan_timeline, t, chan_num):
    """Left/right gains for music channel chan_num (1-4) at tick time t."""
    left, right = 0xF, 0xF
    for pt, pl, pr in pan_timeline:
        if pt <= t:
            left, right = pl, pr
        else:
            break
    bit = 1 << (chan_num - 1)
    return (1.0 if left & bit else 0.0, 1.0 if right & bit else 0.0)


def _events_periodic(p, start, body):
    """True if the two consecutive body traversals at [start, start+body)
    and [start+body, start+2*body) produced identical events (channel
    state carried across the loop seam is steady)."""
    t1 = start + body
    if p.time < start + 2 * body:
        return False  # probe did not run far enough to verify
    ev1 = [e for e in p.events if start <= e["t"] < t1]
    ev2 = [e for e in p.events if t1 <= e["t"] < t1 + body]
    if len(ev1) != len(ev2):
        return False
    for a, b in zip(ev1, ev2):
        if b["t"] - body != a["t"] or b["dur"] != a["dur"]:
            return False
        for k in ("reg", "vol", "fade", "duty", "vib", "slide",
                  "wave_inst", "wave_level"):
            if a[k] != b[k]:
                return False
    return True


def plan_song_loop(song, probes):
    """Decide the intro/loop split for a song.

    probes: list of (num, label, Channel) after a plain run().
    Returns (intro_seconds, loop_seconds) or None for a single-file
    render.  See the module docstring for the alignment rules.
    """
    loopers = [(n, l, p) for n, l, p in probes if p.loop_time is not None]
    if not loopers:
        return None
    intro = 0
    bodies = []
    for num, label, p in loopers:
        if p.loop_start_time is None:
            warn(f"audio: {song}: loop target of {label} never crossed; "
                 "single-file fallback")
            return None
        body = p.loop_time - p.loop_start_time
        if body <= 0:
            continue  # channel just holds at its loop point
        if _events_periodic(p, p.loop_start_time, body):
            start = p.loop_start_time  # steady from the loop label itself
        elif _events_periodic(p, p.loop_time, body):
            # first pass differs (state carried into the loop); absorb it
            # into the intro and loop from the second pass onward
            start = p.loop_time
        else:
            warn(f"audio: {song}: {label} loop body not steady; "
                 "single-file fallback")
            return None
        intro = max(intro, start)
        bodies.append(body)
    if not bodies:
        return None
    for num, label, p in probes:
        # one-shot channels (e.g. Dungeon3's drums) simply end; the loop
        # begins once they have finished
        if p.loop_time is None:
            intro = max(intro, p.time)
    # align all channel bodies (exact integer tick LCM)
    loop_ticks = bodies[0]
    for b in bodies[1:]:
        loop_ticks = loop_ticks * b // math.gcd(loop_ticks, b)
    # the loop body must span a whole number of samples so it repeats on
    # the sample grid: samples = ticks * 735 / 512, so 512 | loop_ticks
    while loop_ticks % 512 and intro + 2 * loop_ticks <= MAX_TICKS:
        loop_ticks *= 2
    if loop_ticks % 512:
        warn(f"audio: {song}: loop body does not fit the sample grid; "
             "single-file fallback")
        return None
    if intro + loop_ticks > MAX_TICKS:
        warn(f"audio: {song}: loop bodies only align after "
             f"{loop_ticks / TICKS_PER_SECOND:.1f}s; single-file fallback")
        return None
    return intro, loop_ticks


def build_tempo_timeline(channels_pass1):
    """Shared wMusicTempo timeline from every channel's standalone run.

    Tempo commands inside a loop body (e.g. Dungeon3's accelerando) are
    re-issued each traversal by the engine, so those entries are
    replicated periodically out to the probe horizon."""
    events = []
    horizon = 3 * MAX_TICKS + 1
    for p in channels_pass1:
        evs = p.tempo_events
        if p.loop_time is not None:
            evs = [(t, v) for t, v in evs if t < p.loop_time]
        events.extend(evs)
        if p.loop_time is not None and p.loop_start_time is not None:
            body = p.loop_time - p.loop_start_time
            inside = [(t, v) for t, v in evs if t >= p.loop_start_time]
            if body > 0 and inside:
                k = 1
                while p.loop_start_time + k * body < horizon:
                    events.extend((t + k * body, v) for t, v in inside)
                    k += 1
    return sorted(events)


def render_song(song, channels, streams, waves, assets_dir):
    """Render one song; returns its audio.lua entry or None."""
    channels = [(num, label) for num, label in channels if label in streams
                or warn(f"audio: {song}: missing channel stream {label}")]
    if not channels:
        return None
    # pass 0: standalone runs to harvest the shared tempo timeline
    pass1 = []
    for num, label in channels:
        p = Channel(streams, label, is_wave=(num == 3), is_noise=(num == 4))
        p.run(iterations=2, max_ticks=3 * MAX_TICKS)
        pass1.append(p)
    timeline = build_tempo_timeline(pass1)

    probes = []
    for num, label in channels:
        p = Channel(streams, label, is_wave=(num == 3), is_noise=(num == 4),
                    tempo_timeline=timeline)
        # measure intro + three loop-body traversals (three are needed to
        # verify periodicity even when the first pass carries state in)
        p.run(iterations=3, max_ticks=3 * MAX_TICKS)
        probes.append((num, label, p))
    if not probes or max(p.time for _, _, p in probes) <= TICKS_PER_SECOND // 20:
        return None

    split = plan_song_loop(song, probes)
    if split:
        intro_ticks, loop_ticks = split
        total = intro_ticks + loop_ticks
    else:
        # single-file fallback: intro + two body traversals, like before
        ends = [p.infinite_times[1] if len(p.infinite_times) > 1 else p.time
                for _, _, p in probes]
        total = min(max(ends), MAX_TICKS)

    # render every channel out to the common end time (channels with
    # shorter loop bodies keep repeating)
    chans = []
    for num, label, _ in probes:
        ch = Channel(streams, label, is_wave=(num == 3), is_noise=(num == 4),
                     tempo_timeline=timeline)
        ch.run(target_time=total + FRAME_TICKS,
               max_ticks=total + FRAME_TICKS)
        chans.append((num, ch))
    pan_timeline = sorted(
        (e for _, ch in chans for e in ch.pan_events), key=lambda e: e[0])
    n_total = snap(total)
    mix = np.zeros((n_total, 2), dtype=np.float32)
    for num, ch in chans:
        pans = [pan_gains(pan_timeline, ev["t"], num) for ev in ch.events]
        sig = synthesize(ch.events, ch.is_wave, ch.is_noise, total,
                         waves=waves, pans=pans)
        mix[:len(sig)] += sig
    mix *= 0.5
    peak = float(np.max(np.abs(mix))) if mix.size else 0.0
    if peak > 1.0:
        mix /= peak  # normalize before splitting so intro/loop match

    base = song.removeprefix("Music_").lower()
    music_dir = os.path.join(assets_dir, "audio/music")
    if split:
        intro_n = snap(intro_ticks)
        loop_buf = mix[intro_n:]
        if intro_n < 32:  # no real intro: single seamlessly-looping file
            write_wav(os.path.join(music_dir, base + ".wav"), loop_buf)
            return {"file": f"assets/generated/audio/music/{base}.wav",
                    "seconds": round(loop_ticks / TICKS_PER_SECOND, 2),
                    "intro": False}
        write_wav(os.path.join(music_dir, base + ".wav"), mix[:intro_n])
        write_wav(os.path.join(music_dir, base + "_loop.wav"), loop_buf)
        return {"file": f"assets/generated/audio/music/{base}.wav",
                "seconds": round(intro_ticks / TICKS_PER_SECOND, 2),
                "loopFile": f"assets/generated/audio/music/{base}_loop.wav",
                "loopSeconds": round(loop_ticks / TICKS_PER_SECOND, 2),
                "intro": True}
    write_wav(os.path.join(music_dir, base + ".wav"), mix)
    return {"file": f"assets/generated/audio/music/{base}.wav",
            "seconds": round(total / TICKS_PER_SECOND, 2), "intro": False}


def parse_species_order(pokered):
    """constants/pokemon_constants.asm: internal id -> species const name."""
    order = {}
    idx = 0
    path = os.path.join(pokered, "constants/pokemon_constants.asm")
    for lineno, line in read_asm(path):
        s = line.strip()
        if re.match(r"const_skip\b", s):
            idx += 1
            continue
        m = re.match(r"const\s+(\w+)", s)
        if m:
            if m.group(1) != "NO_MON":
                order[idx] = m.group(1)
            idx += 1
        if "NUM_POKEMON_INDEXES" in s:
            break
    return order


def parse_cries(pokered):
    """data/pokemon/cries.asm: internal-order (base cry, pitch, length)."""
    cries = []
    path = os.path.join(pokered, "data/pokemon/cries.asm")
    for lineno, line in read_asm(path):
        m = re.match(r"mon_cry\s+SFX_CRY_([0-9A-F]+),\s*(\$?\w+),\s*(\$?\w+)",
                     line.strip())
        if m:
            cries.append({"base": int(m.group(1), 16),
                          "pitch": parse_number(m.group(2)),
                          "length": parse_number(m.group(3))})
    return cries


def render_cries(pokered, assets_dir, sfx_streams, sfx_headers):
    """Render per-species cry WAVs.

    Each species plays one of 38 base cries (SFX_CryXX_1, channels 5/6/8)
    with a per-species frequency modifier (pitch) and tempo modifier
    (length) -- data/pokemon/cries.asm + audio/engine_1.asm.
    """
    species_by_id = parse_species_order(pokered)
    cries = parse_cries(pokered)
    out = {}
    for internal_id, cry in enumerate(cries, start=1):
        species = species_by_id.get(internal_id)
        if species is None:
            continue  # MissingNo. slots
        header = f"SFX_Cry{cry['base']:02X}_1"
        channels = sfx_headers.get(header)
        if not channels:
            warn(f"audio: cry {species}: missing header {header}")
            continue
        chans = []
        total = 0
        for num, label in channels:
            if label not in sfx_streams:
                continue
            # the noise channel (CHAN8) skips Audio1_SetSfxTempo, so the
            # cry's tempo modifier does not stretch it
            ticks = FRAME_TICKS if num in (4, 8) else 0x80 + cry["length"]
            ch = Channel(sfx_streams, label, is_wave=(num in (3, 7)),
                         is_noise=(num in (4, 8)),
                         freq_offset=cry["pitch"], frame_ticks=ticks,
                         is_sfx=True)
            ch.run()
            if ch.events:
                chans.append(ch)
                total = max(total, min(ch.time, 5 * TICKS_PER_SECOND))
        if not chans or total <= TICKS_PER_SECOND // 100:
            warn(f"audio: cry {species}: nothing rendered")
            continue
        mix = np.zeros(snap(total) + 1, dtype=np.float32)
        for ch in chans:
            sig = synthesize(ch.events, ch.is_wave, ch.is_noise, total)
            mix[:len(sig)] += sig
        mix *= 0.5
        fname = species.lower()
        write_wav(os.path.join(assets_dir, "audio/cries", fname + ".wav"), mix)
        out[species] = f"assets/generated/audio/cries/{fname}.wav"
    if len(out) < 150:
        warn(f"audio: only {len(out)} cries rendered")
    return out


def parse_map_songs(pokered):
    out = []
    for lineno, line in read_asm(os.path.join(pokered, "data/maps/songs.asm")):
        m = re.match(r"db\s+(MUSIC_\w+),", line.strip())
        if m:
            out.append(m.group(1))
    return out


def music_const_to_label(const, rendered=None):
    # MUSIC_PALLET_TOWN -> Music_PalletTown
    parts = const.removeprefix("MUSIC_").split("_")
    label = "Music_" + "".join(p.capitalize() for p in parts)
    if rendered is not None and label not in rendered:
        # labels keep initialisms the naive capitalize() breaks
        # (MUSIC_SS_ANNE -> Music_SSAnne): fall back to a
        # case-insensitive match against the rendered song names
        folded = label.lower()
        for k in rendered:
            if k.lower() == folded:
                return k
    return label


def sfx_key(name, bank):
    """SFX header label -> stable key.  Only the bank suffix (the final
    _1/_2/_3 matching the header file the label came from, used for
    sounds duplicated across banks like SFX_Pound_1/SFX_Pound_3) is
    stripped; hex ids like SFX_Battle_09 stay distinct."""
    base = name.removeprefix("SFX_")
    suffix = f"_{bank}"
    if base.endswith(suffix):
        base = base[:-len(suffix)]
    return base


def extract(pokered, out_dir, assets_dir, map_order):
    headers, music_banks = parse_headers(pokered)
    streams = parse_music_files(pokered)
    wave_banks = parse_wave_instruments(pokered)

    rendered = {}
    for song, channels in sorted(headers.items()):
        waves = wave_banks.get(music_banks.get(song, 1), wave_banks[1])
        entry = render_song(song, channels, streams, waves, assets_dir)
        if entry:
            rendered[song] = entry

    # ------------------------------------------------------------- SFX
    sfx_headers, sfx_banks = parse_headers(pokered, "sfxheaders", "SFX_")
    sfx_dir = os.path.join(pokered, "audio/sfx")
    sfx_streams = {}
    for fname in sorted(os.listdir(sfx_dir)):
        if fname.endswith(".asm"):
            sfx_streams.update(
                parse_music_files_dir(os.path.join(sfx_dir, fname)))
    sfx_out = {}
    for name, channels in sorted(sfx_headers.items()):
        base = sfx_key(name, sfx_banks.get(name, 1))
        if base.startswith(("Cry", "Noise_Instrument", "Unused")) \
           or base in sfx_out:
            continue
        waves = wave_banks.get(sfx_banks.get(name, 1), wave_banks[1])
        chans = []
        total = 0
        for num, label in channels:
            if label not in sfx_streams:
                continue
            ch = Channel(sfx_streams, label, is_wave=(num in (3, 7)),
                         is_noise=(num in (4, 8)), is_sfx=True)
            ch.run()
            if ch.events:
                chans.append(ch)
                total = max(total, min(ch.time, 5 * TICKS_PER_SECOND))
        if not chans or total <= TICKS_PER_SECOND // 100:
            continue
        mix = np.zeros(snap(total) + 1, dtype=np.float32)
        for ch in chans:
            sig = synthesize(ch.events, ch.is_wave, ch.is_noise, total,
                             waves=waves)
            mix[:len(sig)] += sig
        mix *= 0.5
        fname = base.lower()
        write_wav(os.path.join(assets_dir, "audio/sfx", fname + ".wav"), mix)
        sfx_out[base] = f"assets/generated/audio/sfx/{fname}.wav"

    # ------------------------------------------------- move SFX variants
    # data/moves/sfx.asm MoveSoundTable: each move's sound carries a
    # pitch modifier (added to every frequency register write) and a
    # tempo modifier (wSfxTempo = tempo + $80, scaling note lengths).
    # The battle sound engine applies both to battle SFX
    # (audio/engine_2.asm Audio2_ApplyFrequencyModifier /
    # Audio2_SetSfxTempo; the noise channel CHAN8 skips SetSfxTempo, so
    # tempo never stretches noise) -- the same mechanism as cries.
    # Pre-synthesize one WAV per distinct non-identity (sfx, pitch,
    # tempo) triple; Sound.playMove looks them up via the
    # "<key>@<pitch><tempo>" sfx-table keys and falls back to the plain
    # sound.  GROWL/ROAR rows are excluded: GetMoveSound (IsCryMove)
    # plays the attacker's cry for those instead of the table sound.
    const_to_label = {}
    path = os.path.join(pokered, "constants/music_constants.asm")
    for lineno, line in read_asm(path):
        m = re.match(r"music_const\s+(\w+)\s*,\s*(\w+)", line.strip())
        if m:
            const_to_label[m.group(1)] = m.group(2)
    move_rows = []
    path = os.path.join(pokered, "data/moves/sfx.asm")
    for lineno, line in read_asm(path):
        m = re.match(r"db\s+(SFX_\w+)\s*,\s*(\$?\w+)\s*,\s*(\$?\w+)",
                     line.strip())
        if m:
            move_rows.append((m.group(1), parse_number(m.group(2)),
                              parse_number(m.group(3)), lineno))
    cry_moves = {45, 46}  # GROWL, ROAR (1-based MoveSoundTable rows)
    variants = {}
    for i, (const, pitch, tempo, lineno) in enumerate(move_rows, start=1):
        if (pitch == 0 and tempo == 0x80) or i in cry_moves:
            continue  # identity modifiers: the base WAV already matches
        label = const_to_label.get(const)
        if label is None:
            warn(f"audio: sfx.asm:{lineno}: unknown sfx constant {const}")
            continue
        if label not in sfx_headers:
            for suffix in ("_1", "_2", "_3"):
                if label + suffix in sfx_headers:
                    label += suffix
                    break
        if label not in sfx_headers:
            warn(f"audio: sfx.asm:{lineno}: no header for {label}")
            continue
        base = sfx_key(label, sfx_banks.get(label, 1))
        variants[(base, pitch, tempo)] = label
    for (base, pitch, tempo), label in sorted(variants.items()):
        waves = wave_banks.get(sfx_banks.get(label, 1), wave_banks[1])
        chans = []
        total = 0
        for num, lbl in sfx_headers[label]:
            if lbl not in sfx_streams:
                continue
            ticks = FRAME_TICKS if num in (4, 8) else 0x80 + tempo
            ch = Channel(sfx_streams, lbl, is_wave=(num in (3, 7)),
                         is_noise=(num in (4, 8)),
                         freq_offset=pitch, frame_ticks=ticks, is_sfx=True)
            ch.run()
            if ch.events:
                chans.append(ch)
                total = max(total, min(ch.time, 5 * TICKS_PER_SECOND))
        if not chans or total <= TICKS_PER_SECOND // 100:
            continue
        mix = np.zeros(snap(total) + 1, dtype=np.float32)
        for ch in chans:
            sig = synthesize(ch.events, ch.is_wave, ch.is_noise, total,
                             waves=waves)
            mix[:len(sig)] += sig
        mix *= 0.5
        fname = f"{base.lower()}_p{pitch:02x}t{tempo:02x}.wav"
        write_wav(os.path.join(assets_dir, "audio/sfx", fname), mix)
        sfx_out[f"{base}@{pitch:02x}{tempo:02x}"] = \
            f"assets/generated/audio/sfx/{fname}"

    # ---------------------------------------------- low health alarm
    # audio/low_health_alarm.asm (Music_DoLowHealthAlarm, ticked every
    # vblank while the battle sound engine is loaded): raw pulse-1
    # register writes, so it has no sfx header to parse.  The timer
    # plays the high tone (NR11 $A0 = 50% duty, NR12 $E2 = vol 14 fade
    # 2, freq reg $750) at timer reset and the low tone ($B0/$E2, reg
    # $6EE) 11 frames later; the dec is skipped on reset frames, so the
    # true cycle is 31 frames: an 11-frame high blip then a 20-frame
    # low tone.  Each write retriggers the envelope, which synthesize()
    # models per event.  One cycle is 11392.5 samples, so two cycles
    # are rendered: 62 frames = exactly 22785 samples at 22050 Hz, a
    # seamless loop BattleState plays while the player's HP bar is red.
    def alarm_tone(frame, dur_frames, reg):
        return {"t": frame * FRAME_TICKS, "dur": dur_frames * FRAME_TICKS,
                "reg": reg, "vol": 14, "fade": 2, "duty": 0.5,
                "vib": None, "slide": None,
                "wave_inst": 0, "wave_level": 0.0}
    alarm_events = [alarm_tone(0, 11, 0x750), alarm_tone(11, 20, 0x6EE),
                    alarm_tone(31, 11, 0x750), alarm_tone(42, 20, 0x6EE)]
    alarm = synthesize(alarm_events, False, False, 62 * FRAME_TICKS) * 0.5
    write_wav(os.path.join(assets_dir, "audio/sfx", "low_health_alarm.wav"),
              alarm)
    sfx_out["Low_Health_Alarm"] = \
        "assets/generated/audio/sfx/low_health_alarm.wav"

    cries = render_cries(pokered, assets_dir, sfx_streams, sfx_headers)

    map_song_consts = parse_map_songs(pokered)
    map_songs = {}
    for i, const in enumerate(map_song_consts):
        if i >= len(map_order):
            break
        label = music_const_to_label(const, rendered)
        if label in rendered:
            map_songs[map_order[i]] = label
        else:
            print(f"WARNING: map song {const} -> {label} has no rendered song; "
                  f"{map_order[i]} keeps no music assignment")

    data = {
        "source": "audio/music/*.asm, audio/sfx/*.asm, audio/headers/*.asm, data/maps/songs.asm",
        "songs": rendered,
        "sfx": sfx_out,
        "cries": cries,
        "mapSongs": map_songs,
        "battle": {
            "wild": "Music_WildBattle",
            "trainer": "Music_TrainerBattle",
            "gym": "Music_GymLeaderBattle",
            "final": "Music_FinalBattle",
            "wildWin": "Music_DefeatedWildMon",
            "trainerWin": "Music_DefeatedTrainer",
            "gymWin": "Music_DefeatedGymLeader",
        },
    }
    util.write_lua(os.path.join(out_dir, "audio.lua"), data,
                   header="Synthesized from the real note data; see extraction-notes.md.")
    return rendered
