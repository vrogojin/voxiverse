# COSMOS — Turn-In-Place Jerkiness: the Camera-Rotation Re-Emit Trace + Design

**Status:** diagnosis (source-complete rotation trace) + byte-off GDScript design.
Branch `deploy/perf-plus-sky`, worktree `deploy-cheats`.
**Scope fence:** this doc owns the **pure-camera-rotation frame cost** (player position
fixed, only the camera basis rotates). It builds on the measured session data (below) and on
`docs/COSMOS-GROUND-WALK-PERF-ATTRIBUTION.md` (the wf_* worst-frame-keyed snapshot, shipped
as `FP_WORST_FRAME_ATTR`) and `docs/COSMOS-FARTIER-WALK-DESIGN.md` (the membership-delta vs
camera-delta law for translation). It does NOT re-open the generation/alloc/lock arc — that
is measured-closed (allocator ~14 %, VoxelData RWLock 0 %, task mutex 0 %, mesh-apply 0 %).

---

## 0. The measured problem (given — not re-derived)

Standing still and turning the camera is "extremely jerky". Probe (throttle-arm walk,
`FP_WORST_FRAME_ATTR` live): **635/656 telemetry frames had `wf_vox_gen==0` yet `worst_ms`
median 116, spikes to 1195 ms.** On the worst no-gen frames:
`wf_smooth_v2_commit_ms≈11.76` **every** frame, `wf_phys` 8-30, `wf_prims` 425-549 k,
`wf_draws` 45-162, and 400-1195 ms **unmetered** by every named bucket. One earlier segment
ran at median 43 ms → situational, not a platform wall.

**Prime hypothesis to prove or kill:** the far tier re-emits/re-commits on camera ROTATION.

---

## 1. The rotation trace — what actually consumes the camera, per subsystem

Method: every far-tier subsystem was read at source and classified by its **driving inputs**
— does any input change when the camera **basis** rotates while the camera **position** is
fixed? (An FPS yaw rotates the player body about its own axis and pitch rotates the camera
node in place — `player.gd:823-837` — so a pure turn leaves `camera_global_transform().origin`
unchanged to sub-block noise.)

### 1.1 The driver chain feeds POSITION only

Every per-frame camera feed into the world layer passes `.origin`, never the basis:

| Feed | Site | Payload |
|---|---|---|
| far-ring emitted-set law | `main.gd:282` → `world_manager.gd:3838-3841` → `facet_far_ring.gd:1232-1248` `apply_camera_set(cam: Vector3)` | camera **position**; ĉ = `normalize(cam − body_centre)` — invariant under basis rotation |
| far-trees / far-structures camera | `main.gd:332` → `world_manager.gd:3892` → `facet_far_ring.gd:6301` → `_ft_cam` (`:83`) | **position** (band membership + rebuild re-arm) |
| SN3 scaled body / camera planes | `main.gd:341-406` `apply_scaled_body(cam)` / `apply_scaled_camera_planes(...)` | **position**-derived scalars (d, h) |
| orbit megablock disc | `main.gd:287` → `world_manager.gd:3812-3833` | **position** (u, d) |
| streaming tail queries | `world_manager.gd:1432-1471` (`set_cover_query`/`set_seam_cover_query`/`set_band_query` `:1440-1459`, `set_player_column` `:1467-1471`) | Callables (identity constant per flag state) + **player position**. The pushed query *payload* is identical under pure rotation |
| texture baker | `world_manager.gd:1490-1509` `_facet_tex.update(eaxis, offs, …, cam_dist, …)` | `shell_emit_axis()`/`shell_cam_dist()` — **position**-derived (`facet_far_ring.gd:3767-3771`) |
| far objects | `world_manager.gd:974-983` `_far_objects.step(cam, vh)` | reads `cam.global_transform.origin` + fov scalar; **dirty-gated on position/K_px/membership/rev** (`facet_far_objects.gd:190-207`) — a pure rotation early-returns |

### 1.2 Per-tier re-emit laws — all rotation-invariant by construction

| Tier | Re-emit / re-commit trigger | Site | Basis-coupled? |
|---|---|---|---|
| **Far ring (shell)** | axis drift of ĉ (position), regime/epoch/coverage-mask flips, env-warm, sector staging ordered by `_emit_axis` | `facet_far_ring.gd:1232-1248` (driver), `:1345` (`_emit_axis`), `:2390-2418` (stage priority = `centre·axis`, "screen-centre" is the **sub-camera position axis**, not the view vector), `:1552-1560` (cull params) | **No** |
| **Smooth-v2 annulus** | residency recomputed **only on a facet crossing** (`set_active`, "no camera coupling, no per-frame re-ranking"); `_dirty` set only by a tile landing or evicting; sun is a **shader param**, not a rebuild | `facet_smooth_v2.gd:664-671` (crossing-only), `:700-712` (tile land), `:733-745` (evict dwell), `:761-800` (commit law); sun: `facet_far_ring.gd:6237-6239` → shader uniform | **No** |
| **Smooth tier (REV2)** | hop-ring residency, "camera-independent, recomputed only on a facet crossing … never per-frame, never on a camera turn"; no per-facet camera test | `facet_far_ring.gd:168, 780-782, 844` | **No** |
| **Far trees** | delta gate re-arms on **camera moved ≥ FT_DELTA_MIN_MOVE** (position), record-cache epoch, edit revision, offsurf `_stale` flip; wanted-scan recomputes on **moved ≥ FT_DELTA_WANTED_MOVE**; staleness floor on **FT_STALE_MOVE** | `facet_far_trees.gd:1052-1068` (gate inputs), `:1035-1037` (wanted scan: "pure function of camera position + fixed facet geometry, so a still camera ⇒ the identical set"), `:892-900` | **No** |
| **Far structures** | `STRUCT_STEP_MS` cadence; camera enters only as **position** (annulus membership + cap ordering — `COSMOS-FARTIER-WALK-DESIGN.md`: "structures are already geometrically camera-independent") | `facet_far_structures.gd:218` `step(…, cam_render)`; walk-doc `:127-128` | **No** |
| **Far objects** | dirty gate: `cam_world` (position), K_px, membership, revs, screen-centre motion | `facet_far_objects.gd:196-207` | **No** |
| **Orbit relief / DEM / prebake** | own pacers, keyed to emit axis + headroom ms | `world_manager.gd:1522-1553`; `facet_far_ring.gd:1520-1521` | **No** |
| **Near field (godot_voxel)** | `VoxelViewer` **position** (`module_world.gd:3084-3109`) | — | **No** |

The far-tier step loop itself (`facet_far_ring.gd:1490-1530` — smooth-v2 step, orbit relief,
far-trees step, far-structures step, `_cull_update`) is a per-frame *pump*, but every one of
those steps is internally gated by the position/membership/epoch laws above — on a
position-fixed frame they are the documented fast no-op scans.

### 1.3 The ONE camera-basis consumer in the world layer — and it is retired live

A codebase-wide sweep for basis readers (`get_camera_3d`, `global_transform.basis`,
`is_position_in_frustum`, `unproject`) finds **exactly one** far/LOD subsystem that consumes
the view **direction**: the FP-M2 block-LOD selector.

- `facet_lod_mesher.gd:292-343` `_recompute_wants()` — per-facet **facing test**
  `to_cam.dot(nrm_w) <= 0` (`:316`, position-only) *plus* the **frustum test**
  `cam.is_position_in_frustum(ctr)` + 4 corners (`:321-327`) — a pure function of the camera
  **basis**. It runs **every frame** from `tick()` (`:567`), called per-frame from
  `module_world.gd:468-469`.
- Downstream, a want-membership change is exactly a re-emit engine: budgeter grants → builds
  → main-thread `_apply_one` ArrayMesh applies whose LOD_APPLY_BUDGET_MS budget is only
  checked **between** applies (`:557-566` — one large apply overshoots, unmetered);
  off-frustum facets idle-evict after 30 s (`:434-443`, `LOD_IDLE_DEMOTE_S:35`) and cap
  pressure LRU-evicts non-wanted facets **immediately** (`:472-497`) — i.e. *if this mesher
  were live, repeated 360° turning would be a textbook build/evict pump and would fully
  explain the spikes.*
- **But it is retired in the served build:** `FP_NO_NEAR_LOD=true` with `FP_M2_LOD=true`
  (served-pck flag dump, `docs/COSMOS-BORDER-SHADE-WELD-DESIGN.md:21,28`) makes
  `_near_lod_on()` false (`world_manager.gd:3277-3283`) — "the mesher is never created live"
  (`module_world.gd:2016-2020`: setup returns false, `_lod_mesher` stays null, `tick()` never
  runs). `FP_BLOCK_LOD=false`, `FP_SKIN_TIER=false` likewise (far-height served dump,
  `docs/COSMOS-FAR-HEIGHT-DESIGN.md` §0).

### 1.4 Verdict on the prime hypothesis

**FALSIFIED for the served build, at source level: a pure camera rotation produces ZERO
far-tier CPU re-emit/re-commit — there is no code path for it.** Every far-tier rebuild law
is a function of camera *position*, facet *membership*, content *epochs*, or wall-clock
cadences; none reads the camera basis. The one basis-coupled subsystem (the M2 frustum-want
selector) is proven retired live. The walk-calm lesson ("membership-delta vs camera-delta")
is *already structurally satisfied for rotation* — rotation isn't even a camera-delta in any
far-tier gate, because the gates key on position.

Two caveats keep this honest:

1. **Re-confirm the served pck** (the FARTREE-POLISH methodology — `load_resource_pack` +
   `get_script_constant_map` on `build/web/index.pck`): if a future deploy flips
   `FP_NO_NEAR_LOD` back off, §1.3's pump goes live and §4.2's gate becomes the fix.
2. "Zero re-emit" is a *CPU-rebuild* statement. Rotation still changes what the **renderer**
   culls and submits — see §3.

---

## 2. The `wf_smooth_v2_commit_ms ≈ 11.76`-every-frame suspicion — resolved: it is a LATCH

`wf_smooth_v2_commit_ms` is **not** a per-frame cost meter. The chain:

- `facet_smooth_v2.gd:594` `var _last_commit_ms := 0.0` — written only when a commit
  actually lands (`:724` async reap, `:824` sync `_commit`), read by `commit_ms()`
  (`:859-860`);
- forwarded as a **live last-value** by `facet_far_ring.gd:6245-6257` →
  `world_manager.gd:4098-4117` → `remote_bridge.gd:714-723` (`wf_smooth_v2_commit_ms`).

A byte-constant ≈11.76 across many worst frames is the *fingerprint of a stale latch* — the
duration of the **one most recent** whole-surface commit, re-read at every snapshot. It is
**not evidence of a per-frame 12 ms commit**, and §1.2 shows a per-frame commit is
structurally impossible at rest (residency changes only on crossing; `_dirty` only on tile
land/evict; `FP_SMOOTH_V2_PACE` additionally rate-caps to `SMOOTH_V2_COMMIT_MS`). The proof
instrument is one field away: `commit_count()` already exists (`facet_smooth_v2.gd:866-867`)
and is not yet plumbed into the snapshot — §4.1 adds it. Expected live result: `wf_sv2_commits`
is **flat** across an idle/turning window. (The same latch semantics were already flagged for
`st_bms`/`smooth_v2_commit_ms` in `COSMOS-GROUND-WALK-PERF-ATTRIBUTION.md` §1 — this closes it.)

So the "second lever" hypothesised in the brief (gate a per-frame smooth-v2 commit) has **no
target**: there is no unconditional per-frame commit to gate.

---

## 3. What CAN cost 400-1195 ms on a no-gen frame while turning (ranked)

With far-tier CPU re-emit excluded by §1 and generation zero by measurement, the unmetered
majority must live in code no GDScript timer wraps. The wf_ data itself narrows it:
`wf_draws` 45-162 (low) with `wf_prims` 425-549 k and **GPU-draw lower on spikes** acquits
steady rendering of static geometry; `wf_main_commit_ms` ≈ 0 acquits the job-lane commit;
`vt_total` acquits the *active* terrain's `_process`.

**H1 — first-draw materialization of freshly-revealed near-field chunks (the only genuinely
rotation-correlated cost left).** The far tier is submitted rotation-invariantly (huge
`custom_aabb`s: `facet_far_objects.gd:16` "never wrongly frustum-culled",
`facet_far_trees.gd:474` convention; the shell is ONE `_mi`). The **near field** is not:
chunks meshed behind the player while walking accumulate *never drawn* (frustum-culled).
Turning draws dozens-to-hundreds of them for the **first time** in one frame — and on
WebGL2/ANGLE (gl_compatibility, render on the main thread of a threaded export) first use is
where driver-side buffer/VAO/pipeline materialization and validation land. This cost is (a)
proportional to how much was meshed-but-unseen (worse right after a walk arc — matches the
probe being a throttle-arm walk), (b) invisible to every wf_ bucket, (c) **self-warming**:
the second consecutive 360° should be cheap until new meshes land. That prediction is the
A/B discriminator (§6).

**H2 — the steady main-thread floor explains the 116 ms median (not the spikes).** The
every-frame pump: far-ring `_process` tail (`facet_far_ring.gd:1490-1560` — structure probe
pass + staged bake `st_bms` 12.8, tree dwell probes, env warm, cull update),
`update_streaming`'s dozen-subsystem sweep (`COSMOS-GROUND-WALK-PERF-ATTRIBUTION.md` §2.1,
~19 ms under load), the snowfall step (`world_manager.gd:989-993` — "~20-25 ms/frame"
`:986-988`, **situational**: precip-gated per biome, a clean candidate for why one segment ran
43 ms median and another 116), the weather slice, 4 Hz telemetry. These are bounded,
position/cadence-driven, rotation-invariant — they set the floor the spikes ride on.

**H3 — browser/GL-layer stalls** (the known ~1 Hz class, `voxiverse-fall-instrumentation`):
compositor/driver pauses no in-page timer attributes. Discriminated by H1's repeat-turn test:
persistent per-revolution spikes with all §4.1 counters flat and `wf_cam_rot_dps` high ⇒
engine/browser render side ⇒ escalate to the native T2a meter
(`COSMOS-PERF-POSTPORT-DESIGN.md` §3) or a 10 Hz probe.

---

## 4. Design — byte-off, GDScript-only

Three pieces: (4.1) the instrumentation that *proves* the trace live and names the residual
(ship first — it is the decisive step), (4.2) the rotation-invariant gate for the one
basis-coupled subsystem (conditional — it is retired live today; ship with any near-LOD
re-enable), (4.3) the mitigation for H1 if the A/B confirms it (contingent).

### 4.1 `FP_TURN_ATTR` — rotation-keyed worst-frame attribution (ship first)

New flag `const FP_TURN_ATTR := false` (cube_sphere.gd, beside `FP_WORST_FRAME_ATTR:4355`).
All additions live inside code only reached under `FP_WORST_FRAME_ATTR and FP_TURN_ATTR` ⇒
byte-off. Counters follow the existing unconditional-cheap-counter precedent
(`_dbg_tail_runs` `world_manager.gd:1415`, `_dbg_rebuild_count` `facet_far_trees.gd:1126`).

1. **`wf_cam_rot_dps`** — the direct rotation correlator. In `RemoteBridge._process` (beside
   the `_win_worst` update `:467-479`), under the flags: cache the camera quaternion
   (`get_viewport().get_camera_3d().global_transform.basis.get_rotation_quaternion()`), keep
   an EMA of `2·acos(|q·q_prev|)/dt` in deg/s, snapshot it in
   `_capture_worst_frame_snapshot()` (`remote_bridge.gd:661`). A worst frame with
   `wf_cam_rot_dps` high and every rebuild counter flat is H1/H3 proven; a counter that moves
   names the culprit directly.
2. **`wf_sv2_commits`** — plumb `FacetSmoothV2.commit_count()` (`facet_smooth_v2.gd:866`)
   through `facet_far_ring.gd:6245-6257` and `world_manager.gd:4098-4117` (one key each),
   emitted beside `wf_smooth_v2_commit_ms`. Kills/confirms §2 in one live window (cumulative;
   diff across windows, the `ftr_rb`/`st_rb` pattern `remote_bridge.gd:719-723`).
3. **`wf_ring_emits`** — a cumulative far-ring emit counter: `_dbg_emit_count += 1` at the
   three swap/commit sites (sync whole-mesh swap, `_swap_in_arrays`, `_swap_in_sectors`) +
   accessor, forwarded in `worst_frame_markers()`. Proves "zero shell re-emit while turning"
   live (the trace says it will be flat; if not, the ring's own SRC_* re-emit source telemetry
   — `facet_far_ring.gd:362` — names which input drifted).
4. **`wf_snow_ms` / `wf_weather_ms`** — peek (non-resetting reads) of `_snow_us_max` /
   `_weather_us_max` (`world_manager.gd:993,1013`) into `worst_frame_markers()` — the H2
   situational-floor discriminator (the 43-vs-116 median split).

Cost: a few comparisons per frame + one dict-build per new window maximum. NEVER-OOM: zero
growing state.

### 4.2 `FP_LOD_ROT_INVARIANT` — the rotation-invariant want signature (conditional)

The gate the brief asked for, applied to the **only** subsystem that needs it. Dormant while
`FP_NO_NEAR_LOD=true`; mandatory companion if near-LOD ever re-enables.

**Engage law:** a pure basis rotation must produce a byte-identical `_want` set and zero
`request()`/`evict()` traffic; wants may change **only** when the *rotation-invariant
signature* changes:

```
sig = [ floori(cam_pos.x/16), floori(cam_pos.y/16), floori(cam_pos.z/16),   # position cell (16-block quantum)
        _active_fid, pool_fids_hash, smooth_residency_epoch,                # membership terms
        int(cam.fov*8), int(viewport_h) ]                                    # projection terms (zoom, resize)
```

**Edit site A — the skip** (`facet_lod_mesher.gd:292`, top of `_recompute_wants`):

```gdscript
# before (shipped): full 3,456-facet scan every tick()  (:567)
func _recompute_wants() -> void:
    var cam := _selector_camera()
    if cam == null or not FacetAtlas.is_ready() or _active_fid < 0:
        return
    _want.clear()
    ...

# after (flag on): identical scan, entered only on a signature change
func _recompute_wants() -> void:
    var cam := _selector_camera()
    if cam == null or not FacetAtlas.is_ready() or _active_fid < 0:
        return
    if CubeSphere.FP_LOD_ROT_INVARIANT:
        var sig := _want_signature(cam)          # the 8-term list above; pool hash from _mod.pool_fids()
        if sig == _want_sig:
            return                               # pure rotation / sub-cell drift ⇒ wants provably unchanged ⇒ zero work
        _want_sig = sig
    _want.clear()
    ...
```

**Edit site B — the membership term** (`facet_lod_mesher.gd:321-328`): under the flag,
replace the frustum test with an omnidirectional distance law so the *scan result itself* is
basis-free (the skip alone is insufficient — the first recompute after a real move must not
bake a view cone into `_want`, or turning right after walking re-arms the pump):

```gdscript
# before (shipped): in-frustum only
var visible := cam.is_position_in_frustum(ctr)
if not visible:
    for corner in _facet_render_corners(fid, gt):
        ...
# after (flag on): front-facing (position-only, kept from :316) ∧ within the SSE-justified disc
if CubeSphere.FP_LOD_ROT_INVARIANT:
    if to_cam.length() > CubeSphere.LODW_OMNI_MAX:   # new const; default = d where sse_lc(d) ≥ LOD_MAX_TIER+1
        continue                                     # beyond it even the coarsest tier is sub-τ — the far-ring quad is correct
else:
    <shipped frustum block verbatim>
```

Safety/no-thrash argument: the omni want disc is ~4-5× the 75° cone at the **coarse** tiers
only (fine tiers stay the idle-luxury + credit-gated path `:397-398`); the NEVER-OOM caps are
untouched and terminal (`_admit` degrades one tier per pressure step and denies to quad at the
coarsest, `:472-497`); with every in-disc facet *wanted*, the LRU can no longer be pumped by
rotation (there are no "behind-you = non-wanted" victims — `_evict_one_non_wanted` finds
nothing to churn) and `_idle_sweep` never sees an off-frustum unwanted facet, so the resident
set is stable under any turning. **No staleness:** a genuine position move crosses a 16-block
cell / changes `_active_fid`/pool/smooth membership ⇒ the signature changes ⇒ the full shipped
scan runs; and the omni set is a *superset* of what any single view cone needs, so turning
lands on already-resident meshes instead of today's build-on-first-sight pop-in. Off ⇒ both
edits vanish (`sig` never computed, shipped frustum block verbatim) ⇒ byte-identical.

### 4.3 `FP_REVEAL_WARM` — H1 mitigation (contingent on the §6 A/B)

Only if the A/B confirms first-revolution-only spikes. GDScript-only sketch: a 4×4 px
`SubViewport` sharing the main `World3D`, its own `Camera3D` at the player position with a yaw
that sweeps 360° over ~16 warm frames, `UPDATE_ALWAYS` but enabled only for a bounded window
after near-field mesh applies land (hook: the module's meshed-block counter; cadence 1-in-4
frames). Effect: first-draw driver materialization of behind-you chunks is paid continuously
in ~4-6 small slices instead of one 400-1195 ms slice at the user's turn; fill cost ~16 px.
Bound: doubles cull/submit CPU during warm windows only. If the submission-pass CPU cost
proves too high on WASM, the correct home is native (a T2-class engine patch: warm-draw or
orphaned-upload pacing at mesh apply — noted as the fallback, not the first move).

---

## 5. Byte-off / FLAT identity

- All three flags default `false`; every new branch is behind them; §4.1's counters are
  behavior-invisible increments in the existing `_dbg_*` style. Flag-off behavior is
  byte-identical; served flips remain sed-at-export (`docs/COSMOS-FAR-HEIGHT-DESIGN.md` §0
  mechanism).
- `verify_feature.gd` (FLAT) builds none of these tiers ⇒ 6042/0 untouched.
- `FP_LOD_ROT_INVARIANT` touches a subsystem that is **null live** (`_lod_mesher` never
  created under `FP_NO_NEAR_LOD=true`) — zero live risk even flag-on until near-LOD returns.

## 6. Gate + Live A/B

**Gate `verify_turn_calm.gd`** (headless, real classes, the codebase's injected-driver
convention):
- **G-TURN-TREES:** `FacetFarTrees` stepped 100× at a fixed camera (basis irrelevant — the
  API is position-only, which the gate *asserts* by signature) ⇒ `rebuild_count()` delta 0;
  then move the camera > `FT_DELTA_MIN_MOVE` ⇒ delta ≥ 1.
- **G-TURN-SV2:** `FacetSmoothV2.step()` 100× at fixed `set_active` ⇒ `commit_count()` delta
  0; `set_active(new_fid)` + landed tile ⇒ a commit.
- **G-TURN-LODSIG** (flag on, mesher force-created as verify_fp_m2 does): injected camera
  (`_cam` hook `facet_lod_mesher.gd:273-275`) rotated 360° in 32 steps at fixed position ⇒
  `_want` identical every step, ledger/`_building`/`_cache` untouched (zero request/evict);
  translate one facet ⇒ `_want` changes and a build dispatches.
- **G-TURN-BYTEOFF:** flags off ⇒ existing verify_fp_m2 suite green + FLAT 6042/0.
- **G-TURN-MARKERS:** `worst_frame_markers()` carries `wf_sv2_commits`/`wf_ring_emits` keys,
  values cumulative.

**Live A/B** (sed-at-export flag flip `FP_TURN_ATTR` on, no engine rebuild): stand still,
rotate the camera 360° repeatedly, wf_* probe on. Success/branch criteria:
1. `wf_sv2_commits`, `wf_ring_emits`, `wf_ftr_rb`, `wf_st_rb` **flat** across the turning
   window ⇒ §1's zero-re-emit trace CONFIRMED live (any counter moving instead names the
   culprit and re-opens §4.2-style gating for that tier).
2. Spikes on the **first** revolution, collapsing on later revolutions (until new meshes
   land) ⇒ H1 confirmed ⇒ ship `FP_REVEAL_WARM` (§4.3) / native warm.
3. Spikes on **every** revolution with counters flat and `wf_cam_rot_dps` high ⇒ H3
   (engine/browser render layer) ⇒ escalate: T2a native apply/upload meter
   (`COSMOS-PERF-POSTPORT-DESIGN.md` §3) or 10 Hz telemetry.
4. `wf_snow_ms`/`wf_weather_ms` explaining the 116-vs-43 median split ⇒ the floor is H2 ⇒
   budget/gate those steps in their own pass (out of scope here).
5. `wf_smooth_v2_commit_ms` still reading ≈11.76 with `wf_sv2_commits` flat ⇒ §2's latch
   reading CONFIRMED; treat the ms field as "last commit's price", never as per-frame load.

Expected effect on turn-in-place `worst_ms`: under outcome 2 + `FP_REVEAL_WARM`, the
400-1195 ms rotation spikes collapse toward the measured 43 ms smooth-segment floor (the
median stays governed by H2 until its own pass). Under outcome 3, no GDScript fix exists —
the doc's honest deliverable is that the next lever is native instrumentation, not far-tier
gating.

## 7. Files referenced

- `godot/src/world/facet_lod_mesher.gd` — `_recompute_wants:292-343` (facing `:316`, frustum
  `:321-327`), `tick:534-571`, budgeter `:368-409`, idle sweep `:434-443`, admission/LRU
  `:452-497`, apply `:557-566,573-625`, injected camera `:273-277`.
- `godot/src/world/facet_far_ring.gd` — `apply_camera_set:1232-1248`, `_emit_axis:1345`,
  `_process:1490-1560`, stage priority `:2390-2418`, sticky/no-camera-turn law `:168,780-844`,
  `worst_frame_markers:6245-6257`, `set_far_trees_camera:6301`, `_ft_cam:83`.
- `godot/src/world/facet_smooth_v2.gd` — crossing-only residency `:664-671`, step/commit law
  `:691-800`, `_last_commit_ms:594,724,824`, `commit_ms:859`, `commit_count:866`.
- `godot/src/world/facet_far_trees.gd` — delta gate `:1052-1068`, wanted scan `:1035-1037`,
  staleness floor `:892-900`, `rebuild_count:1659`.
- `godot/src/world/facet_far_structures.gd` — `step:218`, `rebuild_count:607`.
- `godot/src/world/facet_far_objects.gd` — dirty gate `:190-207`.
- `godot/src/world/world_manager.gd` — `update_streaming:1348-1578` (query pushes
  `:1432-1471`), `_near_lod_on:3277-3283`, far-ring drivers `:3802-3841,3892`,
  `worst_frame_markers:4098-4117`, snow/weather `:986-1013`.
- `godot/src/world/voxel_module/module_world.gd` — `_lod_mesher` tick `:468-469`, `_lod_setup`
  null-guard `:2016-2034`.
- `godot/src/net/remote_bridge.gd` — `_win_worst:467-479`,
  `_capture_worst_frame_snapshot:661-731`.
- `godot/src/player/player.gd` — mouse handler `:823-837`; `godot/src/main.gd` — camera feeds
  `:282,287,332,341-406` (all `.origin`).
- `docs/COSMOS-BORDER-SHADE-WELD-DESIGN.md:21,28` — served-pck proof `FP_NO_NEAR_LOD=true`;
  `docs/COSMOS-FAR-HEIGHT-DESIGN.md` §0 — served flag-dump mechanism;
  `docs/COSMOS-GROUND-WALK-PERF-ATTRIBUTION.md` — wf_* semantics + the unattributed-majority
  finding; `docs/COSMOS-FARTIER-WALK-DESIGN.md` — the membership-vs-camera-delta law this doc
  extends to rotation.
