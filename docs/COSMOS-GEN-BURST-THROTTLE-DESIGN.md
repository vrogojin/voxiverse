# COSMOS — Walking Gen-Burst Throttle (FP_WALK_STEP_GATE)

**Status:** DESIGN (this doc) — GDScript-only, byte-off, no engine rebuild.
**Problem class:** ground-walk jerkiness on web = per-crossing GENERATION BURSTS
(established this session; see `docs/COSMOS-GEN-CONVOY-*.md`, `docs/COSMOS-CROSSING-FASTGEN-DESIGN.md`).
**Companion memory:** voxiverse-ground-walk-perf, voxiverse-perf-next-architecture.

---

## 1. The established problem (input, not re-derived)

Every ~3 s of walking the player crosses a 16-voxel **data-block boundary**. A strip of
new blocks floods the voxel worker pool: `wf_vox_gen` (remote_bridge.gd:669 =
`VoxelEngine.get_stats().tasks.generation`) spikes to **1000–2186**, all 6 workers busy,
worst frame 300–1700 ms. The byte-off alloc+lock probe (Builds #1/#2) ruled out every
fixable engine-side cause: allocator lock-stall ~15–35 %, VoxelData RWLock 0 %, task-queue
mutex 0 %, mesh-apply/dequeue ~0 %, GPU draws LOWER on spikes. **65–83 % of spike frame
time is unmetered by every engine timer** — a WASM/browser platform cost of the burst
itself (linear-memory growth copies, memory-bandwidth saturation from 6 worker threads,
emscripten pthread runtime). The only remaining lever is **reduce the burst size**: admit
fewer blocks per unit time while walking so the platform stall each burst triggers is
smaller. Accepted trade: terrain-arrival latency for smoothness.

---

## 2. Admission-path trace — where a walking crossing's strip enters the gen queue

The module render path streams the near field through exactly **one** engine-side
mechanism, and it has **no GDScript admission gate at all**:

1. **The viewer is a plain child of the player.**
   `module_world.gd:3085-3114 attach_viewer()`: instantiates the single global
   `VoxelViewer`, sets `view_distance = near_render_radius()` (=128 faceted,
   terrain_config.gd:171-176), `view_distance_vertical_ratio` (≈0.5 ⇒ vertical
   half-extent 64 voxels), then `player.add_child(_viewer)` (:3111). From that moment the
   viewer's global position tracks the player **continuously, every physics tick,
   with no code in between** — WorldManager's `update_streaming` head
   (world_manager.gd:1348-1352) only updates the fallback `_streamer` (null on the module
   path) and the `GroundCollider`. Nothing in GDScript ever mediates the viewer's motion.

2. **The strip is admitted inside C++ on the box-step.**
   godot_voxel's `VoxelTerrain::process` quantizes the viewer position to 16-voxel data
   blocks. The frame the quantized cell changes, it diffs the new paired-viewing box
   against the loaded set and enqueues **every missing block of the leading wall in one
   process pass** — for **each** live terrain. Under FP_M1_POOL a border walk keeps 2–3
   bounds-clamped `VoxelTerrain` slots live (module_world.gd:52-53, :1883-1955), all
   served by the ONE viewer (:1881 — "exactly ONE VoxelViewer serves all of them; NO
   static/extra viewers ever"), so **every slot's strip lands in the same frame**.
   Geometry per single-axis step: active slot leading cap ≈ π·8·4 ≈ **100 data blocks**
   (radius 128/16 = 8 blocks, vertical 4); each neighbour ≈ π·6·3, bounds-clamped ≈
   **30–60**; total ≈ **160–220 gen tasks per axis-step**. Walking diagonally and/or
   uphill crosses x, z and y block boundaries inside the same drain window (~300 tasks/s
   drain — cube_sphere.gd:2788 comment), the far tier re-arms at ~2 blocks, and the
   crossing machinery (imminent commit-grow 96→112/128 at
   `CTRL_IMMINENT_COMMIT_PACE = 1.0`, cube_sphere.gd:2772; spawn prefill,
   module_world.gd:2133-2143) stacks on top ⇒ the measured 1000–2186 queue peaks.

3. **Why the shipped controller + inflight gate don't cap it.**
   - `StreamLoadController` (stream_load_controller.gd) computes AIMD `credit` and four
     surfaces, but its **only actuator over near-field volume is the view-RAMP pace**:
     WorldManager pushes `stream_pace()` → `module_world.set_stream_pace`
     (world_manager.gd:1035-1040), consumed **exclusively** in the ramp grow legs —
     `_process`'s `_ramp_active` leg (module_world.gd:438-444) and `_ramp_pool_step`'s
     `span·delta·pace/RAMP_SECONDS` (module_world.gd:581-604). **At steady-state walking
     `view_f == view_target`, no ramp is active, so pace multiplies nothing.** The
     box-step strip bypasses the entire credit system.
   - `FP_INFLIGHT_GATE` (P1) likewise: its feed-forward cut is
     `pace *= clamp(1 − main_q/APPLY_CHOKE)` **inside `_ramp_pool_step`**
     (module_world.gd:591-592) plus the controller's `backlog_gated()` latch
     (stream_load_controller.gd:241-244) — which again only zeroes `stream_pace()`
     (surface 3) and promote admission (surface 4). Neither touches the viewer.
   - The controller's **0.25 s tick** (`CTRL_TICK_S`, credit recompute at
     stream_load_controller.gd:106-107) is reactive: the C++ diff pass enqueues the whole
     strip in **one frame**, ~15× faster than the first possible credit response — and
     even an instant credit-0 response has no surface that un-admits an enqueued strip.
   - The fall path has a pacing equivalent (`FP_STREAM_FALL_PACE` / reentry view ramp /
     `FP_LAND_RAMP_HOLD` clamp, module_world.gd:510-515) because falling **moves the view
     target**, which the ramp paces. **Walking moves the view CENTRE, and nothing paces
     that.** This is the gap.

**Conclusion:** the choke point is the viewer node's un-gated continuous motion. It is the
one C++-admission input GDScript fully owns (we created the node; FP_APPROACH_ANCHOR
already mutates its position/view_distance live — module_world.gd:485-497 — proving the
engine tolerates scripted viewer writes).

---

## 3. Lever selection

| Candidate | Verdict |
|---|---|
| (a) per-frame block-admission rate cap | **CHOSEN — realized as a stepped, drain-gated viewer** (§4). GDScript cannot intercept individual block enqueues (C++), but it CAN quantize *when* the C++ diff pass fires and guarantee at most **one axis × one block-quantum** of new frontier per admitted step, with the next step gated on the gen queue draining. That is a rate cap at strip granularity — the finest admission unit the engine exposes. |
| (b) walk-paced view-distance grow | REJECTED: while walking, `max_view_distance` is already AT target; the grow leg is idle (§2.3). Shrinking-then-regrowing the radius around each crossing would unload the whole [R−Δ, R] annulus and re-generate it on regrow — strictly MORE gen work (churn), and FP_SHRINK_PACED exists precisely because unload bursts also convoy. |
| (c) faster controller reaction / per-tick ceiling | REJECTED: the controller has **no actuator** over the box-step (§2.3); tightening its tick changes when a lever that isn't connected moves. The new gate instead *reuses* the controller's philosophy (feed-forward backlog gate) at the correct choke point. |
| (d) stagger FP_M1_POOL slots | REJECTED: all slots stream from the ONE viewer by LAW (module_world.gd:1881); per-slot staggering would need per-slot viewers (forbidden) or per-slot bounds animation (churns the C++ loaded-set diff, same failure as (b)). The chosen lever still helps here: one admitted step per drain window serializes what the slots co-admit in time. |

---

## 4. The lever: `FP_WALK_STEP_GATE` — stepped, drain-gated streaming viewer

### 4.1 Mechanism

Hold the viewer's **global** position at a committed anchor instead of letting it free-run
with the player. Advance the anchor toward the player in **discrete steps of one
data-block quantum (16 voxels) along one axis at a time**, and admit a step only when the
gen queue has drained below an open threshold (feed-forward, same signal family as the
shipped `backlog_gated()`), with a minimum inter-step interval. Hard safety caps force a
step regardless of backlog once the lag exceeds a bound, and snap the anchor on any
discontinuity (crossing/flip PlanetRoot re-place, teleport) or non-walking motion.

Effect on the C++ side: `VoxelTerrain::process` sees the viewer's quantized data-block
cell change **at most once per admitted step**, so each diff pass admits exactly one
axis-strip (~160–220 tasks across the live slots, §2.2) — and the next strip cannot be
admitted until the previous one has substantially drained. The compound multi-axis ×
multi-event burst that today lands in one window is serialized.

### 4.2 Engage law

Per physics tick (from `update_streaming`'s safety head, so it runs even on 2-step
frames — position holds must never lapse):

```
engaged  ⇔  FP_WALK_STEP_GATE and using_module and viewer exists
            and _player_speed ≤ WALK_GATE_MAX_SPEED          # walking/running only (walk 5.5, run 9.5 < 12; fly 16, falls excluded)
            and |want − anchor| ≤ WALK_GATE_SNAP_DIST        # not a crossing/flip re-place or teleport
```

Disengaged ⇒ anchor := want and the viewer is written to exactly the shipped follow
position (`player.to_global(0, y0, 0)`, where `y0` is the attach-time A2 offset,
module_world.gd:3114) — numerically identical to free-follow, so every existing airborne/
fall/orbit feature (FP_APPROACH_ANCHOR, FP_LAND_RAMP_HOLD, reentry) sees the shipped
viewer behaviour. FP_APPROACH_ANCHOR composition: its driver runs in the orchestration
tail (world_manager.gd:1417) *after* the gate's head write and only mutates local
`position.y` + `view_distance` (module_world.gd:492-497) — when grounded its offset is the
base `y0` (no fight); when genuinely airborne the speed test has already disengaged the
gate. Residual slow-hover overlap (< 12 b/s airborne): anchor owns y, gate steps x/z —
coherent, and both are bounded by their own caps.

### 4.3 Step law

```
d        := want − anchor                       # the lag vector, viewer-global frame
axis     := argmax |d.axis|                     # ONE axis per step: splits a diagonal/uphill
                                                # multi-boundary crossing into serialized strips
pending  ⇔ |d[axis]| ≥ WALK_STEP_QUANTUM/2
forced   ⇔ |d[axis]| > WALK_GATE_MAX_LAG        # safety: the frontier must recede
admit    ⇔ forced or ( backlog < WALK_STEP_OPEN
                       and now − last_step ≥ WALK_STEP_MIN_INTERVAL_S )
on admit:  anchor[axis] += sign(d[axis]) · min(WALK_STEP_QUANTUM, |d[axis]|)
every tick: viewer.global_position = anchor     # the hold — one Node3D write
```

`backlog` = `VoxelEngine.get_stats().tasks.generation` — the **existing** WorldManager
helper `_voxel_gen_backlog()` (world_manager.gd:805-814, cached singleton), i.e. the same
counter the A/B metric (`wf_vox_gen`) and the shipped controller feed-forward read.

### 4.4 Constants (all in `cube_sphere.gd`, appended after the FP_INFLIGHT_GATE block, :2789)

```gdscript
## COSMOS-GEN-BURST-THROTTLE (docs/COSMOS-GEN-BURST-THROTTLE-DESIGN.md) — FP_WALK_STEP_GATE: ... (doc comment)
const FP_WALK_STEP_GATE := false
const WALK_STEP_QUANTUM := 16.0        # one godot_voxel data block — the admission unit the C++ box-diff quantizes at
const WALK_STEP_OPEN := 128            # admit the next step only when tasks.generation is below this (~0.4 s of pipe @300/s)
const WALK_STEP_MIN_INTERVAL_S := 0.2  # ≥1 render frame of drain between admitted steps even at zero backlog
const WALK_GATE_MAX_LAG := 24.0        # per-axis force-step bound (voxels): the streamed frontier never trails farther
const WALK_GATE_SNAP_DIST := 48.0      # beyond this the delta is a crossing/flip/teleport re-place — snap, don't step
const WALK_GATE_MAX_SPEED := 12.0      # engage only at ground speeds (walk 5.5 / run 9.5); fly/fall keep the shipped viewer
```

### 4.5 Exact edit sites (all GDScript; no engine/module change)

**E1 — `godot/src/cosmos/cube_sphere.gd`** (after :2789 `INFLIGHT_MIN`): the block above.

**E2 — `godot/src/world/world_manager.gd:1358`** — share the FP_VEL_PREDICT speed EMA
(the same multi-flag-sharing precedent as :1378's four-flag `or` chain):

```gdscript
# before
	if CubeSphere.FP_VEL_PREDICT:
# after
	if CubeSphere.FP_VEL_PREDICT or CubeSphere.FP_WALK_STEP_GATE:
```
(`_player_speed`, declared :281, stays 0 with both flags off — byte-identical.)

**E3 — `godot/src/world/world_manager.gd`**, insert between :1391 (end of the
FP_ENV_FALL_HOLD block) and :1392 (`# Latch the latest player position…`) — in the
**safety head**, i.e. per physics tick, deliberately NOT behind the FP_STREAM_TICK_ONCE
tail return (:1403-1406), because the position hold must never lapse on a 2-step frame:

```gdscript
	# FP_WALK_STEP_GATE (docs/COSMOS-GEN-BURST-THROTTLE-DESIGN.md §4): hold the streaming viewer on its
	# committed step anchor (drain-gated, one data-block axis-step at a time) so a walking crossing's
	# strip admissions serialize instead of flooding one C++ diff pass. Off ⇒ never called (byte-identical).
	if CubeSphere.FP_WALK_STEP_GATE and using_module and _module_world != null \
			and _module_world.has_method("walk_gate_update"):
		_module_world.walk_gate_update(_player_speed, _voxel_gen_backlog())
```

**E4 — `godot/src/world/voxel_module/module_world.gd`** — state near the viewer state
(:28), method after the viewer-introspection block (:508):

```gdscript
# FP_WALK_STEP_GATE state (docs/COSMOS-GEN-BURST-THROTTLE-DESIGN.md §4). _wg_anchor is the committed
# streaming position in the viewer's GLOBAL frame (INF = unarmed → first call snaps). Inert off the flag.
var _wg_anchor := Vector3.INF
var _wg_last_step_ms := -1
var _wg_y0 := 0.0                 # attach-time A2 local +Y viewer offset (0 when the clamp is off)
var _wg_steps := 0                # gate/PerfHUD read-back: admitted steps
var _wg_forced := 0               # gate read-back: forced (lag-cap) steps

func walk_gate_update(speed: float, backlog: int) -> void:
	var v := _viewer as Node3D
	if v == null: return
	var p := v.get_parent() as Node3D
	if p == null: return
	var want: Vector3 = p.to_global(Vector3(0.0, _wg_y0, 0.0))     # the shipped free-follow position
	if _wg_anchor == Vector3.INF or speed > CubeSphere.WALK_GATE_MAX_SPEED \
			or want.distance_to(_wg_anchor) > CubeSphere.WALK_GATE_SNAP_DIST:
		_wg_anchor = want                                          # disengaged / discontinuity: snap-follow
		v.global_position = want
		return
	var d := want - _wg_anchor
	var ax := 0
	if absf(d.y) > absf(d[ax]): ax = 1
	if absf(d.z) > absf(d[ax]): ax = 2
	var lag := absf(d[ax])
	if lag >= CubeSphere.WALK_STEP_QUANTUM * 0.5:
		var now := Time.get_ticks_msec()
		var interval_ok := _wg_last_step_ms < 0 \
				or now - _wg_last_step_ms >= int(CubeSphere.WALK_STEP_MIN_INTERVAL_S * 1000.0)
		var forced := lag > CubeSphere.WALK_GATE_MAX_LAG
		if forced or (interval_ok and backlog < CubeSphere.WALK_STEP_OPEN):
			_wg_anchor[ax] += signf(d[ax]) * minf(CubeSphere.WALK_STEP_QUANTUM, lag)
			_wg_last_step_ms = now
			_wg_steps += 1
			if forced: _wg_forced += 1
	v.global_position = _wg_anchor

func walk_gate_lag() -> Vector3:   # verify/PerfHUD introspection
	var v := _viewer as Node3D
	if v == null or _wg_anchor == Vector3.INF: return Vector3.ZERO
	var p := v.get_parent() as Node3D
	return (p.to_global(Vector3(0.0, _wg_y0, 0.0)) - _wg_anchor) if p != null else Vector3.ZERO
func walk_gate_counts() -> Vector2i:
	return Vector2i(_wg_steps, _wg_forced)
```

plus in `attach_viewer` (after :3114), flag-guarded so off-path state is untouched:

```gdscript
	if CubeSphere.FP_WALK_STEP_GATE:
		_wg_y0 = params.y if use_clamp else 0.0
```

### 4.6 Byte-off argument

Off (the default `const false`): E2's condition is the shipped `FP_VEL_PREDICT` test
(short-circuit identical); E3 is never entered — `walk_gate_update` is never called, the
viewer node is **never written** and remains the plain player child from `attach_viewer`
(byte-identical admission); E4's vars are dead state; `_wg_y0` is never assigned. No
timing, no allocation, no read path changes. FLAT `verify_feature.gd` stays **6042/0**
(it never enables the flag; the module viewer path it exercises is untouched).

---

## 5. Expected effect (quantified)

**Burst size.** Today one walking-crossing window enqueues the compound admission
(x+z(+y) strips × 2–3 slots + crossing machinery) faster than the ~300/s drain ⇒ measured
`wf_vox_gen` peaks **1000–2186**. Gated: one admitted step = one axis-strip ≈ **160–220
tasks** (§2.2), admitted only when the queue is already below **128** ⇒ expected peak
≈ 128 + 220 ≈ **~350, a ~4–6× reduction in burst size**. Since the 65–83 % unmetered
spike cost is a platform function of the burst itself (heap-growth copies + 6-thread
bandwidth churn scale with concurrent task volume), worst_ms spikes are expected to fall
materially with the peak — this is the design premise the A/B (§7) validates, not a
promise.

**Latency cost.** Steady walk at 5.5 b/s crosses one 16-voxel boundary per ~2.9 s — the
gate normally holds at most one pending step, delayed by drain-wait
≤ (peak−OPEN)/drain ≈ 0.9 s worst + the 0.2 s interval ⇒ the leading rim strip arrives
**≤ ~1 s later** than today. Diagonal-uphill worst case (3 axes pending) serializes over
~0.6 s + drain waits. Absolute bound: the forced step at `WALK_GATE_MAX_LAG = 24` caps the
frontier deficit at 24 + 16 = **40 voxels ever**, backlog or not.

**Walk-into-hole safety (the CRITICAL invariant).**
1. *Physics can never fall through:* collision is analytic — `WorldManager.block_id_at`,
   `floor_under`, and the `GroundCollider` read `TerrainConfig`/the edit overlay, **never
   the voxel mesh** (architecture rule #1/“Physics is analytic”), so a late mesh strip has
   zero physical effect.
2. *The near field under and ahead of the player stays prompt:* the gate paces the
   **periphery** only — the streamed set is a radius-128 (active) ellipsoid around the
   anchor, and the anchor trails the player by ≤ 40 voxels worst-case ⇒ generated+meshed
   terrain always extends ≥ 128 − 40 = **88 voxels ahead of the player** (≥ 16 s at run
   speed), and the forced-step law guarantees the frontier keeps receding even under a
   permanently saturated queue.
3. *No see-through at the rim:* an un-meshed rim strip fails the near-cover query
   (`skin_near_meshed` / `is_area_meshed`), so the far-tier backstop
   (FP_FARRING_CULL_COVERED culls only *confirmed-meshed* cover; FP_FARRING_FULL_COVER)
   keeps drawing there until the strip lands — the same cover law that already handles
   in-flight strips today, just for ≤ 1 s longer.

**Composition with the shipped stack.** The gate is upstream of, and orthogonal to, the
controller: ramp legs (spawn/commit-grow) stay paced by `stream_pace`/FP_INFLIGHT_GATE
exactly as shipped; the gate adds admission control to the one path they never touched.
It cannot fight them — when the controller holds the ramps at pace 0, the gate's drain
condition is *also* naturally closed (same backlog signal), and the forced step keeps the
near field alive exactly like the shipped `CTRL_RELIEF_FLOOR`/`FP_LANDING_STREAM_KICK`
floors do for the ramps.

---

## 6. Gate (headless, real path): `godot/src/tools/verify_walk_gate.gd`

Pattern: `verify_approach_anchor.gd` (build the module world, `attach_viewer` on a scripted
player holder, drive real methods; needs the custom editor + `--import` first). The
flag stays `const false`; the LIVE call-site behaviour is asserted via `update_streaming`,
and the gate logic via direct `walk_gate_update(speed, backlog)` calls (the codebase's
gate-override convention — explicit params, no flag flip needed).

- **G-WG-OFF (byte-off identity):** drive `update_streaming` across a scripted 64-voxel
  walk with the flag off ⇒ the viewer's local transform is bit-identical to attach-time
  (`(0, y0, 0)`, never written), `walk_gate_counts() == (0,0)`, instance id stable.
- **G-WG-CAP (per-frame admission cap):** scripted 48-voxel diagonal walk, synthetic
  `backlog := WALK_STEP_OPEN + 1000` every call ⇒ the anchor advances **only** by forced
  steps; per-call advance ≤ `WALK_STEP_QUANTUM` on exactly one axis; per-axis lag never
  exceeds `WALK_GATE_MAX_LAG + WALK_STEP_QUANTUM`.
- **G-WG-DRAIN (throughput):** same walk, synthetic backlog 0 ⇒ steps admitted at the
  `WALK_STEP_MIN_INTERVAL_S` cadence (injected clock deltas) until every axis lag
  < QUANTUM/2 — the strip spreads over N calls, terrain target still fully reached.
- **G-WG-NEARFIELD (not-starved invariant):** throughout CAP+DRAIN,
  `max_axis(walk_gate_lag()) ≤ WALK_GATE_MAX_LAG + WALK_STEP_QUANTUM` (⇒ frontier ≥
  near_render_radius − 40 by arithmetic), and `block_id_at`/`floor_under` at the player
  remain solid (analytic-physics invariant exercised on the real query path).
- **G-WG-SNAP (discontinuity):** teleport the holder 100 voxels ⇒ one snap (no step spam,
  forced-counter unchanged); speed 16 b/s (fly) ⇒ snap-follow every call.
- Plus the standing rule: FLAT `verify_feature.gd` **6042/0** unchanged.

---

## 7. Live A/B protocol

- **Flip:** sed-at-export on the GDScript const (no rebuild):
  `sed -i 's/const FP_WALK_STEP_GATE := false/const FP_WALK_STEP_GATE := true/' godot/src/cosmos/cube_sphere.gd`
  → `scripts/export-web.sh` → `scripts/deploy.sh` (the deploy-cheats flow; note the
  deploy_cheats.sh checkout-revert gotcha on cube_sphere.gd — re-apply after any revert).
- **Scenario:** 3-minute no-village ground walk (mixed straight/diagonal/uphill), probe on,
  remote-bridge telemetry (`wf_vox_gen` per snapshot + worst_ms distribution +
  `walk_gate_counts` forced-step share).
- **Success:** per-5s-window `wf_vox_gen` peak reduced from 1000–2186 to ≲ 450;
  spike worst_ms p90/max down materially (target ≥ 40 %); forced-step share small
  (< 20 % — the drain gate, not the safety cap, doing the work); zero see-through /
  walk-into-hole observations; terrain-arrival lag subjectively acceptable (≤ ~1 s rim
  delay per §5).
- **Rollback:** redeploy with the const false (byte-identical admission).

---

## 8. Native fallback (explicit, per the constraint)

GDScript can only quantize *when* the C++ diff pass fires; it cannot shrink the strip a
single 16-voxel step admits (~100 blocks/slot leading cap — larger in full-height mountain
bands). If the A/B shows a single serialized axis-strip **still** triggers the platform
stall (worst_ms spikes persist at ~350-task bursts), the lever moves into the module:
a **per-process admission budget in `VoxelTerrain::process_viewers`** — cap the data-block
load requests enqueued per process pass (e.g. ≤ 64) and carry a cursor for the remainder,
so even a full box-diff drains over N passes. ~20-line C++ patch in the existing
`docker/engine` patch series (precedent: patch 0007 FP_CPPGEN), engine rebuild required.
The GDScript gate above remains valuable in front of it (it serializes multi-event
stacking that a per-pass cap alone would still admit back-to-back).
