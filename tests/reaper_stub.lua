-- tests/reaper_stub.lua — fakes the global `reaper` table for headless testing
-- of comparator_bridge.lua. MUST be dofile'd and installed BEFORE dofile'ing
-- comparator_bridge.lua.
--
-- Unknown reaper.* calls become silent no-ops (return nil) via the __index
-- metamethod. Only calls whose return values the bridge actually consumes get
-- curated, stateful fakes below, backed by a small in-memory REAPER model.

local M = {}
M.tracks = {}
M.gmem = {}
M.show_calls = {}

local guid_seq = 0
local function next_guid()
  guid_seq = guid_seq + 1
  return string.format('{STUB-GUID-%04d}', guid_seq)
end

-- Reset all stub state between test sections.
function M.reset()
  M.tracks = {}
  M.gmem = {}
  M.show_calls = {}
  guid_seq = 0
end

-- opts: name, guid, color, vol, mute, folderdepth, receives, items, selected,
--       fx (array of {name=, params={[0]=...}}), chain_visible
function M.addTrack(opts)
  opts = opts or {}
  local tr = {
    name = opts.name or '',
    guid = opts.guid or next_guid(),
    color = opts.color or 0,
    vol = opts.vol or 1.0,
    pan = opts.pan or 0,
    mute = opts.mute or false,
    folderdepth = opts.folderdepth or 0,
    receives = opts.receives or 0,
    items = opts.items or 1,
    selected = opts.selected or false,
    fx = opts.fx or {},
    chain_visible = opts.chain_visible or -1,
  }
  M.tracks[#M.tracks + 1] = tr
  return tr
end

local function is_comparator_candidate(name)
  return type(name) == 'string' and name:find('Comparator', 1, true) ~= nil
end

local R = {}

function R.CountTracks(proj) return #M.tracks end
function R.GetTrack(proj, idx) return M.tracks[idx + 1] end

function R.TrackFX_GetCount(tr) return #tr.fx end

function R.TrackFX_GetFXName(tr, fx, buf)
  local slot = tr.fx[fx + 1]
  if not slot then return false, '' end
  return true, slot.name
end

function R.TrackFX_GetParam(tr, fx, param)
  local slot = tr.fx[fx + 1]
  if not slot then return 0 end
  return slot.params[param] or 0
end

function R.TrackFX_SetParam(tr, fx, param, val)
  local slot = tr.fx[fx + 1]
  if slot then slot.params[param] = val end
  return true
end

-- Real REAPER signature: TrackFX_AddByName(track, fxname, recFX, instantiate).
-- We ignore recFX/instantiate and just check whether the candidate string
-- addresses the Comparator Tap JSFX (every ADD_CANDIDATES form contains the
-- substring 'Comparator'); anything else fails to add, mirroring a REAPER
-- install where the plugin isn't found under that name/path.
function R.TrackFX_AddByName(tr, name, recFX, instantiate)
  if not is_comparator_candidate(name) then return -1 end
  local idx = #tr.fx -- 0-based index the new slot will occupy
  tr.fx[#tr.fx + 1] = { name = 'JS: Comparator Tap', params = { [0] = -1 } }
  return idx
end

function R.TrackFX_Delete(tr, fx)
  if tr.fx[fx + 1] then table.remove(tr.fx, fx + 1) end
  return true
end

-- Only same-track moves are exercised by the bridge (reseat_all copies a
-- track's own tap to the end of its own chain with is_move=true).
function R.TrackFX_CopyToTrack(tr, fx, desttr, destidx, is_move)
  local slot = table.remove(tr.fx, fx + 1)
  if not slot then return end
  local dest = desttr or tr
  local pos = math.min(destidx + 1, #dest.fx + 1)
  table.insert(dest.fx, pos, slot)
end

function R.TrackFX_GetChainVisible(tr) return tr.chain_visible end

function R.TrackFX_Show(tr, fx, flag)
  M.show_calls[#M.show_calls + 1] = { track = tr, fx = fx, flag = flag }
end

function R.GetSetMediaTrackInfo_String(tr, key, val, set)
  if key == 'P_NAME' then
    if set then
      tr.name = val
      return true
    end
    return true, tr.name
  end
  return false, ''
end

function R.GetMediaTrackInfo_Value(tr, key)
  if key == 'I_FOLDERDEPTH' then return tr.folderdepth
  elseif key == 'D_VOL' then return tr.vol
  elseif key == 'D_PAN' then return tr.pan
  elseif key == 'B_MUTE' then return tr.mute and 1 or 0
  end
  return 0
end

function R.GetTrackColor(tr) return tr.color end
function R.GetTrackGUID(tr) return tr.guid end

function R.GetTrackNumSends(tr, cat)
  if cat == -1 then return tr.receives end
  return 0
end

function R.CountTrackMediaItems(tr) return tr.items end
function R.IsTrackSelected(tr) return tr.selected and true or false end

function R.gmem_attach(name) return true end
function R.gmem_read(idx) return M.gmem[idx] or 0 end
function R.gmem_write(idx, val)
  M.gmem[idx] = val
  return true
end

M.R = R

-- Installs the fake into _G.reaper. Any reaper.* call not defined in R above
-- becomes a no-op function returning nil.
function M.install()
  _G.reaper = setmetatable(R, { __index = function() return function() end end })
  return M
end

return M
