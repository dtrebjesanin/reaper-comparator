-- Comparator.lua — Comparator: masking/interference metering window for REAPER.
-- Requires: ReaImGui (ReaPack), Comparator_Tap.jsfx installed under the Effects folder.
local dir = debug.getinfo(1, 'S').source:match('@(.*[\\/])')
local core = dofile(dir .. 'comparator_core.lua')
local B = dofile(dir .. 'comparator_bridge.lua')

if not reaper.ImGui_CreateContext then
  reaper.MB('ReaImGui is required (install via ReaPack).', 'Comparator', 0)
  return
end

local ctx = reaper.ImGui_CreateContext('Comparator')
B.attach()

-- state
-- slider state lives in one table so the latched double-click reset can pin by key
-- settings migration: reads fall back to the pre-rename 'MixOverlap'
-- sections so existing preferences and project state survive; writes go
-- to 'Comparator' only
local function ext_get(key)
  local v = reaper.GetExtState('Comparator', key)
  if v == '' then v = reaper.GetExtState('MixOverlap', key) end
  return v
end

local function projext_get(key)
  local ok, v = reaper.GetProjExtState(0, 'Comparator', key)
  if ok ~= 1 or v == '' then ok, v = reaper.GetProjExtState(0, 'MixOverlap', key) end
  return ok, v
end

local prm = {
  ramp = 6.0,       -- dB the reference must exceed a track by for full violet
  floor = -30.0,    -- bands this far below a signal's OWN peak are ignored
  lane = tonumber(ext_get('lane_h')) or 120,
}
local avg_fast = false          -- display smoothing toggle
local show_contest = ext_get('show_contest') ~= '0'
local show_louder  = ext_get('show_louder') ~= '0'
local auto_cal     = ext_get('auto_cal') == '1'
local spatial_on   = ext_get('spatial') ~= '0'   -- default on
local show_strips  = ext_get('strips') ~= '0'    -- default on
local frozen       = false        -- freeze: hold the display for calm reading
local show_help    = false        -- in-app guide window
local stale_cache  = {}           -- per-id stale flags, reused while frozen
local tt = { key = nil, txt = '', t = 0 }   -- hover-tooltip hold (anti-flicker)
local view = ext_get('view')                  -- 'mask' | 'width' | 'contrib'
if view ~= 'mask' and view ~= 'width' and view ~= 'contrib' then view = 'mask' end
local lane_over = {}            -- per-lane height overrides, keyed by track GUID
do
  local ok, s = projext_get('lane_heights')
  if ok == 1 and s ~= '' then
    for guid, h in s:gmatch('([^|:]+):(%d+)') do lane_over[guid] = tonumber(h) end
  end
end

local function save_lane_over()
  local parts = {}
  for g, h in pairs(lane_over) do parts[#parts + 1] = g .. ':' .. math.floor(h) end
  reaper.SetProjExtState(0, 'Comparator', 'lane_heights', table.concat(parts, '|'))
end
local ref_guid = select(2, projext_get('ref_guid'))
local last_hb, last_hb_t = {}, {}
local disp = {}                 -- per-id display-smoothed {pL,pR,cLR,pk} (v2)
-- Temporal-classification history: per tapped id, per band, a fixed-length
-- ring (no per-frame allocation) of 0/1 flags for `overlapped` and
-- `ref_active`. Order doesn't matter for core.stability (it only counts),
-- so the ring is written circularly via a single shared head index per id.
-- Capped to the first HIST_CAP tapped ids ever seen this session (ids beyond
-- the cap simply skip history; their stability reads as 1 -> no dashing).
local hist = {}
local hist_count = 0
local HIST_LEN, HIST_CAP = 300, 32
-- Activity strip: per id, a 120-bucket ring (~20 s at ~0.17 s/bucket) of the
-- max broadband power seen since the previous bucket flush.
local act = {}
local ACT_LEN, ACT_PERIOD = 120, 0.17
-- Band edges (Hz) for the hover-verdict tooltip, precomputed once.
local BAND_EDGES = core.band_edges()
local lane_order = {}           -- manual lane order (guid -> rank), per project
do
  local ok, s = projext_get('lane_order')
  if ok == 1 and s ~= '' then
    local i = 0
    for g in s:gmatch('[^,]+') do i = i + 1; lane_order[g] = i end
  end
end

local function save_lane_order(rows)
  local parts = {}
  for i, e in ipairs(rows) do
    lane_order[e.guid] = i
    parts[i] = e.guid
  end
  reaper.SetProjExtState(0, 'Comparator', 'lane_order', table.concat(parts, ','))
end

local COL_SPEC    = 0x5588CCAA
local COL_CONTEST = 0xE8542ECC   -- red-orange: competing — comparable levels, shared territory
local COL_INTRUDE = 0x8B5CF6CC   -- violet: reference louder in the track's territory
                                 -- (CVD-safe pair, validated: worst deutan dE 29 vs blue bars)
local COL_TEXT    = 0xEEEEEEFF
local COL_STALE   = 0x777777FF

local function set_ref(guid)
  ref_guid = guid
  reaper.SetProjExtState(0, 'Comparator', 'ref_guid', guid or '')
end

local function track_rgb(e)
  if e.color ~= 0 then
    local r, g, b = reaper.ColorFromNative(e.color)
    return (r << 24) | (g << 16) | (b << 8) | 0xFF
  end
  return COL_TEXT
end

-- Generalized display smoothing: one-pole per band across all four v2 raw
-- arrays at once (same avg_fast semantics as v1's single-array version).
-- `raw` arrays are already fader/mute-scaled; disp[id] persists and is
-- mutated in place (no per-frame allocation of the smoothing state itself).
local function smooth_display(id, raw)
  local d = disp[id]
  if not d then
    d = { pL = {}, pR = {}, cLR = {}, pk = {} }
    for i = 1, core.NBANDS do d.pL[i], d.pR[i], d.cLR[i], d.pk[i] = 0, 0, 0, 0 end
    disp[id] = d
  end
  if raw then                    -- nil raw = frozen: hand back the held state
    local a = avg_fast and 0.5 or 0.15
    for i = 1, core.NBANDS do
      d.pL[i]  = d.pL[i]  + a * (raw.pL[i]  - d.pL[i])
      d.pR[i]  = d.pR[i]  + a * (raw.pR[i]  - d.pR[i])
      d.cLR[i] = d.cLR[i] + a * (raw.cLR[i] - d.cLR[i])
      d.pk[i]  = d.pk[i]  + a * (raw.pk[i]  - d.pk[i])
    end
  end
  return d
end

local function maxband(arr)
  local m = 0
  for i = 1, core.NBANDS do if arr[i] > m then m = arr[i] end end
  return m
end

-- Broadband crest badge: round(10*log10(max_b pk / max_b p)); nil when either
-- max is non-positive (guarded per the task spec — badge is omitted then).
local function crest_text(e)
  local maxk = 0
  for i = 1, core.NBANDS do if e.smooth.pk[i] > maxk then maxk = e.smooth.pk[i] end end
  local maxp = e.pmax or 0
  if maxp <= 0 or maxk <= 0 then return nil end
  return math.floor(10 * math.log(maxk / maxp, 10) + 0.5)
end

-- Activity ring: accumulate max broadband power between ~0.17 s flushes.
local function update_activity(id, now, level)
  local a = act[id]
  if not a then
    a = { buf = {}, head = 1, acc = 0, next_t = now }
    for i = 1, ACT_LEN do a.buf[i] = 0 end
    act[id] = a
  end
  if level > a.acc then a.acc = level end
  if now >= a.next_t then
    a.buf[a.head] = a.acc
    a.head = a.head % ACT_LEN + 1
    a.acc = 0
    a.next_t = now + ACT_PERIOD
  end
end

-- Activity strip: per-bucket bars in the track's color, dB-scaled against the
-- strip's own loudest bucket with a 45 dB silence floor — so gaps are real
-- gaps and hits are distinct bars, not one fused mass. 1 px between buckets.
local ACT_H, ACT_RANGE = 14, 45
-- absolute silence gate (~-90 dB power): the bars scale against the strip's
-- own loudest bucket, so without this a silent track's envelope residue
-- normalizes against itself and draws full bars out of nothing
local ACT_SILENCE = 1e-9

local function draw_activity(e, w)
  if w <= 0 then return end
  local a = act[e.id]
  if not a then reaper.ImGui_Dummy(ctx, w, ACT_H); return end
  local m = 0
  for i = 1, ACT_LEN do if (a.buf[i] or 0) > m then m = a.buf[i] end end
  if m > ACT_SILENCE then
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
    local bw = w / ACT_LEN
    local col = (track_rgb(e) & 0xFFFFFF00) | 0xB4
    local mdb = core.to_db(m)
    -- draw the ring ROTATED so the newest bucket is always the rightmost bar
    -- and time scrolls leftward — a.head is the next write slot, i.e. the
    -- oldest entry (an unrotated draw made the cursor visibly "wrap around")
    for j = 1, ACT_LEN do
      local v = a.buf[((a.head - 1 + j - 1) % ACT_LEN) + 1] or 0
      if v > ACT_SILENCE then
        local norm = (core.to_db(v) - (mdb - ACT_RANGE)) / ACT_RANGE
        if norm > 0 then
          if norm > 1 then norm = 1 end
          local bh = 2 + norm * (ACT_H - 2)     -- audible = a visible tick, at least
          local bx = x0 + (j - 1) * bw
          reaper.ImGui_DrawList_AddRectFilled(dl, bx, y0 + ACT_H - bh, bx + bw - 1, y0 + ACT_H, col)
        end
      end
    end
    -- "now" edge marker, same anchor as the explainer
    reaper.ImGui_DrawList_AddRectFilled(dl, x0 + w - 2, y0, x0 + w, y0 + ACT_H, 0x53C9D6CC)
  end
  reaper.ImGui_Dummy(ctx, w, ACT_H)
end

-- Dashed horizontal edge (3px on / 3px off) marking an intermittent-overlap band.
local function dashed_top(dl, xa, xb, y)
  local x = xa
  while x < xb do
    local xe = math.min(x + 3, xb)
    reaper.ImGui_DrawList_AddLine(dl, x, y, xe, y, 0xE9EEF2FF, 1)
    x = x + 6
  end
end

-- Linear-interpolate two 0xRRGGBBAA colors by t in [0,1] (alpha kept from c1).
-- Defined ahead of draw_spectrum, which calls it directly (Lua resolves a
-- bare identifier to a global unless the local is already in scope at the
-- point the calling function's body is compiled — forward refs don't work).
local function lerp_color(c1, c2, t)
  if t < 0 then t = 0 elseif t > 1 then t = 1 end
  local r1, g1, b1 = (c1 >> 24) & 0xFF, (c1 >> 16) & 0xFF, (c1 >> 8) & 0xFF
  local r2, g2, b2 = (c2 >> 24) & 0xFF, (c2 >> 16) & 0xFF, (c2 >> 8) & 0xFF
  local r = math.floor(r1 + (r2 - r1) * t + 0.5)
  local g = math.floor(g1 + (g2 - g1) * t + 0.5)
  local b = math.floor(b1 + (b2 - b1) * t + 0.5)
  return (r << 24) | (g << 16) | (b << 8) | (c1 & 0xFF)
end

-- draw_spectrum: `mode` selects the active view ('mask' | 'width' | 'contrib').
-- 'mask'    — e.d.p bands, contested/intrude overlays + stability dashing (v1.1 behavior).
-- 'width'   — e.d.p bands (same height as mask), bar tinted grey 0x5C6570FF -> cyan 0x2FE5DEFF by sqrt(e.d.width[b]).
-- 'contrib' — bar HEIGHT itself is e.share[b] (0..1 share, precomputed once per frame), bar 0x5FA8D3FF.
-- `stab` is an optional per-band 0..1 stability array (nil == treat every band
-- as stable/steady, i.e. no dashing, current alpha); only consulted in 'mask'.
local function draw_spectrum(e, mode, contested, intrude, w, h, stale, stab)
  if w <= 0 then return end
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + h, 0x17171AFF, 3)
  local bw = w / core.NBANDS
  for i = 1, core.NBANDS do
    local bh
    if mode == 'contrib' then
      local s = (e.share and e.share[i]) or 0
      if s < 0 then s = 0 elseif s > 1 then s = 1 end
      bh = s * (h - 2)
    else
      local db = core.to_db(e.d.p[i])
      local norm = (db + 90) / 90          -- -90..0 dB display range
      if norm < 0 then norm = 0 elseif norm > 1 then norm = 1 end
      bh = norm * (h - 2)
    end
    local bx = x0 + (i - 1) * bw
    if bh > 0 and not stale then
      local col = COL_SPEC
      if mode == 'width' then
        -- mono = colorless grey, wide = vivid cyan: width literally adds
        -- color (the old blue->cyan ramp was two similar blues; field
        -- report: not noticeable). sqrt lifts the midrange so moderate
        -- width is already clearly tinted.
        col = lerp_color(0x5C6570FF, 0x2FE5DEFF, math.sqrt(e.d.width[i]))
      elseif mode == 'contrib' then
        col = 0x5FA8D3FF
      end
      reaper.ImGui_DrawList_AddRectFilled(dl, bx + 1, y0 + h - bh, bx + bw - 1, y0 + h, col)
      if mode == 'mask' then
        local c = contested and contested[i] or 0
        local n = intrude and intrude[i] or 0
        local sb = stab and (stab[i] or 1) or 1
        local reduced = sb < 0.7 and (sb >= 0.2 or (c + n) > 0)
        local mul = reduced and 0.55 or 1.0
        if contested and c > 0 then
          local oa = math.floor(c * 0xAA * mul)
          reaper.ImGui_DrawList_AddRectFilled(dl, bx + 1, y0 + h - bh, bx + bw - 1, y0 + h,
            (COL_CONTEST & 0xFFFFFF00) | oa)
        end
        if intrude and n > 0 then
          local oa = math.floor(n * 0xCC * mul)
          reaper.ImGui_DrawList_AddRectFilled(dl, bx + 1, y0 + h - bh, bx + bw - 1, y0 + h,
            (COL_INTRUDE & 0xFFFFFF00) | oa)
        end
        if reduced and (c > 0 or n > 0) then
          dashed_top(dl, bx + 1, bx + bw - 1, y0 + h - bh)
        end
      end
    end
  end
  reaper.ImGui_Dummy(ctx, w, h)
end

-- Hover verdict over the spectrum itself: band under the cursor, its masking
-- state, and (when meaningfully overlapped) the stability-based verdict.
-- x0 is the screen-space left edge of the spectrum (captured by the caller
-- before draw_spectrum ran); relies on draw_spectrum's trailing Dummy being
-- the last item, so IsItemHovered right after the call refers to it.
-- Per-band hover tooltips hold their text: refreshed only when the hovered
-- band changes or every 0.35 s, so live meters don't make them unreadable.
-- (Freeze stops the data instead, making these fully static.)
local function held_tooltip(key, txt)
  local t_now = reaper.time_precise()
  if key ~= tt.key or t_now - tt.t > 0.35 then
    tt.key, tt.txt, tt.t = key, txt, t_now
  end
  reaper.ImGui_SetTooltip(ctx, tt.txt)
end

local function masking_hover(e, x0, w)
  if w <= 0 then return end
  if not reaper.ImGui_IsItemHovered(ctx) then return end
  local mx = reaper.ImGui_GetMousePos(ctx)
  local frac = (mx - x0) / w
  if frac < 0 then frac = 0 elseif frac >= 1 then frac = 0.999999 end
  local b = math.floor(frac * core.NBANDS) + 1
  if b < 1 then b = 1 elseif b > core.NBANDS then b = core.NBANDS end
  local c = e.contested and e.contested[b] or 0
  local n = e.intrude and e.intrude[b] or 0
  local state
  if c <= 0 and n <= 0 then state = 'no conflict'
  elseif c >= n then state = 'competing'
  else state = 'reference louder' end
  local lo, hi = BAND_EDGES[b], BAND_EDGES[b + 1]
  local txt = string.format('%d-%d Hz \xE2\x80\x94 %s', math.floor(lo + 0.5), math.floor(hi + 0.5), state)
  if (c + n) > 0.15 then
    local sb = (e.stab and e.stab[b]) or 1
    local verdict
    if sb >= 0.7 then verdict = 'steady'
    elseif sb >= 0.2 then verdict = 'intermittent'
    else verdict = 'takes turns' end
    txt = txt .. '\n' .. verdict
  end
  held_tooltip(tostring(e.guid) .. ':m:' .. b, txt)
end

local function tip(text)
  if reaper.ImGui_IsItemHovered(ctx) then reaper.ImGui_SetTooltip(ctx, text) end
end

-- responsive rows: keep the next item on this row only if ~w px still fit,
-- otherwise flow it onto a new row (footer controls use this)
local function wrap_next(w)
  reaper.ImGui_SameLine(ctx)
  if select(1, reaper.ImGui_GetContentRegionAvail(ctx)) < w then
    reaper.ImGui_NewLine(ctx)
  end
end


local VIEWS = { 'mask', 'width', 'contrib' }
local VIEW_LABEL = { mask = 'Masking', width = 'Width', contrib = 'Contribution' }
local HINTS = {
  mask    = 'who fights the Reference, where \xE2\x80\x94 and whether it\xE2\x80\x99s constant',
  width   = 'who claims the stereo sides, and what dies in mono',
  contrib = 'who owns each region of the tapped mix',
}

-- Width view badge: energy-weighted mean correlation across bands (weights =
-- e.d.p); below -0.2 means summing to mono would meaningfully cancel this track.
local function mono_loss(e)
  local num, den = 0, 0
  for i = 1, core.NBANDS do
    local p = e.d.p[i]
    num = num + e.d.corr[i] * p
    den = den + p
  end
  if den <= 0 then return false end
  return (num / den) < -0.2
end

-- Top toolbar: Masking / Width / Contribution segmented selector + hint.
local function draw_view_selector()
  for _, v in ipairs(VIEWS) do
    local active = (view == v)
    local tcol = active and 0x53C9D6FF or 0x8B97A2FF
    local bcol = active and 0x31424AFF or 0x26262BFF
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), tcol)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), bcol)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), bcol)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), bcol)
    if reaper.ImGui_Button(ctx, VIEW_LABEL[v]) then
      view = v
      reaper.SetExtState('Comparator', 'view', view, true)
    end
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_PopStyleColor(ctx)
    reaper.ImGui_SameLine(ctx)
  end
  -- freeze: hold every meter/verdict/tooltip still for calm reading while
  -- the audio keeps playing. Amber when engaged (it's a "stop" state).
  local fcol = frozen and 0xE8B02EFF or 0x8B97A2FF
  local fbg = frozen and 0x3A3222FF or 0x26262BFF
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), fcol)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), fbg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), fbg)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), fbg)
  if reaper.ImGui_Button(ctx, frozen and 'frozen' or 'freeze') then frozen = not frozen end
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_PopStyleColor(ctx)
  tip('Hold the display still to read it properly \xE2\x80\x94 spectra, colors,\npercentages, verdicts and tooltips all stop updating (audio keeps\nplaying). Click again to resume.')
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, '?') then show_help = not show_help end
  tip('Open the guide.')
  reaper.ImGui_SameLine(ctx)
  reaper.ImGui_TextColored(ctx, 0x6E7982FF, HINTS[view])
  reaper.ImGui_Separator(ctx)
end

-- Width-view hover: per-band width % + correlation, with a mono-cancellation
-- warning line when that band's correlation is negative enough to matter.
local function width_hover(e, x0, w)
  if w <= 0 then return end
  if not reaper.ImGui_IsItemHovered(ctx) then return end
  local mx = reaper.ImGui_GetMousePos(ctx)
  local frac = (mx - x0) / w
  if frac < 0 then frac = 0 elseif frac >= 1 then frac = 0.999999 end
  local b = math.floor(frac * core.NBANDS) + 1
  if b < 1 then b = 1 elseif b > core.NBANDS then b = core.NBANDS end
  local pct = math.floor(e.d.width[b] * 100 + 0.5)
  local txt = string.format('width %d%% \xC2\xB7 corr %.2f', pct, e.d.corr[b])
  if e.d.corr[b] < -0.2 then txt = txt .. '\nwould partially cancel in mono' end
  held_tooltip(tostring(e.guid) .. ':w:' .. b, txt)
end

-- Contribution-view hover: this track's share of the tapped mix in that band.
local function contrib_hover(e, x0, w)
  if w <= 0 then return end
  if not reaper.ImGui_IsItemHovered(ctx) then return end
  local mx = reaper.ImGui_GetMousePos(ctx)
  local frac = (mx - x0) / w
  if frac < 0 then frac = 0 elseif frac >= 1 then frac = 0.999999 end
  local b = math.floor(frac * core.NBANDS) + 1
  if b < 1 then b = 1 elseif b > core.NBANDS then b = core.NBANDS end
  local pct = math.floor((e.share and e.share[b] or 0) * 100 + 0.5)
  held_tooltip(tostring(e.guid) .. ':c:' .. b, string.format('share of tapped mix: %d%%', pct))
end

-- Fader polish + latched double-click reset, ported from the Contour toolkit
-- (reaper-lfo-toolkit/Contour/ui/common.lua). The latch matters: a double-click
-- on the frame GRABS the slider, and an active slider rewrites its value from
-- the mouse every frame while the button is held — a one-frame reset silently
-- loses. So the reset is re-pinned each frame until the button is released.
-- frameW must be passed in: CalcItemWidth() is wrong after a SameLine row of
-- items with individual SetNextItemWidth (it reports the default width, which
-- made every overlay draw against the wrong frame and drift into neighbors)
local function drawFaderPolish(v, vmin, vmax, vdef, hovered, disp, frameW)
  if vmax <= vmin then return end
  local active = reaper.ImGui_IsItemActive(ctx)
  local held = reaper.ImGui_IsMouseDown(ctx, 0)
  if active and not held then return end   -- text-input mode: draw nothing
  local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
  local _, y1 = reaper.ImGui_GetItemRectMax(ctx)
  if not frameW or frameW <= 0 then return end
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local gs, pad = 14, 2
  local usable = frameW - pad * 2 - gs
  if usable <= 0 then return end
  local function xFor(val)
    local t = (val - vmin) / (vmax - vmin)
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return x0 + pad + gs * 0.5 + usable * t
  end
  local xv, xd = xFor(tonumber(v) or vmin), xFor(vdef)
  if math.abs(xv - xd) > 0.5 then
    reaper.ImGui_DrawList_AddRectFilled(dl, math.min(xv, xd), y0 + 2, math.max(xv, xd), y1 - 2, 0x2E8B9B4D, 4)
  end
  local mcol = hovered and 0x53C9D6E6 or 0x8B97A296
  reaper.ImGui_DrawList_AddTriangleFilled(dl, xd - 3, y0 + 1, xd + 3, y0 + 1, xd, y0 + 5, mcol)
  reaper.ImGui_DrawList_AddTriangleFilled(dl, xd - 3, y1 - 1, xd + 3, y1 - 1, xd, y1 - 5, mcol)
  local body = active and 0x53C9D6FF or (hovered and 0x3FB6C4FF or 0x359DADFF)
  local cx, hw = xv, 7
  local ct, cb = y0 + 2, y1 - 2
  local FLL = reaper.ImGui_DrawFlags_RoundCornersLeft()
  local FLR = reaper.ImGui_DrawFlags_RoundCornersRight()
  reaper.ImGui_DrawList_AddRectFilled(dl, cx - hw - 2, ct - 1, cx + hw + 2, cb + 1, 0x0E1317D9, 5)
  reaper.ImGui_DrawList_AddRectFilled(dl, cx - hw, ct, cx + hw, cb, body, 4)
  reaper.ImGui_DrawList_AddRectFilled(dl, cx - hw, ct, cx, cb, 0xFFFFFF22, 4, FLL)
  reaper.ImGui_DrawList_AddRectFilled(dl, cx, ct, cx + hw, cb, 0x00000026, 4, FLR)
  if disp then
    local tw, th = reaper.ImGui_CalcTextSize(ctx, disp)
    if tw then
      reaper.ImGui_DrawList_AddText(dl, x0 + (frameW - tw) / 2, y0 + ((y1 - y0) - (th or 13)) / 2,
        0xE9EEF2FF, disp)
    end
  end
end

local pinned = {}   -- [key] = vdef: latched resets, cleared on mouse release
local function tickReset(g, key, vmin, vmax, vdef, disp, frameW)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  drawFaderPolish(g[key], vmin, vmax, vdef, hovered, disp, frameW)
  if pinned[key] ~= nil then
    g[key] = pinned[key]
    if not reaper.ImGui_IsMouseDown(ctx, 0) then pinned[key] = nil end
    return true
  end
  if hovered and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
    g[key] = vdef
    if reaper.ImGui_IsMouseDown(ctx, 0) then pinned[key] = vdef end
    return true
  end
  return false
end

-- freshly inserted FX don't process until the audio stream restarts; a seek to
-- the current play position restarts it in place. The seek is SCHEDULED ~0.4 s
-- after tapping: fired in the same frame as the insertion it restarts a stream
-- that doesn't include the new tap yet (anticipative FX rebuild race).
local nudge_at
local function nudge_playback()
  if reaper.GetPlayState() & 1 == 1 then
    nudge_at = reaper.time_precise() + 0.4
  end
end

local function run_pending_nudge()
  if nudge_at and reaper.time_precise() >= nudge_at then
    nudge_at = nil
    if reaper.GetPlayState() & 1 == 1 then
      reaper.SetEditCurPos(reaper.GetPlayPosition(), false, true)
    end
  end
end

-- 6 px grab strip under a lane: drag vertically to resize that lane only
local function resize_strip(guid, w, cur_h)
  reaper.ImGui_InvisibleButton(ctx, '##rsz' .. guid, math.max(w, 1), 6)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local active = reaper.ImGui_IsItemActive(ctx)
  if hovered or active then
    reaper.ImGui_SetMouseCursor(ctx, reaper.ImGui_MouseCursor_ResizeNS())
    local dl = reaper.ImGui_GetWindowDrawList(ctx)
    local x0, y0 = reaper.ImGui_GetItemRectMin(ctx)
    local x1, y1 = reaper.ImGui_GetItemRectMax(ctx)
    reaper.ImGui_DrawList_AddRectFilled(dl, x0, y0 + 2, x1, y1 - 2, 0x888888AA)
  end
  if active then
    local _, dy = reaper.ImGui_GetMouseDelta(ctx)
    if dy ~= 0 then
      lane_over[guid] = math.max(24, math.min(300, cur_h + dy))
    end
  end
  if hovered and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
    lane_over[guid] = nil            -- reset this lane to the default height
    save_lane_over()
  end
  if reaper.ImGui_IsItemDeactivated(ctx) then save_lane_over() end
end

local FREQ_TICKS = {
  { 50, '50' }, { 100, '100' }, { 200, '200' }, { 500, '500' },
  { 1000, '1k' }, { 2000, '2k' }, { 5000, '5k' }, { 10000, '10k' },
}

local function draw_freq_scale(w)
  if w <= 0 then return end
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local x0, y0 = reaper.ImGui_GetCursorScreenPos(ctx)
  for _, t in ipairs(FREQ_TICKS) do
    -- same log mapping as the bands: fraction = log10(f/20) / 3
    local x = x0 + (math.log(t[1] / 20, 10) / 3) * w
    reaper.ImGui_DrawList_AddLine(dl, x, y0, x, y0 + 3, COL_STALE)
    reaper.ImGui_DrawList_AddText(dl, x - 8, y0 + 4, COL_STALE, t[2])
  end
  reaper.ImGui_Dummy(ctx, w, 18)
end

local last_reseat = 0

local function frame()
  local now = reaper.time_precise()
  -- keep every tap last in its chain automatically (cheap: moves only when
  -- something was added behind a tap), so metering always covers the full
  -- chain and FX added via the fx buttons land before the tap
  if not frozen and now - last_reseat > 1 then
    last_reseat = now
    B.reseat_all()
  end
  local entries = B.scan()

  draw_view_selector()

  -- read v2 + fader-scale all four raw arrays; find reference. When frozen,
  -- skip reading/smoothing entirely: smooth_display(id, nil) hands back the
  -- held state, so every derived number and verdict stays put for reading.
  local ref_entry, rows = nil, {}
  for i, e in ipairs(entries) do
    if frozen then
      e.smooth = smooth_display(e.id, nil)
      e.d = core.derive(e.smooth.pL, e.smooth.pR, e.smooth.cLR, e.smooth.pk)
      e.pmax = maxband(e.d.p)
      e.stale = stale_cache[e.id] or false
      e.ord = i
      if e.guid == ref_guid then ref_entry = e else rows[#rows + 1] = e end
      goto continue_entry
    end
    local r = B.read_tap(e.id)
    local stale = false
    if last_hb[e.id] ~= r.heartbeat then
      last_hb[e.id], last_hb_t[e.id] = r.heartbeat, now
    end
    stale = (now - (last_hb_t[e.id] or 0)) > 0.5
    stale_cache[e.id] = stale
    -- fader/mute/PAN scaling. The FX chain is pre-fader AND pre-pan, so both
    -- knobs must be applied here from the API values. REAPER's balance law:
    -- panning right attenuates the LEFT channel (and vice versa), never
    -- boosting the other side. Amplitude gains gL/gR multiply the per-channel
    -- powers by their squares and the cross term by their product, which
    -- makes derived pan follow the knob while width/corr stay source-true.
    -- r's arrays are freshly allocated by read_tap this call: scale in place.
    local vol = e.mute and 0 or e.vol
    local pan = e.pan or 0
    local gL = vol * (pan > 0 and (1 - pan) or 1)
    local gR = vol * (pan < 0 and (1 + pan) or 1)
    local gL2, gR2, gX = gL * gL, gR * gR, gL * gR
    local gP = (gL2 + gR2) * 0.5   -- pk holds L+R total: mean channel power gain
    for i = 1, core.NBANDS do
      r.pL[i] = r.pL[i] * gL2
      r.pR[i] = r.pR[i] * gR2
      r.cLR[i] = r.cLR[i] * gX
      r.pk[i] = r.pk[i] * gP
    end
    e.smooth = smooth_display(e.id, r)
    e.d = core.derive(e.smooth.pL, e.smooth.pR, e.smooth.cLR, e.smooth.pk)
    e.pmax = maxband(e.d.p)
    e.stale = stale
    -- activity feeds from the tap's FAST envelope (30 ms), not the smoothed
    -- band powers: individual hits and phrase gaps survive only there
    update_activity(e.id, now, (r.env or 0) * gP)
    e.ord = i               -- project track order, stable sort tiebreak
    if e.guid == ref_guid then ref_entry = e else
      rows[#rows + 1] = e
    end
    ::continue_entry::
  end

  -- Contribution view: per-band totals across ALL non-stale tapped tracks
  -- (reference included), computed once per frame rather than once per lane.
  if view == 'contrib' then
    local totals = {}
    for b = 1, core.NBANDS do totals[b] = 0 end
    for _, e in ipairs(entries) do
      if not e.stale then
        for b = 1, core.NBANDS do totals[b] = totals[b] + e.d.p[b] end
      end
    end
    local grand = 0
    for b = 1, core.NBANDS do grand = grand + totals[b] end
    for _, e in ipairs(entries) do
      if e.stale then
        e.share, e.contrib_pct = nil, nil
      else
        local share, own = {}, 0
        for b = 1, core.NBANDS do
          local t = totals[b]
          share[b] = t > 0 and (e.d.p[b] / t) or 0
          own = own + e.d.p[b]
        end
        e.share = share
        e.contrib_pct = grand > 0 and (own / grand) or 0
      end
    end
  end

  -- overlap vs reference
  local refmax = ref_entry and ref_entry.pmax or 0
  -- auto-calibration: derive ramp/floor from the reference's own band-level
  -- distribution, slow-smoothed so the sliders glide instead of jittering.
  -- Masking-only: ramp/floor (and hence autocal) have no meaning in the
  -- Width/Contribution views, which don't compare against the reference.
  if view == 'mask' and auto_cal and not frozen and ref_entry and not ref_entry.stale then
    local ar, af = core.autocal(ref_entry.d.p)
    prm.ramp = prm.ramp + 0.1 * (ar - prm.ramp)
    prm.floor = prm.floor + 0.1 * (af - prm.floor)
  end

  -- per-band: is the reference itself active this frame? (same test core
  -- uses internally: band dB > that signal's own peak dB + floor)
  local ref_active
  if ref_entry then
    local rpeak_db = core.to_db(refmax)
    ref_active = {}
    for i = 1, core.NBANDS do
      ref_active[i] = core.to_db(ref_entry.d.p[i]) > (rpeak_db + prm.floor)
    end
  end

  -- interference of the reference against each track (pan-aware via
  -- interference_v2); floors are relative to each signal's own peak, so
  -- fader levels and recording headroom don't change the meaning. Near-
  -- silent signals paint nothing (handled in core). Also updates the
  -- overlap/ref_active history ring (capped to the first HIST_CAP tapped
  -- ids) and derives per-band stability for the temporal dashed treatment.
  for _, e in ipairs(rows) do
    if ref_entry and not e.stale and not ref_entry.stale then
      e.contested, e.intrude, e.score =
          core.interference_v2(ref_entry.d, e.d, prm.ramp, prm.floor, spatial_on)
      local h = hist[e.id]
      if not h and hist_count < HIST_CAP then
        h = { head = 1, ovl = {}, ref = {} }
        for b = 1, core.NBANDS do
          h.ovl[b], h.ref[b] = {}, {}
          for k = 1, HIST_LEN do h.ovl[b][k], h.ref[b][k] = 0, 0 end
        end
        hist[e.id] = h
        hist_count = hist_count + 1
      end
      if h then
        if not frozen then     -- frozen: history holds, stability stays put
          for b = 1, core.NBANDS do
            h.ovl[b][h.head] = ((e.contested[b] + e.intrude[b]) > 0.15) and 1 or 0
            h.ref[b][h.head] = ref_active[b] and 1 or 0
          end
          h.head = h.head % HIST_LEN + 1
        end
        local stab = {}
        for b = 1, core.NBANDS do stab[b] = core.stability(h.ovl[b], h.ref[b]) end
        e.stab = stab
      else
        e.stab = nil   -- beyond the history cap: treated as always-stable (1)
      end
    else
      e.contested, e.intrude, e.score, e.stab = nil, nil, 0, nil
    end
  end
  -- Contribution view has no reference concept: the ★ is ignored and the
  -- reference track simply joins the lane list as a normal row (simplest
  -- way to satisfy "renders as a normal lane" without special-casing it
  -- further down) instead of being pinned above a Separator.
  if view == 'contrib' and ref_entry then
    rows[#rows + 1] = ref_entry
  end

  -- manual ordering only: saved drag order first, new tracks in project order
  table.sort(rows, function(a, b)
    local ra = lane_order[a.guid] or (100000 + a.ord)
    local rb = lane_order[b.guid] or (100000 + b.ord)
    if ra ~= rb then return ra < rb end
    return a.ord < b.ord
  end)

  -- reference row (pinned) — not shown in Contribution view (see above)
  if view ~= 'contrib' and ref_entry then
    reaper.ImGui_TextColored(ctx, 0xFFD700FF, '\xE2\x98\x85')
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextColored(ctx, track_rgb(ref_entry), ref_entry.name .. '  (Reference)')
    reaper.ImGui_SameLine(ctx)
    local ref_cr = crest_text(ref_entry)
    if ref_cr then
      reaper.ImGui_TextColored(ctx, COL_STALE, string.format('cr %d dB', ref_cr))
      tip('crest factor: peak vs average level. Low (<6 dB) = squashed,\nhigh (>15 dB) = punchy/spiky.')
      reaper.ImGui_SameLine(ctx)
    end
    if reaper.ImGui_SmallButton(ctx, 'fx') then
      reaper.SetOnlyTrackSelected(ref_entry.track)
      reaper.Main_OnCommand(40271, 0)   -- View: Show FX browser window
    end
    tip('Open the FX browser to add a plugin to the Reference track —\nusually where you carve. Added FX stay before the tap automatically.\nNote: selects this track.')
    local ref_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
    local ref_h = lane_over[ref_entry.guid] or (prm.lane + 16)
    local ref_x0 = select(1, reaper.ImGui_GetCursorScreenPos(ctx))
    draw_spectrum(ref_entry, view, nil, nil, ref_w, ref_h, ref_entry.stale)
    if view == 'width' then width_hover(ref_entry, ref_x0, ref_w) end
    draw_freq_scale(ref_w)
    if show_strips then draw_activity(ref_entry, ref_w) end
    resize_strip(ref_entry.guid, ref_w, ref_h)
    reaper.ImGui_Separator(ctx)
  elseif view ~= 'contrib' then
    reaper.ImGui_TextColored(ctx, 0xFFCC33FF, 'Click a \xE2\x98\x85 to choose a Reference track.')
    reaper.ImGui_Separator(ctx)
  end

  -- track rows
  local move_from, move_to
  for idx, e in ipairs(rows) do
    reaper.ImGui_PushID(ctx, e.guid)
    reaper.ImGui_SmallButton(ctx, '\xE2\x89\xA1')
    tip('Drag up/down to reorder lanes (order is saved with the project)')
    if reaper.ImGui_IsItemActive(ctx) and not reaper.ImGui_IsItemHovered(ctx) then
      local _, dy = reaper.ImGui_GetMouseDragDelta(ctx, 0)
      if dy < -10 and idx > 1 then
        move_from, move_to = idx, idx - 1
        reaper.ImGui_ResetMouseDragDelta(ctx, 0)
      elseif dy > 10 and idx < #rows then
        move_from, move_to = idx, idx + 1
        reaper.ImGui_ResetMouseDragDelta(ctx, 0)
      end
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_SmallButton(ctx, '\xE2\x98\x85') then set_ref(e.guid) end
    reaper.ImGui_SameLine(ctx)
    local col = e.mute and COL_STALE or track_rgb(e)
    reaper.ImGui_TextColored(ctx, col, string.format('%-22s', e.name:sub(1, 22)))
    reaper.ImGui_SameLine(ctx)
    if e.stale then
      reaper.ImGui_TextColored(ctx, COL_STALE, '(no data)')
    elseif view == 'mask' then
      reaper.ImGui_Text(ctx, string.format('%3d%%', math.floor((e.score or 0) * 100 + 0.5)))
      tip('Share of this track\x27s energy that the Reference is contesting\nor out-levelling. Falls as you carve the Reference away from\nthis track\x27s territory.')
    elseif view == 'width' then
      if mono_loss(e) then
        reaper.ImGui_TextColored(ctx, 0xE8B02EFF, 'mono-loss')
        tip('Energy-weighted correlation across bands is negative here:\nsumming this track to mono would partially cancel it.')
      end
    elseif view == 'contrib' then
      reaper.ImGui_Text(ctx, string.format('%3d%%', math.floor((e.contrib_pct or 0) * 100 + 0.5)))
      tip('This track\x27s share of the total energy across all tapped\ntracks\x27 combined band power (fader-scaled).')
    end
    reaper.ImGui_SameLine(ctx)
    local cr = crest_text(e)
    if cr then
      reaper.ImGui_TextColored(ctx, COL_STALE, string.format('cr %d dB', cr))
      tip('crest factor: peak vs average level. Low (<6 dB) = squashed,\nhigh (>15 dB) = punchy/spiky.')
      reaper.ImGui_SameLine(ctx)
    end
    if reaper.ImGui_SmallButton(ctx, 'fx') then
      reaper.SetOnlyTrackSelected(e.track)
      reaper.Main_OnCommand(40271, 0)   -- View: Show FX browser window
    end
    tip('Open the FX browser to add a plugin to this track (double-click\nan FX in the browser). Added FX are kept BEFORE the Comparator tap\nautomatically. Note: selects this track.')
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_SmallButton(ctx, '\xC3\x97') then
      reaper.Undo_BeginBlock2(0)
      B.remove_tap(e.track)
      reaper.Undo_EndBlock2(0, 'Comparator: untap track', -1)
    end
    tip('Untap this track: removes its analyzer, the lane disappears.')
    local avail = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
    local h = lane_over[e.guid] or prm.lane
    local spec_x0 = select(1, reaper.ImGui_GetCursorScreenPos(ctx))
    draw_spectrum(e, view, show_contest and e.contested or nil,
        show_louder and e.intrude or nil, avail, h, e.stale, e.stab)
    if view == 'mask' then
      masking_hover(e, spec_x0, avail)
    elseif view == 'width' then
      width_hover(e, spec_x0, avail)
    elseif view == 'contrib' then
      contrib_hover(e, spec_x0, avail)
    end
    if show_strips then draw_activity(e, avail) end
    resize_strip(e.guid, avail, h)
    reaper.ImGui_PopID(ctx)
  end
  if move_from then
    rows[move_from], rows[move_to] = rows[move_to], rows[move_from]
    save_lane_order(rows)
  end

  -- footer (responsive: items flow to the next row when the panel narrows;
  -- wrap_next(w) = "put the next w-px item on this row only if it fits")
  reaper.ImGui_Separator(ctx)
  local rv
  if view == 'mask' then
    local ch
    ch, show_contest = reaper.ImGui_Checkbox(ctx, '##showc', show_contest)
    if ch then reaper.SetExtState('Comparator', 'show_contest', show_contest and '1' or '0', true) end
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextColored(ctx, COL_CONTEST, '\xE2\x96\xA0 competing')
    tip('Both tracks live here at comparable levels (within the ramp range).\nNeither wins = mud. Decide which track should own this range and\ncarve the other. Checkbox shows/hides this layer.')
    wrap_next(170)
    ch, show_louder = reaper.ImGui_Checkbox(ctx, '##showl', show_louder)
    if ch then reaper.SetExtState('Comparator', 'show_louder', show_louder and '1' or '0', true) end
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextColored(ctx, COL_INTRUDE, '\xE2\x96\xA0 reference louder')
    tip('The Reference is clearly LOUDER than this track here — the Reference\nowns this range. Fine if intended; if this track should own it instead\n(e.g. pad drowning the bass low end), cut the Reference here.\nCheckbox shows/hides this layer.')
    wrap_next(80)
    local sp_ch
    sp_ch, spatial_on = reaper.ImGui_Checkbox(ctx, 'spatial', spatial_on)
    if sp_ch then reaper.SetExtState('Comparator', 'spatial', spatial_on and '1' or '0', true) end
    tip('Discounts overlap when the two tracks sit apart in the stereo image.')
    wrap_next(430)
    reaper.ImGui_TextColored(ctx, COL_STALE, '(track louder = unpainted; star the other track for the reverse view)')

    local ac_changed
    ac_changed, auto_cal = reaper.ImGui_Checkbox(ctx, 'auto', auto_cal)
    if ac_changed then reaper.SetExtState('Comparator', 'auto_cal', auto_cal and '1' or '0', true) end
    tip('Derive ramp and floor from the Reference automatically: a narrow\nreference guards only its core zones with a tight ramp; a broadband\none keeps more territory. Sliders follow along (and are locked).')
    wrap_next(200)
    if auto_cal then reaper.ImGui_BeginDisabled(ctx) end
    reaper.ImGui_SetNextItemWidth(ctx, 140)
    rv, prm.ramp = reaper.ImGui_SliderDouble(ctx, 'ramp', prm.ramp, 1, 18, '%.0f dB')
    tickReset(prm, 'ramp', 1, 18, 6.0, string.format('%.0f dB', prm.ramp), 140)
    tip('Level-difference range for the colors. Equal levels = pure red-orange\n(competing); it fades and violet reaches full once the Reference is\nthis many dB louder than the track. Smaller = stricter.\nDouble-click resets to 6.')
    wrap_next(200)
    reaper.ImGui_SetNextItemWidth(ctx, 140)
    rv, prm.floor = reaper.ImGui_SliderDouble(ctx, 'floor', prm.floor, -60, -10, '%.0f dB')
    tickReset(prm, 'floor', -60, -10, -30.0, string.format('%.0f dB', prm.floor), 140)
    tip('What counts as a track\x27s territory: bands more than this far below\nthat track\x27s OWN loudest band are ignored. Applies to the Reference\nand each compared track alike, so fader moves don\x27t change meaning.\nCloser to 0 = core zones only; more negative = faint edges too.\nDouble-click resets to -30.')
    if auto_cal then reaper.ImGui_EndDisabled(ctx) end
    wrap_next(80)
  elseif view == 'width' then
    reaper.ImGui_TextColored(ctx, 0x2FE5DEFF, '\xE2\x96\xA0')
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextColored(ctx, 0x8B97A2FF, 'tint = stereo width (side share)')
    wrap_next(250)
    reaper.ImGui_TextColored(ctx, 0xE8B02EFF, '\xE2\x96\xA0')
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextColored(ctx, 0x8B97A2FF, 'mono-loss risk (correlation < 0)')
    wrap_next(80)
  elseif view == 'contrib' then
    reaper.ImGui_TextColored(ctx, 0x5FA8D3FF, '\xE2\x96\xA0')
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_TextColored(ctx, 0x8B97A2FF, 'bar height = this track\x27s share of all tapped energy in that band')
    wrap_next(190)
    reaper.ImGui_TextColored(ctx, 0x8B97A2FF, '\xE2\x98\x85 not used in this view')
    wrap_next(80)
  end
  local st_ch
  st_ch, show_strips = reaper.ImGui_Checkbox(ctx, 'strips', show_strips)
  if st_ch then reaper.SetExtState('Comparator', 'strips', show_strips and '1' or '0', true) end
  tip('20-second activity timeline under each lane ("who was playing when").\nMost useful for phrased material (vocals, comps, percussion); turn off\nif your tracks all play wall-to-wall.')
  wrap_next(100)
  rv, avg_fast = reaper.ImGui_Checkbox(ctx, 'fast avg', avg_fast)
  tip('Display smoothing speed. Fast = meters react quickly but jump around;\nslow (off) = calmer, easier to read while making EQ decisions.')
  wrap_next(180)
  reaper.ImGui_SetNextItemWidth(ctx, 110)
  local lane_before = prm.lane
  rv, prm.lane = reaper.ImGui_SliderInt(ctx, 'lane px', math.floor(prm.lane), 24, 240)
  tickReset(prm, 'lane', 24, 240, 120, tostring(math.floor(prm.lane)), 110)
  if prm.lane ~= lane_before then
    reaper.SetExtState('Comparator', 'lane_h', tostring(math.floor(prm.lane)), true)
  end
  tip('Default lane height. Drag the thin strip under any individual lane\nto resize just that lane (per-lane sizes are saved with the project;\ndouble-click a strip to reset that lane). Double-click resets to 120.')
  wrap_next(100)
  if reaper.ImGui_Button(ctx, 'reset order') then
    lane_order = {}
    reaper.SetProjExtState(0, 'Comparator', 'lane_order', '')
  end
  tip('Forget the manual lane order and go back to project track order.')

  if reaper.ImGui_Button(ctx, 'Tap all') then
    reaper.Undo_BeginBlock2(0)
    B.tap_tracks('all')
    reaper.Undo_EndBlock2(0, 'Comparator: tap all tracks', -1)
    nudge_playback()
  end
  tip('Insert the analyzer tap (last in FX chain) on every leaf track.\nSkips folder parents and receive-only tracks/buses. Safe to re-run;\nalready-tapped tracks are left untouched.')
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, 'Tap selected') then
    reaper.Undo_BeginBlock2(0)
    B.tap_tracks('selected')
    reaper.Undo_EndBlock2(0, 'Comparator: tap selected tracks', -1)
    nudge_playback()
  end
  tip('Insert the tap on the selected track(s) regardless of type —\nthis is how you deliberately meter a bus or FX return.')
  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, 'Remove all') then
    if reaper.MB('Remove every Comparator tap from the project?', 'Comparator', 4) == 6 then
      reaper.Undo_BeginBlock2(0)
      B.remove_all()
      reaper.Undo_EndBlock2(0, 'Comparator: remove all taps', -1)
    end
  end
  tip('Delete every Comparator tap from the project (asks first).')
end

-- Whole-window visual pass (SPEC-v1.2 "Visual design"): pushed before Begin,
-- popped after End, so it applies to the titlebar/frame too and never gets
-- skipped by the pcall guard around frame(). 16 colors, 6 vars — see pop_theme.
-- Scrollbar tokens follow Contour's theme (reaper-lfo-toolkit ui/theme.lua).
local function push_theme()
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(), 0x1E1E22FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(), 0x26262BFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(), 0x2E2E34FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(), 0x33333AFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), 0x35353CFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0xE9EEF2FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_CheckMark(), 0x53C9D6FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrab(), 0x359DADFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_SliderGrabActive(), 0x53C9D6FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), 0x26262BFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), 0x2E2E34FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(), 0x31424AFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarBg(), 0x1B1E23FF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrab(), 0x3C444EFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrabHovered(), 0x4A535EFF)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ScrollbarGrabActive(), 0x53C9D6FF)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 3)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_GrabRounding(), 3)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 10, 8)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 8, 5)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ScrollbarRounding(), 6)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ScrollbarSize(), 12)
end

local function pop_theme()
  reaper.ImGui_PopStyleVar(ctx)
  reaper.ImGui_PopStyleVar(ctx)
  reaper.ImGui_PopStyleVar(ctx)
  reaper.ImGui_PopStyleVar(ctx)
  reaper.ImGui_PopStyleVar(ctx)
  reaper.ImGui_PopStyleVar(ctx)
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_PopStyleColor(ctx)
  reaper.ImGui_PopStyleColor(ctx)
end

-- ---------------------------------------------------------------------------
-- In-app guide ('?' in the toolbar). Sections of plain text, same theme.
local GUIDE = {
  { 'What this is',
    'Live interference metering: star a Reference track - your current point of view - and every other tapped track shows where the Reference competes with it or drowns it, per frequency band.\n\nThe Reference is whichever track you\x27re asking the question FROM: the one you plan to EQ, the one you want to protect (a lead vocal), or the one you suspect of causing trouble. Swap the star freely - each choice asks a different question.\n\nThree views answer three questions:\n- Masking: who fights the Reference, where, and whether it\x27s constant\n- Width: who claims the stereo sides, and what dies in mono\n- Contribution: who owns each region of the whole tapped mix' },
  { 'Quick start',
    '1. Tap all - inserts an analyzer last in every leaf track\x27s FX chain.\n2. Press play.\n3. Star (\xE2\x98\x85) your point-of-view track: the one to protect, examine, or fix.\n4. Read the colors on the other lanes. Carve, watch them respond.\n5. Freeze (toolbar) any time you want to read calmly.' },
  { 'Visual vocabulary - every mark on screen',
    'BLUE BARS - the track\x27s spectrum, 32 bands, 20 Hz to 20 kHz (log scale; the Reference lane has the Hz ruler).\n\nRED-ORANGE OVERLAY - competing with the Reference (details below).\n\nVIOLET OVERLAY - Reference louder than this track there (details below).\n\nWHITE DOTTED LINE across a band\x27s top + dimmer paint - the conflict in that band is NOT constant; it comes and goes, or the tracks take turns. Hover the band to see which.\n\nN% BADGE - share of this track\x27s energy the Reference is contesting or out-levelling. In Contribution view: share of the whole tapped mix.\n\ncr N dB - crest factor (peaks vs average): under 6 dB reads as squashed/dense, over 15 dB as punchy/spiky.\n\nmono-loss (amber, Width view) - this track partially cancels when summed to mono.\n\n(no data) - the tap on that track is not publishing: bypassed, offline, or (after a JSFX update) still running the old version. See Housekeeping.\n\nTHIN COLORED TAPE under a lane (when "strips" is on) - the 20-second activity timeline; the small teal edge at its right is "now".\n\nTHIN GREY STRIP at a lane\x27s very bottom - drag it to resize the lane; double-click resets.' },
  { 'Masking view: the colors, with examples',
    'RED-ORANGE (competing): both tracks hold comparable levels in a band where both genuinely live. Neither wins - that\x27s where mud comes from.\nExample: your pad and a piano both sit around 1-2 kHz at similar level. That zone paints red-orange on the piano\x27s lane. Decide who owns 1-2 kHz and carve the other one there.\n\nVIOLET (reference louder): the Reference out-levels this track inside the track\x27s OWN territory.\nExample: the pad is starred and the bass lane shows violet at 60-150 Hz - the pad is drowning the bass in the bass\x27s home. If the bass should win there (it almost always should), high-pass or shelf the pad. Watch the violet fade as you do.\n\nUNPAINTED: this track simply wins there. Owned territory is never a problem.\nExample: the bass lane\x27s lowest bands show no paint even though the pad also has lows - because the bass is clearly louder there. Nothing to fix. To ask the reverse question (is the BASS stepping on the PAD?), star the bass instead.\n\nThe two colors crossfade: equal levels = pure red-orange; Reference louder by the full ramp (default 6 dB) = pure violet.' },
  { 'The dotted line: constant vs sometimes vs taking turns',
    'The tool watches each band for ~10 seconds and renders the overlap by how STEADY it has been:\n\nSOLID PAINT (no dotted line) = the clash is present at least 70% of the time. Structural: the two sounds always collide there. A permanent (static) EQ move is a reasonable answer to a permanent problem.\nExample: sustained pad vs sustained bass - their low-band overlap never blinks, so it draws solid.\n\nDIMMER PAINT + WHITE DOTTED TOP EDGE = intermittent (roughly 20-70% of the time). The conflict only exists sometimes - a permanent cut would also punish the moments with no conflict.\nExample: piano comping against a lead vocal - the presence zone flags only while chords ring under a phrase. Hover reads "intermittent".\n\nSAME DOTTED TREATMENT, hover reads "takes turns" = both tracks use the band but almost never at the same instant.\nExample: kick and bass sharing 50-120 Hz on alternating beats. A frequency meter alone would scream conflict; in time they interleave, and your groove already solved it. This classification exists mostly to stop unnecessary EQ.\n\nHover any painted band: the tooltip shows its frequency range, the state (competing / reference louder), and the classification (steady / intermittent / takes turns).' },
  { 'Spatial: same band is only a fight in the same place',
    'Two sounds sharing frequencies barely mask each other if they sit in different places in the stereo image - your ears separate them by location.\n\nWith "spatial" on (default), paint is discounted by pan distance. Track panning is read from the TCP pan knob automatically; pan baked into the source (a synth\x27s own stereo spread) is measured from the audio itself.\nExample: pad starred and centered, keys panned 50% right. With spatial ON their shared 1-4 kHz paints faintly or not at all; toggle spatial OFF and the same zone lights up. The difference is what panning is doing for you. Sometimes the fix for masking is not EQ - it\x27s panning one element away.' },
  { 'Width view, with an example',
    'Bar tint = each band\x27s stereo width: GREY = narrow/mono (colorless, literally), CYAN = wide - the wider the band, the more color it gets. Hover a band for width % and correlation.\n\nThe amber "mono-loss" badge appears when a track\x27s stereo size is built from left and right FIGHTING each other (negative correlation), typically from stereo wideners. It sounds huge on headphones and partially cancels on any mono playback: phone speaker, many club PAs, some Bluetooth.\nExample: a widened synth shows strong cyan plus "mono-loss". Ease the widener depth or mono everything below ~200 Hz; the badge clears while the safe width stays.\n\nAlso worth a glance: multiple tracks all wide in the SAME region = the sides turn to soup and nothing sounds big. Narrow the least important one.' },
  { 'Contribution view, with an example',
    'Bar height = this track\x27s share of ALL tapped energy in that band; the badge = its overall share. The \xE2\x98\x85 is ignored here - no Reference needed.\n\nUse it when the mix feels crowded but no single PAIR of tracks looks guilty.\nExample: the low-mids feel stuffed, yet every masking comparison looks mild. Contribution view shows the pad holding 55% of everything at 200-500 Hz on its own. One glutton, no fights. Thin the pad there (or pick a leaner patch) and watch the shares rebalance.\n\nOnly tapped tracks are counted - the "mix" here is the sum of what\x27s tapped.' },
  { 'A worked session, start to finish',
    'Goal: make the pad, bass and keys coexist.\n\n1. Tap all, play the busiest section, star the PAD (you\x27ll EQ it first).\n2. Bass lane shows solid violet at 60-150 Hz: the pad is drowning the bass constantly. High-pass the pad around 120-150 Hz. Violet fades to nothing.\n3. Keys lane shows dotted red-orange at 1-2 kHz, hover says "intermittent": only while both play. Either accept it, or pan the keys slightly (watch spatial reduce it), or use a dynamic EQ move if it still bothers your ears.\n4. Freeze, hover the remaining painted bands, read the classifications calmly. Unfreeze.\n5. Star the BASS to ask the reverse question. Check nobody drowns IT.\n6. Switch to Width once per mix: any "mono-loss" badges? Fix those before someone hears your mix on a phone.\n7. Switch to Contribution when something still feels crowded and nothing above explains it.' },
  { 'Controls reference',
    'auto - derive ramp and floor from the Reference\x27s spectrum continuously. Broadband reference -> deep floor + wide ramp (guard everything, judge gently); narrow reference -> shallow floor + tight ramp (only its core zones). Sliders lock and glide while on.\n\nramp - the dB range over which the colors crossfade. At 6 dB: equal levels = pure red-orange, Reference 6 dB louder = pure violet. Smaller = stricter judgments.\n\nfloor - what counts as a track\x27s territory: bands more than this far below that track\x27s OWN loudest band are ignored entirely. Applies to the Reference and each compared track alike, so fader moves never change its meaning.\n\nspatial - the pan-distance discount (see its section).\n\ncompeting / reference louder checkboxes - show or hide each paint layer independently.\n\nfast avg - snappier display smoothing (jumpier, more responsive).\n\nstrips - the activity timelines, on by default; turn off if they earn nothing on your material.\n\nlane px - default lane height; individual lanes resize by dragging their bottom strip.\n\nfreeze - hold everything still to read; amber while engaged.\n\nAll sliders: double-click resets to default. Hover anything for its tooltip.' },
  { 'Lane controls',
    '\xE2\x89\xA1 drag up/down - reorder lanes; the order is saved with the project; "reset order" (footer) restores project track order.\n\n\xE2\x98\x85 - make this track the Reference.\n\nfx - opens the FX browser targeting this track; whatever you add is kept BEFORE the tap automatically (the tap re-seats itself to stay last, so metering always covers the full chain).\n\n\xC3\x97 - untap this track (lane disappears; one undo point).\n\nBottom grey strip - drag vertically to resize this lane only; double-click resets it. Sizes are saved with the project.' },
  { 'Activity strips: reading the tape',
    'A rolling 20-second recording of "was this track audible, and how loud". Newest at the RIGHT edge (small teal marker = now), history slides left, oldest falls off.\n\nHow patterns read:\n- solid unbroken ribbon = playing wall-to-wall (sustained pads; the strip tells you little there - the checkbox turns them off)\n- blocks with gaps = phrases (vocals, comping) - see exactly when it was silent\n- picket fence = rhythmic hits (drums)\n- two lanes whose blocks NEVER overlap in time cannot mask each other, whatever the spectrum says\n\nBar height is relative to that strip\x27s own loudest moment over the window, with silence drawing nothing at all.' },
  { 'Multi-out instruments (drum VSTs etc.)',
    'A tap analyzes ONE channel pair - 1/2 by default, which on a multi-out VST track carries the full mix, not the individual instrument.\n\nTwo recipes:\n1. Open the tap in that track\x27s FX chain and set "Analyze channel pair" to the instrument\x27s output pair (slider 1 = channels 3/4, 2 = 5/6, ...). Good for metering ONE instrument off the VST track.\n2. Tap the instrument\x27s child/receive track with Tap selected - receives always arrive on that track\x27s channels 1/2. Better when you want several instruments from one VST as separate lanes ("Tap all" skips receive-only tracks by design, so tap them explicitly).' },
  { 'Housekeeping & troubleshooting',
    'Metering follows faders, mutes and pan - what you see matches what you hear. Taps keep themselves last in their chains. Tapping during playback nudges the audio stream so new taps meter within a second.\n\n(no data) on a lane - the tap is bypassed/offline, or (most common) you updated Comparator_Tap.jsfx and that instance still runs the OLD code: running instances don\x27t reload from disk. Fix: Remove all, then Tap all (worst case: save and reopen the project first, then re-tap).\n\nEmpty window / no lanes - no taps in the project, or the JSFX isn\x27t installed under REAPER\x27s Effects folder. Run the Comparator_SelfTest action for diagnostics.\n\nAnd the principle behind all of it: every good mix contains masking - overlapping instruments blending is what a mix IS. The paint says "look here", never "this is wrong". Your ears outrank the meter, always.' },
}

-- Smooth wheel scrolling: the window opts out of ImGui's instant wheel
-- handling (NoScrollWithMouse) and we glide ScrollY toward an accumulated
-- target instead. Scrollbar drags still work and re-sync the target.
local scrolls = {}
local function smooth_scroll(key)
  local s = scrolls[key]
  if not s then s = { target = 0, expect = nil }; scrolls[key] = s end
  local cur = reaper.ImGui_GetScrollY(ctx)
  local maxy = reaper.ImGui_GetScrollMaxY(ctx)
  -- external movement (scrollbar drag, keyboard, resize): if the position
  -- isn't where our glide left it, the USER moved it — adopt it instead of
  -- tugging back toward a stale target
  if s.expect and math.abs(cur - s.expect) > 0.5 then
    s.target = cur
  end
  if reaper.ImGui_IsWindowHovered(ctx) then
    local wheel = reaper.ImGui_GetMouseWheel(ctx)
    if wheel and wheel ~= 0 then s.target = s.target - wheel * 60 end
  end
  if s.target < 0 then s.target = 0 elseif s.target > maxy then s.target = maxy end
  if math.abs(s.target - cur) >= 1 then
    local new = cur + (s.target - cur) * 0.3
    reaper.ImGui_SetScrollY(ctx, new)
    s.expect = new
  else
    s.target = cur
    s.expect = cur
  end
end

local help_y = {}   -- section Y positions captured while rendering (stable content)

local function draw_help()
  if not show_help then return end
  local gvp = reaper.ImGui_GetMainViewport(ctx)
  local gvw, gvh = reaper.ImGui_Viewport_GetWorkSize(gvp)
  reaper.ImGui_SetNextWindowSize(ctx, math.min(520, gvw * 0.9), math.min(560, gvh * 0.85),
      reaper.ImGui_Cond_FirstUseEver())
  local hv, hopen = reaper.ImGui_Begin(ctx, 'Comparator \xE2\x80\x94 Guide', true,
      reaper.ImGui_WindowFlags_NoScrollWithMouse())
  if hv then
    smooth_scroll('help')
    -- table of contents: click a title to glide to its section
    reaper.ImGui_TextColored(ctx, 0x8B97A2FF, 'Contents')
    for i, sec in ipairs(GUIDE) do
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), 0x53C9D6FF)
      if reaper.ImGui_Selectable(ctx, '  ' .. sec[1] .. '##toc' .. i, false) then
        local y = help_y[i]
        if y then
          local s = scrolls['help']
          if s then s.target = math.max(0, y - 8) else reaper.ImGui_SetScrollY(ctx, math.max(0, y - 8)) end
        end
      end
      reaper.ImGui_PopStyleColor(ctx)
    end
    reaper.ImGui_Dummy(ctx, 1, 8)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Dummy(ctx, 1, 8)
    -- content origin: subtracting it converts cursor positions to pure
    -- content-space (0 = first content line), cancelling BOTH the scroll
    -- offset and the window decoration (title bar + padding) — cursor pos
    -- alone is window-relative, which overshot anchors by the title bar
    local _, sy0 = reaper.ImGui_GetCursorStartPos(ctx)
    for i, sec in ipairs(GUIDE) do
      help_y[i] = reaper.ImGui_GetCursorPosY(ctx) - sy0
      reaper.ImGui_TextColored(ctx, 0x53C9D6FF, sec[1])
      reaper.ImGui_TextWrapped(ctx, sec[2])
      reaper.ImGui_Dummy(ctx, 1, 6)
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_Dummy(ctx, 1, 6)
    end
    reaper.ImGui_End(ctx)
  end
  if not hopen then show_help = false end
end

-- a frame() throw must not brick the window: pcall keeps Begin/End balanced
-- and the defer loop alive; the error prints once per distinct message
-- instead of spamming the console every frame (pattern from Contour)
local last_draw_err

local function loop()
  run_pending_nudge()
  push_theme()
  -- roomy default (three ~120px lanes + reference + footer without
  -- scrolling), clamped to the monitor's work area so it can't overflow
  -- small laptop screens; FirstUseEver, so user resizes stick
  local vp = reaper.ImGui_GetMainViewport(ctx)
  local vw, vh = reaper.ImGui_Viewport_GetWorkSize(vp)
  reaper.ImGui_SetNextWindowSize(ctx, math.min(920, vw * 0.9), math.min(780, vh * 0.85),
      reaper.ImGui_Cond_FirstUseEver())
  local visible, open = reaper.ImGui_Begin(ctx, 'Comparator', true,
      reaper.ImGui_WindowFlags_NoScrollWithMouse())
  if visible then
    smooth_scroll('main')
    local ok, err = pcall(frame)
    reaper.ImGui_End(ctx)
    if not ok and err ~= last_draw_err then
      last_draw_err = err
      reaper.ShowConsoleMsg('Comparator draw error: ' .. tostring(err) .. '\n')
    end
  end
  draw_help()   -- its own window, themed, Begin/End balanced internally
  pop_theme()
  if open then reaper.defer(loop) end
end

reaper.defer(loop)
