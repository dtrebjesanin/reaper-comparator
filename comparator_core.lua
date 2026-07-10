-- comparator_core.lua — pure math for Mix Overlap. No reaper.* calls allowed.
local core = {}
core.NBANDS = 32
core.FMIN, core.FMAX = 20, 20000

function core.band_edges()
  local e = {}
  for b = 0, core.NBANDS do
    e[b + 1] = core.FMIN * 10 ^ (3 * b / core.NBANDS)
  end
  return e
end

function core.band_of(f)
  if f < core.FMIN or f > core.FMAX then return nil end
  local b = math.floor(core.NBANDS * math.log(f / core.FMIN, 10) / 3)
  if b > core.NBANDS - 1 then b = core.NBANDS - 1 end
  return b
end

function core.to_db(p)
  if p <= 0 then return -120 end
  local db = 10 * math.log(p, 10)
  if db < -120 then db = -120 end
  return db
end

local function clamp01(x)
  if x < 0 then return 0 elseif x > 1 then return 1 else return x end
end

-- Interference of the REFERENCE against another track, per band.
-- contested[b]: both tracks genuinely live here (each within floor_rel_db of
--   its own peak) at comparable levels — 1 at equal, fading to 0 at ±T_db.
-- intrude[b]: the reference is LOUDER than the track in the track's own
--   territory — ramps 0→1 as the reference goes 0→T_db above the track.
-- The two crossfade: equal level = pure contested, ref +T_db = pure intrude.
-- Track louder than reference is deliberately unpainted (owned territory);
-- swap the reference to inspect the other direction.
-- score: share of the track's energy that is contested or intruded (0..1).
function core.interference(ref_pow, trk_pow, T_db, floor_rel_db)
  local contested, intrude = {}, {}
  local rmax, tmax = 0, 0
  for i = 1, core.NBANDS do
    if (ref_pow[i] or 0) > rmax then rmax = ref_pow[i] end
    if (trk_pow[i] or 0) > tmax then tmax = trk_pow[i] end
  end
  local rpeak, tpeak = core.to_db(rmax), core.to_db(tmax)
  if rpeak <= -90 or tpeak <= -90 then
    -- either signal near-silent: no meaningful comparison, paint nothing
    for i = 1, core.NBANDS do contested[i], intrude[i] = 0, 0 end
    return contested, intrude, 0
  end
  local score, total = 0, 0
  for i = 1, core.NBANDS do
    local tp = trk_pow[i] or 0
    local rdb = core.to_db(ref_pow[i] or 0)
    local tdb = core.to_db(tp)
    local ref_act = rdb > rpeak + floor_rel_db
    local trk_act = tdb > tpeak + floor_rel_db
    local d = rdb - tdb                 -- positive = reference louder
    local c, n = 0, 0
    if ref_act and trk_act then
      c = 1 - math.abs(d) / T_db
      if c < 0 then c = 0 end
    end
    if trk_act and d > 0 then
      n = d / T_db
      if n > 1 then n = 1 end
    end
    contested[i], intrude[i] = c, n
    total = total + tp
    score = score + (c > n and c or n) * tp
  end
  if total > 0 then score = score / total else score = 0 end
  return contested, intrude, clamp01(score)
end

-- v2 per-band derivations from tap protocol 2 raw arrays (pL, pR, cLR, pk).
-- Guards (binding, see PLAN-v1.2 Task 1): a silent band (pL+pR <= 0) reports
-- pan 0, width 0, corr 0, crest 0. The corr denominator sqrt(pL*pR) <= 0
-- reports corr 0. pk <= 0 or p <= 0 reports crest_db 0. width and corr are
-- clamped to their valid ranges to absorb float noise.
function core.derive(pL, pR, cLR, pk)
  local out = { p = {}, pan = {}, width = {}, corr = {}, crest_db = {} }
  for i = 1, core.NBANDS do
    local l, r, x, k = pL[i] or 0, pR[i] or 0, cLR[i] or 0, pk[i] or 0
    local p = l + r
    out.p[i] = p
    if p <= 0 then
      out.pan[i], out.width[i], out.corr[i], out.crest_db[i] = 0, 0, 0, 0
    else
      out.pan[i] = (r - l) / p
      local mid = (l + r + 2 * x) / 4
      local side = (l + r - 2 * x) / 4
      local denom = mid + side
      local width = denom > 0 and (side / denom) or 0
      if width < 0 then width = 0 elseif width > 1 then width = 1 end
      out.width[i] = width
      local cdenom = math.sqrt(l * r)
      local corr = cdenom > 0 and (x / cdenom) or 0
      if corr < -1 then corr = -1 elseif corr > 1 then corr = 1 end
      out.corr[i] = corr
      if k <= 0 then
        out.crest_db[i] = 0
      else
        out.crest_db[i] = 10 * math.log(k / p, 10)
      end
    end
  end
  return out
end

-- Spatial proximity factor between two pan positions, 1 = co-located, 0 = hard opposite.
function core.spatial(pan_a, pan_b)
  return clamp01(1 - math.abs(pan_a - pan_b))
end

-- Same contested/intrude/score contract as core.interference (v1), but
-- computed from v2 .p arrays, with an optional per-band spatial discount
-- applied to both contested and intrude when both bands are active.
function core.interference_v2(ref, trk, T_db, floor_rel_db, use_spatial)
  local contested, intrude, score = core.interference(ref.p, trk.p, T_db, floor_rel_db)
  if not use_spatial then
    return contested, intrude, score
  end
  local rmax, tmax = 0, 0
  for i = 1, core.NBANDS do
    if (ref.p[i] or 0) > rmax then rmax = ref.p[i] end
    if (trk.p[i] or 0) > tmax then tmax = trk.p[i] end
  end
  local rpeak, tpeak = core.to_db(rmax), core.to_db(tmax)
  local score, total = 0, 0
  for i = 1, core.NBANDS do
    local tp = trk.p[i] or 0
    local rdb = core.to_db(ref.p[i] or 0)
    local tdb = core.to_db(tp)
    local ref_act = rdb > rpeak + floor_rel_db
    local trk_act = tdb > tpeak + floor_rel_db
    local sp = 1
    if ref_act and trk_act then
      sp = core.spatial(ref.pan[i] or 0, trk.pan[i] or 0)
    end
    contested[i] = contested[i] * sp
    intrude[i] = intrude[i] * sp
    total = total + tp
    local c, n = contested[i], intrude[i]
    score = score + (c > n and c or n) * tp
  end
  if total > 0 then score = score / total else score = 0 end
  return contested, intrude, clamp01(score)
end

-- Per-band share of one track's power against the sum of all tapped tracks'
-- power in that band. all_p is an array of per-band .p arrays (one per tap);
-- k selects the track whose share is returned.
function core.contribution(all_p, k)
  local share = {}
  for i = 1, core.NBANDS do
    local total = 0
    for t = 1, #all_p do total = total + (all_p[t][i] or 0) end
    local own = (all_p[k] or {})[i] or 0
    share[i] = total > 0 and (own / total) or 0
  end
  return share
end

-- Fraction of history frames where both hist and ref_active_hist are true
-- (nonzero), over the frames where ref_active_hist is true. 0 if ref is
-- never active (or the histories are empty).
function core.stability(hist, ref_active_hist)
  local both, ref_count = 0, 0
  for i = 1, #ref_active_hist do
    if (ref_active_hist[i] or 0) ~= 0 then
      ref_count = ref_count + 1
      if (hist[i] or 0) ~= 0 then both = both + 1 end
    end
  end
  if ref_count <= 0 then return 0 end
  return both / ref_count
end

-- Suggest ramp/floor from the reference's spectral SPREAD: how many bands
-- (loudest-first) it needs to reach 90% of its energy. Broadband reference
-- (many bands) -> deep floor (guard everything, and don't over-exclude the
-- compared tracks' territory either, since the floor gates both sides) and a
-- wide ramp; narrow reference (few bands) -> shallow floor + tight ramp,
-- focused on its core zones only.
-- (v1 of this heuristic derived the floor from the marginal band's LEVEL,
-- which is near-peak for flat spectra -> shallow floors for broadband
-- references -> field report: "auto is WAY more forgiving than defaults".)
function core.autocal(ref_pow)
  local total, rmax = 0, 0
  for i = 1, core.NBANDS do
    local p = ref_pow[i] or 0
    total = total + p
    if p > rmax then rmax = p end
  end
  if total <= 0 or rmax <= 0 then return 6, -30 end
  local levels = {}
  for i = 1, core.NBANDS do levels[i] = ref_pow[i] or 0 end
  table.sort(levels, function(a, b) return a > b end)
  local acc, count = 0, 0
  for _, p in ipairs(levels) do
    count = count + 1
    acc = acc + p
    if acc >= total * 0.9 then break end
  end
  local spread = count / core.NBANDS          -- 1/32 (pure tone) .. 1 (flat)
  local fl = -(10 + spread * 40)              -- ~-11 narrow .. -50 broadband
  if fl > -10 then fl = -10 elseif fl < -60 then fl = -60 end
  local ramp = 3 + spread * 9                 -- 3 narrow .. 12 broadband
  return ramp, fl
end

return core
