# COSMOS-ORBITAL-O1O4-DESIGN — O1 orbit mechanics + O4 the walkable Moon

Status: **IMPLEMENTATION-READY DESIGN** (Fable, 2026-07-17). Concretizes phases O1 and O4 of
docs/COSMOS-ORBITAL-DESIGN.md (§5/§6/§8/§11 — the user-signed-off scale/time/mass model D2, the
vast-distance intent, and D1 planet-resize live there and are NOT re-litigated here). O0 SKY is
implemented and gated on `feat/voxiverse-orbital` (CosmosEphemeris/DVecF64/CosmosSky, 38/0).

Related: docs/COSMOS-FIXED-FRAME-DESIGN.md (ActiveFrame + PlanetRoot@identity — the substrate),
docs/COSMOS-FACETED-IMPL.md (the facet engine), docs/COSMOS-FP-M2-DESIGN.md (pool + controller),
memories `voxiverse-never-oom-web`, `voxiverse-physics-scale`.

Code line references are the current working tree (post-#17 crossing-hitch merge); the O0 kernel
references are `feat/voxiverse-orbital`.

---

## 0. Executive summary

**O1** adds the three-regime gravity field, an f64 orbital state with a symplectic integrator +
freeze-to-Kepler, the ORBITAL player mode with gear-2 thrust, atmosphere drag, re-entry through
`facet_of_dir` + pool pre-warm, and the anchor-follow / home-body-impostor machinery that keeps
f32 sane off-surface. All behind `FP_M3_ORBIT`, flag-off byte-identical.

**O4** makes the Moon a real faceted voxel body. The keystone move is the **global fid namespace**:
`FacetAtlas`'s packed static tables stay static and immutable but grow to hold ALL bodies' facets
contiguously — Earth fids `0..6K_E²−1` at base 0 (bit-unchanged), Moon fids appended at
`fid_base_moon`. Every per-fid accessor (`fid * 12` row reads), the edit key, the pool, collision,
gravity volumes, and the crossing algebra work **verbatim** — the audited K/R/facet-count call
surface is ~10 sites. Worker safety is **by construction**: all bodies' tables are built in
`warm_up` before the first worker exists and are never mutated after, so there is no swap and no
"half-swapped body" state to protect against. Earth byte-identity before the Moon exists is proven
by the **equivalence gate** (a pinned hash of the atlas tables + pinned worldgen samples). The
dominant-body swap at the SOI is deliberately trivialized by one invariant: *near-field voxel
content exists only below H_FARSWAP altitude, and SOI boundaries are ≥60k blocks from any surface*
— so the swap only ever touches sky-scale nodes, and ALL heavy streaming goes through the one O1
re-entry path regardless of body.

Staging: **O1a → O1b → O4a (namespace refactor, Earth-only) → O3 (D1 resize) → O4b (Moon body,
dark) → O4c (SOI swap + landing)**. O4a before O3 because per-fid `r_of/k_of` makes the resize a
data change.

## 1. Ground truth (code-verified)

What the design stands on, verified in source:

- **FacetAtlas is a static, immutable-after-warm_up table store** (facet_atlas.gd:19-39): flat
  packed arrays `_frame` (12 f64/fid), `_off` (2 i32), `_poly` (8 f64), `_dom` (4 i32),
  `_seam_plane/_neigh/_ring/_mhat` (16 f64 / 4 i32 / 24 f64 / 12 f64) — **616 B/fid**, all indexed
  `fid * stride`. `K := 24`, `R_BLOCKS := 3072.0` are consts (facet_atlas.gd:12-13). `warm_up()`
  (facet_atlas.gd:84-108) builds everything on the main thread; every runtime accessor is a pure
  row read. The per-facet decorrelation offset hashes **fid** (`_hash01_3d(fid, 11, 0, 751)`,
  facet_atlas.gd:146-147) — fid-stable, body-agnostic.
- **The K/R/count call surface is tiny**: `FacetAtlas.K` — main.gd:30 (log),
  facet_far_ring.gd:219,287; `FacetAtlas.R_BLOCKS` — terrain_config.gd:814 (facet_profile),
  facet_lod_builder.gd:247-248, facet_far_ring.gd:390,434; `facet_count()` —
  facet_lod_mesher.gd:291,727, spawn scan (facet_atlas.gd:610), far ring. `facet_of_dir` has ONE
  production caller (world_manager.gd:2021, the off-surface spawn freeze) plus gates.
- **Worldgen is direction-parameterised at ONE choke point**: `facet_profile(fid,x,z)` =
  `profile_at_dir(cell_dir(fid,x,z), R_BLOCKS)` (terrain_config.gd:812-814). `profile_at_dir`
  (terrain_config.gd:798-810) is a pure function of (SEED, d̂, rr). All noise singletons are built
  in `_ensure_noise()` on the main thread via `warm_up()` (terrain_config.gd:317-352, 404-421).
- **The worker frozen-epoch contract**: the runtime-compiled generator freezes `gen_facet` (+ all
  appearance tables) at creation (module_world.gd:2712-2717); the worker threads it through
  `GenCtx.facet` → `column_profile` → `facet_profile` and reads ONLY frozen instance vars + the
  immutable statics. A facet change installs a NEW generator. `block_all_air(gen_facet, …)` is a
  frozen-atlas row read (facet_atlas.gd:559-573).
- **Edits are already fid-namespaced**: `_edits` keys are `FacetAtlas.edit_key(fid, cell)`
  (facet_atlas.gd:66-67) — multiplicative packing, key ≈ fid·2^47, so int64 holds to fid ~65,000
  (the "fid < 4096" in the doc comment is a documentation bound, not a packing limit).
- **The fixed frame + anchor exist**: ActiveFrame @ `T_active` hosts player/collider/debris
  (world_manager.gd:204-224); `FrameAdapter` bridges local↔global (world/frame_adapter.gd);
  `_anchor_offset` + `REANCHOR_TRIGGER_BLOCKS := 8192` (cube_sphere.gd:299) is the shipped
  integer floating-origin shift (never fires at R=3072). Per-facet gravity `Area3D`s are bounded
  to the live pool (world_manager.gd:46-64).
- **Player gravity**: `gravity := 22.0` feel (player.gd:25), per-body feel hook `gravity *= s;
  jump_velocity *= sqrt(s)` (player.gd:90-99), applied as lattice `velocity.y -= gravity·δ`
  (player.gd:380). Fly = lattice noclip (player.gd:319-331). `OFFSURFACE_Y := 256` pool freeze
  (cube_sphere.gd:243, world_manager.gd:2014-2021).
- **The O0 kernel** (feat/voxiverse-orbital): `CosmosEphemeris` — `BODIES` table (gm_real, r,
  parent, a, m0, spin, tidal), `gm_game(body) = gm_real × 5.184e-6`, `body_pos_parent/helio`,
  `spin_angle` (tidal = orbit + π), `dir_to_bodyfixed` (R_z(−spin)·d, spin axis **+Z**),
  `omega_orbit/spin`; `CosmosClock.t` (f64 s, the only mutable state); `DVecF64` (f64 vec3 as
  PackedFloat64Array). All pure/static/engine-free.

The one geometric convention that matters everywhere below: **the scene frame is the dominant
body's body-fixed frame** (planet pinned at identity); the ephemeris inertial frame is rotated
+`spin_angle(body,t)` about **+Z** relative to it. `ω⃗ = ω ẑ` with ω = `omega_spin(body)`
(Earth: 2π/1200 ≈ 5.236e-3 rad/s → equatorial ω·R = 33.4 m/s).

---

# Part A — O1: ORBIT (flag `FP_M3_ORBIT`)

## 2.1 Constants (CubeSphere, beside OFFSURFACE_Y)

```gdscript
const FP_M3_ORBIT := false        # master flag; OFF ⇒ byte-identical (nothing below is created)
const H_BLEND_LO := 128.0         # radial altitude: below = pure lattice feel gravity (shipped)
const H_BLEND_HI := 512.0         # above = pure GM/r² inertial regime (> ATMO_TOP, > OFFSURFACE_Y)
const ATMO_TOP := 384.0           # atmosphere ceiling (D10; near-field scale, user-locked)
const H_FARSWAP := 20000.0        # above: pool+far-ring retire, home body renders as impostor (§2.8)
const ORBIT_THRUST_G2 := 25.0     # gear-2 thrust authority, m/s² (0→LEO 548 m/s in ~22 s)
const ORBIT_ACTIVE_MAX := 8       # hard cap on actively-integrated orbital entities
const DRAG_TERMINAL := 55.0       # sea-level terminal speed target, m/s (co-tuned with controller gate)
const ORBIT_PREWARM_H := 1024.0   # descending through this altitude designates + pre-warms the landing facet
```

Altitude is **radial**: `h = |p_fixed| − R_body` (f64), where `p_fixed` is the planet-centred
body-fixed position (PlanetRoot is at identity, so scene position + anchor = p_fixed). The
planarization sag (≤3 blocks) makes lattice-y vs radial-h disagreement irrelevant at 128+.

## 2.2 The gravity field — `cosmos_gravity.gd` (new, pure static kernel)

House-style pure f64 kernel (CubeSphere/CosmosEphemeris discipline: static, engine-free,
deterministic, worker-safe, headless-gate-testable):

```gdscript
class_name CosmosGravity
## g vector at body-fixed position p (DVec3 f64) over `body`, blending the three regimes (§5.1
## of the parent design). `fid` = the active facet (for the lattice-regime facet normal); −1 ⇒
## radial-down is used below the band too (off-facet callers).
static func gravity_fixed(body: String, fid: int, p: PackedFloat64Array) -> PackedFloat64Array
```

- `r = |p|`, `h = r − R_body` (R from `CosmosEphemeris.radius_of` — == `FacetAtlas.r_of` post-O4a).
- `w = smoothstep(H_BLEND_LO, H_BLEND_HI, h)` (compute in f64; Godot's smoothstep is fine).
- **Direction**: slerp(−facet_normal(fid), −p̂, w). Facet normal from `facet_normal64(fid)`
  (facet_atlas.gd:304-306). Deviation mid-facet ≤ dihedral/2 — the shipped, accepted approximation.
- **Magnitude**: `lerp(FEEL_G_body, gm_game(body)/r², w)` where `FEEL_G_body = 22.0 ×
  (gm_real_body/R_body²)/(gm_real_earth/R_earth²)` — the same real-datum ratio the player feel
  hook uses (player.gd:90-99), so player and debris agree. Earth: 22 → (at h=512) 43.6 → GM/r².
- `w == 0` (h ≤ 128): returns exactly the shipped facet-−Y at feel magnitude — the walking game is
  untouched (and the function is simply not consulted there; see below).

**Consumers.** The walking/jumping player below the band keeps the shipped analytic
`velocity.y -= gravity·δ` verbatim (byte-path: no new code executes at h < H_BLEND_LO). FLY mode
(gear 1) gains the blend only under the flag: when `FP_M3_ORBIT` and h > H_BLEND_LO, the fly-mode
vertical is no longer pure noclip — v1 keeps noclip fly as-is (fly is a creative verb) and the
blend applies only to ORBITAL mode + debris. Debris: the per-facet gravity `Area3D` magnitude
stays feel-g (debris live near the surface; areas are pool-bounded ≪ H_BLEND_LO) — no change.
This keeps O1's blast radius minimal: **the blend function's only v1 consumer is the ORBITAL
integrator and the mode-transition logic**; it exists as the single named field so later phases
(O2 grids, gravity-aware debris) read the same truth.

## 2.3 OrbitalState — `orbital_state.gd` (new, pure f64, engine-free)

The ONE orbital-state implementation players/grids/debris share (parent §5.2):

```gdscript
class_name OrbitalState                  # RefCounted; all math static-friendly f64
var body: String                          # dominant attractor
var mode: int                             # ACTIVE (integrated) | RAILS (Kepler elements)
var pos: PackedFloat64Array               # DVec3, body-centred INERTIAL (BCI), blocks
var vel: PackedFloat64Array               # DVec3, BCI, blocks/s
var elems: PackedFloat64Array             # RAILS: [a, e, i, raan, argp, m0, epoch] (f64 ×7)
```

- **Integrator** (ACTIVE): semi-implicit (symplectic) Euler at the physics tick:
  `v += (g(p) + a_thrust + a_drag)·dt; p += v·dt`, `g(p) = −gm_game(body)·p/|p|³`. Substep clamp:
  `dt_sub ≤ 1/60 s` (loop `ceil(dt/h)`). At 60 Hz on the 79-s LEO, dt·ω ≈ 1.3e-3 → bounded energy
  oscillation ~1e-3 relative, zero secular drift (the symplectic property). RK4/n-body rejected
  per parent D3.
- **Freeze rule**: no thrust + no drag (h > ATMO_TOP) + no imminent surface intercept ⇒ convert to
  Kepler elements (`rv → elements`, standard f64 algebra) and go RAILS: closed-form position on
  demand, zero per-tick cost, drift-free coasting (hours-long transfers cost nothing — parent
  §6.3). Any input/disturbance thaws (`elements → rv` at t). **v1 freezes only elliptic bound
  orbits (e < 1 − ε, r_ap inside SOI)**; hyperbolic/escape states simply stay ACTIVE — correct,
  cheap (one entity), and cuts the universal-variable Kepler solver from scope. Elliptic
  thaw needs Kepler's equation (Newton iteration on E − e·sinE = M, ~4 iterations, f64) — small,
  gate-pinned.
- Cap: `ORBIT_ACTIVE_MAX = 8` ACTIVE entities (O1 uses 1 — the player; the cap is asserted
  machinery for O2).

**Why BCI**: integrating in the inertial frame means no fictitious forces, exact Newton; the
rotating scene frame is a render-side re-expression (next section). Geostationary orbits come out
scene-stationary for free.

## 2.4 The frame algebra (the exact handoff formulas)

Let `θ = spin_angle(body, t)`, `R_z(θ)` the +Z rotation, `ω⃗ = omega_spin(body)·ẑ`.

- **BCI → body-fixed (scene)**: `p_fixed = R_z(−θ)·p_bci`;
  `v_fixed = R_z(−θ)·(v_bci − ω⃗ × p_bci)`.
- **body-fixed → BCI**: `p_bci = R_z(θ)·p_fixed`;
  `v_bci = R_z(θ)·(v_fixed + ω⃗ × p_fixed)` — **the ω×r term** (33.4 m/s eastward at the equator;
  the free eastward-launch Δv, ~4% of orbital velocity — parent D4).
- **lattice ↔ body-fixed**: the shipped facet algebra —
  `p_fixed = lattice_to_world64(fid, x, y, z) (+ anchor bookkeeping)`, velocity/look via
  `frame_basis(fid)` (rotation only). All f64 (facet_atlas.gd:257-271).

**SURFACE/FLY → ORBITAL** (climb through H_BLEND_HI, or explicit keybind while flying):
1. `p_fixed` = player's f64 absolute position (FrameAdapter local→global is f32-safe here only
   because |abs| ≤ 3.3k on-surface; the handoff recomputes through `lattice_to_world64` + the f64
   anchor to avoid the f32 lane — position-critical, pitfall #1).
2. `v_fixed` = lattice velocity rotated by `frame_basis(fid)`.
3. Apply the body-fixed → BCI map above. Mode = ORBITAL; capsule collider disabled (like fly,
   player.gd:242); pool freeze already active (> OFFSURFACE_Y).

**ORBITAL → SURFACE (re-entry commit)** at h < H_BLEND_LO over the designated facet (§2.7):
inverse map to `p_fixed/v_fixed`, then `fid = facet_of_dir(p̂_fixed)`,
`[x,y,z] = world_to_lattice64(fid, p_fixed)`, velocity by `frame_basis(fid).transposed()`. Mode =
SURFACE (falling; the analytic floor catches it). This is the crossing algebra with an extra
rotation — same class of exact f64 re-expression the FP3 crossing ships
(facet_atlas.gd:289-296).

Every map above is a pure function ⇒ each handoff has a headless f64 continuity gate (§2.10).

## 2.5 Player modes (extending, not replacing, the shipped machine)

```
enum PMode { SURFACE, FLY, ORBITAL }      # player.gd; `flying` stays the FLY alias (compat)
```

- SURFACE/FLY below H_BLEND_HI: **byte-identical shipped code** (the flag only adds the altitude
  check + keybind).
- ORBITAL: per physics tick — build the wish vector in the *camera* frame (free-look; mouse =
  pitch/yaw, v1 roll locked), thrust `a_T = ORBIT_THRUST_G2 · wish` rotated body-fixed → BCI, step
  `OrbitalState`, then render placement (§2.8). No `move_and_slide`, no collider. HUD (§2.9).
- Transitions: FLY→ORBITAL auto at h > H_BLEND_HI (one-way latch with hysteresis band ±32 to
  prevent mode flapping); ORBITAL→re-entry per §2.7. Gear 3 (TRANSFER/cruise) ships with O4c —
  in O1 the Moon is scenery (no SOI, disclosed; gear-2 Δv makes reaching it deliberate).

Owner of the orchestration: `WorldManager` (it owns frames/facets/anchor); `player.gd` owns input
+ the mode enum; `OrbitalState` owns the math. The RemoteBridge telemetry gains
`mode/h/|v|/ap/pe` fields (the live-loop validation reads these).

## 2.6 Atmosphere drag (D10 — load-bearing for re-entry pacing)

In the ACTIVE integrator, when `h < ATMO_TOP` for a body **with an atmosphere** (BodySpec flag;
Earth yes, Moon no):

```
v_air = v_bci − ω⃗ × p_bci               # air co-rotates with the body
a_drag = −k(h) · |v_air| · v_air
k(h) = K0 · exp(−h / H_SCALE),  H_SCALE = 128.0
K0 = FEEL_G / DRAG_TERMINAL²  ≈ 22/55² ≈ 7.27e-3   # terminal ≈ 55 m/s at h=0
```

Consequences (all intended): terminal descent ≤ ~55-60 m/s (streaming-survivable — the
controller's commit-band politeness window from 512 is ≥ 8.5 s); a periapsis inside the
atmosphere decays the orbit ("orbit or fall back" is real); drag is isotropic (no flight model —
parent §13). Drag forces ACTIVE mode (no RAILS inside the atmosphere).

## 2.7 Re-entry: designation + pool pre-warm

While ORBITAL with radial velocity < 0:

1. Each tick compute `fid_target = facet_of_dir(p̂_fixed)` (facet_atlas.gd:639-644 — pure, cheap).
2. Falling through `ORBIT_PREWARM_H` (1024): `WorldManager.prepare_landing(fid_target)` — the
   teleport-class pool rebuild (`set_active_facet` + `set_facet`, the shipped machinery
   module_world.gd:1524+), running under the StreamLoadController exactly as a committed crossing
   (the POOL_D_COMMIT geometric-admission rationale: the landing is committed; pre-paying strictly
   dominates paying at the ground). If `fid_target` drifts (cross-range), re-designate — the
   pool's neighbour machinery absorbs adjacent-facet corrections; a designation jump > 1 facet
   re-runs prepare (rare below 1024 at drag-capped speeds).
3. At h < H_BLEND_LO: commit the ORBITAL→SURFACE handoff (§2.4). The player lands falling onto
   the analytic floor; worst case under a hot descent is briefly low-LOD ground (LOD tiles are
   radially complete — parent risk #1).

Descent-time budget check: 1024 → 0 at ≤60 m/s ≥ 17 s; the pool's full crossing rebuild is
seconds-scale — margin ~3×.

## 2.8 Off-surface render placement: anchor-follow + H_FARSWAP

Above the surface the shipped "|abs| ≤ 3.3k" bound breaks — LEO is 6.9k, the Moon 384k. Two
mechanisms, both O1:

**Anchor-follow.** The shipped integer anchor (`_anchor_offset`, REANCHOR_TRIGGER_BLOCKS=8192,
world_manager.gd:59-62, cube_sphere.gd:299) starts actually firing: when
`|p_fixed − anchor| > 8192`, step the anchor by integer multiples of 4096 toward the player and
re-place every absolute node (PlanetRoot, slots, far ring, gravity areas, ActiveFrame, debris) —
the shipped shift, now routine. In ORBITAL mode the player node is placed as
`node.position = f32(p_fixed − anchor)` with the subtraction **in f64 before the downgrade**
(DVecF64 → Vector3 at ≤ 8k magnitude ⇒ sub-mm f32 ulp). ActiveFrame pins to
`Transform3D(Basis.IDENTITY, −anchor)` in ORBITAL mode (the facet lattice frame is meaningless in
orbit; FrameAdapter keeps bridging for anything still parented there).

**H_FARSWAP impostor-ization.** Above `H_FARSWAP` (20k — measured, then pinned): retire the live
pool (already frozen since 256) AND the far ring + facet slots; the home body renders as a **body
impostor** — v1 the CosmosSky moon-impostor pattern pointed home (shaded sphere, albedo from the
far-ring palette; v2 a low-poly mesh baked from the facet atlas — the far-ring builder emits
exactly this geometry). Below H_FARSWAP on descent, rebuild the far ring (budgeted; the veil is
acceptable v1 — measured). Rationale: with the anchor at 384k the far ring's f32 coords are ~4e5
(ulp 0.03 — sub-pixel at that distance, but the node churn per anchor step is waste), and O4's
dominant-body swap becomes trivial (§3.5) precisely because nothing voxel-scale exists above
H_FARSWAP. Impostor placement generalizes CosmosSky: direction computed **from the player's f64
position** (not the body centre) so parallax is honest when far from home.

Hysteresis: swap altitude ±2k band; the swap is idempotent and abortable (a bounce off H_FARSWAP
re-uses the still-warm far ring if it hasn't finished retiring).

## 2.9 Orbit HUD

Closed-form from the f64 ACTIVE/RAILS state (cheap, once per frame): frame-explicit speed
(surface-relative below H_BLEND_HI + in atmosphere; inertial above; target-relative comes with
O2), radial altitude, Ap/Pe + time-to (from a, e, M — the single most orbit-teaching UI element),
prograde/retrograde markers. House pattern: a read-only view like ThermometerHUD.

## 2.10 O1 gates (headless, `verify_orbital.gd`; live via remote bridge)

| Gate | Asserts |
|---|---|
| G-O1-FIELD | gravity_fixed: continuity at LO/HI (|Δg| < ε across band edges); == shipped facet-−Y·feel at h<LO; == GM/r² radial at h>HI; magnitude monotone on the ramp |
| G-O1-ENERGY | 10 LEO orbits ACTIVE at dt=1/60: specific energy + |angular momentum| — bounded oscillation, **secular drift ≈ 0** (linear-fit slope < 1e-6/orbit); r deviation < 10 blocks (measured-then-pinned) |
| G-O1-KEPLER | freeze→thaw round-trip == state to f64 ε; RAILS position at t+T == at t (period exact); thaw at 1000 sampled times matches an ACTIVE integration < ε |
| G-O1-HANDOFF | lattice→BCI→lattice round-trip < 1e-9 blocks; standing still at the equator ⇒ |v_bci| == ω·R = 33.4 m/s eastward (the spin term, exact) |
| G-O1-REENTRY | deorbit integration: facet_of_dir designates; world_to_lattice64 y ≈ h; landing point in_polygon(fid); designation stable below PREWARM_H at drag-capped speeds |
| G-O1-DRAG | terminal speed at h=0 == DRAG_TERMINAL ± 5%; periapsis at 200 decays; no drag above ATMO_TOP |
| G-O1-ANCHOR | forced anchor step: every (node − player) relative position invariant to f32 ε; OrbitalState untouched (anchor is render-only) |
| G-O1-OFF | FP_M3_ORBIT=false ⇒ FLAT 6035/0 + full faceted suite byte-identical; no new nodes exist |

Live (remote bridge): fly to orbit, coast 3 orbits on-rails, deorbit, land, walk; worst-frame
deltas within the shipped envelope (real frame deltas + p90 — never TIME_PROCESS).

## 2.11 O1 change map

| File | Change |
|---|---|
| `src/cosmos/cosmos_gravity.gd` | NEW — the blend kernel (§2.2) |
| `src/cosmos/orbital_state.gd` | NEW — f64 state/integrator/Kepler (§2.3) + the frame algebra statics (§2.4) |
| `src/cosmos/cube_sphere.gd` | the §2.1 consts |
| `src/player/player.gd` | PMode enum, ORBITAL input/tick, transitions, keybind |
| `src/world/world_manager.gd` | handoff orchestration, prepare_landing, anchor-follow in ORBITAL, H_FARSWAP retire/rebuild, ActiveFrame orbital pinning |
| `src/world/facet_far_ring.gd` | retire/rebuild entry points (H_FARSWAP) |
| `src/cosmos/cosmos_sky.gd` | observer-position parallax; home-body impostor |
| HUD scene + `src/tools/verify_orbital.gd` | NEW |

---

# Part B — O4: the walkable Moon (flag `MULTI_BODY`)

## 3.1 The BodyAtlas refactor — a global fid namespace, not an instance rewrite

**The problem.** `FacetAtlas` + `TerrainConfig` are static singletons whose frozen tables voxel
workers read concurrently. A second body naively suggests either (a) instantiating FacetAtlas per
body (churns all ~151 `FacetAtlas.*` call sites, most of them worker-hot), or (b) swapping the
static tables when the dominant body changes (**catastrophic** — a worker mid-`_generate_block`
would read a half-swapped table; this is exactly the race class the frozen-epoch discipline
exists to kill).

**The design: append, never swap.** Facet ids become a **global namespace across bodies**:

```gdscript
# facet_atlas.gd — the body registry (immutable const; append-only FOREVER, see the contract)
const BODY_TABLE := [
    {"name": "earth", "k": 24, "r": 3072.0},           # fid_base 0      (K=50/R=6371 after O3)
    {"name": "moon",  "k": 14, "r": 1737.0},           # fid_base 6·24²  (built only if MULTI_BODY)
]
static var _fid_base: PackedInt32Array   # per body slot; earth == 0 always
static var _fid_body: ...                # body_of_fid via binary search / range check (2 bodies: 1 compare)
static func k_of(fid) / r_of(fid) / body_of_fid(fid) / fid_base(body) / body_facet_count(body)
```

`warm_up()` builds Earth's facets **exactly as today** (same loops, same math, fid_base 0 —
byte-identity by construction), then, under `MULTI_BODY`, appends the Moon's 6·14² = 1176 facets
into the SAME packed arrays at `fid_base_moon = 3456`. All tables remain static, built on the
main thread before any worker exists, immutable forever after.

**Why this is safe and cheap — the five load-bearing facts:**

1. **Every per-fid accessor works verbatim.** All runtime reads are `fid * stride` row lookups
   (`cell_dir`, `lattice_to_world64`, seam planes, `block_all_air`, `junction_modify`,
   `cell_interior_scaled`, `facet_transform`, crossing algebra…). A Moon fid indexes Moon rows.
   **Zero call-site churn** on the fid-parameterised API — the 151 sites keep compiling and
   keep being correct.
2. **Worker safety is structural, not disciplinary.** There is no per-body table set to swap;
   both bodies coexist immutably. The worker's frozen `gen_facet` ∈ one body's range selects its
   rows. The "build ALL per-body tables before workers spawn" requirement is satisfied by
   `warm_up` having always been that place (main.gd:26-28). The one addition:
   `CubeSphere.warm_edge_tables` must be warmed for **both** K grids (fold_cell at n=K_earth and
   n=K_moon — seam building + facet_of_dir read them), still inside warm_up.
3. **Seams never cross bodies.** `_build_seam` folds within its own face grid at that body's K
   (fold at n=K_b, then + fid_base_b) — each body's facet graph is closed; neighbour fids stay
   in-range by construction.
4. **The edit overlay is already multi-body.** `edit_key(fid, cell)` packs fid multiplicatively
   (key ≈ fid·2^47; int64 holds to fid ~65,000). Earth+Moon at K=50: 15,000 + 1176 = 16,176 fids
   → max key ≈ 2.3e18 < 2^63. Moon edits, `block_id_at`, collapse, collision — all free via the
   fid. Update the facet_atlas.gd:53-59 doc comment; the gate asserts pack/unpack round-trip over
   the full range.
5. **fid stability contract**: `BODY_TABLE` is **append-only, never re-ordered, and a body's K/R
   never changes after content exists on it** (fids encode into persisted edits and future portal
   anchors). The D1 resize (O3) changes Earth's K — which is exactly why O3 must land **before**
   persistent multi-body content, and why O4a should precede O3 (the resize becomes a
   registry-row edit + regen instead of a const hunt).

**Per-body dispatch lands at the ~10 audited const sites** (§1): `facet_profile` samples at
`r_of(fid)`; far ring/LOD builders take a `body` (or derive from their fid range); the spawn scan
restricts to Earth's range (`body_facet_count("earth")`); `facet_of_dir(d)` gains a body
parameter → `facet_of_dir(body, d)` (its one production caller, world_manager.gd:2021, passes the
dominant body; gates updated).

**Memory (NEVER-OOM ledger):** 616 B/fid → Moon +0.72 MB static one-shot; Earth 2.1 MB today /
9.2 MB post-O3. Both bodies' **atlases** stay resident (small, static); the near-field **pool**
remains strictly exclusive to the dominant body (§3.5) so peak pool memory is max-over-bodies,
not sum — the parent §8.1 invariant, enforced by the swap machinery.

## 3.2 Per-body worldgen — BodySpec profiles in TerrainConfig

`facet_profile(fid, x, z)` (terrain_config.gd:812-814) becomes the **dispatch point** — the only
worldgen entry the faceted engine uses:

```gdscript
static func facet_profile(fid: int, x: int, z: int) -> Vector4:
    var d := FacetAtlas.cell_dir(fid, x, z)
    match FacetAtlas.body_of_fid(fid):
        0: return profile_at_dir(d.x, d.y, d.z, FacetAtlas.r_of(fid))        # Earth — verbatim
        1: return moon_profile_at_dir(d.x, d.y, d.z, FacetAtlas.r_of(fid))   # Moon
    ...
```

Everything downstream (GenCtx threading, column memo keyed (facet,x,z), resolve_cell, the module
worker, the analytic queries, LOD/far-ring sampling) flows **unchanged** — the profile is already
the single choke point both render paths and all queries share.

**Moon worldgen profile** (`moon_profile_at_dir`, new noises seeded `SEED_MOON := SEED + 900001`,
built in `_ensure_noise` on the main thread — all bodies' noises warm up front, frozen):

- **Base**: gentle rolling regolith noise (hills-class, lower amplitude) + a broad low-frequency
  **maria mask** (dark basalt plains, ~30% coverage, lower elevation) vs **highlands** (brighter,
  rougher, higher).
- **Craters** (the signature): deterministic hash-jittered sparse placement — partition the
  sphere by coarse cube-face cells (the existing face/cell math at a small n); each cell hashes
  (SEED_MOON, cell) → 0..2 craters with centre jitter, radius 8..64, age. Height contribution of
  a crater at angular distance s from centre (all f64, pure): bowl `−depth·(1 − (s/R_c)²)` inside,
  raised rim `+h_rim·falloff` near s ≈ R_c, ejecta noise beyond. Sum over the ≤ 3×3 neighbouring
  cells' craters (bounded, memoized per column by the existing profile memo). Depth/radius ratio
  ~0.2, rim ~0.04·R_c — reads as Minecraft-heroic, honest at near-field scale.
- **Biomes**: new band `B_MOON_MARIA`, `B_MOON_HIGHLANDS` (+ `B_MOON_POLAR` slot for later ice —
  content hook, not v1). **No sea** (the biome branch never emits liquid — SEA_LEVEL simply never
  matches), **no trees** (TreeGen density 0 for moon biomes), no snow.
- **resolve_cell stays THE choke point**: moon biomes route to a moon strata ladder — `regolith`
  (new BlockCatalog id, silver-grey, mass ~ gravel) top 3-5 cells, `basalt`/`anorthosite` (new
  ids; maria/highlands respectively) beneath, existing deepslate band + bedrock floor below
  (shared bones = shared caves/ore machinery later). Adding materials is the data change the
  engine was built for (CLAUDE.md rule 2: BlockCatalog + BlockMaterials + the biome rule).
- **Envelope**: crater math is clamped so `height ≤ MAX_SURFACE_Y` (gate-asserted — the worker
  early-outs depend on the bound, module_world.gd `_generate_block`).
- **Sky/environment**: no atmosphere → no fog tint, black sky, stars at full day (CosmosSky ramp
  parameterised by BodySpec `has_atmo`); PerVoxelEnvironment temperature: harsh day/night swing
  slot — v1 keeps the latitude model with a wider amplitude (data change).

**Feel gravity**: the shipped hook (player.gd:90-99) with s = 0.165 → g 3.63, jump_velocity
×0.406 — lunar hang time ~2.5× at preserved jump height, out of the box.

**Tidal lock**: already in the O0 kernel (`spin = orbit + π`); nothing to build — the Moon's
body-fixed frame IS the scene frame when dominant, and Earth hangs at the sub-Earth point
(angular diameter 1.9°) by construction. Gate: O0's sub-longitude invariant re-asserted against
the **rendered** Earth impostor direction.

## 3.3 module_world / pool / far ring / edits under multi-body

- **The generator**: unchanged in structure. `gen_facet` freezes a Moon fid; `column_profile`
  dispatches by fid (§3.2); `block_all_air(gen_facet,…)` reads Moon seam rows. The frozen tables
  the loader publishes (arid tables etc.) already include the moon materials once BlockCatalog
  has them (the appearance pipeline is id-driven). `MAX_SURFACE_Y` early-outs use the
  max-over-bodies bound (conservative, correct).
- **The pool** is fid-driven and body-blind — `set_facet(moon_fid)` + the neighbour machinery
  work verbatim (neighbour fids come from Moon seam slots). The **dominant-body invariant** (one
  body's near-field at a time) is owned by WorldManager: the pool is only ever asked for fids of
  the dominant body (all pool entries share one body by construction — entered via
  prepare_landing/crossings, which are dominant-body operations).
- **Far ring**: `FacetFarRing` builds per body (`fid_base + body_facet_count` range at that K);
  Moon ring = 1176 facets (~⅓ of Earth's — small). Built at the H_FARSWAP descent, not at the
  SOI swap (§3.5).
- **Edits/collision/gravity-areas/crossings**: free via the fid namespace (§3.1 fact 4; gravity
  areas take the facet's own T_fid basis — Moon facets included; magnitude = moon feel-g via the
  body ratio).
- **Spawn**: Earth-only scan (§3.1). The Moon needs no spawn facet — you arrive where you land.

## 3.4 The equivalence gate — G-O4-EQ (the keystone the refactor rides on)

Proves the refactored engine renders/simulates **Earth byte-identically** before the Moon exists:

1. **Atlas hash pin**: a tool run pre-refactor dumps a canonical hash (e.g. MD5 over the raw
   bytes of `_frame,_off,_poly,_dom,_seam_plane,_seam_neigh,_seam_ring,_seam_mhat` + `_spawn_fid`)
   → pinned const in the gate. Post-refactor (MULTI_BODY=false AND =true), the hash over Earth's
   fid range must equal the pin. Catches any accidental math/order drift; f64 determinism makes
   byte-hashing valid (same code path, same platform — the gate runs on the pinned toolchain).
2. **Worldgen sample pin**: 1,000 deterministic (fid, x, z) samples of `facet_profile` + 200
   `resolve_cell` columns, full-precision-printed pre-refactor → pinned; asserted equal.
3. **The full existing suites green**: FLAT 6035/0 (verify_feature), faceted G-M2-ID, the FP
   fixed-frame + M2 gates — all byte-identical (they exercise the pool/mesher/edits end-to-end).
4. **MULTI_BODY=false ⇒ no Moon rows built** (facet_count/memory identical to pre-refactor;
   asserted).

Because Earth's build path is textually unchanged at fid_base 0, identity holds by construction;
the gate makes it *proven*, and stays as the permanent regression net for every later body.

## 3.5 The dominant-body swap (SOI handoff, Earth ↔ Moon)

**Precondition that makes it clean** (established by O1): above H_FARSWAP (20k) NO voxel
near-field exists — pool retired, far ring retired, home body is an impostor. Moon's SOI radius
is 66,100 blocks; Earth↔Moon SOI crossing happens ≥ 64k from the Moon's surface and ~318k from
Earth's. **Therefore the swap never touches voxel terrain** — it is bookkeeping + sky:

1. **Pure state re-expression** (f64, exact, one tick):
   `p_moon_bci = p_earth_bci − moon_pos(t)`; `v_moon_bci = v_earth_bci − moon_vel(t)` (circular
   ephemeris derivative closed-form: `v = a·n·t̂`). Then `OrbitalState.body = "moon"`. Pure
   function → headless-gated round trip.
2. **Scene frame re-expression**: the scene becomes Moon-body-fixed — i.e. the render-side
   `R_z(−spin_angle(dominant))` now reads the Moon's (tidal) spin. The player's rendered position
   jumps only by the anchor reset (integer, one step); sky directions are recomputed from the
   same ephemeris — the **rendered** (inertial) sun/star directions are continuous by
   construction (gate-asserted).
3. **Sky swap**: Earth impostor appears (shaded sphere v1, 1.9° from the Moon), Moon impostor
   retires in favor of… nothing yet — the Moon is still > 60k away, rendered as the same impostor
   until H_FARSWAP descent builds its far ring + (later) pool via the **one O1 re-entry path**,
   now running on Moon fids with moon gravity/no-drag.
4. **Hysteresis**: SOI boundary ±2% band (no flapping on a grazing trajectory).

The parent design's "loading veil" concern moves to where it belongs: the H_FARSWAP far-ring
build on descent (measured; veil acceptable v1) — NOT the SOI crossing, which is imperceptible.

**Landing on the Moon — the no-atmosphere problem (flagged, needs the user):** without drag
there is no terminal-velocity cap; a ballistic lunar descent arrives at ~120-170 m/s (surface
orbit/escape speeds) — 2-3× the streaming-tuned Earth re-entry. Landing *requires* a retro-burn
(genuinely realistic and good gameplay), but a player who doesn't brake will outrun the pool.
Mitigations (choose in D-O4-5): (a) accept brief low-LOD ground under a hot lander (LOD tiles are
radially complete; you were going to crash anyway), (b) raise ORBIT_PREWARM_H to ~4096 for
atmosphere-less bodies (descent from 4k at 170 m/s ≈ 24 s — pool margin restored), (c) a soft
"landing assist" auto-retro below 512. Recommendation: **(b) + (a)** — no physics magic, honest
worst case.

## 3.6 O4 gates

| Gate | Asserts |
|---|---|
| G-O4-EQ | §3.4 — the keystone (atlas hash pin + worldgen pins + full suites green, both flag states) |
| G-O4-KEY | edit_key/unpack bijection over Earth+Moon fid ranges; edit on a Moon fid survives a swap round-trip |
| G-O4-MOONGEN | moon_profile determinism (pure fn of SEED_MOON, d̂); no liquid emitted; height ≤ MAX_SURFACE_Y over 10⁴ samples; crater fields present (statistical floor); no trees |
| G-O4-ATLAS2 | Moon facet frames pass verify_frame thresholds (facet_atlas.gd:652+) over all 1176 fids; facet_of_dir("moon", d) round-trips centre dirs; seam closure within Moon's graph |
| G-O4-SOI | zero-thrust SOI crossing in/out: heliocentric-expressed position+velocity continuous to f64 ε at both crossings; per-regime energy conserved |
| G-O4-SWAP | post-swap gravity == GM_moon/r²; facet classification uses Moon K/base; rendered sun direction continuous across the swap tick |
| G-O4-LOCK | O0 tidal-lock invariant re-asserted on the rendered Earth-impostor direction from a Moon-surface lattice point across a sampled month |
| G-O4-OFF | MULTI_BODY=false ⇒ everything (incl. memory/facet_count) byte-identical to post-O4a Earth-only |

Live: LEO → transfer (gear 3, a_C per D5) → SOI swap → lunar orbit → retro-burn descent → land →
walk/mine/place on Moon fids (edit overlay) → ascend → return → Earth re-entry. The full loop on
the remote bridge with telemetry.

## 3.7 O4 change map

| File | Change |
|---|---|
| `src/cosmos/facet_atlas.gd` | BODY_TABLE + fid_base/k_of/r_of/body_of_fid; warm_up multi-body append; facet_of_dir(body, d); spawn scan Earth-range; doc-comment widen on edit_key |
| `src/cosmos/cube_sphere.gd` | MULTI_BODY flag; warm_edge_tables for both Ks |
| `src/world/terrain_config.gd` | facet_profile dispatch; moon noises (SEED_MOON) in _ensure_noise; moon_profile_at_dir + crater kernel; moon biomes in resolve_cell/_biome |
| `src/world/block_catalog.gd` + materials/textures | regolith, basalt, anorthosite ids (data) |
| `src/world/tree_gen.gd` | zero density on moon biomes |
| `src/world/world_manager.gd` | dominant-body state; SOI monitor + swap orchestration; prepare_landing body-aware |
| `src/world/facet_far_ring.gd`, `facet_lod_*` | per-body fid range |
| `src/cosmos/cosmos_sky.gd` | dominant-body parameterisation (spin source, atmo ramp, Earth-impostor) |
| `src/cosmos/orbital_state.gd` | SOI re-expression (pure statics) |
| `src/tools/verify_multibody.gd` | NEW — the §3.6 suite incl. G-O4-EQ |

---

## 4. Staging + sequencing (what Opus builds, in order)

Each stage is independently gated, flag-defaulted-OFF, shippable (or shippable-dark):

| Stage | Content | Ships when | Size |
|---|---|---|---|
| **O1a** | CosmosGravity + consts; anchor-follow in flight; H_FARSWAP retire/impostor; observer-parallax sky | G-O1-FIELD, G-O1-ANCHOR, G-O1-OFF | ~1 agent-night |
| **O1b** | OrbitalState + ORBITAL mode + gear-2 + drag + handoffs + re-entry/prepare_landing + HUD | full §2.10 suite + the live orbit loop | ~2 nights |
| **O4a** | the fid-namespace refactor, **Earth-only** (MULTI_BODY absent/false); k_of/r_of dispatch plumbing | **G-O4-EQ green** — the safety net exists before anything else | ~1 night |
| **O3** | D1 resize (Earth K=50/R=6371) — now a BODY_TABLE row edit + regen + re-measure | existing FP suite at new R; heap A/B; parent §11 O3 gates | ~1 night + A/B |
| **O4b** | Moon body registered behind MULTI_BODY: atlas append, worldgen, materials, biomes — **dark** (unreachable in-game) | G-O4-MOONGEN/ATLAS2/KEY/OFF | ~1-2 nights |
| **O4c** | SOI patched-conic + dominant swap + gear-3 + Earth-in-moon-sky + lunar landing path | G-O4-SOI/SWAP/LOCK + the live round trip | ~1-2 nights |

Rationale: O1 first (you must orbit before the Moon is worth reaching — and H_FARSWAP is O4c's
precondition). **O4a immediately after O1** and **before O3**: the equivalence gate is cheapest
to trust while the engine is quiet, and it converts the resize from a const-hunt into data.
O4b/O4c split so the risky worldgen authoring (taste iteration with the user) never blocks the
mechanics, and MULTI_BODY can soak dark.

Honest total: **~6-9 agent-nights** plus user taste passes (Moon terrain look, D5 thrust). The
realistic first increment that delivers user-visible value: **O1a+O1b** — fly to space, orbit the
Earth you walked on, watch the sunrise sweep the facets, deorbit and land. That alone is a
milestone; everything after it is reaching the thing in the sky.

## 5. NEVER-OOM ledger (additions; every flag OFF by default, flipped at export after heap A/B)

| Item | Cost | Cap / lifetime |
|---|---|---|
| CosmosGravity / OrbitalState / frame algebra | O(bytes); zero per-frame alloc (DVecF64 24-B temps) | static kernels |
| ACTIVE orbital states | ~100 B each | ORBIT_ACTIVE_MAX = 8 (O1 uses 1) |
| RAILS elements | 56 B + header | counted; O1: player only |
| Home-body impostor (v1 sphere + albedo) | ≤ ~1 MB | 1, reused node |
| Moon atlas rows (O4b) | +0.72 MB static | one-shot at warm_up; MULTI_BODY=false ⇒ 0 |
| Moon noises + crater kernel | O(KB) + per-column memo (existing memo, existing lifetime) | frozen at warm_up |
| Moon far ring | ~⅓ Earth's (1176 facets) | exists only while dominant=moon **below H_FARSWAP** |
| Pool | unchanged budget | **exclusive to dominant body** (max-over-bodies, never sum) |
| HUD | 1 control | static |

## 6. Risk register

| # | Risk | Sev | Mitigation |
|---|---|---|---|
| 1 | Lunar landing outruns streaming (no drag cap) | H | §3.5: PREWARM_H 4096 for airless bodies + accept low-LOD under a non-braking lander; D-O4-5 |
| 2 | Namespace refactor silently perturbs Earth | H | G-O4-EQ (hash + sample pins + full suites, both flag states) lands FIRST as its own stage |
| 3 | fold-table warm-up missed for K_moon → worker first-touch race (the project's worst race class) | H | warm_edge_tables(K_earth)+(K_moon) in warm_up, gate-asserted built before setup returns |
| 4 | Handoff/spin-term sign errors (θ vs −θ, ω×r direction) | M | every map is a pure function with an exact-value gate (33.4 m/s eastward is a pinned number) |
| 5 | H_FARSWAP retire/rebuild hitch or flapping | M | hysteresis band; budgeted rebuild; veil v1; measured on the remote bridge |
| 6 | f32 jitter: far ring under a large anchor, impostors | M | anchor steps integer; impostors are camera-relative direction×clamp; G-O1-ANCHOR asserts relative invariance |
| 7 | Mode flapping at H_BLEND_HI / SOI | L | hysteresis bands both places (±32 / ±2%) |
| 8 | Moon worldgen taste misses (craters too busy/sparse) | L | O4b is dark; parameters are data; user taste pass before O4c exposes it |
| 9 | edit_key int64 overflow at future body counts | L | gate asserts round-trip at the max registered fid; contract caps registry growth |

## 7. Open decisions for the user

| # | Decision | Options | Recommendation |
|---|---|---|---|
| D-O4-1 | Moon terrain character | crater density/scale/maria fraction (taste) | author in O4b, screenshot pass before O4c |
| D-O4-2 | Home/Earth impostor v1 fidelity | shaded sphere + albedo tex / baked-atlas low-poly mesh | sphere v1, baked mesh v2 |
| D-O4-3 | First shippable increment | O1 alone as a milestone vs hold for O4 | **ship O1** (orbit+re-entry is standalone value) |
| D-O4-5 | Airless-body landing pacing | low-LOD acceptance / PREWARM_H 4096 / auto-retro assist | **PREWARM 4096 + low-LOD worst case** (no physics magic) |
| D5 (parent) | gear-3 a_C (Moon trip 0.5–3.3 h) | 0.2 / 0.5 / 2 m/s² | 0.2–0.5 (parent §6.3) — needed by O4c, not before |

(D1/D2/D3/D10 etc. are already user-locked in the parent ledger and consumed here as-is.)

## 8. What this deliberately does not do

No gear-3 before O4c, no grids (O2 owns SpaceGrid/RCS/match-velocity — OrbitalState is built to
be shared with it), no hyperbolic Kepler freeze (ACTIVE covers escape correctly), no Moon
atmosphere/weather, no lunar caves/ores v1 (the strata bones are shared so they slot in as data),
no barycentric refinement (O5), no portal implementation (PortalAnchor addressing compatibility
is inherited from the parent §7.4 — `(body-encoded fid, cell)` is already the O4a namespace).
