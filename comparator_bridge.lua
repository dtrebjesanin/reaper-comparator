-- comparator_bridge.lua — REAPER glue for Mix Overlap. Requires reaper.* API.
local B = {}
B.BASE, B.STRIDE, B.MAX_TAPS = 256, 256, 512
B.NBANDS = 32
B.FXNAME = 'Comparator Tap'
-- AddByName candidates: JSFX can be addressed by desc or by file path relative
-- to the Effects folder. Try in order until one works on this install.
B.ADD_CANDIDATES = {
  'JS:Comparator/Comparator_Tap.jsfx',
  'JS:Comparator/Comparator_Tap',
  'JS:Comparator_Tap.jsfx',
  'JS:Comparator_Tap',
  'Comparator Tap',
}

function B.attach()
  reaper.gmem_attach('Comparator')
end

local function find_tap(tr)
  local n = reaper.TrackFX_GetCount(tr)
  for i = 0, n - 1 do
    local _, fxname = reaper.TrackFX_GetFXName(tr, i, '')
    -- legacy match: taps inserted before the rename ('MixOverlap Tap') stay
    -- findable so they show as lanes and Remove all / x can clean them up
    if fxname:find('Comparator Tap', 1, true)
        or fxname:find('MixOverlap Tap', 1, true) then return i end
  end
  return nil
end

function B.is_leaf(tr)
  if reaper.GetMediaTrackInfo_Value(tr, 'I_FOLDERDEPTH') == 1 then return false end
  local receives = reaper.GetTrackNumSends(tr, -1)
  local items = reaper.CountTrackMediaItems(tr)
  if receives > 0 and items == 0 then return false end
  return true
end

local function get_id(tr, fx)
  local v = reaper.TrackFX_GetParam(tr, fx, 0)
  return math.floor(v + 0.5)
end

local function set_id(tr, fx, id)
  reaper.TrackFX_SetParam(tr, fx, 0, id)
end

function B.scan()
  local entries, used = {}, {}
  for t = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, t)
    local fx = find_tap(tr)
    if fx then
      local id = get_id(tr, fx)
      local _, name = reaper.GetSetMediaTrackInfo_String(tr, 'P_NAME', '', false)
      if name == '' then name = 'Track ' .. (t + 1) end
      entries[#entries + 1] = {
        track = tr, fx = fx, id = id, name = name,
        color = reaper.GetTrackColor(tr),
        vol = reaper.GetMediaTrackInfo_Value(tr, 'D_VOL'),
        -- the FX chain is pre-pan: the TCP pan knob never reaches the tap, so
        -- the UI must apply it (same reason vol is read here for fader scaling)
        pan = reaper.GetMediaTrackInfo_Value(tr, 'D_PAN'),
        mute = reaper.GetMediaTrackInfo_Value(tr, 'B_MUTE') == 1,
        guid = reaper.GetTrackGUID(tr),
      }
    end
  end
  -- fix unassigned (-1) and colliding IDs
  local function next_free()
    for id = 0, B.MAX_TAPS - 1 do if not used[id] then return id end end
    return nil
  end
  for _, e in ipairs(entries) do
    if e.id >= 0 and not used[e.id] then
      used[e.id] = true
    else
      e.id = -2 -- needs (re)assignment
    end
  end
  for _, e in ipairs(entries) do
    if e.id == -2 then
      local id = next_free()
      if id then
        used[id] = true
        set_id(e.track, e.fx, id)
        e.id = id
      end
    end
  end
  return entries
end

function B.read_tap(id)
  local base = B.BASE + id * B.STRIDE
  local r = {
    heartbeat = reaper.gmem_read(base),
    srate = reaper.gmem_read(base + 1),
    pL = {}, pR = {}, cLR = {}, pk = {},
    env = reaper.gmem_read(base + 136),   -- fast broadband envelope (activity strip)
  }
  for b = 1, B.NBANDS do
    r.pL[b] = reaper.gmem_read(base + 8 + (b - 1))
    r.pR[b] = reaper.gmem_read(base + 40 + (b - 1))
    r.cLR[b] = reaper.gmem_read(base + 72 + (b - 1))
    r.pk[b] = reaper.gmem_read(base + 104 + (b - 1))
  end
  return r
end

local function add_tap(tr)
  if find_tap(tr) then return true end
  for _, cand in ipairs(B.ADD_CANDIDATES) do
    local idx = reaper.TrackFX_AddByName(tr, cand, false, -1)
    if idx >= 0 then return true end
  end
  return false
end

function B.tap_tracks(which)
  local added, failed = 0, 0
  for t = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, t)
    local want = (which == 'selected')
        and reaper.IsTrackSelected(tr)
        or (which == 'all' and B.is_leaf(tr))
    if want and not find_tap(tr) then
      if add_tap(tr) then added = added + 1 else failed = failed + 1 end
    end
  end
  return added, failed
end

function B.remove_tap(tr)
  local fx = find_tap(tr)
  while fx do
    reaper.TrackFX_Delete(tr, fx)
    fx = find_tap(tr)
  end
end

function B.remove_all()
  for t = 0, reaper.CountTracks(0) - 1 do
    B.remove_tap(reaper.GetTrack(0, t))
  end
end

function B.reseat_all()
  for t = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, t)
    local fx = find_tap(tr)
    if fx then
      local last = reaper.TrackFX_GetCount(tr) - 1
      if fx < last then
        reaper.TrackFX_CopyToTrack(tr, fx, tr, last, true)
        -- moving the tap makes REAPER's chain view follow IT; hand focus back
        -- to the FX now just before the tap (in the add-flow: the plugin the
        -- user just added). -1 = chain window hidden, nothing to fix then.
        if last - 1 >= 0 and reaper.TrackFX_GetChainVisible(tr) ~= -1 then
          reaper.TrackFX_Show(tr, last - 1, 1)
        end
      end
    end
  end
end

return B
