-- Comparator_SelfTest.lua — prints Mix Overlap diagnostics to the ReaScript console.
local dir = debug.getinfo(1, 'S').source:match('@(.*[\\/])')
local B = dofile(dir .. 'comparator_bridge.lua')
local core = dofile(dir .. 'comparator_core.lua')
local function log(s) reaper.ShowConsoleMsg(tostring(s) .. '\n') end

reaper.ShowConsoleMsg('')  -- clear
log('== Mix Overlap self-test ==')
B.attach()
log('gmem[0] (protocol version, 1 expected once any tap runs): ' .. reaper.gmem_read(0))

log('\n-- AddByName candidate probe (first selected track) --')
local tr = reaper.GetSelectedTrack(0, 0)
if not tr then
  log('SELECT A TRACK first, then re-run.')
else
  for _, cand in ipairs(B.ADD_CANDIDATES) do
    local idx = reaper.TrackFX_AddByName(tr, cand, false, 0)  -- query only
    log(string.format('%-40s -> %d', cand, idx))
  end
  local added = select(1, B.tap_tracks('selected'))
  log('tap_tracks(selected) added: ' .. added)
end

log('\n-- Scan --')
local entries = B.scan()
log('tapped tracks found: ' .. #entries)
for _, e in ipairs(entries) do
  local r = B.read_tap(e.id)
  local d = core.derive(r.pL, r.pR, r.cLR, r.pk)
  log(string.format('  [%3d] %-24s hb=%d sr=%d band8=%.9f pan=%+.2f width=%.2f corr=%.2f',
      e.id, e.name, r.heartbeat, r.srate, r.pL[8] + r.pR[8], d.pan[8], d.width[8], d.corr[8]))
end
-- scratch-track round-trip: validates the real-API contracts the headless
-- stub tests can only assume (AddByName resolution, SetParam natural range,
-- CopyToTrack move semantics). Creates its own track and deletes it after —
-- run this on macOS before first real use there ("things stubs can lie about").
log('\n-- Scratch-track round-trip --')
reaper.Undo_BeginBlock2(0)
local sidx = reaper.CountTracks(0)
reaper.InsertTrackAtIndex(sidx, false)
local str = reaper.GetTrack(0, sidx)
reaper.GetSetMediaTrackInfo_String(str, 'P_NAME', 'Comparator SelfTest (scratch)', true)

local added = false
for _, cand in ipairs(B.ADD_CANDIDATES) do
  if reaper.TrackFX_AddByName(str, cand, false, -1) >= 0 then added = true break end
end
log('AddByName on scratch track: ' .. (added and 'OK' or 'FAIL - no candidate resolved'))

if added then
  reaper.TrackFX_SetParam(str, 0, 0, 7)
  local v = reaper.TrackFX_GetParam(str, 0, 0)
  local ok_param = math.abs(v - 7) < 0.01
  log(string.format('SetParam natural-range round-trip (wrote 7): %s (read %.2f)',
      ok_param and 'OK' or 'FAIL', v))

  -- add a second tap and move the first to last: exercises the reseat path
  for _, cand in ipairs(B.ADD_CANDIDATES) do
    if reaper.TrackFX_AddByName(str, cand, false, -1) >= 0 then break end
  end
  local n = reaper.TrackFX_GetCount(str)
  if n >= 2 then
    reaper.TrackFX_CopyToTrack(str, 0, str, n - 1, true)
    local last_v = reaper.TrackFX_GetParam(str, n - 1, 0)
    log(string.format('CopyToTrack move-to-last: %s (param 7 now at slot %d: read %.2f)',
        math.abs(last_v - 7) < 0.01 and 'OK' or 'FAIL', n - 1, last_v))
  else
    log('CopyToTrack check skipped (could not add second instance)')
  end
end

reaper.DeleteTrack(str)
reaper.Undo_EndBlock2(0, 'Mix Overlap: self-test scratch track', -1)
log('scratch track deleted')

log('\nPlay some audio and re-run: heartbeats must increase, band powers must be > 0 on audible tracks.')
