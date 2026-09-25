-- RandomPanItems.lua
-- Scatters media items into a stereo soundscape: every item gets its own random
-- stereo position (take pan), its own random start time inside a window, and its
-- own distance (item volume plus a low-pass take FX that closes with distance),
-- so the sounds are spread out left to right, over time, and near to far
-- instead of piled on top of each other.
--
-- Targets the selected items; if none are selected, every item on the selected tracks.
-- The time window is the length you give, starting at the earliest item. Enter 0
-- as the length to use the time selection instead.
--
-- All settings are asked for in a dialog when the script runs (tab between the
-- fields, Enter to go). Your last answers are remembered. Answer y or n for the
-- yes/no questions.
--
-- Install: Reaper > Actions > Show action list > New action > Load ReaScript, pick this file.
-- Run it again to re-roll.

local EXT = "AudiothologyRandomPanItems2"

---------------------------------------------------------------- settings dialog
-- Captions must not contain commas: GetUserInputs splits its caption list on them.
local fields = {
  { key = "limit",    caption = "Pan width 0 to 1 where 1 is hard left and right", default = "0.9" },
  { key = "evenpan",  caption = "Spread pans evenly so they do not clump: y or n",  default = "y" },
  { key = "mono",     caption = "Fold stereo files to mono before panning: y or n", default = "y" },
  { key = "time",     caption = "Also scatter start times: y or n",                default = "y" },
  { key = "start",    caption = "Window start seconds: blank for earliest item or c for edit cursor", default = "" },
  { key = "span",     caption = "Window length seconds: 0 to use the time selection", default = "30" },
  { key = "eventime", caption = "One time slot per item so they do not bunch: y or n", default = "y" },
  { key = "gap",      caption = "Minimum gap before the next slot in seconds",      default = "0.25" },
  { key = "depth",    caption = "Depth as volume drop in dB for the farthest sound: 0 for none", default = "9" },
  { key = "cutoff",   caption = "Low-pass in Hz for the farthest sound: 0 for none", default = "3500" },
}

local function yes(s)
  s = tostring(s or ""):lower()
  return s:sub(1, 1) == "y" or s == "1" or s == "true"
end

local function ask_settings()
  local captions, values = {}, {}
  for i, f in ipairs(fields) do
    local saved = reaper.GetExtState(EXT, f.key)
    captions[i] = f.caption
    values[i] = (saved ~= "" and saved) or f.default
  end
  local ok, csv = reaper.GetUserInputs(
    "Scatter items across stereo and time",
    #fields,
    table.concat(captions, ",") .. ",extrawidth=120",
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
  s.LIMIT        = tonumber(answers.limit) or 0.9
  if s.LIMIT < 0 then s.LIMIT = 0 elseif s.LIMIT > 1 then s.LIMIT = 1 end
  s.EVEN_SPREAD  = yes(answers.evenpan)
  s.MONO_DOWNMIX = yes(answers.mono)
  s.SPREAD_TIME  = yes(answers.time)
  s.START        = answers.start or ""
  s.SPAN         = tonumber(answers.span) or 30
  if s.SPAN < 0 then s.SPAN = 0 end
  s.EVEN_TIME    = yes(answers.eventime)
  s.MIN_GAP      = tonumber(answers.gap) or 0.25
  if s.MIN_GAP < 0 then s.MIN_GAP = 0 end
  s.DEPTH_DB     = math.abs(tonumber(answers.depth) or 0)
  s.CUTOFF_HZ    = tonumber(answers.cutoff) or 0
  if s.CUTOFF_HZ < 0 then s.CUTOFF_HZ = 0 end
  if s.CUTOFF_HZ > 0 and s.CUTOFF_HZ < 200 then s.CUTOFF_HZ = 200 end
  return s
end
----------------------------------------------------------------

math.randomseed(math.floor(reaper.time_precise() * 1000) % 2147483647)
math.random(); math.random(); math.random()

local function collect_items()
  local items = {}
  local n = reaper.CountSelectedMediaItems(0)
  if n > 0 then
    for i = 0, n - 1 do items[#items + 1] = reaper.GetSelectedMediaItem(0, i) end
    return items
  end
  local t = reaper.CountSelectedTracks(0)
  for ti = 0, t - 1 do
    local track = reaper.GetSelectedTrack(0, ti)
    for ii = 0, reaper.CountTrackMediaItems(track) - 1 do
      items[#items + 1] = reaper.GetTrackMediaItem(track, ii)
    end
  end
  return items
end

local function shuffle(t)
  for i = #t, 2, -1 do
    local j = math.random(i)
    t[i], t[j] = t[j], t[i]
  end
end

local function pan_positions(count, s)
  local pans = {}
  if s.EVEN_SPREAD and count > 1 then
    for i = 0, count - 1 do
      pans[#pans + 1] = -s.LIMIT + (2 * s.LIMIT) * i / (count - 1)
    end
    shuffle(pans)
  else
    for _ = 1, count do
      pans[#pans + 1] = (math.random() * 2 - 1) * s.LIMIT
    end
  end
  return pans
end

-- One distance per item, from 0 (nearest) to 1 (farthest): evenly spaced steps
-- dealt out in random order, so the field has near, middle and far layers
-- rather than everything at one distance. Volume and low-pass both follow it.
local function distances(count)
  local d = {}
  if count > 1 then
    for i = 0, count - 1 do d[#d + 1] = i / (count - 1) end
    shuffle(d)
  else
    d[1] = math.random()
  end
  return d
end

local function depth_gain_db(distance, s)
  return -s.DEPTH_DB * distance
end

-- Cutoff slides on a log scale from fully open (20 kHz) at distance 0 down to
-- CUTOFF_HZ at distance 1, so the middle of the field sits around 8 kHz.
local OPEN_HZ = 20000
local function depth_cutoff_hz(distance, s)
  if s.CUTOFF_HZ <= 0 or distance <= 0 then return nil end
  return OPEN_HZ * (s.CUTOFF_HZ / OPEN_HZ) ^ distance
end

-- Stock Cockos JS low-pass that ships with Reaper. Slider 1 is frequency in Hz,
-- slider 2 is resonance.
local LOWPASS_NAMES = { "JS:filters/resonantlowpass", "JS: Resonant Lowpass Filter" }

local function remove_lowpass(take)
  for _, name in ipairs(LOWPASS_NAMES) do
    local idx = reaper.TakeFX_AddByName(take, name, 0)
    while idx >= 0 do
      reaper.TakeFX_Delete(take, idx)
      idx = reaper.TakeFX_AddByName(take, name, 0)
    end
  end
end

-- Returns true when the filter was added and set.
local function set_lowpass(take, hz)
  remove_lowpass(take)
  if not hz then return true end
  for _, name in ipairs(LOWPASS_NAMES) do
    local idx = reaper.TakeFX_AddByName(take, name, -1)
    if idx >= 0 then
      reaper.TakeFX_SetParam(take, idx, 0, hz)   -- frequency
      reaper.TakeFX_SetParam(take, idx, 1, 0.0)  -- no resonant peak
      return true
    end
  end
  return false
end

-- Returns the window [start, start + length] the items are scattered across.
-- Start: a typed number of seconds, or c for the edit cursor, or blank for the
-- earliest item. Length: the typed length; 0 means use the time selection.
local function time_window(items, s)
  local start_text = s.START:lower():gsub("%s", "")
  local start
  if start_text:sub(1, 1) == "c" then
    start = reaper.GetCursorPosition()
  elseif tonumber(start_text) then
    start = tonumber(start_text)
  else
    start = math.huge
    for _, item in ipairs(items) do
      local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      if pos < start then start = pos end
    end
  end
  if start < 0 then start = 0 end

  if s.SPAN > 0 then return start, s.SPAN end
  local ts_start, ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if ts_end > ts_start then return ts_start, ts_end - ts_start end
  return start, 30
end

-- Speaks through OSARA when it is installed, otherwise writes to the console.
local function say(msg)
  if reaper.osara_outputMessage then
    reaper.osara_outputMessage(msg)
  else
    reaper.ShowConsoleMsg(msg .. "\n")
  end
end

-- One start time per item. Slot order is shuffled so the arrangement is random.
local function start_times(items, win_start, win_len, s)
  local starts = {}
  local count = #items
  if s.EVEN_TIME and count > 1 then
    local slot = win_len / count
    local order = {}
    for i = 1, count do order[i] = i end
    shuffle(order)
    for i, item in ipairs(items) do
      local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local slot_start = win_start + slot * (order[i] - 1)
      local room = slot - len - s.MIN_GAP
      if room < 0 then room = 0 end       -- item longer than its slot: sit at the slot start
      starts[i] = slot_start + math.random() * room
    end
  else
    for i, item in ipairs(items) do
      local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local room = win_len - len
      if room < 0 then room = 0 end
      starts[i] = win_start + math.random() * room
    end
  end
  return starts
end

---------------------------------------------------------------- main
local items = collect_items()
if #items == 0 then
  reaper.ShowMessageBox("Select some items, or select a track that has items.", "Scatter items", 0)
  return
end

local s = ask_settings()
if not s then return end   -- cancelled

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)

local pans = pan_positions(#items, s)
local dist = distances(#items)
local lowpass_missing = false
local starts, win_start, win_len
if s.SPREAD_TIME then
  win_start, win_len = time_window(items, s)
  starts = start_times(items, win_start, win_len, s)
end

for i, item in ipairs(items) do
  local take = reaper.GetActiveTake(item)
  if take then
    if s.MONO_DOWNMIX then
      local src = reaper.GetMediaItemTake_Source(take)
      if src and reaper.GetMediaSourceNumChannels(src) > 1 then
        reaper.SetMediaItemTakeInfo_Value(take, "I_CHANMODE", 2) -- mono downmix
      end
    end
    reaper.SetMediaItemTakeInfo_Value(take, "D_PAN", pans[i])
    if not set_lowpass(take, depth_cutoff_hz(dist[i], s)) then lowpass_missing = true end
  end
  reaper.SetMediaItemInfo_Value(item, "D_VOL", 10 ^ (depth_gain_db(dist[i], s) / 20))
  if starts then
    reaper.SetMediaItemInfo_Value(item, "D_POSITION", starts[i])
  end
end

reaper.PreventUIRefresh(-1)
reaper.UpdateArrange()
reaper.Undo_EndBlock("Scatter " .. #items .. " items (pan + time)", -1)

-- Spoken report so the result can be checked without looking.
local report = string.format("Scattered %d items, pans within %d percent", #items, math.floor(s.LIMIT * 100 + 0.5))
if s.DEPTH_DB > 0 then
  report = report .. string.format(", depth down to minus %d dB", math.floor(s.DEPTH_DB + 0.5))
end
if s.CUTOFF_HZ > 0 then
  if lowpass_missing then
    report = report .. ". Low-pass effect not found, so no filtering was applied"
  else
    report = report .. string.format(", low-pass down to %d hertz", math.floor(s.CUTOFF_HZ + 0.5))
  end
end
if starts then
  local longest = 0
  for _, item in ipairs(items) do
    local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
    if len > longest then longest = len end
  end
  report = report .. string.format(", window %.2f seconds starting at %.2f seconds", win_len, win_start)
  if s.EVEN_TIME and #items > 1 and win_len / #items < longest + s.MIN_GAP then
    report = report .. ". Window is shorter than the items, so they overlap"
  end
end
say(report)
