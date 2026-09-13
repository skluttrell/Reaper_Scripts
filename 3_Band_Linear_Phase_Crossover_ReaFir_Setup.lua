-- Crossover_ReaFir_Setup.lua
-- Builds a linear-phase ReaFir low-pass / high-pass crossover on track 1.
--
--   Instance 1 "LOW-PASS":  100 Hz 0 dB, 200 -24, 400 -48, 800 -72, 1600 -96 -> out ch 5/6
--   Instance 2 "HIGH-PASS": 500 Hz -96, 1000 -72, 2000 -48, 4000 -24, 8000 0 -> out ch 3/4
--   Both take input from channels 1/2; channels 1/2 continue unfiltered.
--
-- Also builds the rest of the project:
--   Tracks: 1 Crossover (6 ch, master send off), 2 Full Range (folder), 3 Low, 4 Mid, 5 High (children)
--   Sends from Crossover: 5/6 -> Low, 3/4 -> High,
--                         1/2 -> Mid, 5/6 -> Mid (polarity inverted), 3/4 -> Mid (polarity inverted)
--
-- ReaFir does not expose its EQ points as parameters, so this script writes
-- the plugin state directly (format decoded from a fresh ReaFir 7.79 state).
-- Existing ReaFir instances on the track are reused in order; missing ones
-- are added. Everything is in one undo block.

local r = reaper
local LOG_PATH   = r.GetResourcePath() .. "/Scripts/Crossover/crossover_setup_log.txt"

local INSTANCES = {
  { name = "ReaFir LOW-PASS 100 Hz -> ch 5/6",  out = {5, 6},
    points = { {100,0}, {200,-24}, {400,-48}, {800,-72}, {1600,-96} } },
  { name = "ReaFir HIGH-PASS 8 kHz -> ch 3/4", out = {3, 4},
    points = { {500,-96}, {1000,-72}, {2000,-48}, {4000,-24}, {8000,0} } },
}

---------------------------------------------------------------- base64
local B = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function b64enc(data)
  return ((data:gsub('.', function(x)
    local bits, byte = '', x:byte()
    for i = 8, 1, -1 do bits = bits .. (byte % 2^i - byte % 2^(i-1) > 0 and '1' or '0') end
    return bits
  end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
    if #x < 6 then return '' end
    local c = 0
    for i = 1, 6 do c = c + (x:sub(i,i) == '1' and 2^(6-i) or 0) end
    return B:sub(c+1, c+1)
  end) .. ({ '', '==', '=' })[#data % 3 + 1])
end
local function b64dec(data)
  data = data:gsub('[^' .. B .. '=]', '')
  return (data:gsub('.', function(x)
    if x == '=' then return '' end
    local rbits, f = '', (B:find(x, 1, true) - 1)
    for i = 6, 1, -1 do rbits = rbits .. (f % 2^i - f % 2^(i-1) > 0 and '1' or '0') end
    return rbits
  end):gsub('%d%d%d?%d?%d?%d?%d?%d?', function(x)
    if #x ~= 8 then return '' end
    local c = 0
    for i = 1, 8 do c = c + (x:sub(i,i) == '1' and 2^(8-i) or 0) end
    return string.char(c)
  end))
end

---------------------------------------------------------------- ReaFir state
-- Layout of a fresh EQ-mode state (88 bytes):
--  0 i32 4764 (format tag)  4 f32 -90 (graph min dB)  8 f32 24 (graph max dB)
-- 12 i32 4096 (FFT size)   16 f32 1.0               20 i32 0
-- 24 i32 2 (edit mode: points, smooth)  28 i32 point count  32.. (f32 Hz, f32 dB) pairs
-- then: i32 processing mode (0 = EQ), i32 0, f32 comp ratio, f32 output gain,
--       f32 analysis floor, f32 legacy, i32 0, i32 0, i32 0x02000002, f32 1.0
local function build_state(points)
  local s = string.pack("<i4 f f i4 f i4 i4 i4", 4764, -90, 24, 4096, 1.0, 0, 2, #points)
  for _, p in ipairs(points) do s = s .. string.pack("<f f", p[1], p[2]) end
  s = s .. string.pack("<i4 i4 f f f f i4 i4 i4 f",
        0, 0, 0.00801603, 1.0, 3.16228e-05, 0.125, 0, 0, 0x02000002, 1.0)
  return s
end

local function read_points(state)
  if #state < 32 then return nil, "state too short (" .. #state .. " bytes)" end
  local tag, _, _, fft, _, _, edit, n = string.unpack("<i4 f f i4 f i4 i4 i4", state)
  local pts, pos = {}, 33
  for i = 1, n do
    if pos + 7 > #state then return nil, "truncated point list" end
    local hz, db = string.unpack("<f f", state, pos)
    pts[#pts+1] = string.format("%g Hz %g dB", hz, db); pos = pos + 8
  end
  local mode = string.unpack("<i4", state, pos)
  return string.format("tag %d, fft %d, editmode %d, mode %d, %d points: %s",
         tag, fft, edit, mode, n, table.concat(pts, "; "))
end

---------------------------------------------------------------- helpers
local function mask(ch) local b = ch - 1
  if b < 32 then return (1 << b), 0 else return 0, (1 << (b - 32)) end end

local function set_pins(tr, fx, out)
  r.TrackFX_SetPinMappings(tr, fx, 0, 0, mask(1))
  r.TrackFX_SetPinMappings(tr, fx, 0, 1, mask(2))
  r.TrackFX_SetPinMappings(tr, fx, 1, 0, mask(out[1]))
  r.TrackFX_SetPinMappings(tr, fx, 1, 1, mask(out[2]))
end

local function pin_desc(tr, fx)
  local function chans(isout, pin)
    local lo, hi = r.TrackFX_GetPinMappings(tr, fx, isout, pin)
    local t = {}
    for b = 0, 31 do if lo & (1 << b) ~= 0 then t[#t+1] = b + 1 end end
    for b = 0, 31 do if hi & (1 << b) ~= 0 then t[#t+1] = b + 33 end end
    return #t > 0 and table.concat(t, ",") or "none"
  end
  return string.format("in1<-%s in2<-%s out1->%s out2->%s",
    chans(0,0), chans(0,1), chans(1,0), chans(1,1))
end

---------------------------------------------------------------- main
local log = {}
local function say(s) log[#log+1] = s end

r.Undo_BeginBlock()
r.PreventUIRefresh(1)

-- tracks: find by name (case-insensitive, ignoring spaces) or create in order
local TRACKS = { "Crossover", "Full Range", "Low", "Mid", "High" }
local function norm(s) return (s:lower():gsub("%s", "")) end
local function find_track(name)
  for i = 0, r.CountTracks(0) - 1 do
    local t = r.GetTrack(0, i)
    local _, n = r.GetSetMediaTrackInfo_String(t, "P_NAME", "", false)
    if norm(n) == norm(name) then return t end
  end
end
local T = {}
for i, name in ipairs(TRACKS) do
  local t = find_track(name)
  if not t then
    -- unnamed track 1 becomes Crossover; otherwise append at the end
    if i == 1 and r.CountTracks(0) > 0 then
      local _, n = r.GetSetMediaTrackInfo_String(r.GetTrack(0, 0), "P_NAME", "", false)
      if n == "" then t = r.GetTrack(0, 0) end
    end
    if not t then r.InsertTrackAtIndex(r.CountTracks(0), true); t = r.GetTrack(0, r.CountTracks(0) - 1) end
    r.GetSetMediaTrackInfo_String(t, "P_NAME", name, true)
    say("Created track '" .. name .. "'.")
  end
  T[i] = t
end
local tr = T[1]
if r.GetMediaTrackInfo_Value(tr, "I_NCHAN") ~= 6 then
  r.SetMediaTrackInfo_Value(tr, "I_NCHAN", 6); say("Crossover channel count set to 6.")
end
-- Crossover must not reach the master directly; only the sends carry audio
if r.GetMediaTrackInfo_Value(tr, "B_MAINSEND") ~= 0 then
  r.SetMediaTrackInfo_Value(tr, "B_MAINSEND", 0); say("Crossover master/parent send disabled.")
end
-- folder: Full Range is the parent, Low/Mid/High are its children (High closes the folder)
r.SetMediaTrackInfo_Value(T[2], "I_FOLDERDEPTH", 1)
r.SetMediaTrackInfo_Value(T[3], "I_FOLDERDEPTH", 0)
r.SetMediaTrackInfo_Value(T[4], "I_FOLDERDEPTH", 0)
r.SetMediaTrackInfo_Value(T[5], "I_FOLDERDEPTH", -1)
say("Folder: Full Range contains Low, Mid, High.")

-- collect existing ReaFir instances on the track, in chain order
local existing = {}
for fx = 0, r.TrackFX_GetCount(tr) - 1 do
  local _, n = r.TrackFX_GetFXName(tr, fx, "")
  if n:find("ReaFir") then existing[#existing+1] = fx end
end

local all_ok = true
for i, spec in ipairs(INSTANCES) do
  local fx = existing[i]
  if fx then
    say(string.format("Instance %d: reusing ReaFir at FX slot %d.", i, fx + 1))
  else
    fx = r.TrackFX_AddByName(tr, "ReaFir (FFT EQ+Dynamics Processor) (Cockos)", false, -1)
    if fx < 0 then say("Instance " .. i .. ": could not add ReaFir!"); all_ok = false; goto continue end
    say(string.format("Instance %d: added ReaFir at FX slot %d.", i, fx + 1))
  end

  local ok = r.TrackFX_SetNamedConfigParm(tr, fx, "vst_chunk", b64enc(build_state(spec.points)))
  say(string.format("  state write %s", ok and "accepted" or "REJECTED"))
  r.TrackFX_SetNamedConfigParm(tr, fx, "renamed_name", spec.name)
  set_pins(tr, fx, spec.out)

  -- verify by reading back
  local ok2, chunk = r.TrackFX_GetNamedConfigParm(tr, fx, "vst_chunk")
  local desc, err = read_points(ok2 and b64dec(chunk) or "")
  say("  read back: " .. (desc or ("ERROR " .. tostring(err))))
  say("  pins: " .. pin_desc(tr, fx))
  if not desc or not desc:find(#spec.points .. " points") then all_ok = false end
  ::continue::
end

-- sends from Crossover. srcchan/dstchan are 0-based first channel of a stereo pair
local SENDS = {
  { dst = 3, src = 4, phase = false, label = "5/6 -> Low" },
  { dst = 5, src = 2, phase = false, label = "3/4 -> High" },
  { dst = 4, src = 0, phase = false, label = "1/2 -> Mid (dry)" },
  { dst = 4, src = 4, phase = true,  label = "5/6 -> Mid, polarity inverted" },
  { dst = 4, src = 2, phase = true,  label = "3/4 -> Mid, polarity inverted" },
}
local function find_send(src_tr, dst_tr, srcchan)
  for s = 0, r.GetTrackNumSends(src_tr, 0) - 1 do
    if r.GetTrackSendInfo_Value(src_tr, 0, s, "P_DESTTRACK") == dst_tr
       and r.GetTrackSendInfo_Value(src_tr, 0, s, "I_SRCCHAN") == srcchan then return s end
  end
end
for _, sd in ipairs(SENDS) do
  local dst = T[sd.dst]
  local s = find_send(tr, dst, sd.src)
  local created = false
  if not s then s = r.CreateTrackSend(tr, dst); created = true end
  r.SetTrackSendInfo_Value(tr, 0, s, "I_SRCCHAN", sd.src)
  r.SetTrackSendInfo_Value(tr, 0, s, "I_DSTCHAN", 0)
  r.SetTrackSendInfo_Value(tr, 0, s, "B_PHASE", sd.phase and 1 or 0)
  say((created and "Send created: " or "Send updated: ") .. sd.label)
end

r.PreventUIRefresh(-1)
r.UpdateArrange()
r.TrackList_AdjustWindows(false)
r.Undo_EndBlock("Crossover ReaFir setup", -1)

local f = io.open(LOG_PATH, "w")
if f then f:write(table.concat(log, "\n"), "\n"); f:close() end
r.ShowMessageBox((all_ok and "Crossover set up OK.\n\n" or "Crossover setup had problems, see log.\n\n")
  .. table.concat(log, "\n"), "Crossover ReaFir setup", 0)
