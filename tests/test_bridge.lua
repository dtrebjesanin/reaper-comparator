-- tests/test_bridge.lua — headless tests for comparator_bridge.lua using
-- reaper_stub.lua. Must be run with cwd = repo root (dofile paths below are
-- relative to it), matching the convention in test_core.lua / run_core_tests.py.

local stub = dofile('tests/reaper_stub.lua')
stub.install() -- installs _G.reaper BEFORE the bridge is loaded

local B = dofile('comparator_bridge.lua')

local function close(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end
local function check(cond, msg) if not cond then error(msg, 2) end end

local function tap_fx() return { name = 'JS: Comparator Tap', params = { [0] = -1 } } end
local function other_fx(name) return { name = name or 'ReaEQ (Cockos)', params = {} } end

-- ============================================================
-- 1. B.is_leaf
-- ============================================================
stub.reset()
do
  local folder_parent = stub.addTrack({ folderdepth = 1 })
  check(B.is_leaf(folder_parent) == false, 'folder parent must not be a leaf')

  local receive_only = stub.addTrack({ receives = 1, items = 0 })
  check(B.is_leaf(receive_only) == false, 'receive-only track must not be a leaf')

  local normal = stub.addTrack({ receives = 0, items = 1 })
  check(B.is_leaf(normal) == true, 'normal audio track must be a leaf')

  local receives_and_items = stub.addTrack({ receives = 2, items = 3 })
  check(B.is_leaf(receives_and_items) == true, 'track with receives AND items must be a leaf')
end

-- ============================================================
-- 2. B.tap_tracks('all')
-- ============================================================
stub.reset()
do
  local leaf1 = stub.addTrack({ name = 'Kick' })
  local leaf2 = stub.addTrack({ name = 'Snare' })
  local bus = stub.addTrack({ name = 'Drum Bus', folderdepth = 1 })

  local added, failed = B.tap_tracks('all')
  check(added == 2, 'expected 2 leaf tracks tapped, got ' .. added)
  check(failed == 0, 'expected 0 failures, got ' .. failed)
  check(#leaf1.fx == 1 and leaf1.fx[1].name:find('Comparator Tap', 1, true) ~= nil,
    'leaf1 must have a tap')
  check(#leaf2.fx == 1 and leaf2.fx[1].name:find('Comparator Tap', 1, true) ~= nil,
    'leaf2 must have a tap')
  check(#bus.fx == 0, 'non-leaf bus must not be tapped by all-mode')

  -- idempotent: second call adds 0
  local added2, failed2 = B.tap_tracks('all')
  check(added2 == 0, 'second tap_tracks(all) call must add 0, got ' .. added2)
  check(failed2 == 0, 'second call must fail 0, got ' .. failed2)
  check(#leaf1.fx == 1 and #leaf2.fx == 1, 'idempotent call must not duplicate taps')
end

-- ============================================================
-- 3. B.tap_tracks('selected') bypasses the leaf filter
-- ============================================================
stub.reset()
do
  local selected_bus = stub.addTrack({ name = 'Bus', folderdepth = 1, selected = true })
  local unselected_leaf = stub.addTrack({ name = 'Leaf', selected = false })

  check(B.is_leaf(selected_bus) == false, 'sanity: selected_bus is not a leaf')

  local added, failed = B.tap_tracks('selected')
  check(added == 1, 'expected 1 track tapped in selected-mode, got ' .. added)
  check(failed == 0, 'expected 0 failures, got ' .. failed)
  check(#selected_bus.fx == 1, 'selected non-leaf bus must be tapped (leaf filter bypassed)')
  check(#unselected_leaf.fx == 0, 'unselected leaf must not be tapped in selected-mode')
end

-- ============================================================
-- 4. B.scan()
-- ============================================================
stub.reset()
do
  local trackA = stub.addTrack({
    name = 'Kick', vol = 0.8, mute = true, fx = { tap_fx() }, -- id = -1 (unassigned)
  })
  trackA.fx[1].params[0] = -1

  local trackB = stub.addTrack({
    name = 'Snare', vol = 1.0, pan = -0.4, mute = false, fx = { tap_fx() },
  })
  trackB.fx[1].params[0] = 5 -- already assigned, unique

  local trackC = stub.addTrack({
    name = 'Hat', vol = 0.5, mute = false, fx = { tap_fx() },
  })
  trackC.fx[1].params[0] = 5 -- collides with trackB

  local entries = B.scan()
  check(#entries == 3, 'expected 3 scanned entries, got ' .. #entries)

  local byTrack = {}
  for _, e in ipairs(entries) do byTrack[e.track] = e end

  local eA, eB, eC = byTrack[trackA], byTrack[trackB], byTrack[trackC]
  check(eA ~= nil and eB ~= nil and eC ~= nil, 'all three tracks must appear in scan results')

  -- names/guids/vol/mute flow through
  check(eA.name == 'Kick', 'trackA name must flow through, got ' .. tostring(eA.name))
  check(close(eA.vol, 0.8), 'trackA vol must flow through')
  check(eA.mute == true, 'trackA mute must flow through')
  check(eA.guid == trackA.guid, 'trackA guid must flow through')
  check(eB.name == 'Snare' and close(eB.vol, 1.0) and eB.mute == false,
    'trackB fields must flow through')
  -- pan must flow through: the FX chain is pre-pan, so the UI depends on
  -- scan() delivering D_PAN (the v1.2 spatial feature is blind without it)
  check(close(eB.pan, -0.4), 'trackB pan must flow through, got ' .. tostring(eB.pan))
  check(close(eA.pan, 0), 'default pan must be 0, got ' .. tostring(eA.pan))

  -- unassigned id (-1) gets a fresh unique id, and the stub's param actually changed
  check(eA.id >= 0, 'trackA had id -1, must be assigned a non-negative id, got ' .. eA.id)
  check(trackA.fx[1].params[0] == eA.id,
    'SetParam must have written the new id back into the stub fx param')

  -- colliding id=5: one keeps 5, the other is repaired to a distinct id
  check(eB.id == 5, 'first-seen track keeps its assigned id 5, got ' .. eB.id)
  check(eC.id ~= 5, 'colliding track must be reassigned away from 5, got ' .. eC.id)
  check(eC.id >= 0, 'reassigned id must be non-negative, got ' .. eC.id)
  check(trackC.fx[1].params[0] == eC.id,
    'SetParam must have written the repaired id back into the stub fx param')

  -- all three ids end up distinct
  check(eA.id ~= eB.id and eA.id ~= eC.id and eB.id ~= eC.id,
    'all three ids must be pairwise distinct after scan')
end

-- ============================================================
-- 5. B.read_tap(id) — protocol v2 (BASE=256, STRIDE=256; pL/pR/cLR/pk blocks)
-- ============================================================
stub.reset()
do
  local id = 7
  local base = B.BASE + id * B.STRIDE
  stub.gmem[base] = 42       -- heartbeat
  stub.gmem[base + 1] = 48000 -- srate
  for b = 1, B.NBANDS do
    stub.gmem[base + 8 + (b - 1)] = 1000 + b  -- pL
    stub.gmem[base + 40 + (b - 1)] = 2000 + b -- pR
    stub.gmem[base + 72 + (b - 1)] = 3000 + b -- cLR
    stub.gmem[base + 104 + (b - 1)] = 4000 + b -- pk
  end

  local r = B.read_tap(id)
  check(r.heartbeat == 42, 'heartbeat must map from base+0, got ' .. tostring(r.heartbeat))
  check(r.srate == 48000, 'srate must map from base+1, got ' .. tostring(r.srate))
  check(#r.pL == B.NBANDS, 'expected ' .. B.NBANDS .. ' pL values, got ' .. #r.pL)
  check(#r.pR == B.NBANDS, 'expected ' .. B.NBANDS .. ' pR values, got ' .. #r.pR)
  check(#r.cLR == B.NBANDS, 'expected ' .. B.NBANDS .. ' cLR values, got ' .. #r.cLR)
  check(#r.pk == B.NBANDS, 'expected ' .. B.NBANDS .. ' pk values, got ' .. #r.pk)

  -- spot-check first/middle/last index of each block
  for _, b in ipairs({ 1, 16, 32 }) do
    check(r.pL[b] == 1000 + b, 'pL[' .. b .. '] must map from base+8+(b-1), got ' .. tostring(r.pL[b]))
    check(r.pR[b] == 2000 + b, 'pR[' .. b .. '] must map from base+40+(b-1), got ' .. tostring(r.pR[b]))
    check(r.cLR[b] == 3000 + b, 'cLR[' .. b .. '] must map from base+72+(b-1), got ' .. tostring(r.cLR[b]))
    check(r.pk[b] == 4000 + b, 'pk[' .. b .. '] must map from base+104+(b-1), got ' .. tostring(r.pk[b]))
  end
end

-- ============================================================
-- 6. B.remove_tap / B.remove_all
-- ============================================================
stub.reset()
do
  -- single track, tap sandwiched between two other FX
  local tr = stub.addTrack({
    fx = { other_fx('ReaEQ (Cockos)'), tap_fx(), other_fx('ReaComp (Cockos)') },
  })
  B.remove_tap(tr)
  check(#tr.fx == 2, 'expected 2 FX left after remove_tap, got ' .. #tr.fx)
  check(tr.fx[1].name == 'ReaEQ (Cockos)' and tr.fx[2].name == 'ReaComp (Cockos)',
    'other FX must be untouched (identity and order) after remove_tap')

  -- duplicate taps on one track: remove_tap's while-loop must remove all of them
  local dup = stub.addTrack({
    fx = { tap_fx(), other_fx('ReaEQ (Cockos)'), tap_fx() },
  })
  B.remove_tap(dup)
  check(#dup.fx == 1 and dup.fx[1].name == 'ReaEQ (Cockos)',
    'remove_tap must remove every tap instance, leaving only the other FX')

  -- remove_all across multiple tracks
  stub.reset()
  local t1 = stub.addTrack({ fx = { tap_fx(), other_fx() } })
  local t2 = stub.addTrack({ fx = { other_fx(), tap_fx() } })
  local t3 = stub.addTrack({ fx = { other_fx() } }) -- no tap at all
  B.remove_all()
  check(#t1.fx == 1 and t1.fx[1].name ~= 'JS: Comparator Tap', 't1 tap must be gone')
  check(#t2.fx == 1 and t2.fx[1].name ~= 'JS: Comparator Tap', 't2 tap must be gone')
  check(#t3.fx == 1, 't3 (no tap) must be untouched by remove_all')
end

-- ============================================================
-- 7. B.reseat_all
-- ============================================================
stub.reset()
do
  -- visible chain (>= 0): Show must be called for the slot before the tap's new spot
  local tr_visible = stub.addTrack({
    fx = { tap_fx(), other_fx('A'), other_fx('B') }, -- tap at 0-based index 0
    chain_visible = 1,
  })
  B.reseat_all()
  check(#tr_visible.fx == 3, 'reseat_all must not add/remove FX, got ' .. #tr_visible.fx)
  check(tr_visible.fx[3].name == 'JS: Comparator Tap',
    'tap must end up last after reseat_all, got fx[3]=' .. tr_visible.fx[3].name)
  check(#stub.show_calls == 1, 'expected exactly 1 Show call for the visible chain, got ' ..
    #stub.show_calls)
  local sc = stub.show_calls[1]
  check(sc.track == tr_visible and sc.fx == 1 and sc.flag == 1,
    'Show must be called with (track, last-1=1, 1) for the visible chain')

  -- hidden chain (-1): no Show call
  stub.show_calls = {}
  local tr_hidden = stub.addTrack({
    fx = { tap_fx(), other_fx('A'), other_fx('B') },
    chain_visible = -1,
  })
  B.reseat_all() -- note: also re-processes tr_visible, but its tap is already last (fx==last, no-op)
  check(tr_hidden.fx[3].name == 'JS: Comparator Tap',
    'tap must end up last for the hidden-chain track too')
  check(#stub.show_calls == 0,
    'expected 0 Show calls when chain is hidden (-1), got ' .. #stub.show_calls)
end

print('test_bridge.lua: all assertions passed')
