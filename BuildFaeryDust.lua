-- BuildFaeryDust.lua
-- Builds a twinkling "faery dust" bed from stock Reaper effects only: no samples, no
-- third-party plugins. Random puffs of pink noise open a gate on a high sine, so the
-- tone sparkles at unpredictable moments. Several noise-and-tone pairs at different
-- pitches, each with its own noise, twinkle independently, which is what makes it
-- sound like a scatter of dust rather than one blinking light.
--
-- Tracks built inside a folder bus, one set per pitch you ask for:
--
--   <prefix>              the folder bus: a subtle chorus to blur the sines, then a
--                         ReaVerbate with a big room and a high-pass so the tail is air.
--   <prefix> noise N      pink noise into a ReaGate keyed by itself with a high
--                         threshold, so it only opens on the noise's rare peaks.
--                         That is the random trigger. Silent on its own; sent raw to
--                         the tone track on channels 3 and 4 and to the puff track.
--   <prefix> tone N       a sine at one pitch, plus a quieter second sine at 2.76
--                         times the pitch (the first overtone of a glockenspiel bar,
--                         which is what turns a beep into a chime), into a ReaGate
--                         whose detector reads the auxiliary input (channels 3 and
--                         4), so the chime only sounds while a noise puff is
--                         happening. Its release is the sparkle tail.
--   <prefix> puff N       optional: the gated noise through a band-pass with 24 dB
--                         of resonance tuned to the same pitch, so the puff is a
--                         pitched tick at the chime's own note instead of static.
--   <prefix> shimmer      optional return outside the folder: the reverbed mix
--                         pitched up an octave and mixed back in quietly.
--
-- Every number is asked for in a dialog when the script runs (tab between fields,
-- Enter to go). Your last answers are remembered. Running the script again deletes
-- the tracks it built last time (every track whose name starts with the prefix) and
-- builds fresh ones. The render settings are pointed at the render folder as a mono
-- 16-bit 44.1 kHz WAV of the length you give; answer y to the last question to
-- render straight away.
--
-- Tuning by ear afterwards: the noise track's gate threshold sets how often it
-- twinkles (raise for sparser), its hold sets how long each twinkle is, and the tone
-- track's gate release sets how long each twinkle rings.
--
-- The trigger threshold is asked for as dB below the noise's peak, because the
-- window is narrow. Simulating Liteon's pink noise generator at 44.1 kHz: its
-- slider carries a hidden 28 dB offset, so the output peaks about 1 dB below the
-- slider value and its RMS sits about 15 dB below it. With a 30 ms hold and 80 ms
-- release, a gate 2 dB below the peak opens about once a second, 3.5 dB below about
-- three times a second, and from 5 dB down it never closes. The script turns the
-- number you give into an absolute threshold from the noise level you give.
--
-- Install: Reaper > Actions > Show action list > New action > Load ReaScript, pick this file.

local EXT = "AudiothologyFaeryDust"
local DEFAULT_RENDER_DIR = "C:\\Users\\sklut\\Documents\\Reaper\\sports_mayhem\\Renders"

---------------------------------------------------------------- settings dialog
-- Captions must not contain commas: GetUserInputs splits its caption list on them.
-- The frequency list is separated by spaces for the same reason.
local fields = {
  { key = "prefix",   caption = "Track name prefix: tracks starting with it are rebuilt", default = "Faery dust" },
  { key = "freqs",    caption = "Tone pitches in Hz separated by spaces: one pair each", default = "2093 2637 3136 3520" },
  { key = "noise",    caption = "Noise level dB",                                        default = "-12" },
  { key = "trigger",  caption = "Trigger dB below the noise peak: 2 is sparse and 4.5 is busy", default = "3.5" },
  { key = "hold",     caption = "Trigger hold ms: length of each twinkle",               default = "30" },
  { key = "trel",     caption = "Trigger release ms",                                    default = "80" },
  { key = "tone",     caption = "Tone level dB",                                         default = "-18" },
  { key = "partial",  caption = "Bell overtone dB below the tone: n for a pure sine",    default = "8" },
  { key = "tonerel",  caption = "Tone release ms: the sparkle tail",                     default = "300" },
  { key = "puff",     caption = "Pitched puff level dB: n for no puffs",                 default = "-6" },
  { key = "reverb",   caption = "Reverb wet dB: n for no reverb",                        default = "-8" },
  { key = "shimmer",  caption = "Shimmer octave-up level dB: n for none",                default = "-15" },
  { key = "level",    caption = "Overall level dB on the folder",                        default = "-18" },
  { key = "length",   caption = "Seconds to render",                                     default = "8" },
  { key = "renderdir",caption = "Render folder: blank to leave render settings alone",   default = DEFAULT_RENDER_DIR },
  { key = "rendernow",caption = "Render now: y or n",                                    default = "n" },
}

local function yes(s)
  s = tostring(s or ""):lower()
  return s:sub(1, 1) == "y" or s == "1" or s == "true"
end

local function num(s, default)
  local cleaned = tostring(s or ""):gsub("%s", "")   -- gsub also returns a count; keep the string only
  local v = tonumber(cleaned)
  if v == nil then return default end
  return v
end

-- A level in dB, or nil when the answer starts with n (none, no, off) or is blank.
local function level_or_none(s, default)
  local cleaned = tostring(s or ""):gsub("%s", ""):lower()
  if cleaned == "" or cleaned:sub(1, 1) == "n" or cleaned == "off" then return nil end
  return num(cleaned, default)
end

local function ask_settings()
  local captions, values = {}, {}
  for i, f in ipairs(fields) do
    local saved = reaper.GetExtState(EXT, f.key)
    captions[i] = f.caption
    values[i] = (saved ~= "" and saved) or f.default
  end
  local ok, csv = reaper.GetUserInputs(
    "Build faery dust",
    #fields,
    table.concat(captions, ",") .. ",extrawidth=180",
    table.concat(values, ","))
  if not ok then return nil end

  local answers = {}
  local i = 1
  for v in (csv .. ","):gmatch("([^,]*),") do
    if fields[i] then answers[fields[i].key] = v; i = i + 1 end
  end
  for _, f in ipairs(fields) do
    reaper.SetExtState(EXT, f.key, answers[f.key] or f.default, true)
  end

  local s = {}
  s.PREFIX = (answers.prefix or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if s.PREFIX == "" then s.PREFIX = "Faery dust" end
  s.FREQS = {}
  for word in tostring(answers.freqs or ""):gmatch("%S+") do
    local hz = tonumber(word)
    if hz then s.FREQS[#s.FREQS + 1] = math.min(20000, math.max(20, hz)) end
  end
  if #s.FREQS == 0 then s.FREQS = { 2093, 2637, 3136, 3520 } end
  s.NOISE_DB   = num(answers.noise, -12)
  s.TRIGGER_BELOW = math.min(12, math.max(0, num(answers.trigger, 3.5)))
  s.TRIGGER_DB = s.NOISE_DB - 1 - s.TRIGGER_BELOW    -- the generator peaks about 1 dB under its slider
  s.HOLD_MS    = math.max(0, num(answers.hold, 30))
  s.TREL_MS    = math.max(1, num(answers.trel, 80))
  s.TONE_DB    = num(answers.tone, -18)
  s.PARTIAL_BELOW = level_or_none(answers.partial, 8)     -- nil for a pure sine
  s.TONEREL_MS = math.max(1, num(answers.tonerel, 300))
  s.PUFF_DB    = level_or_none(answers.puff, -6)          -- nil for no puff tracks
  s.REVERB_DB  = level_or_none(answers.reverb, -8)        -- nil for no reverb
  s.SHIM_DB    = level_or_none(answers.shimmer, -15)      -- nil for no shimmer
  s.LEVEL_DB   = num(answers.level, -18)
  s.LENGTH     = math.max(1, num(answers.length, 8))
  s.RENDER_DIR = (answers.renderdir or ""):gsub("^%s+", ""):gsub("%s+$", "")
  s.RENDER_NOW = yes(answers.rendernow)
  return s
end
----------------------------------------------------------------

-- Speaks through OSARA when it is installed, otherwise writes to the console.
local function say(msg)
  if reaper.osara_outputMessage then
    reaper.osara_outputMessage(msg)
  else
    reaper.ShowConsoleMsg(msg .. "\n")
  end
end

-- Console lines are also collected and written to faery_dust_log.txt at the end,
-- since the console window is hard to reach with a screen reader.
local log_lines = {}
local function log(msg)
  log_lines[#log_lines + 1] = msg
  reaper.ShowConsoleMsg(msg .. "\n")
end

local function write_log(dir)
  if dir == "" then dir = reaper.GetResourcePath() end
  local path = dir .. "\\faery_dust_log.txt"
  local f = io.open(path, "w")
  if not f then return nil end
  f:write(os.date("%Y-%m-%d %H:%M:%S"), "\n", table.concat(log_lines, "\n"), "\n")
  f:close()
  return path
end

---------------------------------------------------------------- effects
-- Each effect is tried by file path and then by its display name, so it is found
-- whichever way this Reaper indexes it. For JS effects slider N is parameter N-1 and
-- takes the slider's own units.
local FX = {
  tone   = { "JS:synthesis/tonegenerator", "JS: Tone Generator" },
  pink   = { "JS:Liteon/pinknoisegen",     "JS: Pink Noise Generator" },
  svf    = { "JS:Liteon/statevariable",    "JS: State Variable Morphing Filter" },
  chorus = { "JS:delay/delay_chorus",      "JS: Delay w/Chorus" },
  pitch  = { "JS:pitch/superpitch",        "JS: Pitch Shifter 2" },
  gate   = { "VST:ReaGate (Cockos)",       "ReaGate (Cockos)", "ReaGate" },
  verb   = { "VST:ReaVerbate (Cockos)",    "ReaVerbate (Cockos)", "ReaVerbate" },
}

-- The Liteon filters take their frequency as a 0 to 100 scale:
-- hz = floor(exp((16 + scale * 1.20103) * ln 1.059) * 8.17742). Inverted here.
local function liteon_scale(hz)
  local scale = ((math.log(hz / 8.17742) / math.log(1.059)) - 16) / 1.20103
  if scale < 0 then scale = 0 elseif scale > 100 then scale = 100 end
  return scale
end

-- The first overtone of a struck metal bar sits at 2.76 times the fundamental.
local BAR_OVERTONE = 2.76

local missing = {}

-- Adds the effect to the end of the track's chain and sets its sliders in order.
-- Returns the FX index, or -1 when the effect could not be found.
local function add_fx(track, names, params)
  local idx = -1
  for _, n in ipairs(names) do
    idx = reaper.TrackFX_AddByName(track, n, false, -1)
    if idx >= 0 then break end
  end
  if idx < 0 then
    missing[#missing + 1] = names[2]
    return -1
  end
  for i, v in ipairs(params or {}) do
    if v ~= nil then reaper.TrackFX_SetParam(track, idx, i - 1, v) end
  end
  return idx
end

-- Finds a parameter by name: an exact match first, then the first name containing it.
local function find_param(track, fx, name)
  local count = reaper.TrackFX_GetNumParams(track, fx)
  local want = name:lower()
  for p = 0, count - 1 do
    local _, pname = reaper.TrackFX_GetParamName(track, fx, p, "")
    if pname:lower() == want then return p end
  end
  for p = 0, count - 1 do
    local _, pname = reaper.TrackFX_GetParamName(track, fx, p, "")
    if pname:lower():find(want, 1, true) then return p end
  end
  return nil
end

-- The value a parameter displays, as a number where it is one (dB, ms, Hz) and as text.
local function shown(track, fx, p)
  local ok, text = reaper.TrackFX_GetFormattedParamValue(track, fx, p, "")
  if not ok then return nil, "" end
  local n = tonumber(text:match("^%s*([-+]?%d*%.?%d+)"))
  if n == nil and text:find("inf") then
    n = text:find("-", 1, true) and -1e9 or 1e9
  end
  return n, text
end

-- Sets a Rea plugin parameter by the value it displays (dB, ms), whatever scale the
-- plugin uses inside, by bisecting on the displayed value. Returns the display text,
-- or nil when the parameter was not found.
local function set_shown(track, fx, name, target)
  if fx < 0 then return nil end
  local p = find_param(track, fx, name)
  if not p then return nil end
  local _, lo, hi = reaper.TrackFX_GetParam(track, fx, p)
  reaper.TrackFX_SetParam(track, fx, p, lo)
  local at_lo = shown(track, fx, p)
  reaper.TrackFX_SetParam(track, fx, p, hi)
  local at_hi = shown(track, fx, p)
  if at_lo == nil or at_hi == nil or at_lo == at_hi then
    reaper.TrackFX_SetParam(track, fx, p, target)
    local _, text = shown(track, fx, p)
    return text
  end
  local rising = at_hi > at_lo
  local a, b = lo, hi
  local best, best_gap = (a + b) / 2, math.huge
  for _ = 1, 40 do
    local mid = (a + b) / 2
    reaper.TrackFX_SetParam(track, fx, p, mid)
    local n = shown(track, fx, p)
    if n == nil then break end
    local gap = math.abs(n - target)
    if gap < best_gap then best, best_gap = mid, gap end   -- displays round, so keep the closest seen
    if gap == 0 then break end
    if (n < target) == rising then a = mid else b = mid end
  end
  reaper.TrackFX_SetParam(track, fx, p, best)
  local _, text = shown(track, fx, p)
  return text
end

-- Sets a parameter that is a fraction of full scale, whether the plugin displays it
-- as 0 to 1 or as a percentage.
local function set_fraction(track, fx, name, frac)
  if fx < 0 then return nil end
  local p = find_param(track, fx, name)
  if not p then return nil end
  local _, _, hi = reaper.TrackFX_GetParam(track, fx, p)
  reaper.TrackFX_SetParam(track, fx, p, hi)
  local at_hi = shown(track, fx, p)
  local target = (at_hi and at_hi > 1.5) and frac * 100 or frac
  return set_shown(track, fx, name, target)
end

-- Points ReaGate's detector at the auxiliary input (track channels 3 and 4). The
-- choices are stepped through and their display texts collected. A text naming an
-- auxiliary pair wins outright; failing that, the second of six choices is taken,
-- which is Auxiliary Inputs in ReaGate's list (Main Inputs, Auxiliary Inputs, Main
-- Input Channel L, Main Input Channel R, Auxiliary Input Channel L, Auxiliary Input
-- Channel R, as read from the plugin's own dropdown). Returns the display text,
-- whether it was confirmed by name, and the list of distinct choices seen, for the log.
local function set_detector_aux(track, fx)
  if fx < 0 then return nil, false, {} end
  local p = find_param(track, fx, "SignIn") or find_param(track, fx, "Detector")
  if not p then return nil, false, {} end
  local choices, positions = {}, {}
  for k = 0, 64 do
    reaper.TrackFX_SetParamNormalized(track, fx, p, k / 64)
    local _, text = shown(track, fx, p)
    if choices[#choices] ~= text then
      choices[#choices + 1] = text
      positions[#positions + 1] = k / 64
    end
    local l = text:lower()
    if l:find("aux", 1, true) and l:find("+", 1, true) then return text, true, choices end
  end
  if #choices == 6 then
    reaper.TrackFX_SetParamNormalized(track, fx, p, positions[2])
    return choices[2], true, choices
  end
  reaper.TrackFX_SetParamNormalized(track, fx, p, 0.2)
  return nil, false, choices
end

-- Every parameter of an effect as "name = display", for the log.
local function dump_params(track, fx)
  local out = {}
  for p = 0, reaper.TrackFX_GetNumParams(track, fx) - 1 do
    local _, name = reaper.TrackFX_GetParamName(track, fx, p, "")
    local _, text = shown(track, fx, p)
    out[#out + 1] = name .. " = " .. text
  end
  return table.concat(out, ", ")
end

---------------------------------------------------------------- tracks
local function delete_previous(prefix)
  local removed = 0
  for i = reaper.CountTracks(0) - 1, 0, -1 do
    local track = reaper.GetTrack(0, i)
    local _, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    if name:sub(1, #prefix) == prefix then
      reaper.DeleteTrack(track)
      removed = removed + 1
    end
  end
  return removed
end

local function new_track(name)
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, true)
  local track = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", name, true)
  return track
end

local function db_to_gain(db)
  return 10 ^ (db / 20)
end

---------------------------------------------------------------- main
local s = ask_settings()
if not s then return end   -- cancelled

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

local removed = delete_previous(s.PREFIX)

local bus = new_track(s.PREFIX)
reaper.SetMediaTrackInfo_Value(bus, "I_FOLDERDEPTH", 1)
reaper.SetMediaTrackInfo_Value(bus, "D_VOL", db_to_gain(s.LEVEL_DB))
-- A short, slow chorus smears the pure sines so they stop sounding like test tones:
-- 12 ms delay, no feedback, chorus at -12 dB, no clean delay, dry at 0 dB, 700 ms period, 3 ms depth.
add_fx(bus, FX.chorus, { 12, -120, -12, -120, 0, 700, 3 })
local verb_report = "off"
if s.REVERB_DB then
  local verb = add_fx(bus, FX.verb)
  local wet  = set_shown(bus, verb, "Wet", s.REVERB_DB)
  local room = set_fraction(bus, verb, "Room size", 0.9)    -- a big room
  set_fraction(bus, verb, "Dampening", 0.3)
  set_shown(bus, verb, "Hipass", 800)                        -- keep the tail out of the low end
  verb_report = ("wet %s, room %s"):format(wet or "?", room or "?")
end

local pairs_built = 0
local detector_ok = true
local gate_report = {}
local last_track = bus

for i, hz in ipairs(s.FREQS) do
  -- The random trigger: pink noise gated by its own peaks.
  local noise = new_track(("%s noise %d"):format(s.PREFIX, i))
  add_fx(noise, FX.pink, { 0, s.NOISE_DB, -25, 0 })          -- mono, noise dB, dry off, output 0 dB
  local ngate = add_fx(noise, FX.gate)
  local n_thr  = set_shown(noise, ngate, "Threshold", s.TRIGGER_DB)
  local n_att  = set_shown(noise, ngate, "Attack", 1)
  local n_hold = set_shown(noise, ngate, "Hold", s.HOLD_MS)
  local n_rel  = set_shown(noise, ngate, "Release", s.TREL_MS)
  set_shown(noise, ngate, "Hysteresis", 0)
  reaper.SetMediaTrackInfo_Value(noise, "B_MAINSEND", 0)   -- a trigger only, never heard raw

  -- The tone: a sine whose gate follows the noise puffs arriving on channels 3 and 4.
  local tone = new_track(("%s tone %d (%.0f Hz)"):format(s.PREFIX, i, hz))
  reaper.SetMediaTrackInfo_Value(tone, "I_NCHAN", 4)
  add_fx(tone, FX.tone, { s.TONE_DB, -120, hz, 0, 0, 0, 0 })   -- wet dB, dry off, Hz, note, octave, cents, sine
  if s.PARTIAL_BELOW and hz * BAR_OVERTONE < 20000 then
    -- the bar overtone, mixed on top of the fundamental (dry at 0 dB passes it through)
    add_fx(tone, FX.tone, { s.TONE_DB - s.PARTIAL_BELOW, 0, hz * BAR_OVERTONE, 0, 0, 0, 0 })
  end
  local tgate = add_fx(tone, FX.gate)
  local t_thr = set_shown(tone, tgate, "Threshold", -40)
  set_shown(tone, tgate, "Attack", 2)
  set_shown(tone, tgate, "Hold", 0)
  local t_rel = set_shown(tone, tgate, "Release", s.TONEREL_MS)
  set_shown(tone, tgate, "Hysteresis", 0)
  local det, det_confirmed, det_choices = set_detector_aux(tone, tgate)
  if not det_confirmed then detector_ok = false end

  local send = reaper.CreateTrackSend(noise, tone)
  reaper.SetTrackSendInfo_Value(noise, 0, send, "I_SRCCHAN", 0)   -- from channels 1 and 2
  reaper.SetTrackSendInfo_Value(noise, 0, send, "I_DSTCHAN", 2)   -- into channels 3 and 4
  reaper.SetTrackSendInfo_Value(noise, 0, send, "I_SENDMODE", 0)  -- post-fader

  -- The puff: the same gated noise rung at the chime's pitch, so it reads as part of
  -- the chime rather than as static laid over it.
  local puff
  if s.PUFF_DB then
    puff = new_track(("%s puff %d"):format(s.PREFIX, i))
    -- mono, morph X 1 and Y 1 (band-pass), frequency scale, 24 dB resonance, fully filtered, +12 dB out
    add_fx(puff, FX.svf, { 1, 1, 1, liteon_scale(hz), 24, 100, 12 })
    reaper.SetMediaTrackInfo_Value(puff, "D_VOL", db_to_gain(s.PUFF_DB))
    local psend = reaper.CreateTrackSend(noise, puff)
    reaper.SetTrackSendInfo_Value(noise, 0, psend, "I_SRCCHAN", 0)
    reaper.SetTrackSendInfo_Value(noise, 0, psend, "I_DSTCHAN", 0)
    reaper.SetTrackSendInfo_Value(noise, 0, psend, "I_SENDMODE", 0)
  end

  if i == 1 then
    gate_report[#gate_report + 1] = ("Noise gate: threshold %s (%.1f dB below the noise peak), attack %s, hold %s, release %s")
      :format(n_thr or "?", s.TRIGGER_BELOW, n_att or "?", n_hold or "?", n_rel or "?")
    gate_report[#gate_report + 1] = ("Tone gate: threshold %s, release %s, detector %s%s")
      :format(t_thr or "?", t_rel or "?", det or "not recognised",
        det_confirmed and " (Auxiliary Inputs, the second of six choices)" or " (choices not recognised, check it by hand)")
    gate_report[#gate_report + 1] = "Detector choices seen: " .. table.concat(det_choices, " | ")
    gate_report[#gate_report + 1] = "Tone gate parameters: " .. dump_params(tone, tgate)
  end
  pairs_built = pairs_built + 1
  last_track = puff or tone
end
reaper.SetMediaTrackInfo_Value(last_track, "I_FOLDERDEPTH", -1)

-- Shimmer return: the folder's output, an octave up, mixed back in quietly.
if s.SHIM_DB then
  local shim = new_track(s.PREFIX .. " shimmer")
  add_fx(shim, FX.pitch, { 0, 12, 0, 50, 20, 0, -120, 1 })   -- cents, +12 st, oct, window, overlap, wet 0, dry off, filter
  reaper.SetMediaTrackInfo_Value(shim, "D_VOL", db_to_gain(s.SHIM_DB))
  local send = reaper.CreateTrackSend(bus, shim)
  reaper.SetTrackSendInfo_Value(bus, 0, send, "I_SENDMODE", 0)
end

-- Time selection, cursor, render settings -----------------------------------------------
reaper.GetSet_LoopTimeRange(true, false, 0, s.LENGTH, false)
reaper.SetEditCurPos(0, false, false)
reaper.SetOnlyTrackSelected(bus)

local render_note = ""
if s.RENDER_DIR ~= "" then
  reaper.GetSetProjectInfo_String(0, "RENDER_FILE", s.RENDER_DIR, true)
  reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", "faery_dust", true)
  reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", "ZXZhdxAAAQ==", true)  -- WAV 16-bit PCM
  reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", 0, true)      -- master mix
  reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", 0, true)    -- custom bounds
  reaper.GetSetProjectInfo(0, "RENDER_STARTPOS", 0, true)
  reaper.GetSetProjectInfo(0, "RENDER_ENDPOS", s.LENGTH, true)
  reaper.GetSetProjectInfo(0, "RENDER_TAILFLAG", 0, true)
  reaper.GetSetProjectInfo(0, "RENDER_CHANNELS", 1, true)      -- mono
  reaper.GetSetProjectInfo(0, "RENDER_SRATE", 44100, true)
  reaper.GetSetProjectInfo(0, "RENDER_ADDTOPROJ", 0, true)
  reaper.GetSetProjectInfo(0, "RENDER_DITHER", 0, true)
  render_note = ". Render set to faery_dust.wav in the render folder"
end

reaper.PreventUIRefresh(-1)
reaper.TrackList_AdjustWindows(false)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Build faery dust", -1)

-- Report --------------------------------------------------------------------------------------
local pitches = {}
for i, hz in ipairs(s.FREQS) do pitches[i] = ("%.0f"):format(hz) end
log(("Faery dust built: %d pairs at %s Hz, noise %.1f dB, tone %.1f dB, %.1f s")
  :format(pairs_built, table.concat(pitches, " "), s.NOISE_DB, s.TONE_DB, s.LENGTH))
for _, line in ipairs(gate_report) do log(line) end
log("Puffs " .. (s.PUFF_DB and ("pitched at %.1f dB"):format(s.PUFF_DB) or "off")
  .. ", bell overtone " .. (s.PARTIAL_BELOW and ("%.1f dB below the tone"):format(s.PARTIAL_BELOW) or "off")
  .. ", reverb " .. verb_report
  .. ", shimmer " .. (s.SHIM_DB and ("on at %.1f dB"):format(s.SHIM_DB) or "off")
  .. (", folder level %.1f dB"):format(s.LEVEL_DB))
if not detector_ok then
  log("Could not confirm the tone gates' detector input. Open ReaGate on each tone track and set Detector input to Auxiliary Input L+R.")
end
if #missing > 0 then
  log("Effects not found: " .. table.concat(missing, "; "))
end

local report = ("Built faery dust, %d pairs, %.1f seconds"):format(pairs_built, s.LENGTH)
if removed > 0 then report = report .. (", replaced %d old tracks"):format(removed) end
if not detector_ok then report = report .. ", detector input needs checking by hand, see the console" end
if #missing > 0 then report = report .. (", %d effects not found, see the console"):format(#missing) end
report = report .. render_note
local log_path = write_log(s.RENDER_DIR)
if log_path then
  report = report .. ". Details written to faery_dust_log.txt in " .. (s.RENDER_DIR ~= "" and "the render folder" or "the Reaper resource folder")
end
say(report)

if s.RENDER_NOW and s.RENDER_DIR ~= "" and #missing == 0 then
  reaper.Main_OnCommand(42230, 0)   -- File: Render project, using the most recent render settings, auto-close render dialog when finished
end
