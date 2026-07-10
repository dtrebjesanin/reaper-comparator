# Comparator

> **⚠️ Work in progress / experiment (v0.1.0).** This is an early public release of a tool built and field-tested in one studio. It works — but expect rough edges, opinionated defaults, and breaking changes between updates (tap protocol changes require re-tapping your project). Feedback and bug reports are very welcome.

![Comparator](media/Comparator.gif)

Live interference metering for REAPER. Star a Reference track and every other tapped track shows where the Reference competes with it (red-orange) or out-levels it in its own territory (violet), per frequency band: like an electronic comparator, it tells you which signal wins, everywhere at once. The comparison is pan-aware, classifies conflicts by time (steady / intermittent / takes turns), and two further views cover stereo width & mono compatibility and per-band mix contribution, plus crest factors and activity timelines. Built entirely on REAPER-native technology: a JSFX tap per track, shared `gmem`, and a ReaImGui window for the UI.

## Important: updates that change the tap

Two facts combine into one gotcha: the JSFX tap and the window communicate through a shared-memory layout that may still change between 0.x updates, and REAPER keeps a tap's *old* code running in already-open projects even after the file on disk is updated.

**So, when an update's changelog says the tap changed:** in each project with taps already inserted, click **Remove all**, then **Tap all** (or **Tap selected**) once. Until you do, old taps show as **"(no data)"** even while playing back. New projects, and updates that don't touch the tap, are unaffected.

## Requirements

- REAPER 6.8+
- ReaImGui extension (install via ReaPack)

## Install

**Via ReaPack (recommended):** Extensions → ReaPack → Import repositories, paste

```
https://github.com/dtrebjesanin/reaper-comparator/raw/main/index.xml
```

then install **both** packages from the Comparator category: `Comparator.lua` (the scripts) and `Comparator_Tap.jsfx` (the analyzer). Updates arrive through ReaPack's Synchronize packages — check each version's changelog, some updates require a one-time **Remove all → Tap all** in open projects.

**Manual install:**

1. Copy `Comparator_Tap.jsfx` anywhere under `<REAPER resource path>/Effects/` (a `Comparator/` subfolder keeps things tidy; the tool finds it either way via its FX name).
   Find your resource path via **Options → Show REAPER resource path** — on Windows typically `%APPDATA%\REAPER`, on macOS `~/Library/Application Support/REAPER`.
   After installing on a new machine (especially macOS), run the self-test (below) once — its scratch-track section validates the API behaviors the tool relies on.
2. Load `Comparator.lua` and `Comparator_SelfTest.lua` as actions via **Actions → Show action list → New action... → Load ReaScript**.

**Important:** `Comparator.lua`, `Comparator_SelfTest.lua`, `comparator_core.lua`, and `comparator_bridge.lua` must all stay together in one folder. `Comparator.lua` and `Comparator_SelfTest.lua` load the other two with `dofile` using a path relative to their own location — if you move the `.lua` files apart, they will fail to load.

## First run / self-test

Before opening the main window, select an audio track and run the `Comparator_SelfTest` action. It prints diagnostics to the ReaScript console. Good output looks like:

- At least one of the `AddByName` candidate probes returns an index `>= 0` (this confirms the JSFX is installed where REAPER can find it).
- After you tap a track and play audio, re-running the self-test shows the heartbeat counter increasing between runs.
- Band powers (`band8` in the printout) are nonzero on tracks with audible signal.

If none of the `AddByName` candidates return `>= 0`, the JSFX isn't installed at the expected `Effects/Comparator/` path — recheck step 1 of Install.

## Usage

1. Run the `Comparator` action to open the window.
2. Click **Tap all** to insert a tap on every leaf track (idempotent — only adds taps that are missing). Playing tracks meter within about half a second (the window nudges the audio stream automatically).
3. Press play.
4. Click the ★ next to a track to make it the Reference — the track you intend to EQ (e.g. the pad).
5. Pick a view with the **Masking / Width / Contribution** selector in the toolbar (each answers a different question) and read the lanes as described below.

### Masking view (default)

*Who fights the Reference, where — and whether it's constant.*
- **red-orange = competing** — both tracks hold comparable levels where both live. Mud; decide who owns the range and carve the other.
- **violet = reference louder** — the Reference out-levels this track in the track's own territory ("pad has too much bass" → violet on the bass lane's lows → cut the pad there).
- **unpainted** = this track simply wins there (owned territory). Star the other track to inspect the reverse direction.
- The **%** badge = share of this track's energy the Reference is contesting or out-levelling.

The **spatial** checkbox (default on) discounts overlap when the two tracks sit apart in the stereo image — red now means "same band, same place in the image," not just "same band." Turn it off to A/B against the old, pan-blind coloring.

Overlapping bands also render by how *steady* the overlap has been over the last ~10 s:
- **solid** fill = stable overlap (the band has been in conflict at least 70% of the time) — hover reads **"steady"**: a real, constant clash.
- **reduced-alpha with a dashed top edge** = intermittent (roughly 20-70% of the time) — hover reads **"intermittent"**: comes and goes.
- Same dashed treatment when two tracks are *trading off* rather than clashing (both active but rarely overlapping, e.g. kick vs. bass) — hover reads **"takes turns"**.

### Width view

*Who claims the stereo sides, and what dies in mono.* Same lanes, tinted by per-band stereo width (side share) instead of masking color — neutral/blue when narrow or mono, shifting teal as width grows. Bands with correlation below −0.2 get a warning tint plus a **mono-loss** lane badge — that track would partially cancel if summed to mono. Hover a lane for width % and correlation at that band.

### Contribution view

*Who owns each region of the tapped mix.* Bar height (not color) shows each track's share of the combined energy of all tapped tracks in that band — a bar filling most of the lane means this track dominates the mix there. The **%** badge is the track's overall energy share; it only accounts for tracks that are actually tapped (see Limitations). The Reference star has no effect in this view.

### Crest badges and activity strips (all views)

Each lane shows a **`cr N dB`** badge — broadband crest factor (peak vs. average level): below 6 dB reads as squashed/compressed, above 15 dB as punchy/spiky material like drums.

Under each lane's spectrum, a thin **activity strip** plots that track's level over the last ~20 s — a quick "who was playing when" reference, handy for spotting alternating parts (like the kick/bass example above) without scrubbing the timeline.

Per-lane controls: **≡** drag to reorder lanes (saved per project, "reset order" restores track order) · **★** set Reference · **fx** open the track's FX chain (anything you add is kept before the tap automatically) · **×** untap this track · drag the thin strip under a lane to resize it (double-click resets).

Footer controls (sliders double-click to their defaults; ramp/floor/auto only apply to the Masking view, since Width and Contribution don't compare against a Reference):
- Legend checkboxes — show/hide the competing and reference-louder layers independently (Masking view).
- **spatial** — toggles the pan-aware discount described above (Masking view).
- **auto** — derive ramp and floor from the Reference's spectrum continuously; sliders lock and follow (Masking view).
- **ramp** — level-difference range for the colors: equal levels = pure red-orange, Reference this many dB louder = pure violet (Masking view).
- **floor** — a band counts as a track's territory only within this many dB of that track's own loudest band (applies to Reference and compared tracks alike, so fader moves don't change meaning) (Masking view).
- **fast avg** — faster display smoothing.
- **lane px** — default lane height.

Other buttons:
- **Tap selected** — insert a tap only on the selected track(s). This is also how you deliberately tap a bus (buses are skipped by "Tap all").
- **Remove all** — deletes every Comparator tap in the project (asks for confirmation).

Taps re-seat themselves: if anything ends up after a tap in an FX chain, the tap slides back to last within a second, so metering always reflects the full chain.

## Limitations

- Each tap analyzes ONE channel pair — channels 1/2 by default. For multichannel tracks (multi-out drum/synth VSTs), open the tap in the FX chain and set its **"Analyze channel pair"** slider to the pair carrying the instrument you care about (1 = channels 3/4, 2 = 5/6, ...). Alternatively, tap the instrument's own child/receive track with "Tap selected" — receives always arrive on that track's 1/2.
- "Tap all" targets leaf tracks only — folder parents and receive-only tracks are skipped to avoid double-counting. Tap a bus manually with "Tap selected" if you want it metered.
- The tap must stay last in its track's FX chain to reflect the full, post-FX signal. The window enforces this automatically (taps re-seat within ~1 s), but only while the window is open.
- Metering follows each track's fader and mute state, so it matches what you actually hear, not the raw source signal.
- Contribution view only counts tapped tracks — it approximates the full mix bus by summing the taps you have. Untapped tracks (including buses skipped by "Tap all") aren't represented in any share%.
- Temporal history for the Masking view (the solid/dashed steady-vs-intermittent-vs-takes-turns treatment) covers only the first 32 distinct tracks tapped in a session; tracks tapped beyond that count still meter normally but render as steady/solid (no dashing). Activity strips are not affected by this cap.
- Pan, width, and correlation (and everything derived from them: spatial discount, mono-loss, width tint) are per-band estimates from smoothed spectra, not sample-accurate — they lag fast transients and are meant for reading trends, not exact phase/pan measurement.

## Troubleshooting

- **A row shows "(no data)"**: the tap on that track is bypassed, offline, or the transport has never run since the project was loaded. Un-bypass the tap and press play.
- **The track list is empty**: no taps have been inserted yet (run "Tap all" or "Tap selected"), or the JSFX isn't installed at the expected `Effects/Comparator/` path — check the self-test output.
- **The window won't open**: ReaImGui isn't installed. Install it via ReaPack and restart REAPER.
