# COSMOS — post-de-orbit player up-vector tilt: root cause + fix design

Status: DESIGN (no production code). Author: Fable (architecture). Date: 2026-08-06.
Defect (live, user-reproduced): after a de-orbit descent and landing, the player stands with the
world horizon canted a few degrees, persistently (standing still never self-corrects). Otherwise
healthy: on_ground, altitude ~4, near blocky terrain renders, no fall-through. Observed active
facet at the spot: 1356.

Headless reproduction: **yes** — probe `godot/src/tools/probe_upvector_tilt.gd` (run:
`docker/engine/bin/godot.linuxbsd.editor.x86_64 --headless --path godot --script
res://src/tools/probe_upvector_tilt.gd`). All numbers below are measured against the real atlas.

---

## 1. Root cause

**The up-vector is never "set" and can never be stale — it IS the active facet. The stale thing
is the active facet itself:** a stationary player can sit in a strip along every seam where the
*crossing law* keeps the active facet at A while the *soil-render law* (the junction mask) has
already handed the ground cell under their feet to neighbour B. The player then stands upright in
A's frame on B's visibly-rendered soil, whose plane is one facet step away — a **measured
3.744°** cant at facet 1356 (3.13–3.75° across the atlas). The state is a fixed point of the
shipped machine: standing still, no crossing ever fires, so the tilt persists indefinitely.

### 1.1 Why the up is exactly the active facet's up (the hypothesis space collapses)

- The player's basis is **yaw-only in the lattice frame** by construction: `apply_reframe`
  documents "the player stays UPRIGHT (+Y up in both flat facet frames) … the dihedral tilt is
  carried by ActiveFrame" (player.gd:381-407); the surface camera is body-yaw × pitch-only local
  (player.gd:481-482). There is no roll DOF to be set from a wrong facet.
- The dihedral is carried by the **ActiveFrame node**: `_active_frame.transform =
  _anchored(FacetAtlas.facet_transform(to))`, written **inside the one committed facet-flip**
  `_commit_facet_change` (world_manager.gd:2584-2585; startup world_manager.gd:317; re-anchor
  touches origin only, world_manager.gd:2326-2327). Player/collider/debris are its children
  (world_manager.gd:991-998), so player-up ≡ `facet_transform(active).basis.y` whenever pose and
  frame are consistent.
- **A stale-frame reading is impossible given the observed symptoms.** `facet_transform` folds the
  per-facet decorrelation offsets `_off` (±32768 blocks, facet_atlas.gd:542-549). If the
  ActiveFrame ever held T_A while the pose was B-lattice (an aborted pipeline between
  `set_active_facet` world_manager.gd:2509 and the frame write :2585), the player's global
  position would be kilometres off the terrain — not "standing fine at alt 4 with a slight tilt".
  Standing correctly on visible soil *proves* pose ↔ active-facet ↔ ActiveFrame consistency.
  (`_heal_frame_desync`, player.gd:438-451, restores exactly this consistency; it is pose-only
  and that is sufficient — there is no separate basis to heal.)

### 1.2 The two laws and the strip between them

- **Crossing law** (what keeps A active): fire only when `own_dist(A, slot, feet) <
  −FACET_CROSS_HYST` with `FACET_CROSS_HYST = 0.1` (world_manager.gd:87, :2425-2427). `own_dist`
  is a 3D plane with a y-coefficient (facet_atlas.gd:598-600).
- **Soil-render law** (who draws/collides the ground): a cell is A's only if not junction-masked —
  masked ⇔ the whole unit cell lies beyond a seam plane (`cell_seam_state`,
  facet_atlas.gd:613-625; applied by `junction_modify` :749 in both meshing and the floor scan).
  Under FP_M1_POOL the neighbour facet is *live and meshed at its own true orientation*, so a
  masked-for-A cell is genuinely rendered by B.
- **The strip:** between "the soil cell is fully past A's ridge plane" (mask hands it to B) and
  "the feet point is 0.1 past the plane" (crossing fires) lies a band where **B renders the
  ground but A never crosses**. Byte-off it is up to ~0.1 wide plus cell-quantization alignment;
  **live it is up to ~3× wider**: the crossing check runs at the *lifted play-y* while the mask
  runs at *cell lattice y*, and the seam planes lean in y — measured mean |B| = 0.0299, max
  0.0332 over all 13,824 seam planes, × the FP_DATUM_BAKE lift ≤ 6.9 (facet_atlas.gd:471-486) ⇒
  the feet read up to **+0.23 more interior** than the soil cell, widening the no-fire band to
  ~0.33 blocks (this doubles as the reason the strip is column-specific: it concentrates where
  the ridge runs near cell-axis-aligned).

### 1.3 Measured (probe, real atlas — the headless repro)

- **P1:** up-vector step between edge-neighbours: 3.744°/3.649° at fid 1356; range 2.94–3.75°
  across sampled facets. Matches the observed "slightly tilted, a few degrees" exactly.
- **P2:** scanning 11,808 near-ridge stations on 8 facets (incl. 1356) with the shipped decision
  replicated (post-cooldown, containment, FP_CROSS_CORNER_COMMIT resolver): **244 stationary
  TILT_H equilibria (2.1% of near-ridge stations; 34 on facet 1356)** — no crossing trigger
  (`own_dist ∈ (−0.1, 0)`), soil cell masked for the active facet. Corner-deferral tilt states
  (TILT_C) measured **0** — the corner resolver settles everything sampled; the hysteresis strip
  is THE mechanism.
- **P3:** at every TILT_H cell the owner's mask has `masked=false` — complementarity holds, the
  neighbour (1380 at the fid-1356 examples) truly renders that soil. Raw lattice heights differ
  (dy 1–7) as expected between leaning planes; live the FS2′ datum weld reconciles the *play*
  surfaces at ridges (One-Surface Law).

### 1.4 Why de-orbit, and why now

A walking player traverses the ≤0.33-block strip in a fraction of a second; a **de-orbit landing
deposits a stationary player at an uncontrolled point** — the R3 restore targets `facet_of_dir`
at alt ≈ 416 (world_manager.gd:2645-2653) and the remaining descent drifts the ground track, so
touchdown lands anywhere, including inside the strip, with velocity zeroed. And the fall-through
fixes are what made the state *visible*: FP_QUERY_FRAME_GUARD + FP_FLOOR_SURFACE_WELD (both live)
turn a strip landing into a safe, correct-altitude stand (the masked column's floor fallback
equals the surface — FALLTHROUGH-DESIGN §1.1) — the old symptom was burial, the residue is the
tilt.

### 1.5 Falsifications (the tasked hypotheses, adjudicated)

- **"Player basis bound to a stale/neighbour facet fid" — false as stated.** No code derives a
  player roll basis from any fid; there is nothing to re-level inside `_heal_frame_desync` (the
  pose-owner heal is complete for its domain). The *fid itself* is what desyncs — from the facet
  the soil belongs to, not from the pose.
- **ORBIT_ATTITUDE / LAND_RECOVER residual roll — exonerated analytically.** In ATT_SURFACE the
  displayed basis has no roll term (player.gd:479-482); `_attitude_handback` writes yaw/pitch
  only and explicitly drops residual roll (player.gd:568-573); RECOVER re-references the fresh
  `b_active` every frame (player.gd:488-495) and hands back ≤ ORBIT_T_REC = 0.8 s after the
  PLANETARY commit (≤2 s dwell) — any camera-side residue clears in ≤ ~3 s, incompatible with a
  persistent tilt. **Camera-roll vs body-tilt:** the observed state is body-frame — the player is
  upright w.r.t. gravity (A's up) while the *world* (B's soil and horizon) reads canted; a camera
  roll would cant screen-space cues too and vanish on the next attitude cycle.
- **FP_DESCENT_FACET_RESYNC gap — not the entrance.** It is deliberately non-adjacent-only
  (world_manager.gd:2482-2487); an adjacent *deep* stale facet self-corrects through the normal
  trigger (own_dist ≪ −0.1 fires immediately post-cooldown). Only the sub-hysteresis strip
  survives — exactly what the probe found.

### 1.6 Live-signal adjudication (follow-up, same day): "tilt changes at borders, frequently a bit off"

The user's second observation — the tilt is NOT static, it *changes when crossing facet borders*
and is "quite frequently a bit off" — discriminates three mechanisms:

- **Wrong-phase basis capture at the crossing (the re-proposed hypothesis) — still structurally
  impossible.** The up is never computed or captured at a crossing: it is the ActiveFrame node
  transform, written from the commit's own `to` inside the same synchronous function that flips
  the facet (world_manager.gd:2509 → :2585 — no captured fid, no `_pos_fid` involvement, no
  frame boundary in between). There is no code path in which the up can read a different facet
  than the one being committed. The floor bug's cross-frame *read* window has no analogue here
  because nothing *reads* a facet to build the up — the transform IS the state.
- **The strip desync (§1.2) — real, but explains only the stationary full-step case** (3.744°,
  persistent, standing still): the original de-orbit report.
- **The geometric facet-vs-radial residual — matches the new signal exactly (measured,
  `godot/src/tools/probe_radial_vs_facet_up.gd`).** The player's up is piecewise CONSTANT (the
  active facet's normal) while the perceived horizon at distance — the far-ring limb, the
  atmosphere/sky, the ocean plane — is CONTINUOUS (radially symmetric about the planet centre).
  Measured cant between them: **0.01° at the facet centre, growing ~0.0045°/block to 1.81° at an
  edge midpoint and 2.60° at a corner**. At a committed crossing the up snaps by the full facet
  step (3.744°) while the radial horizon does not move ⇒ the apparent cant **flips sign,
  ≈ −1.9° → +1.9°, instantaneously at every border** — "the tilt changes when crossing facet
  borders"; and it is non-zero everywhere except facet centres — "quite frequently a bit off".
  This is not an ordering bug; it is the piecewise-flat planet visible against its own smooth
  far field. No crossing-side fix can remove it: whichever facet the up locks to, the radial
  horizon disagrees by up to half a step.

**Per-incident discriminator (fold into the §6 telemetry):** each grounded record classifies
itself — strip class: `active ≠ facet_of_dir(feet)`, soil cell masked, cant ≈ 3.6–3.75°;
geometric class: `active == facet_of_dir(feet)`, soil unmasked, cant ≈ the position-predicted
`angle(facet_up, radial_up)` (0–1.9° mid-edge, ≤2.6° corner). One record per sighting settles
which class the user is seeing.

---

## 2. Fix design — `FP_UPVECTOR_FACET_HEAL` (re-own the facet you stand on)

The up cannot be re-leveled independently — it is welded to the active facet by architecture
(§1.1), and that is correct (gravity, physics and pose all agree with it). The minimal true fix
is to **commit the crossing the soil law already implies**: when the ground cell under a
near-stationary grounded player is junction-masked for the active facet, cross to the facet that
owns it — through the normal committed pipeline, so ActiveFrame (the up), pose, pool, far ring
and gravity all flip together.

Touch points (all gated by `const FP_UPVECTOR_FACET_HEAL := false` in cube_sphere.gd;
byte-identical off — the heal is a new call guarded at its single call site, plus optional
trailing args defaulting inert):

1. **world_manager.gd `maybe_cross_facet`** — immediately before the final `return {}`
   (world_manager.gd:2456), after the shipped slot scan found nothing:
   `if CubeSphere.FP_UPVECTOR_FACET_HEAL: var heal := _upvector_strip_heal(fid, player_pos,
   h_speed, grounded); if not heal.is_empty(): return heal`. Placement inside the existing
   cooldown gate (:2418) means the heal can never re-fire faster than a normal crossing.
2. **new `_upvector_strip_heal(fid, pos, h_speed, grounded) -> Dictionary`**:
   - guards, in cost order: `grounded` and `h_speed < UPVECTOR_HEAL_MAX_SPEED` (≈ 0.5 b/s —
     the strip is only a trap for a near-stationary player; walkers exit it in one step, so
     normal walking never pays or fires); `min-slot own_dist(fid, pos) <
     UPVECTOR_HEAL_NEAR_RIDGE` (≈ 0.3, derived: |B|max · (lift 6.9 + 1) ≈ 0.26 — beyond that no
     mask disagreement is possible) — one plane dot per slot, the same math the scan above
     already did;
   - authoritative check: soil cell = the column's effective-height cell;
     `FacetAtlas.cell_seam_state(fid, xi, yi, zi)["air"]` — if the soil is ours, return `{}`
     (zero behaviour change everywhere but the strip);
   - target: `to = FacetAtlas.facet_of_dir(world(feet))` (the classifier oracle — also correct
     at corners where the owner is the diagonal); accept only if the reframed landing clears the
     corner wall, `min-slot own_dist(to, np) ≥ −(FACET_CROSS_HYST + FACET_CORNER_SLACK)`
     (the existing :2385 bound); else defer as shipped (the far ring still draws — the rare
     corner-wedge tilt residue is accepted and measured at 0 occurrences in P2);
   - commit: `return _commit_facet_change(fid, to, np, -1)` — the one blessed flip (ActiveFrame
     write :2584-2585 included), consumed by the player's existing `apply_reframe` at
     player.gd:788-790.
3. **player.gd :788** — pass the two hint args (horizontal speed, `is_on_floor`-equivalent) as
   optional trailing parameters of `maybe_cross_facet` (default values preserve the shipped
   signature ⇒ byte-identical off; FLAT short-circuits at :2395 regardless).

**Stability (no ping-pong, by construction).** The mask law is complementary (P3): after the
commit, B's mask owns the soil cell (`masked=false`), so B's own heal check returns `{}` at the
same point — the healed state is a fixed point of the *shipped* law (own_dist(B) ≈ +|d| interior,
no trigger). The heal direction always follows the deterministic mask/facet_of_dir owner, and the
crossing cooldown (:94, :2418) bounds any pathological case to the normal crossing rate.

**Vertical continuity.** On commit the column's law switches A→B; raw lattice g differs (dy 1–7
measured, P3) but the FS2′ datum weld reconciles the play surfaces at ridges. The gate asserts
play-surface continuity < 1 block at heal points with the live flag set; a residual ≤1-block step
is the normal fall/settle case and FP_FLOOR_SURFACE_WELD's domain.

**Cost.** Off: nothing. On: two floats compared per crossing-scan tick; the mask check only runs
within 0.3 of a ridge while grounded and near-stationary — O(1), no allocation, far below the #70
phys budget.

---

### 2.1 The geometric residual (§1.6) — a separate decision, not a phase fix

`FP_UPVECTOR_FACET_HEAL` fixes the strip class only. The facet-vs-radial residual (≤1.9°
mid-edge, ≤2.6° corner, sign-flipping at every crossing) is a *design* property of the faceted
planet; options, none of which belong in the heal:

- **(a) Accept** — it is bounded, and it is the honest geometry of the piecewise-flat world.
- **(b) `FP_CAMERA_RADIAL_LEVEL` (visual-only camera roll ease)** — roll the *displayed* camera
  by the facet→radial residual so the distant horizon is always level; physics/gravity/pose
  untouched (≤2.6° render-only roll). Wins: the 3.75° up-snap at every crossing disappears
  entirely (the radial reference is continuous) — a real step toward the locked seamless-scales
  continuum. Cost: the *near floor* (flat in the facet frame) then reads canted by the same
  residual — the two references are genuinely inconsistent and only one can be level. Needs an
  eyeball A/B; a plausible refinement is altitude/view-blended roll (facet-level on the ground,
  radial-level high/far — the existing recover-blend pattern).
- **(c) Radial-up player** — the true continuum answer (gravity/pose along the radial), i.e. the
  sphere-continuum refactor. Out of scope here; (b) is its cheap visual precursor.

Decision (user, 2026-08-06): **option (b) accepted** — full implementable spec in §5 below. The
heal (Class A) ships unchanged and independently.

## 3. Gate spec — `verify_upvector_heal.gd` (headless, falsifiable)

1. **Byte-off:** both flags false ⇒ full FLAT `verify_feature` 6042/0 unchanged; the P2 scan
   classifications byte-identical to this probe's.
2. **Repro assert (must demonstrate the defect pre-fix):** hunt a TILT_H point live (the probe's
   `_place_at_own` + `_classify`, no hard-coded cells — atlas-robust): with active = A and the
   pose at the point, assert the shipped `maybe_cross_facet` returns `{}` (the equilibrium),
   assert `cell_seam_state(A, soil).air` and owner B ≠ A, and assert
   `angle(facet_transform(A).basis.y, facet_transform(B).basis.y) > 3.5°` — the persistent tilt,
   reproduced headlessly.
3. **Heal arm:** flag ON at the same pose (grounded, h_speed 0) ⇒ `maybe_cross_facet` returns a
   commit to B; after `apply_reframe` assert active == facet_of_dir(feet) and up-divergence
   < 0.1°; assert f64 world-point continuity `|world(A,pos) − world(B,np)| < 1e-6` and play-
   surface continuity < 1 block; then re-run the scan at np under B ⇒ `{}` (fixed point — no
   ping-pong).
4. **No-regression arms:** (i) interior point (own_min > +1): ON ⇒ `{}`, identical to OFF;
   (ii) a normal deep crossing (own_min < −0.5, contained): ON commits the same destination as
   OFF (the heal is unreachable — the slot scan returns first); (iii) the same TILT_H pose with
   h_speed = 4 (walking): ON ⇒ `{}` — walkers untouched; (iv) a dug-shaft/edited column near a
   ridge: heal decision unchanged (the mask law ignores edits; assert no interference with
   `_edit_columns` behaviour).
5. **Weld/guard composition:** at the TILT_H pose with FP_QUERY_FRAME_GUARD +
   FP_FLOOR_SURFACE_WELD on, assert `floor_under`/`surface_y` agree before and after the heal —
   the heal is read-only w.r.t. the floor funnels and position (it only returns the crossing
   dict; `apply_reframe` remains the sole pose writer).

## 4. Composition & ownership

- **`_heal_frame_desync` (player.gd:438):** untouched, no overlap. It owns pose↔frame
  *consistency*; the heal owns facet *correctness*. The heal routes through
  `_commit_facet_change` → `apply_reframe` (the established pose-owner path), never mutates
  `position`/`_pos_fid` directly, and produces exactly the two-phase window the existing guard
  machinery (FP_QUERY_FRAME_GUARD, `_heal_frame_desync`) already covers — no new window class.
- **FP_QUERY_FRAME_GUARD / FP_FLOOR_SURFACE_WELD:** unaffected; they are what make the strip
  *survivable* (correct-altitude landing), the heal is what makes it *level*. Ship order proven
  safe: welds already live, heal composes on top.
- **FP_DESCENT_FACET_RESYNC:** complementary domains — resync owns non-adjacent lag, the heal
  owns the terminal adjacent sub-hysteresis strip; the two predicates are mutually exclusive by
  construction (non-adjacent vs seam_neighbour/diagonal owner).
- **`maybe_cross_facet` hysteresis/cooldown/containment/corner-commit:** all untouched; the heal
  adds one more resolver *after* them, strictly narrower in trigger, reusing their acceptance
  bounds.
- **ORBIT_ATTITUDE / ORBIT_LAND_RECOVER:** no change needed. If a heal commits mid-RECOVER, the
  blend re-references the fresh `b_active` automatically (player.gd:488-495 — the documented §6.2
  behaviour).
- **FP_TP_FLOOR_WELD dev weld (player.gd:765-772):** suppresses crossings during a dev-teleport
  landing by re-asserting the owner facet — it wins by ordering (runs before the crossing call);
  the heal never fights it. (Note in passing: that path re-asserts `set_active_facet` outside
  `_commit_facet_change`; it is safe only because `_tp_owner_fid` was committed through
  `dev_reanchor_near` first. Any future direct `set_active_facet` caller must pair with a frame
  commit — §1.1 is the invariant.)

## 5. `FP_CAMERA_RADIAL_LEVEL` — visual-only radial horizon leveling (Class C, spec)

Scope contract: **camera-display only.** Never touches the body basis (`apply_reframe`,
player.gd:385-407), `position`/velocity/gravity, the ActiveFrame (world_manager.gd:2584-2585),
or any physics/floor funnel. Composes downstream of FP_UPVECTOR_FACET_HEAL /
FP_QUERY_FRAME_GUARD / FP_FLOOR_SURFACE_WELD without reading or writing anything they own.
`const FP_CAMERA_RADIAL_LEVEL := false` (cube_sphere.gd) — off ⇒ **no per-frame camera write
exists at all** (the shipped event-driven pitch writes at player.gd:384/:666/:2126 remain the
only camera-local writers), byte-identical.

### 5.1 The roll: axis, angle, closed form

**Axis — view-forward (chosen; alternatives rejected below).** A rotation about the camera's
forward axis f̂ changes only the screen "up", never where you look: `−basis.z` is invariant, so
every aim/raycast/wish consumer (`_update_aim` player.gd:1916, the dig ray :2081, dev-flight look
seams via `window_camera_transform().basis.z` :910/:1537) is untouched *by construction*, and
mouse yaw/pitch semantics stay exactly the shipped euler pair. (Rejected: full look-basis
re-derivation with a radial up-hint — it re-parametrizes yaw/pitch, entangles the mouse handler,
and buys nothing the roll doesn't.)

**Inputs, all already at hand at the insertion site (§5.3):**
- `u_r` — radial up in scene coords: `(global_position − world.planet_render_centre()).
  normalized()` (planet_render_centre already folds the floating-origin/anchor offset,
  player.gd:467-473).
- Pre-roll camera basis **rebuilt from the input state, never read from `_camera`** (the
  feedback-loop guard, same rule as window_camera_transform's comment player.gd:475-478):
  `B0 = global_transform.basis * Basis(Vector3(1,0,0), _pitch)`; r̂0 = B0.x, û0 = B0.y,
  f̂ = −B0.z. (`global_transform.basis` = T_active.basis · R_y(yaw) via the ActiveFrame parent —
  the active facet's up enters here implicitly; no explicit facet read is needed.)

**Angle (closed form):**

```
phi_raw = atan2(u_r · r̂0, u_r · û0)        # signed screen-space lean of the radial up
phi     = w(alt) · v(pitch) · phi_raw       # §5.2 blends
camera local basis = Basis(Vector3(1,0,0), _pitch) * Basis(Vector3(0,0,1), s·phi)
```

`s = ±1` is fixed by the post-condition (gate-pinned, §5.4): the rolled basis must satisfy
`r̂'·u_r == 0` with `û'·u_r > 0`. Equivalent constructive form for the gate's independent check:
`û' = normalize(u_r − (u_r·f̂)f̂)`, `r̂' = û' × f̂` (screen-up is the projection of the radial up).
Bound: |phi_raw| ≤ angle(facet_up, u_r) / |cos(pitch-ish)| — with the v(pitch) fade below the
applied |phi| ≤ 2.60° everywhere (the measured corner maximum, §1.6). Cost: ~20 flops/frame,
zero queries, no allocation.

### 5.2 The blends: w(alt) and v(pitch), and the two irreconcilable references

The flat near floor is level in the *facet* frame; the far horizon (ring limb/sky/ocean) is
level in the *radial* frame; they disagree by phi_raw and no single roll satisfies both. The
blend picks the reference the eye is actually using:

- **`w(alt)` — which world dominates the frame.** `alt = position.y − terrain_floor`, reusing
  the frame's own floor result at player.gd:1772 (terrain-relative, NOT radial — a mountaintop
  stand must read w≈0; zero extra queries; continuous across crossings because the floor funnels
  are welded). `w = smoothstep(CAM_RL_ALT_LO, CAM_RL_ALT_HI, alt)` with
  `CAM_RL_ALT_LO := 16.0` (above trees/builds — the flat floor stops filling the lower view)
  and `CAM_RL_ALT_HI := 96.0` (≈ the near view radius — beyond it the far tiers are the only
  horizontal reference). Both are eyeball-tunable consts; the curve (C1 smoothstep, exact 0
  below LO, exact 1 above HI) is the spec. On the ground w = 0 exactly ⇒ flag-on standing play
  renders the shipped image bit-for-bit modulo float noise — the floor reads true, and the heal's
  domain (grounded, stationary) sees zero roll.
- **`v(pitch) = cos²(_pitch)` — which reference is in view along the gaze.** Looking level
  (horizon visible) ⇒ v = 1, full leveling; looking steeply down/up (floor/sky fill the view and
  the atan2 projection degenerates near ±90°) ⇒ v → ~0.005 at the ±1.5 rad clamp. C1, kills
  both the mid-altitude floor-cant objection when looking down *and* the numerical
  ill-conditioning at extreme pitch with one factor.

**Continuity across a facet crossing (the point of the feature).** At a committed crossing the
body/camera basis snaps by the dihedral (3.744°) while `u_r`, `_pitch`, and `alt` are continuous.
Decompose the snap about the ridge axis â into (i) the component about f̂ — pure screen ROLL —
and (ii) the residual that tilts f̂ itself — screen PITCH. The rolled camera's screen-up is, by
the constructive form, a pure function of (u_r, f̂): `û' ∝ u_r − (u_r·f̂)f̂`. Therefore: (i) is
**erased exactly** — for any gaze, the displayed horizon orientation tracks the continuous u_r
with no roll jump (looking along the ridge, f̂ ∥ â, the whole 3.744° snap is roll and the border
becomes visually seamless); (ii) remains — looking square across the ridge the snap is pure
forward-pitch (≤ the full step at w=1) and roll cannot address it (that residue belongs to
option (c), the radial-forward continuum). w and v are continuous at the crossing (their inputs
are), so the applied phi is C0; at ground level w=0 makes the whole feature inert where the snap
was already smallest on screen. **Net claim, stated honestly: the standing/roll cant (the
reported Class C symptom) is erased everywhere; the border snap is reduced to its forward-pitch
component instead of eliminated.**

**SPACE/RECOVER seam.** The roll applies in ATT_SURFACE only (`_att_mode == ATT_SURFACE` — the
machine owns the camera in SPACE/RECOVER, player.gd:519-547, and already displays free attitude
there). At `_attitude_handback` (player.gd:568-573) the camera returns at roll 0 while the flag
would apply w·v·phi_raw ≤ 2.6° next frame; since a de-orbit handback happens at high alt (w≈1)
this is a small pop — ease it by ramping a scalar `_cam_rl_ease` 0→1 over ~0.5 s after each
handback (the recover-alpha pattern, player.gd:557-561), multiplied into phi. SPACE *entry*
(seed_bci at :515/:539/:544) reads `_camera.global_transform.basis` — the rolled basis — which is
exactly what is displayed ⇒ the C0 no-pop seed contract is preserved automatically.

### 5.3 Insertion point (exact)

One flag-gated per-frame write at the tail of `Player._move`, **after** the crossing/resync/heal
block (player.gd:773-795) and **after** the floor query (:1772) — so the active facet is
post-commit/post-heal and `terrain_floor` is this frame's (the §5.5 ordering):

```
if CubeSphere.FP_CAMERA_RADIAL_LEVEL and _att_mode == ATT_SURFACE and _camera != null:
    _camera.transform = Transform3D(
        Basis(Vector3(1, 0, 0), _pitch) * Basis(Vector3(0, 0, 1), s * _cam_rl_phi()),
        Vector3(0, eye_height, 0))
```

- Flag off ⇒ the branch does not exist; the shipped event-driven writes (:384, :666, :2126)
  remain the only camera-local writers — byte-identical.
- Flag on ⇒ this write lands after any same-frame mouse write (:666 sets `rotation.x` only) and
  is the final displayed pose; the mouse handler itself is untouched.
- Mirror the same `* Basis(Vector3(0,0,1), s·phi)` into `window_camera_transform()`'s SURFACE
  branch (player.gd:486) so the one camera seam (prewarm placement, dev-look consumers — all
  forward-based, hence roll-invariant anyway) stays equal to the displayed pose.
- Explicitly NOT touched: body basis/`rotation.y` (:385-407), `_pitch` semantics, physics,
  gravity areas, ActiveFrame, all world queries. The only reader that sees a changed value is
  the dev freeze-look up-hint (`_camera.global_transform.basis.y`, :2346) — a ≤2.6° hint change,
  cosmetic and dev-only.

### 5.4 Gate — `verify_camera_radial_level.gd`

1. **Byte-off:** flag false ⇒ FLAT `verify_feature` 6042/0; assert no per-frame camera write
   path exists (camera local transform unchanged over N idle physics ticks after a mouse event).
2. **Analytic roll:** at constructed poses (facet centre / edge-mid / corner from
   `facet_planar_corner`, yaw sampled over 8 headings, pitch 0): assert `phi_raw` equals the
   independently-constructed projection form (`û' = normalize(u_r − (u_r·f̂)f̂)`) to 1e-6, and
   equals the §1.6 measured residuals (≈0° / ≈1.81° / ≈2.60° within the per-facet tolerance);
   assert the sign post-condition `r̂'·u_r == 0 ∧ û'·u_r > 0` (pins `s`).
3. **Blend law:** applied phi == `w(alt)·v(pitch)·phi_raw` at alt {0, LO, (LO+HI)/2, HI, 2·HI}
   × pitch {0, ±0.75, ±1.5}; exact 0 at alt ≤ LO (ground reads true — the near-floor bound);
   monotone C1 in between (finite-difference check).
4. **Crossing continuity:** drive the G-CROSS-HEADING harness pattern across a mid-edge seam at
   w=1 with the gaze along the ridge: assert the *displayed* screen-up direction (û' in scene
   coords) is continuous across the commit tick to < 0.05° (the roll component of the 3.744°
   snap is absorbed); with the gaze across the ridge: assert the residual displayed-basis jump
   equals the forward-pitch component only (roll jump still < 0.05°).
5. **Aim invariance:** for random poses with the flag on, `−camera_basis.z` equals the flag-off
   forward to 1e-6 (roll axis = forward ⇒ aim/dig/raycast byte-consistent).
6. **Heal composition (both flags on):** at a §3-hunted TILT_H pose, run the heal commit, then
   the same-frame roll: assert phi is computed against the POST-heal basis (facet-step-sized
   phi_raw before the heal would be the §5.5 double-count — assert it is the ≤ half-step
   residual instead).

**Eyeball-only residue (the live A/B must judge, no gate can):** the mid-altitude trade — at
w ≈ 0.5 with terrain and horizon both in frame, the floor reads canted by w·phi_raw (≤ ~1.3°)
while the horizon is half-leveled. That subjective balance point (and the LO/HI consts) is what
the A/B tunes; everything else above is asserted.

### 5.5 Interaction with FP_UPVECTOR_FACET_HEAL (ordering)

One-directional dependency, enforced by the §5.3 placement: the heal (inside
`maybe_cross_facet`, player.gd:788) commits first and changes the active facet → the body's
global basis → phi_raw; the roll is computed after it, from the post-commit basis. The roll
writes nothing the heal (or any physics) reads — no cycle, no double-count: the heal removes the
full-step Class-A error by *re-owning the facet*; the roll then levels only the remaining
≤ half-step geometric residual. With the heal off, the roll would cosmetically mask ~2.6° of a
3.744° strip tilt at altitude but nothing on the ground (w=0) — the classes stay separately
owned, which is why both flags exist.

## 6. Live verification

Deploy discipline: `scratchpad/deploy_cheats.sh` checkout-reverts uncommitted `cube_sphere.gd` +
`remote_bridge.gd` — the flag and any probe must be committed on the deploy branch.

- **Adjudicating telemetry (1/s, grounded only), fold into the FP_FALLTHRU_PROBE record:**
  {active_fid, facet_of_dir(feet), min-slot own_dist, soil-cell masked?, predicted tilt =
  angle(up_active, up_owner)}. This design predicts the tilt spot shows active ≠ owner,
  own_min ∈ (−0.1, +0.26), soil masked, predicted tilt ≈ 3.6–3.75° — one record confirms or
  falsifies. A camera-roll cause (falsified §1.5) would instead show active == owner with the
  tilt still visible.
- **Drill:** de-orbit, land near a seam (or dev-teleport to a probe-found strip column with the
  landing weld), stand still 10 s: flag OFF ⇒ horizon canted + telemetry signature; flag ON ⇒ one
  heal crossing in the log ≤ 0.1 s after touchdown, horizon level, no position pop (f64
  continuity), fps unchanged.
