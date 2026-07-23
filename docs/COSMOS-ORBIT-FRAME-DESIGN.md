# COSMOS ORBIT REFERENCE FRAME — inertial attitude + 6DOF space controls + inertial sky

**Status: DESIGN (Fable, 2026-07-18). No runtime code in this branch — doc only.**

Scope: how the player's ORIENTATION and the SKY become inertial in orbit, how 6DOF
microgravity controls work, and how both reconcile with the fixed-frame engine
(`ActiveFrame`/`FrameAdapter`, PlanetRoot@identity), the shipped surface FPS, and the
already-live POSITION frame-detach (hover drift −ω⃗×p, SN-FIX FIX-B).

Explicitly OUT of scope (owned elsewhere, do not conflate):
- the unsolved **landing freeze** (being root-caused in a parallel stream);
- **atmospheric braking** (in progress);
- position mechanics — the hover drift, free-fall, dev-flight controller are SHIPPED
  and this design composes with them without touching their math.

The behaviour spec is USER-LOCKED (this doc designs HOW, not WHETHER):
- SURFACE (PLANETARY): shipped FPS byte-identical — up = facet normal, pitch clamped
  ±1.5 rad, yaw via mouse, no roll.
- SPACE (LOW_ORBIT+): microgravity 6DOF — no gravity vertical, free orientation as a
  QUATERNION (mouse yaw + unlimited mouse pitch, roll on Q/E), movement flies the full
  6DOF look, camera decoupled from the facet frame.
- INERTIAL SKY in orbit: stars fixed, planet rotates beneath; sun/moon day-night preserved.
- LANDING RECOVERY: returning to PLANETARY smoothly re-aligns up to the facet normal,
  zeroes roll, re-clamps pitch — no snap.

---

## 1. Frame inventory (definitions used throughout)

| Frame | Definition | Where it lives in code |
|---|---|---|
| **BCI** (body-centred inertial) | Planet-centred, non-rotating; spin axis = +Z | `OrbitalState.fixed_to_bci` / `bci_to_fixed` (orbital_state.gd:242-254) |
| **Body-fixed / scene / world** | Planet-centred, co-rotating with the planet. **The planet is pinned at scene identity** (the fixed-frame keystone), so the Godot global frame IS the body-fixed frame; spin is expressed by moving the SKY. | The whole render scene; `cosmos_sky.gd` header comment |
| **Facet lattice** | The active facet's flat chart; +Y = facet normal | `FacetAtlas.frame_basis(fid)` / `facet_normal64(fid)` (facet_atlas.gd:320-334); `TerrainConfig.active_facet()` |
| **ActiveFrame** | Node3D @ `facet_transform(active)` hosting the player; player `position` is lattice-local, `global_transform = T_active · local` | `WorldManager._active_frame` (world_manager.gd:223-236), `FrameAdapter` |
| **Camera window frame** | `global_transform · Transform3D(Basis(X, _pitch), (0, eye, 0))` — body yaw ⊗ camera pitch | `player.gd window_camera_transform()` (player.gd:278-280) |

The one rotation that links body-fixed to BCI, with θ(t) = `CosmosEphemeris.spin_angle(body, t)`
(cosmos_ephemeris.gd:200-203) and ω = `omega_spin(body)`:

```
p_bci = R_z(+θ) · p_fix          (OrbitalState.fixed_to_bci, orbital_state.gd:249-254)
p_fix = R_z(−θ) · p_bci          (OrbitalState.bci_to_fixed,  orbital_state.gd:242-246)
```

R_z is the standard CCW rotation about +Z (`OrbitalState._rot_z`, orbital_state.gd:348-352).
For DIRECTIONS/BASES the same rotations apply with no ω⃗×p term.

The shipped camera basis chain under FACETED (M5_REAL off — the deployed path; the camera
is a plain child of the player, `_camera.rotation.x = _pitch`, player.gd:299-302):

```
B_cam_scene = B_active(fid) · R_y(yaw) · R_x(pitch)          … (1)
```

where `B_active(fid) = FacetAtlas.frame_basis(fid)` via the ActiveFrame. Every factor in
(1) is **body-fixed**: B_active is a facet of the pinned planet; yaw/pitch are player
state that only mouse input changes. That is the entire problem.

---

## 2. The root-cause theorem: both bugs are ONE bug

**Claim.** The star dome is ALREADY inertially fixed in the scene frame. Both live-pilot
bugs — "the sky rotates with the planet" and "roll/pitch still connected to the facet we
hover over" — are the single fact that the camera basis (1) is body-fixed. Making the
camera attitude inertial in orbit fixes both simultaneously; **the star-dome shader and
its transform need NO change.**

**Derivation.** `cosmos_sky.gd _update_sky` (cosmos_sky.gd:286-289) writes:

```gdscript
var spin := EPH.spin_angle(OBSERVER, t)
var star_xf := Transform3D(Basis(Vector3(0, 0, 1), -spin), cam_origin)
_stars.transform = star_xf                       # dome basis = R_z(−θ)
```

A star pattern P fixed in the BCI frame must render in the body-fixed scene as
R_z(−θ)·P — exactly the rotation applied. (Same convention as
`CosmosEphemeris.dir_to_bodyfixed`, cosmos_ephemeris.gd:239-248, which rotates inertial
directions by −θ.) So in the scene frame the stars counter-rotate at −ω: they are
inertially FIXED, and the apparent star motion seen by any camera is purely the
**relative** rotation between the camera basis and the dome basis:

```
B_rel(t) = B_cam(t)⁻¹ · R_z(−θ(t))
```

- Surface FPS: B_cam is body-fixed (constant between inputs) ⇒ B_rel rotates at −ω —
  the stars wheel overhead once per 1200-s game day. CORRECT for a surface observer.
- Orbit today: B_cam is STILL body-fixed while the position hover holds a BCI point
  (live-confirmed v_bci = 0) ⇒ the stars still wheel at −ω through the view and the
  pilot's up/pitch stays referenced to whatever facet passes below. Both reported bugs.
- Orbit with an inertial attitude, B_cam(t) = R_z(−θ(t)) · B_q where B_q is a constant
  (player-controlled) basis held in BCI:

```
B_rel(t) = B_q⁻¹ · R_z(+θ) · R_z(−θ) = B_q⁻¹  — CONSTANT.
```

Stars frozen; the planet (scene-static geometry) sweeps through the view at ω. Exactly
the locked behaviour, with zero sky-side changes.

**Sun/moon verification.** The impostor directions are
`EPH.dir_to_bodyfixed(OBSERVER, "sun"/"moon", t)` = R_z(−θ)·d_inertial
(cosmos_sky.gd:267, 280) — already inertial-correct in the scene. Through the inertial
camera the sun drifts only at Earth's orbital mean motion (2π per game year) and the
moon at 2π per game month; through the surface camera the day-night sweep at ω is
untouched (that path does not change). The Environment day-night ramp
(`_ramp_environment`) keys on `sun_dir·up` with up = radial (cosmos_sky.gd:297-301) —
attitude-independent, so it is unaffected by any camera change. No sky work needed;
Phase A pins all of this with a regression gate so a future edit cannot silently break
the counter-rotation (§8, G-ORBIT-SKY).

---

## 3. Attitude representation and the state machine

### 3.1 Representation

Two parametrizations, one displayed camera:

- **SURFACE**: the shipped clamped-euler pair — `rotation.y` (body yaw, lattice frame) +
  `_pitch` (camera-local X, clamped ±1.5) (player.gd:226-230, 299-302). UNCHANGED,
  byte-identical with the flag off and also with the flag on while in SURFACE mode.
- **SPACE**: one unit quaternion **q_bci** — the camera basis expressed in the BCI
  frame. Scene (render) basis each frame:

```
B_cam_scene(t) = R_z(−θ(t)) · Basis(q_bci)                    … (2)
```

  Note (2) contains NO facet term: the space attitude is facet-independent by
  construction, which is what makes it crossing-immune (§6.2).

State stored on the player: `q_bci: Quaternion`, an attitude-mode enum, and the
recovery blend state (§3.4) — ~40 bytes, no nodes, no per-frame allocation (NEVER-OOM).

### 3.2 The machine

```
            committed nav mode leaves PLANETARY
   SURFACE ────────────────────────────────────▶ SPACE
      ▲                                            │ committed nav mode returns PLANETARY
      │  α reaches 1: write yaw*/pitch* back,      │ OR ground contact (floor_under hit)
      │  camera re-childed, roll ≡ 0               ▼
      └────────────────────────────────────── RECOVER
                    (RECOVER ──▶ SPACE again if the nav mode re-leaves PLANETARY:
                     re-seed q_bci from the DISPLAYED basis — always continuous)
```

**Trigger** = the COMMITTED `CosmosNav.NavState.mode` (cosmos_nav.gd NavState.tick):
PLANETARY ⇔ h < ATMO_TOP = 384 with the ±32-block band (`ATMO_MARGIN`) and the 2-s
dwell (`NAV_DWELL_S`) already built into the classifier (cosmos_nav.gd:63-66, 194-223).
Reusing the committed mode means the attitude machine inherits exactly the hysteresis
the spec asks for and can never flap faster than the nav HUD does. The machine requires
`SN_NAV_MODES` (it reads `player._nav`); with `_nav == null` it never leaves SURFACE.

The RECOVER entry adds one extra trigger — ground contact while still nav-classified
orbital (a fast fall can reach the surface inside the 2-s dwell): entering RECOVER when
the analytic floor test reports contact guarantees the player never stands on terrain
with space attitude. (This is a safety clamp for the transition design only — the
landing-freeze itself is out of scope.)

### 3.3 SURFACE → SPACE: seeding (no view jump)

At the commit instant, seed the quaternion from the CURRENT displayed basis:

```
q_bci = Quaternion( R_z(+θ(t)) · B_cam_scene )                … (3)
      = Quaternion( R_z(+θ) · B_active · R_y(yaw) · R_x(pitch) )
```

By construction (2)∘(3) reproduces the pre-switch scene basis exactly at the switch
frame ⇒ C0-continuous view, no pop. From then on the frozen surface `rotation.y`/`_pitch`
are simply no longer consumed by the camera (they keep their last values; the body node's
yaw is irrelevant while flying — §5).

Camera plumbing: on entering SPACE set `_camera.top_level = true` and write its global
transform each physics frame:

```
_camera.global_transform = Transform3D(B_cam_scene, global_transform * (0, eye_height, 0))
```

This is the SAME mechanism the engine already uses for a globally-driven camera
(`_camera.top_level` + `set_render_camera`, player.gd:183-188, 283-285) — no new render
path. On leaving SPACE (end of RECOVER) `top_level = false` and the child
`rotation.x = _pitch` convention resumes. `window_camera_transform()` (player.gd:278-280)
gains one branch: in SPACE/RECOVER it returns the displayed 6DOF transform instead of
the euler reconstruction — this single seam is what makes dev-flight wishes, the SN5b
compass, aim, and the prewarm all consume the 6DOF attitude with no further edits (§5).

### 3.4 SPACE input: quaternion composition (unlimited pitch, roll)

Mouse and keys compose as CAMERA-LOCAL (right-multiplied) increments — local-axis
composition has no gimbal lock and no ±90° clamp by construction:

```
mouse dx:  q_bci ← q_bci · Quaternion(+Y_local, −dx · mouse_sensitivity)   (yaw)
mouse dy:  q_bci ← q_bci · Quaternion(+X_local, −dy · mouse_sensitivity)   (pitch, UNCLAMPED)
Q / E:     q_bci ← q_bci · Quaternion(+Z_local, ±ROLL_RATE · dt)           (roll)
q_bci ← q_bci.normalized()    each modification (f32 drift guard)
```

`mouse_sensitivity` is the shipped constant (identical feel per pixel at zero roll —
at the seed instant a pure-yaw mouse move matches the surface handler's `rotate_y`
exactly, so the hand feel is continuous through the border). ROLL_RATE ≈ 1.2 rad/s
(live-tuned). The surface mouse branch (player.gd:299-302) is untouched; the SPACE
branch is a new `elif` guarded by the flag AND the attitude mode, so flag-off input
handling is byte-identical.

Zero input ⇒ q_bci constant ⇒ by (2) the camera counter-rotates at −ω in the scene ⇒
inertially fixed attitude, stars frozen (§2), planet turning beneath. This composes
with the position hover drift (`hover_drift_lattice` adding −ω⃗×p, player.gd:525-530,
560-561): position AND attitude are then both at rest in BCI — the complete frame
detach the pilot expected.

### 3.5 SPACE → SURFACE: landing recovery (RECOVER state)

On the trigger (§3.2), freeze the current displayed basis and recover the surface
parametrization SMOOTHLY:

1. **Freeze** `B_start = B_cam_scene` at the trigger instant — held in the SCENE
   (body-fixed) frame from here on. Rationale: during landing the planet is the
   reference the pilot is re-joining; holding the blend endpoints body-fixed makes the
   recovery converge to something terrain-static. The residual star drift during the
   blend is ω·T_REC ≈ 0.005 rad/s · 0.8 s ≈ 0.004 rad — imperceptible.
2. **Derive the target** surface parameters from the current view, in the lattice frame
   `B_lat = B_active⁻¹ · B_start`, forward f = −B_lat.z:

```
yaw*   = atan2(−f.x, −f.z)          (degenerate |f.xz| < ε: derive from the camera
                                     X-axis instead: yaw* = atan2(−x.z, x.x))
pitch* = clamp(asin(f.y / |f|), −1.5, +1.5)
roll*  ≡ 0                          (implicit: the target basis has none)
B_target_lat = R_y(yaw*) · R_x(pitch*)
```

3. **Blend**: α ramps 0→1 over T_REC (0.8 s), eased with smoothstep (C¹ endpoints —
   zero angular-velocity step at both ends):

```
B_cam_scene = B_active · slerp( Quaternion(B_lat_start), Quaternion(B_target_lat), smoothstep(α) )
```

   Mouse input during RECOVER drives yaw*/pitch* (clamped) so the player never loses
   look control; the slerp target moves continuously, the displayed basis stays C0.
4. **Hand back** at α = 1: `rotation.y = yaw*`, `_pitch = pitch*`,
   `_camera.top_level = false`, `_camera.rotation.x = _pitch`, mode = SURFACE. The
   hand-back writes are exactly the state the displayed basis already equals
   (`B_active·R_y(yaw*)·R_x(pitch*)`) ⇒ no jump at the hand-back frame either.

Worst case (upside-down approach, roll ≈ π): the slerp takes the shortest great-circle
arc from the inverted view to the gravity-aligned one — a single smooth ~π tumble over
0.8 s, which is the intended "recover relative to the ground" feel.

Note the blend runs entirely in the lattice frame of the CURRENT active facet; if a
crossing redesignates the facet mid-recovery, both endpoints are re-expressed through
`crossing_basis` (facet_atlas.gd:320-321) exactly as velocity/look already are — one
multiply, continuity preserved.

---

## 4. Inertial sky — what changes (nothing) and what gets pinned

Per §2 the star dome, sun, moon, and Environment ramp are already inertially correct;
the fix is entirely §3. The sky work in this design is a REGRESSION PIN, because the
whole result now depends on an invariant that today is only a comment:

**G-ORBIT-SKY** (headless, pure): assert `Basis(Vector3(0,0,1), −EPH.spin_angle("earth", t))`
composed with `R_z(+θ(t))` is the identity to 1e-6 across a sampled game day (i.e. the
dome basis is exactly the fixed-frame expression of an inertial pattern), and assert
the view-relative star rotation `B_rel = B_cam⁻¹·R_z(−θ)` is CONSTANT (to 1e-6 over
sampled t) when B_cam follows (2) with fixed q_bci, and rotates at exactly −ω when
B_cam is a constant body-fixed basis. This pins BOTH halves of the theorem: the dome's
counter-rotation AND the attitude formula. If live validation after Phase A still shows
star wheel in orbit, the gate localizes the fault to the one remaining unpinned factor
(the camera write plumbing), not the math.

Risk note: the dome shader is on the "safe" additive class (`blend_add` +
`depth_draw_never`, cosmos_sky.gd:48-86) and is NOT touched. The only render-adjacent
change in the whole design is toggling `_camera.top_level` — a live-validation item
(§8) but the same node property the M5_REAL path already exercises.

---

## 5. 6DOF movement

Movement must fly the full orientation. Two flight paths exist; both get the attitude
through ONE seam each:

**(a) Kinematic look-fly** (`_kinematic_look_fly`, player.gd:537-563 — the
SN_NO_CEILING_BOUNCE F-mode). Today it builds the direction from the body-yaw basis +
pitch, in the lattice frame (player.gd:550-551). In SPACE attitude mode the direction
becomes the full 6DOF camera basis expressed in the lattice:

```
B_lat_cam = frame_basis(fid)ᵀ · B_cam_scene              (scene→lattice, orthonormal ⇒ transpose)
dir_lat   = B_lat_cam · (input.x, vy, input.z)           (forward = look, strafe = camera X,
                                                          Space/Ctrl vy = CAMERA-local ±Y — microgravity
                                                          has no world vertical, per the locked spec)
position += (dir_lat.normalized() · speed + carrier) · delta      (carrier = hover_drift_lattice, UNCHANGED)
```

In SURFACE mode the shipped lattice construction is untouched (byte-identical), and the
carrier term (−ω⃗×p in orbit) composes additively exactly as today — attitude changes
WHERE you fly, the carrier keeps the zero-input hover BCI-inertial.

**(b) Dev-flight velocity controller** (`_dev_flight_move`, player.gd:628-683). It
already builds its wish from `window_camera_transform().basis` mapped per-axis to BCI
(`_dev_dir_to_bci`, player.gd:660-672), including camera-relative Space/Ctrl (`cam_y`).
Because §3.3 reroutes `window_camera_transform()` to the 6DOF pose in SPACE, this
controller becomes fully 6DOF with ZERO changes to its code or math. Same for the SN5b
compass (player.gd:451) and the O-release look direction (player.gd:710).

The body node's `rotation.y` is frozen in SPACE (§3.3); the walking `_move` wish uses
`transform.basis` (player.gd:742) but walking is unreachable while flying in orbit, and
RECOVER hands a fresh yaw* back before surface locomotion resumes.

---

## 6. Reconciliation with the fixed-frame engine

### 6.1 Why the camera can bypass the ActiveFrame
The fixed-frame contract (COSMOS-FIXED-FRAME-DESIGN §2.3) is that GAMEPLAY runs in the
ActiveFrame's lattice and the RENDERER consumes globals, bridged only at enumerated
physics-boundary sites via `FrameAdapter`. A camera is pure render: writing its GLOBAL
transform introduces no new gameplay/physics coupling — precisely why `top_level` +
`set_render_camera` already exist for M5_REAL. The player BODY stays a lattice-posed
child of the ActiveFrame throughout; only the camera node's attitude is emancipated.
`FrameAdapter` is not modified and gains no new call sites.

### 6.2 Facet crossings while in SPACE
Formula (2) has no facet term ⇒ a redesignation cannot move the displayed camera at
all (stronger than FP_CROSS_KEEP_HEADING, which preserves heading only). The crossing
still re-poses the body (`apply_reframe`, player.gd:236-253) and twists the frozen
`rotation.y`; that state is display-inert in SPACE and fully re-derived at RECOVER
hand-back, so the twist choice (FP_CROSS_KEEP_HEADING on or off) becomes irrelevant to
the view in orbit — one less interaction to validate. Mid-RECOVER crossings re-express
the blend endpoints via `crossing_basis` (§3.5).

### 6.3 Aim, interaction, HUD
The interaction ray is a child of the camera (player.gd:192-196) and the DDA aim uses
the camera transform — both follow the 6DOF view automatically. Reach (~5 blocks) makes
surface interaction from orbit moot. The NavHUD/compass read
`window_camera_transform()` — consistent through the same seam. The SN3 near/far ramp
(`apply_scaled_camera_planes`, player.gd:291-294) writes camera PROPERTIES, orthogonal
to its transform — unaffected.

### 6.4 The position detach
Attitude is deliberately layered ON TOP of the shipped position mechanics: the hover
drift (−ω⃗×p), free-fall integrator, and dev-flight controller all operate on
`position`/velocities and are byte-untouched. The only contact points are read-only
(`window_camera_transform` for wishes) — so every SN gate that proved those kernels
(G-SN-HOVERDRIFT, G-SN-DEVFLIGHT, G-SN-FALLGRAV, G-SN-CONT) remains valid as-is.

---

## 7. New pure kernel: `CosmosAttitude`

All the math above lands in one engine-free static class
(`godot/src/cosmos/cosmos_attitude.gd`), following the CosmosNav/OrbitalState pattern
so every formula is headless-gateable with no scene:

```
seed_bci(B_scene: Basis, theta: float) -> Quaternion            # (3)
scene_basis(q: Quaternion, theta: float) -> Basis               # (2)
apply_look(q, dx, dy, sens) -> Quaternion                       # §3.4 yaw+pitch
apply_roll(q, dir, dt, rate) -> Quaternion                      # §3.4 roll
lat_cam_basis(fid_basis: Basis, B_scene: Basis) -> Basis        # §5(a)
recover_target(B_active: Basis, B_start: Basis) -> Vector2      # §3.5 [yaw*, pitch*] incl. degenerate branch
recover_blend(B_active, B_lat_start, yaw_t, pitch_t, alpha) -> Basis   # §3.5 eased slerp
```

Player-side wiring consumes these; the machine's mutable state is the quaternion + enum
+ blend scalars (§3.1). NEVER-OOM: zero allocation per frame, zero new nodes (the
camera node is reused).

---

## 8. Phased implementation plan

Every phase = one NEW flag in `cube_sphere.gd`, default **false** ⇒ main stays
byte-identical (the existing G-*-OFF pattern: FLAT `verify_feature` 6035/0 plus the
faceted gates run with all new flags off). Phases are ordered so each lands on the
current build independently and is individually live-testable. Gate script:
`godot/src/tools/verify_orbit_frame.gd` (SceneTree headless, exit 0/1, the
`verify_nav.gd` pattern), extended per phase.

### Phase A — `ORBIT_ATTITUDE` (requires SN_NAV_MODES): the inertial attitude machine
Changes: `CosmosAttitude` kernel; the SURFACE/SPACE/RECOVER enum on the player; the
seed on nav-mode commit; the per-frame camera global write (top_level) in SPACE; the
SPACE mouse/roll input branch; the `window_camera_transform()` seam. RECOVER in Phase A
is the DEGENERATE instant hand-back (α jumps to 1): view-continuous in yaw/pitch by
construction, but a non-zero roll snaps — documented, accepted for a default-off dev
flag, removed by Phase C.
- **Headless (G-ORBIT-ATT)**: seed round-trip `scene_basis(seed_bci(B,θ),θ) == B` to
  1e-6 for random B,θ; pitch composition past ±90° (compose 200 × 1° pitch increments ⇒
  net rotation 200°, no clamp, no axis flip); roll composes and commutes with nothing
  (sanity: 4×90° roll returns to start); zero-input inertial hold: `scene_basis(q,θ(t))`
  vs the dome basis is CONSTANT across a sampled day. Plus **G-ORBIT-SKY** (§4) and
  **G-ORBIT-OFF** (flag-off byte-identity suite).
- **LIVE-ONLY**: the feel of unlimited pitch/roll; the star-freeze look in orbit; the
  `top_level` toggle rendering cleanly (the one render-adjacent item).

### Phase B — `ORBIT_6DOF_FLY` (requires ORBIT_ATTITUDE + SN_DEVNAV): fly the look
Changes: the SPACE branch of `_kinematic_look_fly` (§5(a)); nothing in dev-flight (§5(b)
is free via the seam — assert, don't edit).
- **Headless (G-ORBIT-FLY)**: `lat_cam_basis` maps forward to the BCI look direction to
  1e-6 through random facet/θ (lift `dir_lat` by `frame_basis`·R_z(θ) and compare with
  −q·ẑ·q⁻¹); Space/Ctrl move along camera ±Y not lattice ±Y in SPACE; SURFACE-mode
  construction bit-equal to the shipped one; carrier term unchanged (hover: input 0 ⇒
  Δposition/δt == `hover_drift_lattice` exactly, i.e. v_bci still 0).
- **LIVE-ONLY**: the 6DOF flight feel (roll-then-thrust flies the rolled frame).

### Phase C — `ORBIT_LAND_RECOVER` (requires ORBIT_ATTITUDE): the smooth landing
Changes: the real RECOVER blend (§3.5) replacing Phase A's instant hand-back; the
ground-contact trigger; mouse-driven target during the blend; mid-blend crossing
re-expression.
- **Headless (G-ORBIT-REC)**: convergence — for random start attitudes (incl. roll π,
  forward ±lattice-Y degenerate cases) α=1 yields up == lattice +Y (facet normal),
  roll == 0, pitch ∈ [−1.5, 1.5], to 1e-6; continuity — the displayed basis at α=0
  equals the frozen space basis, at α=1 equals the hand-back euler reconstruction, and
  max per-step angular delta over the blend ≤ (π/T_REC)·dt·(smoothstep-peak 1.5) (no
  spike); trigger honours the committed-mode hysteresis (drive a scripted h(t) through
  384±32 and assert single RECOVER entry).
- **LIVE-ONLY**: the recovery feel (T_REC/ease tuning), interplay with the (separately
  fixed) landing freeze.

### Phase order and independence
A alone fixes both reported bugs (attitude + sky). B makes flight match the new
attitude (without it, F-mode still flies the old yaw+pitch construction — usable but
inconsistent with the view; ship A+B together to the pilot). C is pure polish of the
one remaining discontinuity. A→B→C strictly; each phase's flag can be baked on for a
deploy independently of later ones.

---

## 9. Risks (ranked)

1. **Surface-FPS regression via the input/camera branches** (the biggest): the SPACE
   branches sit in `_unhandled_input` and the camera path — the hottest shipped code.
   Mitigation: flag default-false with the shipped path as the untouched fall-through;
   G-ORBIT-OFF byte-identity gate; the euler fields are never written in SPACE (frozen,
   not repurposed) so SURFACE state cannot be corrupted by a space session.
2. **`top_level` camera plumbing**: correctness is proven headless via the transform
   math, but only a live session proves the render (culling, the SN3 plane ramp, the
   prewarm reading `camera_global_transform`). Precedent (M5_REAL) lowers but does not
   eliminate this; it is the Phase A live checklist item.
3. **Trigger timing at the border**: the 2-s dwell means attitude unlocks ~2 s after
   crossing 384 up (and re-locks late coming down — covered by the ground-contact
   clamp). If live feel demands instant unlock, the fix is classifying on the RAW mode
   for attitude only — a one-line change, deliberately NOT the default (dwell = the
   anti-flap guarantee).
4. **f32 drift in q_bci** over long sessions: normalized on every write; the θ factor
   is recomputed fresh from the f64 clock each frame (no accumulation in the basis).
5. **Mid-RECOVER edge cases** (crossing + re-entry to SPACE during the blend): both
   specified (§3.2, §3.5) and gate-driven with scripted sequences in G-ORBIT-REC.

## 10. Symbol index (everything this design touches or cites)

`cosmos_sky.gd`: `_stars`/`STAR_DOME_SHADER` (48-86, 233-251), `_update_sky` star
transform (286-289), `dir_to_bodyfixed` consumers (267, 280), `_ramp_environment`
(297-343). `cosmos_ephemeris.gd`: `spin_angle` (200-203), `omega_spin` (142-148),
`dir_to_bodyfixed` (239-248). `orbital_state.gd`: `fixed_to_bci`/`bci_to_fixed`
(242-254), `_rot_z` (348-352), `omega_cross` (237-239). `player.gd`: `_pitch`/mouse
(121, 299-302), `set_initial_look` (226-230), `window_camera_transform` (278-280),
`set_render_camera`/`top_level` precedent (183-188, 283-285), `_kinematic_look_fly`
(537-563), `hover_drift_lattice` (525-530), `_dev_flight_move` wish (660-672),
`apply_reframe`/`reframe_twist` (236-261), `_nav_tick` (417-453). `cosmos_nav.gd`:
NavState/dwell/hysteresis (63-66, 194-229, NavState.tick), `hover_drift_fixed`
(315-320). `facet_atlas.gd`: `frame_basis`/`facet_normal64`/`facet_transform`
(320-345), `crossing_basis` (320-321). `frame_adapter.gd` (whole file — unmodified).
`world_manager.gd`: ActiveFrame (223-236), `m5_epoch_camera` (1420-1437).
`cube_sphere.gd`: `ATMO_TOP` (530), `SN_NAV_MODES` (553), `SN_DEVNAV` (565),
`SN_NO_CEILING_BOUNCE` (620), `FP_CROSS_KEEP_HEADING` (602), `ORBITAL_SKY` (516).
