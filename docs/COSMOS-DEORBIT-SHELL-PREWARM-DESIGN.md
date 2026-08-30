# COSMOS DE-ORBIT SHELL PRE-WARM — `FP_SHELL_PREWARM_DESCENT`

**Problem** (3rd attack on the same measured stall — Direction B): at the S1 anchor-release knee
(`ANCHOR_REL_LO/ANCHOR_HYST = 700/1.15 ≈ 608.7`, `cube_sphere.gd:2751/2753`) the FacetFarRing shell
rebuilds from a **collapsed / stale orbit residency** in ONE worker build: `sh_emit = sh_visN = 927`
facets ≈ 1.07 M prims → WASM dlmalloc single-lock convoy → **`worst_ms = 2662 @ alt = 596.9`**
(`vox_gen = 0`, `t_farring_us` tiny — the driver is cheap, the alloc storm is not). Reproduces on a
natural gradual de-orbit.

**Prior attempts, measured-REJECTED — do not repeat**:

1. `docs/COSMOS-PERF-ENGINE-DEEP-DESIGN.md` — mimalloc swap: rejected, +430 MB heap (NEVER-OOM).
2. `docs/COSMOS-FALL-CLITE-DESIGN.md` (`FP_REENTRY_*`) — near-field gen-flood gate: no benefit (the
   gen flood was not the cost). Standing lesson: `_fall_vy_ema` is speed-clamp-frozen (rejects
   samples ≥ 40 b/s) ⇒ useless on a 100–570 b/s de-orbit — use analytic radial-altitude Δ.
3. `docs/COSMOS-DEORBIT-SHELL-STAGING-DESIGN.md` (`FP_SHELL_STAGE_REEMIT`, commit 5c67a20) —
   per-dispatch **budget**: DID NOT FIRE at the knee. Root cause of the miss (§1.2 below): the knee
   burst is a **class-0 GROWTH** rebuild — the shell *opens* from its collapsed orbit residency, so
   the dirty sectors are never-built / member-gaining, and `_stage_filter_dirty` correctly exempts
   class 0 from the budget (deferring a never-built sector at a forced re-emit would be a hole).
   Budgeting the burst is the wrong axis.

**This design**: attack **WHEN** the build happens, not how much per frame. Pre-build the shell's
sector residency **during the descent**, ahead of the knee (band alt 1300 → 650), as a *paced,
staged* sequence of small dispatches — so by the release the sectors are resident and current
(class 1), the knee dispatch's dirty set is small, and the existing staging budget can absorb any
residual. Flag `FP_SHELL_PREWARM_DESCENT := false`, byte-identical off. **Design only — no code is
edited by this document.**

> Naming note: the existing `FP_SHELL_PREWARM` (`cube_sphere.gd:2954`, S2 one-shot whole-planet
> **coarse-cache** warm, `_prewarm_step` `facet_far_ring.gd:1327`) warms *caches*, never emits. This
> flag warms **sector mesh residency** on an incoming descent. Distinct flags, distinct state
> (`_prewarm_cursor`/`_offsurface_dwell` vs the new `_pwd_*` below); they compose (§7).

---

## 1. Root cause, grounded in the code (why the knee is a class-0 avalanche)

### 1.1 The residency decay during the descent

The emit law is the S1 camera-set cap: `shell_set_camera_abs` (`facet_far_ring.gd:1245`) snapshots
axis + `θ_emit = min(θ_h + 8° + 15° (+12° FALL_HOLD margin), 96°)` (`:1247–1254`) and the knee
regime is still `_shell_orbit()` (`:1982` — `_cam_set and not _emit_floored_last`; the floored flip
is `OFFSURFACE_Y = 256` (`cube_sphere.gd:2447`), *below* the 609 knee). With R = 6371, K = 24
(6·K² = 3456 facets): θ_emit(alt 1300) ≈ 68.9°, θ_emit(alt 650) ≈ 59.9°, θ_emit(alt 596) ≈ 58.9° —
a cap of ~900–930 facets, matching `sh_visN = 927`.

During the descent the shell deliberately does **not** re-emit:

- `FP_SHELL_FALL_HOLD` suppresses the radial re-emit for a shrinking cap and throttles axis-sweep
  re-emits to ≥ `SHELL_FALL_REEMIT_MS = 1000` past 13° of drift (`shell_fall_should_reemit`,
  `:1299–1307`);
- `FP_SHELL_ORBIT_IDLE` short-circuits the orbit branch entirely once converged
  (`:1523–1524`, `_orbit_converged`).

So the **resident sector state decays against the wanted set** for the whole fall: the sub-camera
axis sweeps with the orbital ground track (~570 b/s tangential ≈ 4.6°/s at these altitudes) and
θ_h shrinks, while the sector meshes still hold the residency of the last orbit-era build (possibly
also epoch-invalidated by any interim sync `_rebuild_full` → `_sectors_reset()` `:2369–2387`, which
leaves *every* sector "never built at the current epoch"). Live telemetry at orbit shows the
collapsed state directly: `sh_applied_r = 0` and a shell that has long since stopped re-emitting.

### 1.2 The knee, and why staging exempted it

At the knee the anchor re-grow arms `_pending` from up to five sources at once (SRC_CAM /
SRC_UNSINK / SRC_LADDER_* / SRC_SLOTS — staging doc §1.1). The next dispatch
(`_dispatch_async_rebuild` `:2433`) computes the dirty set (`_sectors_compute_dirty` `:2212`), and
`_stage_filter_dirty` (`:2262`) partitions it:

- **class 0** (`:2283–2292`): sector not built at the current epoch, **or** gaining a member its
  resident signature record lacks (`newmem`). *Unconditionally kept — never deferred.*
- **class 1**: resident, replacement-only. *Budgetable.*

and the trigger (`:2294`) counts **class-1 facets only** (`deferrable_dirty_facets >
SHELL_STAGE_TRIGGER`). After the un-emitted descent, the knee's wanted set is a swept/new cap over
sectors whose residency is stale or epoch-dead ⇒ the burst is (near-)all **class 0** ⇒
`deferrable_dirty_facets` never crosses the trigger ⇒ staging stays inert ⇒ one dispatch emits all
927 facets ⇒ the convoy. The class-0 exemption is *correct at a forced re-emit* (deferring
never-built coverage there is a real hole); the fix is to make sure the knee never *sees* a large
class-0 set.

### 1.3 What is actually left for the knee if residency is current

If the sectors are resident and current at ~650:

- **SRC_CAM**: the axis/θ_h delta accumulated over the last ≤ 500 ms of pre-warm pacing (§3) —
  a few rim facets.
- **SRC_UNSINK / SRC_LADDER_GROW**: the applied-cover ladder (`_applied_probe_step` `:1894`) can
  only climb once near meshes exist (`_applied_box_meshed` → `is_area_meshed`), i.e. below the
  ~700→609 anchor re-grow. Its dirty footprint is only **sunkish** sectors
  (`_sector_sig_sunkish` `:2201` — backstop ∧ dense-cache = the FULL_COVER dense disc under the
  player), a few sectors, and under `FP_UNSINK_DRIFT_CALM`/`FP_APPLIED_PROBE_CALM` the climb arms
  **once** at the fixpoint (`:1956–1962`). This is a small **class-1 replacement** — exactly what
  `FP_SHELL_STAGE_REEMIT` budgets, and below its trigger in the common case.
- **SRC_SLOTS**: re-slot waves ride the signature; sector-local, class-1.

So pre-warm converts the knee from "open 927 facets" into "replace a handful of sectors" — the
composition with staging (already deployed) closes the loop.

---

## 2. Design overview

New flag `FP_SHELL_PREWARM_DESCENT := false`. While the player is **off-surface, genuinely
descending, and inside the pre-warm altitude band (1300 → 650)**:

1. **Track** (E4/E5): a freeze-independent descent latch from analytic radial altitude Δ (the
   C-lite `reentry_descent_step` Schmitt latch, `cube_sphere.gd:2841` — reused as a pure static,
   *not* `_fall_vy_ema`), sampled on a wall-clock cadence inside `apply_camera_set` (which already
   computes `h` analytically every frame, `:1221–1226`).
2. **Refresh** (E6): while engaged, force a paced cap snapshot (≤ 1 per `SHELL_PREWARM_SNAP_MS`,
   and only when the cap actually moved) through the existing `_shell_snapshot` — a scoped,
   rate-bounded bypass of the FALL_HOLD suppression, so the *wanted* set tracks the live axis/θ_h
   down the descent instead of decaying.
3. **Build, budgeted** (E7/E8): each resulting dispatch runs the **existing staging machinery**
   with one pre-warm-scoped relaxation: class-0 *growth* becomes budget-eligible (and counts toward
   the trigger), because during pre-warm the emit is **voluntary** — deferring growth just delays
   geometry that today would not appear until the knee at all, while the resident cap + FALL_HOLD's
   +12° margin + the under-layers keep every visible pixel covered (§6). The run chains at worker
   speed via the shipped `SRC_STAGE` re-arm (`_poll_async_rebuild` `:2723–2728`), ≤
   `SHELL_STAGE_FACETS = 112` facets per dispatch, nearest-camera sectors first.
4. **Converge & idle**: once residency == wanted set, dirty sets come back empty/tiny; the pacer's
   drift/Δθ_h thresholds stop forcing snapshots; the shell is quiet until the knee — where the
   residual (§1.3) is small class-1, absorbed or staged as shipped.

**Mechanism choice** (task options): recommend **(c) compose with FP_SHELL_STAGE_REEMIT, driven by
(b)-style paced snapshots** — the two hooks above. Rejected:

- **(a) drive `_applied_r` up early**: the ladder is a *truth probe* of near-mesh coverage
  (`_applied_box_meshed` `:1809`); forcing it above the anchor knee claims sunk zone-C territory
  with **no near cover underneath ⇒ sunken-trench holes**, and the next probe tick re-verifies and
  drops it to 0 anyway (`:1903–1904`) — a flap, not a warm. Also `_applied_r` is not the cost: the
  cost is sector mesh residency; `sh_applied_r` at the knee is a *consequence* of the near re-grow
  and its dirty footprint is the small sunkish disc (§1.3).
- **(b) a standalone pre-build sector queue**: duplicates staging's queue-with-no-persisted-state,
  priority order, input hold, failsafe and telemetry. Composition is ~5 small edits and inherits
  all of staging's proven properties (its gate already passes; only its *scope* was wrong at the
  knee).

**Requires** (compile-time AND into the engage predicate): `FP_SHELL_CAMERA_SET` +
`FP_FARRING_SECTORS` + `FP_FARRING_ASYNC_REBUILD` + `FP_SHELL_STAGE_REEMIT` — all deployed-on.
Without staging, paced growth would be unbounded per dispatch; the flag simply stays inert.

---

## 3. The engage predicate and the pacing law

### 3.1 New constants (`godot/src/cosmos/cube_sphere.gd`, insert after `SHELL_STAGE_MAX_MS`, line 366)

```gdscript
## COSMOS DE-ORBIT SHELL PRE-WARM (docs/COSMOS-DEORBIT-SHELL-PREWARM-DESIGN.md) — build the far-ring
## shell's sector residency DURING the descent, ahead of the S1 anchor-release knee (~609), instead of
## opening it from the collapsed orbit state in ONE 927-facet/1.07M-prim worker build (the dlmalloc
## convoy's 2662 ms knee frame — the class-0 growth burst FP_SHELL_STAGE_REEMIT correctly exempts).
## While off-surface + analytically descending (radial-Δ Schmitt latch, NOT _fall_vy_ema) inside
## [SHELL_PWD_ALT_LO, SHELL_PWD_ALT_HI], the cap snapshot is refreshed on a pace and each dispatch is
## staged with class-0 growth budget-ELIGIBLE (voluntary emit ⇒ deferral is not a hole), ≤
## SHELL_STAGE_FACETS facets/dispatch, chaining on the shipped SRC_STAGE rail. By the knee the sectors
## are resident+current, so the release dirty set is a small class-1 replacement. Never engages at
## steady orbit (latch needs sustained −10 b/s radial), on foot (_shell_orbit() false), or on a climb.
## Requires FP_SHELL_CAMERA_SET + FP_FARRING_SECTORS + FP_FARRING_ASYNC_REBUILD + FP_SHELL_STAGE_REEMIT.
## Default OFF → the shell collapses at orbit and rebuilds at the knee exactly as today (byte-identical,
## FLAT 6042/0). Gate: src/tools/verify_shell_prewarm.gd.
const FP_SHELL_PREWARM_DESCENT := false
const SHELL_PWD_ALT_HI := 1300.0    # engage ceiling (blocks): ≥ 2× the knee, ≥ 1.1 s of band at 570 b/s
const SHELL_PWD_ALT_LO := 650.0     # engage floor: just above the 608.7 knee — below it the knee machinery owns
const SHELL_PWD_SAMPLE_MS := 250    # descent-latch sampling cadence (Δh/Δt per sample, Schmitt via reentry_descent_step)
const SHELL_PWD_SNAP_MS := 500      # min wall-ms between pre-warm-forced cap snapshots (the pacing bound)
const SHELL_PWD_DRIFT_DEG := 2.0    # force a snapshot only when the axis swept ≥ this since the last one…
const SHELL_PWD_DTH_DEG := 1.0      # …or θ_h moved ≥ this (else the pacer stays silent — no-op ticks are free)
```

Reused as-is: `REENTRY_DESCENT_VY_ON/OFF/CALM_N/VY_CLAMP` (`:2817–2822`) via the pure
`reentry_descent_step` (`:2841`), and `SHELL_STAGE_FACETS/TRIGGER/MAX_MS` (`:364–366`).

### 3.2 The predicate

```
_pwd_active := FP_SHELL_PREWARM_DESCENT
               and CubeSphere.FP_SHELL_STAGE_REEMIT and CubeSphere.FP_FARRING_SECTORS   # composition floor
               and _cam_set and _shell_orbit()          # S1 law engaged, off-surface regime (not floored)
               and _pwd_descending                      # Schmitt latch, §3.3
               and h >= SHELL_PWD_ALT_LO and h <= SHELL_PWD_ALT_HI
```

**Proof of off-states**:

- **Steady orbit** (circular, any altitude): radial rate ≈ 0 ≪ the 10 b/s engage threshold ⇒
  `_pwd_descending` never latches. Even in-band, no engagement ⇒ zero new work beyond one float
  compare per `SHELL_PWD_SAMPLE_MS`. (This is the FP_UNSINK_DRIFT_CALM lesson: no perpetual orbit
  rebuild is possible because the *trigger* is off, not because a budget clamps it.)
- **Ground / walk**: `_shell_orbit()` false below `OFFSURFACE_Y = 256` (`_emit_floored_last` true),
  and `h < 650` fails the band anyway ⇒ off. The surface paths (`_surface_converge_emit` etc.) are
  untouched.
- **Climb / fly-up**: Δh > 0 ⇒ `vy_w > −VY_OFF` ⇒ the latch releases after `CALM_N = 3` calm
  samples (and can never engage). A climb through the band does nothing.
- **Incoming de-orbit**: sustained radial descent (natural de-orbits measure 100–570 b/s ≫ 10 b/s)
  latches within 2 samples (~0.5 s); the band 1300→650 lasts 1.1 s (570 b/s) to 6.5 s (100 b/s) ⇒
  engaged for the whole approach.
- **Elliptical orbit dipping through the band**: engages transiently on the descending leg —
  by design (it *is* an incoming pass at the shell); after convergence the pacer's drift/Δθ_h
  thresholds and empty dirty sets make continued engagement near-free (§5), and the ascending leg
  releases the latch.
- **Freeze-independence**: `h` is `|cam − centre| − R_BLOCKS` computed analytically in
  `apply_camera_set` (`:1223–1225`) every frame WorldManager drives it (`world_manager.gd:3834`);
  no velocity state, no `_fall_vy_ema`, no dependence on the speed clamp or the physics regime.

### 3.3 The descent latch and the pacing law

Every `SHELL_PWD_SAMPLE_MS` (wall clock, inside `apply_camera_set`):

```
vy_w = (h − _pwd_prev_h) / dt          # blocks/s, analytic radial rate between samples
[_pwd_descending, _pwd_calm] = CubeSphere.reentry_descent_step(vy_w, _pwd_descending, _pwd_calm)
```

(`reentry_descent_step` gives the Schmitt band −10/−5 b/s, the 3-calm-sample release, and the
2000 b/s teleport clamp for free — the exact latch C-lite shipped for the same signal problem.)

**Pacing** (all bounds per *mechanism*, cumulative bound = their min):

| stage | bound | mechanism |
|---|---|---|
| snapshot | ≤ 1 / `SHELL_PWD_SNAP_MS` (500 ms), and only if drift ≥ 2° or Δθ_h ≥ 1° | E6 |
| dispatch | ≤ 1 in flight ever (`_async_building` gate, `:1490`) | shipped |
| build size | ≤ `max(SHELL_STAGE_FACETS = 112, largest single sector)` facets | E8 + shipped staging take-loop `:2305–2313` |
| chain | 1 worker round-trip ≈ 2 frames per slice, via SRC_STAGE (`:2723–2725`) | shipped |
| run wall-clock | `SHELL_STAGE_MAX_MS = 2500` failsafe (`:2298–2302`) | shipped |

**Throughput check**: full open = 927 facets ⇒ ⌈927/112⌉ ≈ 9 slices ≈ 18 frames ≈ **0.3 s** at
60 fps — inside even the fastest (1.1 s) band crossing with 3.7× margin; the per-slice worst frame
is staging's measured-regime ≤ ~294 ms linear bound, empirically ≤ ~60–120 ms (staging doc §3.1) —
i.e. **no stall is moved to a higher altitude**, the one-shot 2662 ms simply never forms. After the
initial open, each paced snapshot's incremental dirty is the ≤ 500 ms cap motion (~2.3° axis sweep
at 570 b/s ⇒ rim facets only) — sub-trigger, single small dispatches.

---

## 4. The pre-build mechanism — exact edit sites

All in `godot/src/world/facet_far_ring.gd` unless noted; every edit inert with the flag off.
Line numbers = worktree `deploy-cheats` @ `ea1162a`.

**E1 — `cube_sphere.gd:366`** (after `SHELL_STAGE_MAX_MS`): insert the §3.1 block.

**E2 — state (`facet_far_ring.gd:314`,** after the FP_SHELL_STAGE_REEMIT stage-run state block
ending at `_sector_sunk_built`):

```gdscript
# COSMOS DE-ORBIT SHELL PRE-WARM (FP_SHELL_PREWARM_DESCENT, doc in cube_sphere.gd): descent pre-warm
# state. ALL of it is zero/never touched with the flag off (byte-identical).
var _pwd_active := false          # engage predicate result (§3.2) — read by the snapshot pacer + dispatch freeze
var _pwd_descending := false      # analytic radial-Δ Schmitt latch (reentry_descent_step — NOT _fall_vy_ema)
var _pwd_calm := 0                # calm-sample count for the latch release
var _pwd_prev_h := 0.0            # last sampled analytic altitude
var _pwd_prev_ms := -1            # wall-clock of the last sample (−1 = no baseline yet)
var _pwd_snap_due := false        # rising-edge seed: force the first paced snapshot immediately
var _pwd_snap_count := 0          # forced-snapshot count (telemetry sh_pwd_snaps)
var _async_prewarm := false       # _pwd_active FROZEN at dispatch (worker-cycle-coherent staging mode)
```

**E3 — SRC enum (`:366–367`)**:

```gdscript
# before
const SRC_STAGE := 18          # staged re-emit continuation (FP_SHELL_STAGE_REEMIT — SAFETY, drains the run)
const SRC_COUNT := 19
# after
const SRC_STAGE := 18          # staged re-emit continuation (FP_SHELL_STAGE_REEMIT — SAFETY, drains the run)
const SRC_PREWARM := 19        # descent pre-warm paced snapshot (FP_SHELL_PREWARM_DESCENT — SAFETY)
const SRC_COUNT := 20
```

(+ the pinned-enum gate update in `verify_probe_calm.gd` — `SRC_COUNT == 20`, `SRC_PREWARM == 19`
appended to the order assertion; the same deliberate one-liner as staging's E12.)

**E4 — `apply_camera_set` (`:1226`)**, after `_offsurface = h > CubeSphere.OFFSURFACE_Y`:

```gdscript
	_pwd_tick(h)      # COSMOS DE-ORBIT SHELL PRE-WARM: descent latch + engage predicate (no-op unless FP_SHELL_PREWARM_DESCENT)
```

(This runs *before* the `shell_set_camera_abs` call at `:1236`, so a rising edge is consumable by
this same frame's snapshot pacer.)

**E5 — new `_pwd_tick(h: float, on := CubeSphere.FP_SHELL_PREWARM_DESCENT) -> void`** (place after
`_prewarm_step`, `:1356`; `on` is the codebase's gate-forcing param so the headless gate drives the
real law without a sed):

```gdscript
func _pwd_tick(h: float, on := CubeSphere.FP_SHELL_PREWARM_DESCENT) -> void:
	if not (on and CubeSphere.FP_SHELL_STAGE_REEMIT and CubeSphere.FP_FARRING_SECTORS):
		return
	var now := Time.get_ticks_msec()
	if _pwd_prev_ms < 0:
		_pwd_prev_h = h; _pwd_prev_ms = now
		return
	if now - _pwd_prev_ms >= CubeSphere.SHELL_PWD_SAMPLE_MS:
		var dt := float(now - _pwd_prev_ms) / 1000.0
		var r: Array = CubeSphere.reentry_descent_step((h - _pwd_prev_h) / dt, _pwd_descending, _pwd_calm)
		_pwd_descending = r[0]; _pwd_calm = r[1]
		_pwd_prev_h = h; _pwd_prev_ms = now
	var want := _cam_set and _shell_orbit() and _pwd_descending \
			and h >= CubeSphere.SHELL_PWD_ALT_LO and h <= CubeSphere.SHELL_PWD_ALT_HI
	if want and not _pwd_active:
		_pwd_snap_due = true          # rising edge: seed the first snapshot immediately (stale residency)
	_pwd_active = want
```

**E6 — `shell_set_camera_abs` (`:1287`)** — the paced snapshot (the scoped FALL_HOLD bypass).
Before:

```gdscript
	if reemit:
		_shell_snapshot(dir, new_cos, theta_h, floored)
		_last_snapshot_ms = Time.get_ticks_msec()
```

After:

```gdscript
	# COSMOS DE-ORBIT SHELL PRE-WARM: while the descent pre-warm is engaged, force a PACED snapshot so the
	# wanted set tracks the live axis/θ_h down the descent instead of decaying into the knee's one-shot
	# class-0 avalanche (doc in cube_sphere.gd). Bounded: ≥ SHELL_PWD_SNAP_MS apart AND only when the cap
	# actually moved (drift/Δθ_h thresholds) — or the engage rising edge. Off / not engaged ⇒ `reemit`
	# stands exactly as computed above (byte-identical).
	var pwd_snap := false
	if CubeSphere.FP_SHELL_PREWARM_DESCENT and _pwd_active and not reemit:
		pwd_snap = shell_prewarm_snap_due(_pwd_snap_due,
				Time.get_ticks_msec() - _last_snapshot_ms, drift, dtheta)
	if reemit or pwd_snap:
		if pwd_snap:
			_pwd_snap_due = false
			_pwd_snap_count += 1
		_shell_snapshot(dir, new_cos, theta_h, floored, SRC_PREWARM if pwd_snap else SRC_CAM)
		_last_snapshot_ms = Time.get_ticks_msec()
```

plus the pure decision static (beside `shell_fall_should_reemit`, `:1299` — directly gate-testable
with synthetic inputs, its precedent):

```gdscript
## COSMOS DE-ORBIT SHELL PRE-WARM: should an engaged pre-warm force a snapshot this frame? Pure.
static func shell_prewarm_snap_due(rising: bool, elapsed_ms: int, drift: float, dtheta: float) -> bool:
	if rising:
		return true
	if elapsed_ms < CubeSphere.SHELL_PWD_SNAP_MS:
		return false
	return drift >= deg_to_rad(CubeSphere.SHELL_PWD_DRIFT_DEG) \
		or absf(dtheta) >= deg_to_rad(CubeSphere.SHELL_PWD_DTH_DEG)
```

and the one-default-param widening of `_shell_snapshot` (`:1311`) —
`func _shell_snapshot(dir, cap_cos, theta_h, floored, src := SRC_CAM)` with `_arm_pending(SRC_CAM)`
(`:1317`) becoming `_arm_pending(src)`. Every existing caller passes no `src` ⇒ byte-identical.

**E7 — `_dispatch_async_rebuild` (`:2506–2515`)** — freeze the pre-warm mode for the cycle. Before:

```gdscript
	_async_sectored = sectored_on
```

After:

```gdscript
	_async_sectored = sectored_on
	_async_prewarm = CubeSphere.FP_SHELL_PREWARM_DESCENT and _pwd_active   # frozen: this cycle's staging mode
```

(`_stage_filter_dirty` reads the frozen `_async_prewarm`; a mid-run disengage cannot flip the
classification under an in-flight cycle. Note the *hold* semantics are unchanged: once a staged run
starts, `_stage_active` keeps budgeting to the drain (`:2294`) even if `_async_prewarm` goes false —
the shipped run-completion law.)

**E8 — `_stage_filter_dirty` (`:2283–2296`)** — pre-warm makes class-0 growth budget-eligible.
Before:

```gdscript
	var deferrable_dirty_facets := 0
	var class1: Array = []
	for s in _async_sector_dirty.keys():
		var built_current: bool = (s < _sector_built_epoch.size()) and (_sector_built_epoch[s] == _sector_epoch)
		if not built_current or bool(newmem.get(s, false)):
			continue     # class 0 — stays in the dirty set unconditionally
		deferrable_dirty_facets += int(facets.get(s, 0))
		class1.append([float(prio.get(s, -1.0)), s])
```

After:

```gdscript
	var deferrable_dirty_facets := 0
	var class1: Array = []
	# COSMOS DE-ORBIT SHELL PRE-WARM (FP_SHELL_PREWARM_DESCENT): during an ENGAGED pre-warm dispatch the
	# emit is VOLUNTARY (no regime forced it — the resident cap + FALL_HOLD's +12° margin + the under-layers
	# still cover every visible pixel), so deferring class-0 GROWTH is not a hole: it merely delays geometry
	# that, today, would not appear until the knee at all. Class 0 therefore joins the budget/trigger —
	# UNLESS the whole-cap `_mi` mesh still holds surfaces (a resident sync build): its swap-time clear
	# (`_swap_in_sectors` :2397) would drop coverage a deferred sector doesn't yet replace, so that (rare,
	# post-force_rebuild) state keeps the shipped class-0 exemption for the dispatch. Off / not engaged ⇒
	# the shipped partition verbatim (byte-identical — including at the knee with pre-warm disengaged).
	var pwd_growth_ok: bool = _async_prewarm \
			and not (_mi != null and _mi.mesh != null and (_mi.mesh as ArrayMesh).get_surface_count() > 0)
	for s in _async_sector_dirty.keys():
		var built_current: bool = (s < _sector_built_epoch.size()) and (_sector_built_epoch[s] == _sector_epoch)
		if (not built_current or bool(newmem.get(s, false))) and not pwd_growth_ok:
			continue     # class 0 — stays in the dirty set unconditionally (forced-re-emit correctness)
		deferrable_dirty_facets += int(facets.get(s, 0))
		class1.append([float(prio.get(s, -1.0)), s])
```

Everything downstream is shipped and correct as-is: the trigger (`:2294`) now sees the growth
facets; the descending-priority sort (`:2304`) fills the sub-camera sector first; the take-loop
(`:2305–2313`) bounds the slice; the run start captures the input hold (`:2328–2331`); deferral =
removal from `_async_sector_dirty` ⇒ re-derived dirty next dispatch by the same ground-truth
comparison (never-built sectors stay epoch-stale, `newmem` sectors stay signature-short — §4.1 of
the staging doc's "nothing lost" argument applies verbatim to growth); `SRC_STAGE` chains the run
(`:2723–2725`); the 2500 ms failsafe (`:2298–2302`) bounds it.

**E9 — telemetry (`:3769–3771`,** beside the `sh_stage_*` keys, same flag-gated pattern — off ⇒
keys absent ⇒ byte-identical consumers):

```gdscript
	if CubeSphere.FP_SHELL_PREWARM_DESCENT:
		out["sh_prewarm_on"] = 1 if _pwd_active else 0    # the task-required readback
		out["sh_pwd_desc"] = 1 if _pwd_descending else 0
		out["sh_pwd_snaps"] = _pwd_snap_count
```

Nothing else changes. No new dispatch site, no new worker mode, no new mesh path: pre-warm is
(paced snapshots) × (staging with growth admitted) on the shipped pipeline.

---

## 5. No new orbit cost / no churn (the FP_UNSINK_DRIFT_CALM contract)

- **Steady orbit**: the engage predicate is off (§3.2 proof) ⇒ E6/E7/E8 never activate; per-frame
  cost = the E4 tick (one wall-clock compare; the Δh sample every 250 ms is two float ops). The
  `FP_SHELL_ORBIT_IDLE` converged short-circuit (`:1523`) is reached exactly as today because
  `_pending` is never armed by pre-warm there. `_unsink_drift_check`'s calm gating (`:1786–1792`)
  is untouched.
- **On foot / floored descent below 650**: predicate off (`_shell_orbit()` false / band floor);
  `_surface_converge_emit` and the noblack guarantee run verbatim.
- **While engaged**: work is snapshot-paced (≤ 1/500 ms, and silent when the cap hasn't moved ≥
  2°/1°) and build-bounded (≤ 112-facet slices, one in flight). After convergence
  (residency == wanted), a paced snapshot's dispatch computes an empty dirty set — the worker emits
  nothing, the swap touches nothing (`_swap_in_sectors` iterates `_async_sector_dirty` only,
  `:2400`); and the drift thresholds make even those dispatches rare. No treadmill is possible: the
  dirty set is derived from ground truth each dispatch (signatures/epochs), and the stage-hold
  (`:2437/:2463–2467`) prevents the mid-run re-dirty storm exactly as in the staging design §4.2.
- **Disengage mid-run** (descent aborted, band exit): no forced snapshots are added;
  `_async_prewarm` is per-dispatch-frozen; an active staged run drains under the shipped run rules
  (strictly-shrinking dirty + failsafe). Worst case the player re-climbs with a partially-opened
  shell — strictly more resident coverage than today, no correctness edge.

---

## 6. No hole, no seam, no visual regression

- **Earlier appearance = strictly more coverage.** The shell is the FAR backstop tier; pre-warm
  only *adds* sector geometry earlier (at alt ≤ 1300 instead of ~600). Every under-layer that
  covers today — FacetOrbitRelief, the smooth-V2 annulus, chord fallbacks, FP_FARRING_FULL_COVER
  backstops — is untouched, so at every instant the drawn set ⊇ today's drawn set.
- **No double-draw.** Emit membership is exclusive per fid via the single `visible_fids` filter
  (`:3476–3507` — smooth-covered exclusion shared by every consumer); sectored swaps clear the
  whole-cap `_mi` before sector meshes own the cap (`:2397–2398`); and E8's `pwd_growth_ok` guard
  explicitly refuses growth-deferral while `_mi` holds surfaces — the one state where a deferred
  sector's coverage could live in a mesh the swap clears. The orbit-relief tier already coexists
  with the fully-open shell below the knee today (the post-knee steady state) — pre-warm only moves
  *when* that coexistence starts, not its composition.
- **No seam.** Every pre-warm slice emits from the staging run's held input snapshot
  (`_stage_hold`, `:2463–2467`) ⇒ one coherent unsink/applied/slot state across the run. Above the
  anchor knee the frozen `_applied_r` is 0 and there is no near field ⇒ the geometry class is
  un-sunk coarse — the same class today's knee build produces for those facets
  (`FP_UNSINK_DRIFT_CALM`'s own invariant: off-surface, `_applied_r == 0` ⇒ re-arm rebuilds
  byte-identical geometry, `:1786–1792`). The knee's later sunk transition is the small sunkish-disc
  class-1 replacement (§1.3), sector-atomic as ever.
- **Paced by construction.** "Releasing the collapse early" cannot itself be one big build: the
  release *is* the staged run — the first engaged dispatch is budget-filtered before the worker ever
  sees the fid set (E8 runs inside `_dispatch_async_rebuild`, `:2510–2515`). That is precisely the
  structural difference from merely relaxing FALL_HOLD earlier.

---

## 7. Byte-off proof and composition

- Off, every edit is unreachable: E4/E5 early-return (`on` false); E6's `pwd_snap` is
  compile-false ⇒ `if reemit or false` ⇒ verbatim; `_shell_snapshot`'s new param defaults to
  `SRC_CAM` at every existing call site; E7 writes `_async_prewarm = false` (a dead store to a var
  nothing reads off); E8's `pwd_growth_ok` is false ⇒ the shipped partition verbatim; E9 keys
  absent. All E2 state stays at initializers.
- Flag-off-visible deltas: the E3 enum consts only — `sh_pending_src` gains a trailing `,0` column
  *only when FP_APPLIED_PROBE_CALM is on* (positional parsing of existing columns unaffected —
  staging's E3 precedent), plus the deliberate `verify_probe_calm.gd` pin update.
- **FLAT**: `verify_feature.gd` never enters FACETED far-ring paths — stays **6042/0**.
- **Composition**: `FP_SHELL_ORBIT_IDLE` — untouched at steady orbit; pre-warm wakes it only via
  the ordinary `_pending` it already honours. `FP_SHELL_FALL_HOLD` — its suppression law is
  bypassed only by the paced `pwd_snap` (bounded stricter than the hold's own 1000 ms sweep
  throttle in practice: 500 ms *and* thresholds *and* band *and* latch). `FP_FARRING_SECTORS` /
  `FP_SHELL_STAGE_REEMIT` — pre-warm is a scoped *mode* of the staging filter; all staging gates
  keep passing (the knee-with-pre-warm-off case is G-STG's byte-off case). `FP_UNSINK_DRIFT_CALM` —
  arm-throttles untouched; pre-warm arms only SRC_PREWARM/SRC_STAGE, both SAFETY.
  `FP_SHELL_PREWARM` (S2 cache warm) — orthogonal and helpful: by 1300 the one-shot warm has
  usually filled `_pos_cache`, so pre-warm slices are cache-hits (no warm cost in the worker).

---

## 8. Gate plan — `godot/src/tools/verify_shell_prewarm.gd`

New headless SceneTree gate cloned from `verify_shell_staging.gd`'s scaffolding (FACETED sed,
`TerrainConfig.warm_up()`/`FA.warm_up()`, real `FacetFarRing.setup()`, direct
`_dispatch_async_rebuild()` + `while _async_building: _poll_async_rebuild(); OS.delay_msec(1)` spin
— the REAL dispatch→WorkerThreadPool→sectored-swap path, per the C-lite/staging runtime-dead
lesson). All new logic is reachable through forcing params (`_pwd_tick(h, on := true)`,
`_stage_filter_dirty(axis, stage_on, …)` reading the frozen `_async_prewarm`, and the pure
`shell_prewarm_snap_due`) — no sed of the new flag.

The driver simulates a **real descent**: a loop stepping `h` from 1500 → 550 at a configurable
rate, each step calling `_pwd_tick(h, true)` + `shell_set_camera_abs(dir(t), R + h, false)` with an
axis swept ~4.6°/s (the orbital ground track), dispatching whenever `_pending` and not
`_async_building` — i.e. the exact production driver sequence, wall-clock ticked via
`OS.delay_msec` at the sample cadence.

- **G-PWD-ENGAGE** — latch/predicate truth table on the REAL `_pwd_tick`: steady `h` (Δh = 0)
  in-band ⇒ never engages; climb through the band ⇒ never engages; descent at −100 b/s engages
  within 2 samples once `h ≤ 1300` and disengages below 650 and when `_emit_floored_last` flips;
  a −3000 b/s teleport sample is rejected (VY_CLAMP).
- **G-PWD-PACE** — across the engaged descent, forced snapshots are ≥ `SHELL_PWD_SNAP_MS` apart
  (rising edge excepted) and only fire past the drift/Δθ_h thresholds (assert via
  `shell_prewarm_snap_due` call-tracking + `_pwd_snap_count`).
- **G-PWD-BUDGET** — start from a COLLAPSED residency (fresh instance / post-`_sectors_reset()`,
  the real orbit-decay state): every engaged dispatch's emitted slice
  (`_stage_last_emit_facets`, cross-checked by summing `_async_sector_dirty` member counts) ≤
  `max(SHELL_STAGE_FACETS, largest selected sector)` and ≥ 1 — **the growth burst is budgeted**
  (this is the exact assertion the knee failed live; it FAILS on the shipped class-0 exemption,
  proving E8 is load-bearing).
- **G-PWD-RESIDENT** — by `h = SHELL_PWD_ALT_LO` the run has drained: `_sectors_compute_dirty`
  against the live inputs yields ≤ trigger dirt; the drawn union == the reference unstaged build's
  emitted set for the same final axis/cap (element-equal `_emitted`, per-sector `_sector_sig`).
- **G-PWD-KNEE** — continue below 650 with pre-warm disengaged, then apply the knee mutations
  (unsink column set, `_applied_r` 0 → `APPLIED_PROBE_MAX`, band): the resulting dispatch's dirty
  facet count is **small** (≤ the sunkish-disc sectors' membership) and either sub-trigger or
  staged at ≤ budget — i.e. no 927-facet dispatch exists anywhere in the whole run history.
- **G-PWD-NOHOLE** — at every intermediate swap, the drawn union never loses a facet that was
  drawn before and is still in the wanted set; never-deferred `_mi`-resident case: pre-load a sync
  `_rebuild_full`, engage pre-warm ⇒ assert `pwd_growth_ok` stayed false for that dispatch (class-0
  exemption held).
- **G-PWD-CALM** — steady-orbit soak: 5 s of constant-`h` in-band ticks ⇒ zero dispatches, zero
  snapshots, `_pwd_active` false throughout (the no-churn contract, asserted not argued).
- **G-PWD-BYTEOFF** — the whole descent with `on = false`: `_pwd_*`/`_async_prewarm` never leave
  zero; dispatch/dirty behaviour element-equal to a `FP_SHELL_PREWARM_DESCENT`-absent reference run;
  plus the E3 pin update in `verify_probe_calm.gd`. Existing gates re-run unchanged:
  `verify_shell_staging.gd`, `verify_shell.gd`, FLAT `verify_feature.gd` (**6042/0**).

---

## 9. Live A/B plan

Build the deployed flag set + `FP_SHELL_PREWARM_DESCENT := true`; export; deploy. Warm at rest
(prebake settled), then a **natural gradual de-orbit** from ≥ 1500 through the 560–600 knee (repeat
with a fast ~570 b/s profile — the tightest band crossing).

Telemetry (remote-bridge relay, 1 Hz — `worst_ms` is window-worst and rate-robust):
`sh_prewarm_on`, `sh_pwd_snaps`, `sh_emit`, `sh_visN`, `sh_applied_r`, `sh_stage_on/q/emit`,
`worst_ms`, alt.

**Success criteria**:

1. **The knee**: `worst_ms` in the 560–600 band **2662 → ≤ ~300 ms** (expected ≪ per staging's
   slice-regime numbers) — because the release dispatch's dirty delta is small, not because the
   burst was budgeted at the knee.
2. **The mechanism, observed**: during the 1300→650 band `sh_prewarm_on = 1` and `sh_emit` climbs
   toward `sh_visN` (≈ 900+) BEFORE the knee, in `sh_stage_emit ≤ 112`-facet steps
   (`sh_pending_src` slot 19 = SRC_PREWARM, slot 18 = SRC_STAGE attribute the arms); at the knee
   `sh_emit ≈ sh_visN` already holds and `sh_applied_r` climbs 0 → 112 with only a small
   `sh_stage_emit` replacement. (`sh_applied_r` cannot exceed 0 much before ~650 — it is a
   truth-probe of the near re-grow, §4-note-(a); the pre-knee readiness metric is `sh_emit`, the
   knee-time metric is the absence of a big dispatch.)
3. **No moved stall**: per-frame `worst_ms` during the pre-warm band bounded ≤ the staging slice
   regime (~≤ 300 ms hard, expect ≤ ~120) — the stall must not reappear at alt 1300–650.
4. **No visual regression**: no hole/wedge through the whole descent (`sh_emit` never < the
   pre-transition drawn count), no double-image against orbit-relief, shell simply fades in earlier.
5. **Steady orbit + on-foot unchanged**: `sh_prewarm_on = 0`, `worst_ms` baselines unchanged at a
   parked orbit (10 min soak) and while walking.

Rollback = flag off (byte-identical knee behaviour returns).

---

## 10. Executive summary

- **Engage**: `_cam_set ∧ _shell_orbit() ∧ analytic-radial-Δ descent latch
  (reentry_descent_step Schmitt, −10/−5 b/s, NOT `_fall_vy_ema`) ∧ alt ∈ [650, 1300]` — provably
  off at steady orbit (radial ≈ 0), on foot (floored), and on climbs; on for every genuine
  incoming de-orbit ≥ 1.1 s before the 608.7 knee.
- **Pre-build**: option (c) — paced `_shell_snapshot` refreshes (≤ 1/500 ms, drift/Δθ_h-gated,
  SRC_PREWARM) keep the wanted set current, and the **existing FP_SHELL_STAGE_REEMIT run** builds
  it with one scoped relaxation: during an engaged (voluntary) pre-warm dispatch, class-0 growth is
  budget-eligible — ≤ 112 facets/slice, nearest-camera first, SRC_STAGE-chained, 2500 ms failsafe.
- **Pacing**: full 927-facet open ≈ 9 slices ≈ 0.3 s ≪ the 1.1–6.5 s band; per-slice worst ≈
  staging's absorbed regime (≤ ~120 ms) — no stall moved upward.
- **No churn**: the trigger (not a budget) is what's off at steady orbit; converged pre-warm
  dispatches vanish (empty dirty set + silent pacer); FP_UNSINK_DRIFT_CALM/ORBIT_IDLE paths
  untouched.
- **Flag**: `FP_SHELL_PREWARM_DESCENT := false` + 6 consts; off ⇒ collapse-at-orbit /
  rebuild-at-knee byte-identical; FLAT 6042/0; requires the deployed
  CAMERA_SET/SECTORS/ASYNC/STAGE_REEMIT stack.
- **Gate**: `verify_shell_prewarm.gd` drives the REAL descent→tick→snapshot→dispatch→worker→swap
  path (forcing params, no sed): engage truth-table, pace bound, budgeted growth (fails on shipped
  code — E8 load-bearing), resident-by-650, small-knee-delta, no-hole, steady-orbit calm, byte-off.
