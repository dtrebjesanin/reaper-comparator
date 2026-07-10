local core = dofile((... or '') ~= '' and ... or 'comparator_core.lua')
    -- fallback path resolution: dofile relative to package.path set by runner
if core == nil then core = dofile('comparator_core.lua') end
local function close(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end
local function check(cond, msg) if not cond then error(msg, 2) end end

-- band edges
local e = core.band_edges()
check(#e == 33, 'expected 33 edges, got ' .. #e)
check(close(e[1], 20, 1e-9), 'edge 1 must be 20 Hz')
check(close(e[33], 20000, 0.01), 'edge 33 must be 20 kHz, got ' .. e[33])
check(e[17] > e[16], 'edges must be increasing')

-- band_of
check(core.band_of(19.9) == nil, 'below range must be nil')
check(core.band_of(20001) == nil, 'above range must be nil')
check(core.band_of(20) == 0, '20 Hz is band 0')
check(core.band_of(1000) == math.floor(32 * math.log(1000/20, 10) / 3), '1 kHz formula check')
check(core.band_of(19999) == 31, 'just under 20 kHz is band 31')

-- to_db
check(close(core.to_db(1), 0), '1.0 -> 0 dB')
check(close(core.to_db(0.001), -30), '0.001 -> -30 dB')
check(core.to_db(0) == -120, 'zero clamps to -120')
check(core.to_db(-5) == -120, 'negative clamps to -120')

-- interference: identical spectra -> fully contested, no intrusion, score 1
local ref, trk = {}, {}
for i = 1, 32 do ref[i] = 0.01; trk[i] = 0.01 end
local c, n, score = core.interference(ref, trk, 6, -30)
check(close(c[1], 1) and close(c[32], 1), 'equal levels -> contested 1')
check(close(n[1], 0) and close(n[32], 0), 'equal levels -> intrude 0')
check(close(score, 1, 1e-6), 'identical spectra -> score 1, got ' .. score)

-- interference: reference +6 dB everywhere (T=6) -> pure intrusion
for i = 1, 32 do ref[i] = 0.01 * 10^(6/10); trk[i] = 0.01 end
c, n, score = core.interference(ref, trk, 6, -30)
check(close(c[5], 0, 1e-6), 'ref +6 dB -> contested 0, got ' .. c[5])
check(close(n[5], 1), 'ref +6 dB -> intrude 1, got ' .. n[5])
check(close(score, 1, 1e-6), 'full intrusion -> score 1, got ' .. score)

-- interference: reference +3 dB -> amber/red crossfade point (0.5 each)
for i = 1, 32 do ref[i] = 0.01 * 10^(3/10); trk[i] = 0.01 end
c, n, score = core.interference(ref, trk, 6, -30)
check(close(c[5], 0.5, 1e-6), 'ref +3 dB -> contested 0.5, got ' .. c[5])
check(close(n[5], 0.5, 1e-6), 'ref +3 dB -> intrude 0.5, got ' .. n[5])

-- interference: track dominates the reference -> owned territory, unpainted
for i = 1, 32 do ref[i] = 0.01 * 10^(-12/10); trk[i] = 0.01 end  -- ref 12 dB down
c, n, score = core.interference(ref, trk, 6, -30)
check(close(score, 0), 'track dominating ref -> score 0, got ' .. score)

-- floor gating: intrusion only counts inside the TRACK's own territory
for i = 1, 32 do ref[i] = 0.01; trk[i] = 0.01 * 10^(-40/10) end  -- trk 40 dB down...
trk[5] = 0.01                                                    -- ...except band 5
c, n, score = core.interference(ref, trk, 6, -30)
check(close(n[9], 0), 'trk inactive band -> no intrusion, got ' .. n[9])
check(close(c[5], 1), 'trk active equal band -> contested, got ' .. c[5])

-- silence guards: near-silent track or reference -> all zeros
for i = 1, 32 do ref[i] = 0.01; trk[i] = 0 end
c, n, score = core.interference(ref, trk, 6, -30)
check(close(score, 0) and close(n[5], 0), 'silent track -> nothing, got ' .. score)
for i = 1, 32 do ref[i] = 0; trk[i] = 0.01 end
c, n, score = core.interference(ref, trk, 6, -30)
check(close(score, 0) and close(c[5], 0), 'silent reference -> nothing, got ' .. score)

-- weighting: score follows the track's dominant territory
for i = 1, 32 do ref[i] = 1e-12; trk[i] = 1e-12 end
trk[8] = 0.1; ref[8] = 0.1 * 10^(6/10)  -- trk lives in band 8; ref +6 dB there
c, n, score = core.interference(ref, trk, 6, -30)
check(score > 0.99, 'intrusion in trk dominant band must dominate score, got ' .. score)

-- autocal maps from spectral SPREAD (bands needed for 90% of energy):
-- flat/broadband -> deep floor, wide ramp (guard everything, judge gently)
local flat = {}
for i = 1, 32 do flat[i] = 0.01 end
local ar, af = core.autocal(flat)
check(af < -40, 'flat spectrum -> deep floor (< -40), got ' .. af)
check(ar > 10, 'flat spectrum -> wide ramp (> 10), got ' .. ar)

-- autocal: one dominant band -> shallow floor, tight ramp (core zones only)
local peaky = {}
for i = 1, 32 do peaky[i] = 1e-6 end
peaky[8] = 0.5
ar, af = core.autocal(peaky)
check(af >= -12 and af <= -10, 'dominant band -> shallow floor ~-11, got ' .. af)
check(ar < 4, 'dominant band -> tight ramp, got ' .. ar)

-- autocal: silence -> defaults
ar, af = core.autocal({})
check(ar == 6 and af == -30, 'silence -> defaults 6/-30, got ' .. ar .. '/' .. af)

-- autocal: gradual slope -> in between the extremes
local slope = {}
for i = 1, 32 do slope[i] = 0.01 * 10 ^ (-(i - 1) * 1.5 / 10) end  -- -1.5 dB per band
ar, af = core.autocal(slope)
check(af < -15 and af > -45, 'sloped spectrum -> mid floor, got ' .. af)

-- derive: pure-left signal -> hard left pan, half width, zero corr
local pL, pR, cLR, pk = {}, {}, {}, {}
for i = 1, 32 do pL[i] = 1; pR[i] = 0; cLR[i] = 0; pk[i] = 0 end
local d = core.derive(pL, pR, cLR, pk)
check(close(d.p[1], 1), 'pure-left: p must be 1, got ' .. d.p[1])
check(close(d.pan[1], -1), 'pure-left: pan must be -1, got ' .. d.pan[1])
check(close(d.width[1], 0.5), 'pure-left: width must be 0.5, got ' .. d.width[1])
check(close(d.corr[1], 0), 'pure-left: corr must be 0, got ' .. d.corr[1])

-- derive: identical correlated signal -> centered pan, zero width, full corr
for i = 1, 32 do pL[i] = 1; pR[i] = 1; cLR[i] = 1; pk[i] = 0 end
d = core.derive(pL, pR, cLR, pk)
check(close(d.pan[1], 0), 'identical: pan must be 0, got ' .. d.pan[1])
check(close(d.width[1], 0), 'identical: width must be 0, got ' .. d.width[1])
check(close(d.corr[1], 1), 'identical: corr must be 1, got ' .. d.corr[1])

-- derive: anti-correlated signal -> full width, corr -1
for i = 1, 32 do pL[i] = 1; pR[i] = 1; cLR[i] = -1; pk[i] = 0 end
d = core.derive(pL, pR, cLR, pk)
check(close(d.width[1], 1), 'anti-correlated: width must be 1, got ' .. d.width[1])
check(close(d.corr[1], -1), 'anti-correlated: corr must be -1, got ' .. d.corr[1])

-- derive: crest factor -> pk = 4*p -> 6.02 dB
for i = 1, 32 do pL[i] = 1; pR[i] = 1; cLR[i] = 0; pk[i] = 4 * (pL[i] + pR[i]) end
d = core.derive(pL, pR, cLR, pk)
check(close(d.crest_db[1], 6.02, 0.01), 'crest 4x power -> 6.02 dB, got ' .. d.crest_db[1])

-- derive: silent band guards (pL+pR <= 0) -> zeros everywhere
pL[1], pR[1], cLR[1], pk[1] = 0, 0, 0, 0
d = core.derive(pL, pR, cLR, pk)
check(d.pan[1] == 0 and d.width[1] == 0 and d.corr[1] == 0 and d.crest_db[1] == 0,
  'silent band must guard to all zeros')

-- derive: corr denominator guard (one channel silent, other active) -> corr 0
pL[1], pR[1], cLR[1], pk[1] = 1, 0, 0, 0
d = core.derive(pL, pR, cLR, pk)
check(close(d.corr[1], 0), 'zero-denominator corr must guard to 0, got ' .. d.corr[1])

-- derive: pk<=0 or p<=0 -> crest_db 0
pL[1], pR[1], cLR[1], pk[1] = 1, 1, 0, 0
d = core.derive(pL, pR, cLR, pk)
check(d.crest_db[1] == 0, 'pk<=0 must guard crest to 0, got ' .. d.crest_db[1])

-- derive: width/corr clamped to valid ranges against float noise
pL[1], pR[1], cLR[1], pk[1] = 1, 1, 1.0000001, 8
d = core.derive(pL, pR, cLR, pk)
check(d.corr[1] <= 1, 'corr must clamp to <= 1, got ' .. d.corr[1])
check(d.width[1] >= 0, 'width must clamp to >= 0, got ' .. d.width[1])

-- spatial
check(close(core.spatial(0.5, -0.5), 0), 'spatial(0.5,-0.5) must be 0, got ' .. core.spatial(0.5, -0.5))
check(close(core.spatial(0, 0), 1), 'spatial(0,0) must be 1, got ' .. core.spatial(0, 0))
check(close(core.spatial(0.3, 0.5), 0.8), 'spatial(0.3,0.5) must be 0.8, got ' .. core.spatial(0.3, 0.5))

-- interference_v2: use_spatial zeroes out overlap that v1 math would score fully
local ref_p, trk_p = {}, {}
for i = 1, 32 do ref_p[i] = 0.01; trk_p[i] = 0.01 end
local ref_d = { p = ref_p, pan = {}, width = {}, corr = {}, crest_db = {} }
local trk_d = { p = trk_p, pan = {}, width = {}, corr = {}, crest_db = {} }
for i = 1, 32 do ref_d.pan[i] = 0; trk_d.pan[i] = 1 end
local c2, n2, score2 = core.interference_v2(ref_d, trk_d, 6, -30, true)
check(close(score2, 0), 'opposite-pan tracks with spatial on -> score 0, got ' .. score2)
check(close(c2[5], 0) and close(n2[5], 0), 'opposite-pan bands must be zeroed by spatial')
-- sanity: without spatial, identical spectra fully overlap (matches v1 semantics)
local c2b, n2b, score2b = core.interference_v2(ref_d, trk_d, 6, -30, false)
check(close(score2b, 1, 1e-6), 'identical p without spatial -> full score, got ' .. score2b)

-- contribution: equal tracks -> each gets 1/n share
local all_p = {}
for t = 1, 4 do
  all_p[t] = {}
  for i = 1, 32 do all_p[t][i] = 1 end
end
local share = core.contribution(all_p, 2)
check(close(share[1], 0.25), 'equal contribution of 4 tracks -> 0.25, got ' .. share[1])
check(close(share[32], 0.25), 'equal contribution of 4 tracks -> 0.25, got ' .. share[32])

-- stability: fraction of frames where both true, over frames where ref_active is true
local stab = core.stability({1, 1, 0, 1}, {1, 1, 1, 1})
check(close(stab, 0.75), 'stability {1,1,0,1}/{1,1,1,1} -> 0.75, got ' .. stab)
-- stability: ref never active -> 0
stab = core.stability({1, 1, 1, 1}, {0, 0, 0, 0})
check(stab == 0, 'ref never active -> stability 0, got ' .. stab)
-- stability: empty arrays -> 0
stab = core.stability({}, {})
check(stab == 0, 'empty history -> stability 0, got ' .. stab)

print('test_core.lua: all assertions passed')
