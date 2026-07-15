# COSMOS-ORBITAL-DESIGN — true orbits, the Moon, the Sun, and space voxel structures

Status: **RESEARCH + SPEC + ARCHITECTURE** (Fable, 2026-07-16). No implementation — build is
HELD until the on-planet mechanics (fixed-frame, seams, underground) ship. This document is the
decision basis the user signs off on (§10) and the phase plan future Opus teams execute (§11).

Related: docs/COSMOS-FIXED-FRAME-DESIGN.md (the absolute-frame keystone this design stands on),
docs/COSMOS-FACETED-PLANET-STUDY.md + docs/COSMOS-FACETED-IMPL.md (the faceted planet),
docs/COSMOS-FP-M2-DESIGN.md (LOD neighbours + load controller), memory `voxiverse-never-oom-web`,
`voxiverse-physics-scale` (dormant-by-default physics), `voxiverse-faceted-planet`.

---

## 0. Executive summary

The engine is closer to orbital mechanics than it looks. The just-shipped **fixed absolute frame**
(PlanetRoot pinned at identity, all geometry planet-absolute, the player carried by an ActiveFrame,
an integer re-anchor for large coordinates — COSMOS-FIXED-FRAME-DESIGN §2/§3) is exactly the
substrate a multi-body cosmos needs; `CubeSphere` already carries a real-body table
(`BODY_R`: earth 6371, moon 1737 — cube_sphere.gd:232-243) and a 1/r² gravity parameterization
(`gm_for`, GM = g₀R² — cube_sphere.gd:287-293); `FacetAtlas.facet_of_dir` + `OFFSURFACE_Y`
(facet_atlas.gd:639-644, cube_sphere.gd:131) explicitly reserve the off-facet flight slot ("FP-M3").
This design fills that slot and extends it to a Sun–Earth–Moon system.

**The recommended architecture in five sentences:**

1. **Two locked scale rules, one free parameter**: 1 unit = 1 block = 1 m; every *celestial*
   length is real km ÷ 1000 (Earth R 6371, Moon R 1737, Earth–Moon 384,400, Earth–Sun
   149,600,000); the **day is 20 minutes** (time runs 72× real); the *near field* (terrain
   relief, atmosphere = 384 blocks) stays Minecraft-scale and is openly exaggerated. Celestial
   **masses (GM) are the free parameter**, derived from Kepler so Newtonian gravity holds
   exactly at those two scales (GM_game = GM_real × 5.184×10⁻⁶, §3.3) — every period is
   real ÷ 72, every orbital speed real × 0.072, every ratio exactly real: low orbit 548 m/s /
   79 s, escape 805 m/s, the month 9.1 h (27.3 game days), the year 5.07 real days (365 game
   days), and the Sun and Moon subtend their real 0.5°. Distances are **intentionally vast**:
   first reach of the Moon is an hours-scale expedition, later amortized by the (future) portal
   network — this design stays portal-compatible without implementing portals (§7.4).
2. **Frames**: the scene/physics frame is always the **dominant body's body-fixed frame** with the
   voxel planet pinned at identity — the planet **never moves or spins in-scene**; spin and orbits
   are expressed by moving the *sky* (sun light, star field, other-body impostors), extending the
   fixed-frame keystone ("never re-place voxel geometry") to the whole cosmos.
3. **Orbital state is f64 script math** (the shipped DVec3 discipline), integrated in the dominant
   body's *inertial* frame: on-rails Kepler ephemeris for celestial bodies and dormant structures,
   a symplectic integrator for the player + the few awake structures, patched-conic SOI handoffs —
   the KSP model, not n-body.
4. **Space voxel structures are "grids"** (Space Engineers' concept) that reuse the facet machinery
   verbatim: a grid is a small private lattice + one rigid transform + an orbital state; boarding
   one re-parents the player's ActiveFrame to it (Star Citizen's local physics grid — which is
   literally our shipped ActiveFrame pattern), so interior collision is the same analytic
   per-axis voxel test the planet already uses.
5. **Everything is flag-gated, phased O0→O5** (sky/day-night first — shippable now at R = 3072;
   orbit second; grids third; planet resize + Moon fourth), each phase headless-gated and
   NEVER-OOM-ledgered, following the sed-at-export deploy pattern.

The one decision that reshapes the world is **D1: resize the Earth from R = 3072 to R = 6371**
(K 24→50, facet size preserved at ~200 blocks). Recommended — but it is a taste + budget call the
user owns, and the whole orbital layer is deliberately scale-agnostic so it can land before or
after (§3.2, §10). The 20-minute day, the 72× clock, and the vast-distance/portal two-tier travel
model are **user-locked inputs**, recorded as such in the ledger.

## 1. Ground truth — what the engine is today (investigated)

- **The planet**: a piecewise-flat faceted cube-sphere, `K = 24`, `R_BLOCKS = 3072`
  (facet_atlas.gd:12-13), 6K² = 3456 facets of ~200-block edge meeting at ~3.75° dihedral ridges
  (90°/K). K locked by user taste-test at FP0; **R tracks K only to hold facet size ~200** — the
  atlas math is scale-invariant (facet_atlas.gd:14). Facets are planarized, seams welded, ridge
  planes are per-facet data (facet_atlas.gd:199-240).
- **The frame model (FP_FIXED_FRAME, shipped)**: PlanetRoot @ identity forever; every FacetSlot at
  its true absolute `T_fid`; the player/GroundCollider/debris ride an `ActiveFrame @ T_active`
  (world_manager.gd:204-221); crossings are O(1) bookkeeping; a floating-origin **anchor shift**
  exists (`REANCHOR_TRIGGER_BLOCKS = 8192`, cube_sphere.gd:159-165) — integer world shift of
  PlanetRoot + all absolute slots + ActiveFrame. Conversions route through a **FrameAdapter**
  abstraction (player.gd:84-88, world/frame_adapter.gd) — built, per the fixed-frame decision 3,
  explicitly to "ready the multi-body cosmos".
- **Gravity**: player gravity is analytic lattice −Y (`velocity.y -= g·δ`, player.gd:380) with a
  per-body feel hook already in place (`gravity *= g_body/9.81`, player.gd:90-99); debris fall
  along **per-facet Area3D gravity volumes** bounded to the live pool (world_manager.gd:48-64,
  408-437). `CubeSphere.SURFACE_GRAVITY = 9.81` and `gm_for(body) = g₀R²` (1/r² above datum) are
  already defined (cube_sphere.gd:285-293).
- **Off-surface today**: fly mode is a lattice-frame noclip at 16-32 m/s (player.gd:319-331);
  above `OFFSURFACE_Y = 256` the pool freezes spawns, and `facet_of_dir` classifies which facet a
  radial direction lands in — the comment reserves "full off-facet gravity/locomotion is FP-M3"
  (facet_atlas.gd:633-644). Camera far is 9000 in faceted mode (facet_far_ring.gd:22).
- **Lighting**: flat ambient only — *no sun, no shadows, no day-night* (main.gd:147-154). The far
  ring wraps the planet (~2R) as one merged absolute-coords mesh.
- **Precision regime**: GDScript floats are f64, `Vector3` is f32; all position-critical cosmos
  math already runs on f64 scalars/DVec3 (cube_sphere.gd:7-11); the scene's f32 render coords are
  bounded by the anchor shift. The shipped game validated ~33k-block f32 coordinates live.
- **Physics philosophy**: analytic, not trimesh; dormant-by-default (memory
  `voxiverse-physics-scale`); NEVER-OOM outranks visuals (memory `voxiverse-never-oom-web`).
- **Worldgen vertical envelope**: y ∈ [−512, 1535] (facet_atlas.gd:59); sea level 0; terrain
  relief O(100) blocks.

**What does NOT exist**: any notion of time-of-day, a second body, a sun, off-planet coordinates,
or player physics outside the active facet's lattice. That is this design's scope.

## 2. SOTA survey — how shipped games solve surface-to-orbit scale

Studied for: (a) precision across scales, (b) orbit simulation fidelity, (c) local-frame play
inside moving vessels, (d) fit with a faceted-voxel engine on f32 web Godot.

### 2.1 Kerbal Space Program — the reference architecture for our problem

- **Scaled-down system, adjusted GM**: Kerbin R = 600 km (Earth ÷ ~10.6) with 9.81 surface
  gravity → LEO ≈ 2.2 km/s and ~30-min orbits. Playability comes from *deriving* speeds from
  shrunken parameters with Newton intact, never from faking physics. **We adopt this wholesale**
  (§3): our ÷1000 lengths + 72× clock + Kepler-derived GM give 548 m/s / 79-s low orbits.
- **On-rails patched conics**: planets/moons and any non-accelerating vessel follow closed-form
  Kepler orbits (elements + time); only the active, thrusting vessel integrates numerically;
  sphere-of-influence (SOI) boundaries switch the dominant attractor. Buys determinism, zero
  drift, O(1) cost per dormant object, trivially serializable state. Compromise: no Lagrange
  points/perturbations — irrelevant at our fidelity target. **Adopted** (§5).
- **Floating origin + Krakensbane**: the universe is rebased so the active vessel stays near the
  origin (position rebase above ~6 km altitude, *velocity* rebase above 750 m/s — subtracting the
  reference velocity from everything to keep f32 physics numbers small), with f64 for the orbital
  bookkeeping. Fixes the "Deep-Space Kraken" (physics jitter tearing craft apart at lunar
  distance). Our analog: f64 script state + the shipped integer anchor shift; we need the
  *velocity* half only inside grid frames (§7.3).
- **Scaled space**: nearby objects render 1:1; distant planets render as a ~1/6000-scale replica
  composited behind (preserves angular size with tiny coordinates). **Adopted** as the sky layer
  (§4.4) — at ÷1000 uniform scale our impostors automatically subtend real angular sizes.
- Fit: excellent. KSP is Unity/PhysX f32 + f64 bookkeeping — the same split as Godot-f32 +
  GDScript-f64.

### 2.2 Outer Wilds — the miniature fully-simulated system

A solar system a few km across, every body a Unity rigidbody with custom inverse-square gravity,
everything genuinely integrated (which is why the whole sim only has to stay stable for the 22-min
loop), and the coordinate system kept sane by **recentring the universe on the player every frame**
(the player is the origin; planets move around them). Buys: emergent physics everywhere (walk on
anything, quantum moon tricks). Compromises: no dormancy (everything always simulates), scale
capped at km, drift accepted by design. Fit: **rejected as the core model** — incompatible with a
static voxel planet (geometry must never be re-placed per frame — the exact 200-772 ms lesson the
fixed frame just fixed), with dormant-by-default physics, and with 1.5×10⁸-unit distances. But its
*insight* — pick the frame that keeps the expensive thing still — survives inverted: Outer Wilds
keeps the *player* still; we keep the *planet* still (§4.1), which is the right choice when the
planet is a million voxels and the player is one capsule.

### 2.3 Star Citizen — 64-bit world + local physics grids (zones)

CIG refactored CryEngine positioning/physics to 64-bit world coordinates while **rendering stays
32-bit** (camera-relative), and runs a **zone system**: each ship/station carries a local physics
grid — objects inside it simulate in the vessel's local frame (so you walk inside an accelerating
ship trivially), with nested frames for ships-in-ships on rotating planets. Buys: seamless
planet-to-space and interiors-in-motion. Compromise: engine-level surgery, heavy. Fit: the
**zone/local-grid concept is adopted** for structure interiors (§7.3) — and it is literally the
shipped ActiveFrame pattern (player local = lattice, global = absolute) applied to a grid instead
of a facet. The 64-bit-engine half is **rejected**: Godot 4.4 `precision=double` builds are
untested with godot_voxel, unsupported on our locked web toolchain, and unnecessary given the
f64-script + f32-scene split already proven in production.

### 2.4 Elite Dangerous — 1:1 scale via 64-bit + hierarchical generation

Stellar Forge generates a 1:1 Milky Way; the engine needed mm precision on planets whose
coordinates span tens of billions of mm, solved with custom 64-bit and dual-float (two-f32
emulated) math libraries even GPU-side, and top-down hierarchical generation (galaxy → system →
planet → detail). Supercruise is a per-system velocity regime with log-throttled speeds. Buys:
true scale. Compromise: an engine built around it from day one; gameplay distances mostly
uninteresting transit. Fit: scale ambition **rejected** (we are deliberately ÷1000);
**log-throttled cruise** adopted for the interplanetary gear (§6.3); hierarchical determinism we
already have (worldgen is a pure function of (seed, fid, cell)).

### 2.5 Space Engineers — voxel grids, no orbits

Voxel planets/asteroids are static (nothing orbits); ships/stations are **grids** — private block
lattices with their own frame — and gravity is either planetary (radial, altitude-falloff) or
artificial (gravity generators affecting only... what they affect). Buys: the definitive
build-a-ship-and-walk-inside-it model on voxels. Compromise: a dead sky — stationary celestials,
no orbital mechanics at all. Fit: the **grid concept is adopted** (§7) — it is the natural voxel
unit of "structure" and maps 1:1 onto our lattice+transform+overlay machinery; the static-sky half
is exactly what the user is asking us to surpass.

### 2.6 No Man's Sky / others

NMS: planets don't truly orbit (frozen system layout), planet-to-space is a streaming LOD +
camera-relative transition, physics is gameplay-first. Confirms the industry default we are
rejecting (static skies), and the useful pattern we already share (aggressive LOD + streaming by
radial altitude). Minecraft-scale mods (Advanced Rocketry etc.) treat space as separate
dimensions/scenes with menu transitions — the discontinuity the user's vision explicitly excludes.

### 2.7 Synthesis — what we take

| Technique | Source | Verdict |
|---|---|---|
| Shrunken radii + real surface g ⇒ derived playable speeds | KSP | **Adopt** (÷1000, §3) |
| On-rails Kepler + patched conics + SOI; integrate only the active few | KSP | **Adopt** (§5) |
| f64 bookkeeping + f32 scene + floating origin/rebase | KSP / SC / ED | **Adopt** (already shipped; extend §4.3) |
| Scaled-space sky impostors preserving angular size | KSP | **Adopt** (§4.4) |
| Keep-the-expensive-thing-still frame choice | Outer Wilds (inverted) | **Adopt** — planet-fixed scene frame (§4.1) |
| Local physics grids / zones for interiors | Star Citizen | **Adopt** — ActiveFrame re-parent (§7.3) |
| Voxel grids as the structure unit | Space Engineers | **Adopt** (§7.1) |
| Full n-body / everything-rigidbody | Outer Wilds | Reject (dormancy, scale, static planet) |
| Engine-wide 64-bit rebuild | SC / ED | Reject (web toolchain risk, unnecessary) |
| 1:1 scale | ED | Reject (locked ÷1000) |
| Static non-orbiting sky | SE / NMS | Reject (the point of this feature) |

Sources: [KSP precision discussion (HN)](https://news.ycombinator.com/item?id=26938812),
[KSP wiki/dev notes on Krakensbane + scaled space], [Star Citizen 64-bit — GamersNexus interview
with Sean Tracy](https://gamersnexus.net/gg/2622-star-citizen-sean-tracy-64bit-engine-tech-edge-blending),
[Star Engine wiki](https://starcitizen.tools/Star_Engine),
[Elite Dangerous Stellar Forge — 80.lv](https://80.lv/articles/generating-the-universe-in-elite-dangerous),
[space.com Stellar Forge interview](https://www.space.com/31366-elite-dangerous-stellar-forge-interview.html),
[Space Engineers gravity wiki](https://spaceengineers.wiki.gg/wiki/Gravity),
[SE voxels wiki](https://spaceengineers.wiki.gg/wiki/Voxels),
[Outer Wilds physics analysis (video)](https://www.youtube.com/watch?v=dpKUoWgRBSU),
[Road to the IGF — Alex Beachum](https://www.gamedeveloper.com/design/road-to-the-igf-alex-beachum-s-i-outer-wilds-i-),
[Noclip: The Making of Outer Wilds](https://www.youtube.com/watch?v=LbY0mBXKKT0).

## 3. The scale model — one rule, everything derived

### 3.1 The rule

**1 unit = 1 block = 1 m. Celestial lengths are real ÷ 1000 (km → blocks). Time runs 72× real
(one Earth rotation = 20 minutes — USER-LOCKED). Celestial GM values are the free parameter that
makes Newtonian gravity hold at those two scales (§3.3). Near-field relief AND near-field feel
gravity are Minecraft-scale (exaggerated, playable) and honestly so.**

Those rules fix every number in the system — no per-quantity tuning, and every future body is two
table entries (R, GM):

| Quantity | Real | Game (÷1000) |
|---|---|---|
| Earth radius | 6371 km | **6371 blocks** |
| Moon radius | 1737 km | **1737 blocks** |
| Sun radius | 696,000 km | **696,000 blocks** (never voxelized) |
| Earth–Moon distance | 384,400 km | **384,400 blocks** |
| Earth–Sun distance | 149.6M km | **149,600,000 blocks** |
| Moon SOI | 66,100 km | 66,100 blocks (falls out of GM ratios) |
| Geostationary radius | 42,164 km | ~42,150 blocks (falls out of the §3.3 day + GM) |
| Sun/Moon angular diameter | 0.53° / 0.52° | **0.53° / 0.52°** (÷1000 is angle-preserving) |
| Atmosphere thickness | ~100 km | **384 blocks** (near-field, NOT ÷1000 — locked by user) |
| Terrain relief | Everest 8.8 km | O(100) blocks (near-field, ~11× the ÷1000 value) |

The near-field exception is principled: everything a walking player measures with their body
(hills, caves, trees, atmosphere as a gameplay ceiling) is at human/Minecraft scale; everything a
*navigator* measures (radii, distances, periods, speeds) is at strict ÷1000. The seam between the
two regimes is the planet's *surface shell* — a few hundred blocks of relief on a 6371-block ball
(3% of R; visible as slightly-heroic mountains from orbit, which reads great, not wrong).

### 3.2 Reconciling R_BLOCKS = 3072 (the flagged conflict) — D1

The shipped planet is R = 3072 **only because R tracks K = 24 to hold the taste-locked ~200-block
facet** (facet_atlas.gd:12-14); the atlas math is scale-invariant, and `BODY_R` already declares
earth = 6371 (cube_sphere.gd:240). Two coherent options:

- **(a) RESIZE — recommended**: Earth becomes R = 6371 with **K = 50** (facet edge = (π/2·6371)/50
  ≈ 200.1 blocks — the taste lock preserved *exactly*; ridge dihedral softens 3.75° → 1.8°).
  15,000 facets. Costs: atlas grows ~2.1 → ~9.2 MB (616 B/facet — enters the NEVER-OOM ledger,
  §9), far-ring mesh ~4.3× facets (re-measure; still one merged mesh), spawn-scan startup ~4.3×,
  full world regeneration (free **now**, expensive after persistent content ships — this is the
  strongest argument for deciding early), and the `edit_key` doc comment's "fid < 4096" widens
  (the packing itself is multiplicative and holds to fid 15,000 with int64 headroom —
  facet_atlas.gd:53-67). Buys: every celestial quantity reads as real-value÷1000 forever; HUD,
  ephemeris, and the body table need zero special cases; walking around the world takes ~2 h
  (40,030-block circumference at 5.5 m/s) instead of ~1 h.
- **(b) RATIO-SCALE around 3072**: keep the planet; scale the *system* by real ratios instead of
  absolute values (Moon R = 0.2727·R_E = 838, Earth–Moon = 60.34·R_E = 185,300, Earth–Sun =
  23,481·R_E = 72.1M). Preserves all angular sizes and all dynamics *shapes*; zero regeneration.
  Costs: the "strict 1:1000" numbers the user locked are violated (everything is ~0.482× them);
  every published number needs the caveat forever.

Recommendation: **(a)**, decided and executed as its own phase (O3) *before* the Moon phase but
after orbit mechanics prove out at 3072 — the orbital layer reads `R_BLOCKS`/`BODY_R` as data and
is identical under either choice (§11). If the user prefers (b), the 20-min day stays locked, so
§3.3's numbers rescale as lengths ×0.482 ⇒ speeds ×0.482, GM ×0.112 (periods unchanged); nothing
architectural changes.

### 3.3 The time + mass model (USER-LOCKED) — 20-minute day, GM as the free parameter

The user locked: **one Earth rotation = 20 minutes real time** ⇒ time compression **72×**
(86,400 s / 1200 s), applied to ALL time-related values. 1:1000 lengths with 72× time cannot keep
real masses (true-scaled periods would come out √-wrong) — per the user's priority rule, **the
20-min day wins and mass/GM is the free parameter** adjusted so orbits + the day + Newtonian
gravity stay mutually consistent. Kepler (GM = 4π²a³/T²) with a = real÷1000 and T = real÷72
gives the unique scaling law:

> **GM_game = GM_real × s_L³/s_T² = GM_real × (10⁻³)³ × 72² = GM_real × 5.184×10⁻⁶**

with the clean corollaries: every **period = real ÷ 72**, every **orbital speed = real × 0.072**,
every **acceleration = real × 5.184**, and every dimensionless ratio (geo radius / Moon distance,
SOI fractions, orbits-per-day, angular sizes, eclipse geometry) **exactly real**. The physics
engine needs NO dual clock: ephemeris time = real seconds; the scaled GM values alone produce the
72× sky, so a thrown wrench and the Moon obey the same clock and Newton holds everywhere.

**The toy solar system (canonical parameters)** — this table supersedes the shipped
`gm_for() = g₀R²` rule (cube_sphere.gd:291-293), which stays valid only as the near-field feel
anchor (§3.3.1):

| Body | GM_real (m³/s²) | **GM_game** | Datum g = GM/R² | Near-field feel g (§3.3.1) |
|---|---|---|---|---|
| Earth (R 6371) | 3.986×10¹⁴ | **2.066×10⁹** | 50.9 m/s² | **22** (shipped, unchanged) |
| Moon (R 1737) | 4.905×10¹² | **2.543×10⁷** | 8.43 m/s² | 3.6 (= 22 × real ratio 0.165) |
| Sun (R 696,000) | 1.327×10²⁰ | **6.880×10¹⁴** | 1421 m/s² | n/a (unreachable, D8) |

**Derived speeds & periods (Earth system):**

| Quantity | Value | Note |
|---|---|---|
| Walk / run / fly (today) | 5.5 / 9.5 / 16-32 m/s | player.gd:21-24 (real-time, untouched) |
| Circular orbit at datum | **570 m/s** | √(GM/R) |
| Low orbit (h = 500, r = 6871) | **548 m/s, period 78.7 s** | ~15 orbits per 20-min day — the real ISS ratio, preserved |
| Escape at datum | **805 m/s** | lands exactly in the user's "100s-1000s m/s" band |
| Equatorial spin speed | 33.4 m/s | free eastward-launch Δv (ω = 5.25×10⁻³ rad/s) |
| Geostationary | r ≈ 42,150, T = 1197 s | real÷1000, ratio-exact |
| Moon around Earth | 73.4 m/s, **T = 9.11 h = 27.3 game days** | tidally locked ⇒ Moon spin = 9.11 h |
| Moon surface orbit / escape | 121 / 171 m/s | from GM_moon |
| Hohmann LEO→Moon | **Δv ≈ 220 m/s, coast ≈ 3.3 h** | the first-reach expedition (§6.3) |
| Earth around Sun | **2.14 km/s, year = 121.75 h ≈ 5.07 real days = 365 game days** | |

The user's speed brief ("walk → 100s-1000s m/s cross-planet → 100s of km/s interstellar") maps
onto these numbers *better* than the earlier draft: orbital/escape play genuinely occupies
100s-of-m/s; Earth's solar orbit is km/s; 100s of km/s is the interstellar tier (nearest star
4×10¹³ blocks — f64-fine, content not designed here; even 300 km/s means a 4.2-real-year trip,
which is what portals are for, §7.4).

#### 3.3.1 Reconciling far-field GM with near-field playable gravity

The Kepler-derived datum gravity (50.9 m/s² at Earth's surface) is 2.3× the shipped playable
feel gravity (`gravity := 22.0`, player.gd:25) — and per the multi-scale rule they are
**deliberately decoupled**, exactly like terrain relief vs ÷1000 relief:

- **Lattice regime** (walking/jumping, h < H_BLEND_LO): |g| = the shipped feel value 22,
  untouched — jump feel outranks celestial consistency where players live. Per-body feel scales
  by the *real* gravity ratio (= the GM-implied datum ratio, preserved by the scaling law):
  Moon feel g = 22 × 0.165 ≈ 3.6.
- **Blend band** (H_BLEND_LO..H_BLEND_HI ≈ 128..512): direction slerps facet-normal → radial
  (§5.1) and **magnitude ramps 22 → GM/(R+h)²** (= 43.6 at h = 512) — a monotone designed ramp;
  only flyers and thrown debris occupy it. Disclosed consequence: a suborbital hop feels
  slightly heavier aloft. 
- **Orbital regime** (h > H_BLEND_HI): pure GM/r². All the §3.3 numbers live here.

Rejected alternatives: raising walk gravity to the 50.9 datum (breaks the entire shipped game
feel), or shrinking GM until the datum equals 22 (then the 20-min day and the 9.1-h month break —
the priority rule says the day wins).

### 3.4 The calendar, summarized

| Clock | Real | Game (÷72) | In game days |
|---|---|---|---|
| Day | 24 h | **20 min** (sidereal 19.9 min) | 1 |
| Month / Moon spin (locked) | 27.32 d | **9.11 h** | 27.3 |
| Year | 365.25 d | **121.75 h ≈ 5.07 real days** | 365 |
| Low orbit | 92 min | **79 s** | ~1/15 |

The Moon visibly waxes/wanes across a session; a year is a real-world work-week — seasons become
experienceable. An optional global `TIME_WARP` multiplier (sleeping through nights) composes
cleanly on top of the ephemeris (§4.2) — but note it scales the *sky* only unless GM is co-scaled,
so v1 ships without it.

## 4. Frame & precision architecture (the make-or-break)

### 4.1 The prime invariant: voxel geometry never moves

The crossing-hitch investigation proved that transforming a loaded voxel tree re-places every mesh
block synchronously (200-772 ms; memory `voxiverse-crossing-phys-spike`), and the fixed frame
fixed it by pinning PlanetRoot at identity forever. Planetary *spin* and *orbit* would be that
same catastrophe applied every frame. Therefore:

**The scene frame is the dominant body's BODY-FIXED frame.** The voxel planet is pinned at
identity and neither orbits nor spins *in-scene* — instead the rest of the universe is expressed
relative to it, which is O(sky nodes) per frame:

- **Spin** = the sun direction, star field, and other-body impostors rotate (computed from the
  ephemeris, §4.2, and written as a handful of node transforms — one DirectionalLight rotation,
  one sky basis, ≤ 2 impostor transforms).
- **Orbit** = the same: Earth's motion around the Sun only changes where the Sun (light +
  impostor) appears from Earth's frame.
- Standing on the ground you rotate with the planet for free (you are parented in the body-fixed
  frame); the day-night cycle is the light sweeping around you.

This is Outer Wilds' trick with the roles swapped (they pin the player and move planets; we pin
the planet and move the sky) and Space Engineers' static-voxel constraint honored while the sky
still *behaves* Keplerian. Nothing about the shipped facet/pool/LOD/far-ring machinery changes.

### 4.2 CosmosEphemeris — the pure f64 kernel (new, house-style)

A static, pure-f64, engine-free kernel beside `CubeSphere` (same discipline: DVec3, no engine
types, deterministic function of its arguments — worker-safe, gate-friendly):

- `CosmosClock`: `t` = f64 seconds since world epoch, advanced by real delta × `TIME_WARP` (=1).
  The ONLY mutable state in the celestial layer; savegame = one float.
- Body table (extends `BODY_R`/`gm_for`): per body — GM, parent body, circular orbital elements
  v1 (radius a, phase M₀; eccentricity/inclination = 0 in v1, the slots exist), spin rate ω,
  spin phase, axial tilt (v1: 0; the slot exists for seasons later).
- `body_pos_parent(body, t) → DVec3` (Kepler, closed form — trivial for circular),
  `body_pos_helio(body, t)` (chain to parent), `spin_angle(body, t)`,
  `dir_to(body_a, body_b, t)` (e.g. sun direction), all f64.
- **Tidal lock** is one line: `spin_angle(moon, t) = orbit_angle(moon, t) + π` — the same face
  Earth-ward by construction, asserted by a headless gate (sub-Earth longitude constant over a
  sampled month).
- **Frame transforms**: `T_bodyfixed_from_inertial(body, t)` = rotation by −spin_angle about the
  body's axis. The scene frame is body-fixed(dominant); the *integration* frame is
  body-centered-inertial (§4.3). Both are pure functions of `t`.

Eclipses fall out for free: with real angular sizes (0.53° vs 0.52°) the Moon genuinely occults
the Sun on node crossings — worth a deliberate gate + a screenshot, not extra machinery.

### 4.3 Precision strategy (f64 where it counts, f32 where it's bounded)

| Layer | Representation | Bound |
|---|---|---|
| Celestial positions, orbital states, clock | f64 scalars / DVec3 (script) | Earth–Sun 1.5×10⁸ → f64 ulp ~3×10⁻⁸ m. Exact for all purposes |
| Player/structure orbital state | f64 [pos, vel] in dominant-body inertial frame | ≤ SOI radius (9.3×10⁵ for Earth) → ulp ~10⁻¹⁰ m |
| Scene (render + physics server) | f32, **anchor-shifted** | coords kept ≤ ~8k by the shipped re-anchor; ulp ≤ 1 mm |
| Sky impostors | f32 at clamped distance ≤ 8000 | §4.4 |

The **anchor** generalizes the shipped `REANCHOR_TRIGGER_BLOCKS` machinery (cube_sphere.gd:159-165):
one integer f64 offset `A` subtracted from every absolute position before f32 conversion. On the
surface A ≈ 0 (today's behavior, byte-identical); in orbit/space A follows the player in integer
steps (PlanetRoot slides away — and beyond ~10-15k altitude the live pool is already frozen/
retired anyway, so the shift re-places at most the far ring + impostors, not live terrain).
**Velocity rebase (Krakensbane's second half) is NOT needed** in planet frames — our physics
server only ever simulates near-field objects whose *relative* speeds are small; the 6-km/s cruise
regime runs with collision off (§6.3) and grid-interior play subtracts the grid's velocity by
construction (§7.3). Godot `precision=double` is rejected (§2.3, D9).

Rotating-frame honesty: play on the ground happens in a rotating frame but ignores centrifugal/
Coriolis — with the 20-min day, ω = 5.25×10⁻³ rad/s → centrifugal ≤ 0.18 m/s² (0.8% of the feel
g = 22) and Coriolis at sprint speed ≤ 0.10 m/s² (0.45%). Imperceptible; **disclosed as toy
physics** (same class as per-facet flat seas). The *orbital* integrator runs in the inertial
frame, so orbits are exact; the one place the spin genuinely enters gameplay is the
**mode-transition velocity handoff** (§6.2): v_inertial = v_bodyfixed + ω×r (33 m/s at the
equator — you launch eastward for free Δv, a real and delightful consequence worth ~4% of orbital
velocity).

### 4.4 The sky layer (scaled space, ÷1000 edition)

Distant bodies render as **impostors**: direction preserved, distance clamped to
`D_SKY = 8000` (inside the shipped camera far 9000 — facet_far_ring.gd:22), radius scaled by
`D_SKY / d_true` — angular size exact, coordinates tiny, zero far-plane surgery.

- **Sun**: an emissive **smooth SphereMesh** (explicitly non-voxel, per the user's spec) +
  bloom-friendly material, plus THE `DirectionalLight3D` aligned to −sun_dir. It is an
  environmental object, never a destination (D8). Shadows stay OFF by default on web (flag;
  worst-frame budget owns this).
- **Moon (from Earth)** / **Earth (from Moon)**: v1 a shaded sphere impostor with a baked albedo
  texture; v2 a low-poly mesh baked from the body's own facet atlas (the far-ring builder already
  produces exactly this geometry — reuse). Phase (lit fraction) is automatic: the impostor is lit
  by the same DirectionalLight.
- **Stars**: a static skybox rotated by −spin_angle (one basis write/frame). Night = ambient
  floor (today's ambient light becomes the night value; main.gd:149-154).
- Swap rule: when the player enters a body's near zone (§5.3) the impostor is replaced by the real
  faceted world and vice versa — the impostor is the LOD∞ tier of the planet.

## 5. Gravity + orbit propagation

### 5.1 The gravity field (reconciling facets with spheres)

Three altitude regimes over any body, blended, all reading `gm_for`:

1. **Surface (lattice) regime** — h below `H_BLEND_LO` (≈ 128 above the facet plane): gravity is
   the facet's −Y exactly as shipped (analytic player, per-facet Area3D debris) at the shipped
   **feel magnitude 22** (deliberately decoupled from the 50.9 Kepler datum — §3.3.1). Deviation
   from true radial is ≤ ~2° mid-facet (≤ dihedral/2) — the shipped, accepted approximation.
2. **Blend band** — `H_BLEND_LO..H_BLEND_HI` (≈ 128..512): direction slerps facet-normal → radial
   AND magnitude ramps feel-22 → GM/(R+h)² (43.6 at h = 512) — the near-field/far-field gravity
   seam of §3.3.1. Only flying players and thrown debris ever occupy it.
3. **Orbital regime** — above `H_BLEND_HI` ≈ 512 (> the 384 atmosphere, > `OFFSURFACE_Y` = 256’s
   pool freeze): pure radial GM/r² toward the body centre (Kepler-derived GM, §3.3), integrated
   in the inertial frame.

The faceted polyhedron vs the gravity sphere: the polyhedron's surface deviates from the R-sphere
by at most the planarization sag (≤ ~3 blocks at K = 24, less at K = 50) — the sphere is the
gravity/altitude datum everywhere and nothing measurable disagrees.

### 5.2 Propagation (D3): patched conics + a symplectic integrator for the few

- **Celestial bodies**: pure on-rails ephemeris (§4.2). Never integrated. Deterministic forever.
- **Dormant structures & debris in space**: **Kepler elements** (a, e, i, Ω, ω, M₀ + epoch) —
  closed-form position on demand, zero per-tick cost, ~48 bytes each. This is the
  dormant-by-default physics rule (memory `voxiverse-physics-scale`) applied to orbits.
- **Active entities** (the player + awake structures, hard cap `ORBIT_ACTIVE_MAX ≈ 8`):
  **semi-implicit (symplectic) Euler** in f64 at the physics tick, dominant-body gravity only.
  Symplectic ⇒ bounded energy error (no secular spiral-in/out), which is the property that matters
  for "my station is still where I parked it"; at 60 Hz on a 79-s low orbit the per-orbit phase
  error is negligible for gameplay (and coasting entities freeze to exact Kepler anyway). RK4 is rejected (non-symplectic drift, 4× cost, no gameplay gain);
  full n-body is rejected (nothing at our fidelity target needs it, it breaks closed-form
  dormancy, and it makes saves/multiplayer nondeterministic).
- **Freeze rule**: an active entity with no thrust and no imminent collision converts to Kepler
  elements (exact at conversion); any disturbance promotes it back. Player included (coasting =
  on-rails = perfectly stable orbits, KSP-style).
- **SOI (patched conics)**: dominant body = deepest sphere-of-influence containing the entity
  (Earth SOI within the Sun's, Moon's 66,100-block SOI within Earth's). Crossing an SOI re-expresses
  [pos, vel] relative to the new body via ephemeris deltas (exact f64) — for the *player* this
  coincides with the dominant-frame/scene swap (§5.3).

### 5.3 The three big handoffs

1. **Surface ↔ orbital mode** (same body): §6.2. No scene swap — the scene frame is already the
   body-fixed frame; only the player's state representation changes (lattice ↔ inertial f64) and
   the pool warms/freezes (the shipped OFFSURFACE machinery + `facet_of_dir` for re-entry
   targeting — facet_atlas.gd:639-644).
2. **Re-entry**: descending through `H_BLEND_HI`, `facet_of_dir(p̂)` designates the target facet;
   the pool pre-warms it during the fall (the StreamLoadController's commit band, generalized:
   descent time from 512 at drag-limited speed is the politeness window); at `H_BLEND_LO` the
   player converts to lattice state on that facet (the crossing algebra, one `world_to_lattice64`).
   **Atmosphere drag (D10)** is load-bearing here: exponential drag below y = 384 caps terminal
   descent at a streaming-survivable speed (~50-60 m/s — tuned WITH the controller gate) and makes
   "orbit or fall back" a real mechanic (periapsis inside the atmosphere decays the orbit).
3. **Dominant-body swap** (Earth ↔ Moon SOI): the scene rebases to the new body's fixed frame —
   old body's near-field unloads to impostor, new body's atlas/pool/far-ring load. This is a
   seconds-scale, minutes-apart transition (a "system crossing"); it may show a brief loading veil
   in v1 (measured, then optimized — the atlas `warm_up` cost at K = 14 is small; Earth K = 50 is
   the one to measure).

## 6. The player in space

### 6.1 Modes (extending the shipped state machine, not replacing it)

| Mode | State representation | Physics | Exists today? |
|---|---|---|---|
| SURFACE | lattice Vector3 under ActiveFrame | analytic walk/jump (unchanged) | yes |
| FLY | lattice, noclip 16-32 m/s | unchanged | yes (player.gd:319-331) |
| **ORBITAL** | f64 [pos, vel] body-centered-inertial | symplectic + thrust + drag; capsule collision vs grids only | new |
| **GRID** | lattice Vector3 under a grid's frame | analytic 6-DOF vs grid voxels (§7.3) | new |

Transitions: FLY→ORBITAL on climbing through `H_BLEND_HI` (or explicit key); ORBITAL→re-entry per
§5.3; ORBITAL↔GRID by boarding (§7.3). SURFACE/FLY are untouched below the blend band — the
entire shipped game is the SURFACE mode of one body.

### 6.2 Orbital flight mode (the user's item 2) — three gears

- **Gear 1 — JET** (shipped fly): 16-32 m/s, lattice frame, for terrain-scale flight.
- **Gear 2 — ORBITAL THRUST**: continuous thrust `a_T ≈ 25 m/s²` (0 → low orbit 548 m/s in
  ~22 s; 0 → escape 805 m/s in ~32 s) along the wish vector, integrated in the inertial frame.
  This is the workhorse: launch, circularize, deorbit, rendezvous. Entering from FLY performs the
  velocity handoff `v_inertial = v_lattice→absolute + ω×r` (§4.3) — asserted continuous by the
  gate.
- **Gear 3 — TRANSFER** (interplanetary, ships with the Moon phase): sustained low thrust
  (`a_C`, D5) for injection burns and brachistochrone (flip-and-burn) transfers, fully Newtonian
  — **no supercruise, no suspended physics, no in-system speed magic**. Per the user's locked
  vastness intent (§6.3), in-system travel takes real time by design. 100s-of-km/s speeds are an
  *interstellar* tier for a future system — physically the same gear with a bigger a_C budget,
  gated so it cannot trivialize in-system distances.
- **HUD**: speed (frame-explicit: surface / orbital / target-relative), radial altitude,
  apoapsis/periapsis + time-to (closed-form from the f64 state — cheap and the single most
  orbit-teaching UI element), prograde/retrograde marker.

### 6.3 Vastness is the product — travel times and the expedition economy (USER-LOCKED intent)

The ÷1000 distances are **intentionally vast**: the design goal is that players *feel* the
massiveness of space and that conventional travel *takes real time* — reaching another body is a
real achievement, not a hop. Repeat-travel tedium is solved later by the **portal network**
(§7.4), not by compressing distances or adding supercruise. The concrete travel-time menu the
thrust caps produce (Earth system, §3.3 parameters):

| Trip | Mode | Real time | Game days |
|---|---|---|---|
| Around the planet on foot | walk 5.5 m/s | ~2 h | 6 |
| Around the planet | gear-1 fly 32 m/s | ~21 min | 1 |
| Ground → low orbit | gear 2 | ~1 min burn + coast | — |
| **LEO → Moon, Hohmann** (Δv 220 m/s) | gear 2 + coast | **≈ 3.3 h** | 10 |
| LEO → Moon, brachistochrone a_C = 0.2 m/s² | gear 3 | ≈ 46 min (peak 277 m/s) | 2.3 |
| LEO → Moon, brachistochrone a_C = 0.5 m/s² | gear 3 | ≈ 29 min (peak 438 m/s) | 1.5 |
| LEO → Moon, brachistochrone a_C = 2 m/s² | gear 3 | ≈ 15 min (peak 877 m/s) | 0.75 |
| Earth → Sun distance, at 100 km/s (illustrative) | interstellar tier | 17.3 days | 1250 |
| Nearest star, at 300 km/s (illustrative) | interstellar tier | 4.2 **years** | — |

**Recommended tuning (D5, flagged for the user):** first reach of the Moon should sit in the
**1–3 h band** — an expedition spanning several game days, survivable in one determined session.
That means gear-3 a_C ≈ **0.2–0.5 m/s²** (with the 3.3-h ballistic Hohmann as the low-Δv
"sailing ship" default), NOT the 2 m/s²+ regime that collapses it to minutes. Coasting is
on-rails (§5.2) so an hours-long transfer costs zero compute and is safe to leave; the orbit HUD
turns the coast into gameplay (correction burns, arrival planning). If playtesting says 3.3 h is
too brutal for the *first* trip, the tunable is a_C — never the distances.

### 6.4 Microgravity RCS (the user's item 4)

In ORBITAL mode near a reference (a grid, or a targeted body): all inputs apply **Δv relative to
the current orbital velocity** — exactly the user's framing:

- Translation: WASD/Space/Ctrl thrust in the *camera* frame at fine authority (`a_RCS ≈ 3 m/s²`),
  directly adding to the f64 velocity. Mouse = free look (pitch/yaw), Q/E = roll (v1 may lock
  roll; decision D11-lite, cheap either way).
- **Match velocity** (one key, the docking-maker): thrust-limited kill of velocity relative to the
  target grid/body — turns rendezvous from an expert skill into a game verb (KSP's hardest-learned
  lesson; SE ships it as "relative dampeners").
- The HUD velocity readout switches to target-relative automatically when a target is set.

## 7. Space voxel structures — grids (the user's items 3 + 5)

### 7.1 The unit: SpaceGrid

A grid is *a facet that flies*: `{grid_id, orbital state (Kepler elements | active f64 state),
attitude quaternion (v1: inertially FIXED, no spin — D6), a private voxel lattice
(Vector3i → cell id, the edit-overlay pattern), an AABB, a baked mesh + convex collision boxes}`.

- **Same orbital mechanics as the character** by construction: grids and players share the ONE
  `OrbitalState` implementation (§5.2) — orbit, decay in atmosphere, escape, SOI transfer.
- Meshing: the GDScript fallback mesher meshes a dict-backed lattice already (the non-module
  render path) — reused for grids (grids are small; godot_voxel streaming is unnecessary and
  wrong-shaped for them). Materials/ids come from `BlockCatalog` unchanged.
- Sources: player-built (place/break in GRID mode — the shipped interaction verbs against the
  grid lattice), or generated (a **hollow asteroid** is a grid with a worldgen fill: crust shell +
  carved interior, capped size).
- **NEVER-OOM caps** (§9): occupied region per grid ≤ 64³; live (meshed + collidable) grids ≤ 4
  by player distance; dormant grids serialize to packed arrays + Kepler elements (~KBs each);
  hard count on grids per system.

### 7.2 Attitude (D6)

v1 grids do **not** rotate: attitude is inertially fixed (or optionally "prograde-locked" as a
station-keeping cosmetic later). This kills the rotating-frame physics problem inside interiors
(fictitious forces, moving-collider sweeps) at zero gameplay cost for stations/asteroids.
Spin-gravity stations are explicitly future work (they need the full rotating-zone treatment).

### 7.3 Boarding + interior collision (the user's item 5)

The shipped ActiveFrame pattern, re-targeted (this is Star Citizen's local grid, and it is
*already our architecture* — the fixed-frame decision 3 FrameAdapter was built "readying the
multi-body cosmos"):

- **Board** when the capsule enters the grid's dilated AABB with |v_rel| < `V_DOCK ≈ 10 m/s`
  (bonk otherwise): the player's frame parent becomes the grid's transform, position/velocity
  re-express grid-relative (the crossing algebra with T_grid — one f64 transform), mode → GRID.
- **Inside**: microgravity 6-DOF — the analytic per-axis probe (`blocked()`, player.gd:335-360)
  generalized to ±y against the *grid's* lattice (no gravity, no floor snap; RCS = §6.4 with
  velocities grid-relative). Collision correctness is the same guarantee the planet enjoys:
  queries and rendering read the same lattice, so a hollow interior collides exactly as built.
  The capsule↔grid-exterior case (not boarded) uses the grid's convex collision boxes via the
  physics server — the VoxelBody pattern at station scale.
- **Un-board** by exiting the AABB: state re-expresses to body-inertial, mode → ORBITAL.
- Walking *with* gravity inside a grid (artificial gravity) is deferred: the per-facet Area3D
  gravity machinery (world_manager.gd:408-437) generalizes to a per-grid volume naturally, and
  the analytic walk needs the grid's −Y — a contained follow-up (D7), not v1.

### 7.4 Portal-network compatibility (future feature — a design constraint NOW)

The user's locked travel model is **two-tier**: slow, effortful, achievement-gated *first*
arrival by real orbital flight (§6.3); superfast portal travel *thereafter* — a place a player
has slowly reached once can be joined to their portal network (portals are a separate future
feature; a `feat/voxiverse-portals` branch already exists in the repo). This design does NOT
implement portals; it guarantees they can bolt on:

- **Every reachable place has a stable, serializable address** — a `PortalAnchor` is one of:
  `(body_id, fid, cell)` for a surface point (the permanent (fid, cell) identity the edit overlay
  already uses — world_manager.gd FP-M1a), `(grid_id, cell)` for a spot inside a structure, or
  `(body_id, Kepler elements, epoch)` for an empty-space/orbital anchor. All three are exact,
  tiny, and time-resolvable through the ephemeris (a portal to an orbiting station finds the
  station *where it is now* via its elements).
- **Arrival = the handoff machinery**: materializing at an anchor is exactly a §5.3 handoff
  (dominant-frame swap if the body differs + lattice/grid re-frame) — portals reuse the same
  gated, headless-tested transitions and add zero new physics.
- **"Reached once" is detectable**: mode transitions (§6.1) fire on first surface/grid contact
  per body/grid — the natural registration hook.
- Velocity semantics at exit (inherit anchor-frame rest vs preserve momentum) are a portal-side
  decision — the OrbitalState representation supports both trivially.

## 8. The Moon, the Sun, day-night (items 6-8)

### 8.1 Generalizing the planet builder (the real engineering in this design)

`FacetAtlas` and `TerrainConfig` are single-body statics today (facet_atlas.gd:19-39). The
generalization: a **BodySpec** `{body_id, R, K, seed, worldgen profile (biome/sea/crater params),
g₀}` and per-body atlas instances (same packed arrays, indexed by body). The pool, LOD mesher,
far ring, and edit overlay gain a `body` dimension **with exactly one body's near-field resident
at a time** (the dominant body — §5.3 keeps this an invariant, so peak memory is
max-over-bodies, not sum). `CubeSphere.BODY_N/BODY_R` already carry the table; the player's
per-body gravity feel hook is already wired (player.gd:90-99: gravity scales by the body ratio,
jump velocity by its square root — jump *height* is preserved while lunar hang time stretches
~2.5× (1/√0.165), the correct low-gravity feel out of the box).

**Moon**: R = 1737, **K = 14** (edge ≈ 195 — the ~200 taste lock held; 1176 facets, atlas
~0.7 MB), dihedral 6.4° (visibly chunkier horizon — honest and, per the faceted study §3.2,
charming on a small body), feel g ≈ 3.6 (= 22 × the real ratio 0.165 — §3.3.1), worldgen:
regolith/craters/maria, no sea, no trees, black sky (no atmosphere → no fog tint), Earth hanging
in the sky at 1.9° angular diameter (3.7× the Moon-from-Earth — the money shot). **Tidally
locked** via the one-line ephemeris rule (§4.2): spin period = orbital period = 9.11 h.

### 8.2 The Sun + day-night

Per §4.4: smooth emissive sphere impostor + THE DirectionalLight, direction =
`dir_to(sun, dominant_body, t)` expressed in the body-fixed frame — day-night emerges from spin
with zero geometry work. Environment modulation by sun elevation: sky/fog color ramp
(dawn/dusk), ambient floor at night (current ambient values — main.gd:147-154 — become the
night preset), optional star visibility ramp. Shadows: OFF by default on web (flag
`SUN_SHADOWS`, measured against the worst-frame budget before ever shipping on). The Moon phase
+ solar eclipses fall out of geometry (§4.2).

## 9. NEVER-OOM + web budget ledger (additions only; flags default OFF)

| Item | Cost | Cap / lifetime |
|---|---|---|
| Ephemeris + clock | O(bytes) | static |
| Sky layer (sun sphere, 2 impostors, skybox) | ~1-2 MB textures+meshes, fixed | never grows |
| Earth atlas at K = 50 (if D1a) | ~9.2 MB (was 2.1) | one-shot, static; **the largest single item — measured in O3's A/B before flip** |
| Moon atlas K = 14 | ~0.7 MB | resident only as dominant body alternates? No — atlases are small enough to keep both; near-field POOL is the exclusive one |
| Far ring at K = 50 | ~4.3× facet count | re-measured in O3; same merged-mesh pattern |
| Orbital states | 48 B dormant / ~100 B active | `ORBIT_ACTIVE_MAX = 8` active; dormant unbounded-cheap but counted |
| Grids | ≤ 64³ region, meshed ≤ 4, total ≤ `GRID_MAX = 64`/system | dormant = packed arrays + elements |
| Re-entry pre-warm | reuses the pool's existing budget (no extra live terrains) | controller-gated as today |

Per the memory-safety rule (memory `voxiverse-never-oom-web`): every flag ships OFF, flips at
export only after a measured heap A/B; ceilings are asserted by gates, not hoped.

## 10. Decisions ledger — for the user's sign-off

| # | Decision | Options | Recommendation |
|---|---|---|---|
| D1 | Planet size vs the ÷1000 table | (a) resize R=6371, K=50 (regen world, atlas 9.2 MB, facet ~200 kept) (b) keep 3072, ratio-scale the system ×0.482 | **(a)** — strict ÷1000 forever, decided before persistent content exists; executed as phase O3 |
| D2 | Time base | — | **LOCKED by user**: 20-min day, 72× compression on ALL periods; GM is the free parameter making Newton hold (GM_game = GM_real × 5.184×10⁻⁶). Full derived-numbers tables in §3.3-3.4: GM_E 2.066×10⁹ / GM_moon 2.543×10⁷ / GM_sun 6.880×10¹⁴; LEO 548 m/s / 79 s; escape 805 m/s; month 9.11 h; year 121.75 h |
| D2b | Near-field vs datum gravity seam | walk g stays feel-22 with a blend-band magnitude ramp to GM/r² (§3.3.1) / raise walk g to the 50.9 datum / shrink GM to a 22 datum (breaks the locked day) | **feel-22 + blend ramp** — the priority rule (day wins) forces GM; playability keeps the walk feel |
| D3 | Orbit fidelity | patched conics + symplectic active set / full n-body / all-on-rails | **patched conics + symplectic** (KSP model) — deterministic, dormancy-friendly |
| D4 | Ground-frame spin forces | ignore (≤0.8% of feel g, disclosed) / simulate Coriolis | **ignore** — but honor ω×r = 33 m/s at the mode handoff (eastward launch bonus is real, ~4% of orbital v) |
| D5 | Gear-3 thrust cap a_C (sets first-reach travel time; distances are LOCKED-vast, never the tunable) | powered brachistochrone at a_C = 0.2 / 0.5 / 2 m/s² → Moon in 46 / 29 / 15 min; low-Δv Hohmann coast = 3.3 h (§6.3 table) | **a_C 0.2–0.5 m/s² with the 3.3-h Hohmann as the cheap default** — Moon first-reach = a ~0.5–3.3 h expedition (1.5–10 game days) depending on Δv spent; repeats amortized by portals (§7.4). Fully Newtonian, no supercruise; interstellar tier deferred |
| D6 | Grid attitude | inertially fixed v1 / simulated spin | **fixed** — spin stations are a future rotating-zone feature |
| D7 | Interior gravity in grids | microgravity-only v1 / gravity generators now | **microgravity v1**; per-grid Area3D generalization later |
| D8 | The Sun as a place | unreachable environmental object (cruise clamps at ~0.1 AU÷1000) / approachable | **unreachable v1** |
| D9 | Godot precision=double rebuild | no / yes | **no** — f64-script + f32-anchored-scene is shipped, proven, web-safe |
| D10 | Atmosphere drag | exponential below y=384, terminal ~50-60 m/s, orbits decay inside it / none | **on** — makes "fall back" real AND caps re-entry speed for the streamer |
| D11 | Day-night shadows on web | off (flag) / on | **off** until worst-frame A/B passes |
| D12 | Portal compatibility | — | **constraint honored, not implemented**: every reachable place gets a stable PortalAnchor address; arrival = the existing handoff machinery (§7.4); portals themselves are the future `feat/voxiverse-portals` work |

## 11. Phased plan (each flag-gated, independently shippable, headless-gated)

Ordering rationale: O0-O2 are scale-agnostic (they read R_BLOCKS/BODY_R as data) and deliver
visible value early; the D1 resize (O3) lands *after* orbit mechanics prove out but *before* the
Moon locks the system layout; grids don't block on either.

### O0 — SKY (flag `ORBITAL_SKY`): clock, ephemeris, sun, day-night
- CosmosClock + CosmosEphemeris kernel (pure f64); Sun sphere + DirectionalLight + skybox +
  night/dawn environment ramp; Moon as a lit impostor on rails (visual only). Works at R = 3072
  unchanged. **This phase is shippable the moment on-planet work allows — it is pure sky.**
- Gates: ephemeris purity/determinism; the GM scaling-law assert (GM_game/GM_real = 5.184×10⁻⁶
  for every body); calendar asserts (day = 1200 s, month = 9.11 h = 27.3 game days, year =
  121.75 h); tidal-lock invariant; angular-size asserts (0.53°/0.52°); flag-off byte-identity;
  live remote-bridge sunset.
- Risk: none structural (no gameplay change).

### O1 — ORBIT (flag `FP_M3_ORBIT`): radial gravity + orbital mode + re-entry
- Gravity blend bands; ORBITAL mode (f64 inertial state, symplectic integrator, freeze-to-Kepler);
  gear-2 thrust; ω×r handoff; atmosphere drag; orbit HUD (Ap/Pe/speed/markers); re-entry via
  `facet_of_dir` + pool pre-warm; anchor follows the player off-surface.
- Gates (headless): 10-orbit energy/eccentricity drift < ε; handoff velocity continuity to f64 ε
  incl. the spin term; re-entry lands on the classified facet; drag terminal speed ≤ streamer
  budget; flag-off byte-identity. Live: fly to orbit, coast 3 orbits on-rails, deorbit, land, walk.
- Risks: re-entry streaming throughput (mitigated by drag cap + commit-band pre-warm — the
  controller gate from COSMOS-FP-M2-CONTROLLER-FIX re-runs with a falling player); pool policy vs
  high-altitude viewer (OFFSURFACE freeze exists; soak it).

### O2 — GRIDS (flag `SPACE_GRIDS`): structures, RCS, boarding, interiors
- SpaceGrid (lattice + mesh + collision + OrbitalState shared with the player); place/break in
  space; microgravity RCS + match-velocity; board/un-board; hollow-asteroid generator (one
  template); dormancy (Kepler + packed arrays); NEVER-OOM caps asserted.
- Gates (headless): grid orbit == player orbit under identical elements; boarding round-trip
  preserves absolute pose/velocity to ε; interior 6-DOF collision invariants (can't clip out of a
  sealed 5³ room under randomized RCS); dormancy round-trip byte-identity. Live: build a hollow
  station in orbit, enter, float through, exit, redock.
- Risks: capsule-vs-grid exterior collision at speed (bound by V_DOCK bonk rule); mesher perf for
  64³ grids (budgeted, off-thread like the LOD builder).

### O3 — SCALE (flag/param `BODY_SCALE` per D1): Earth to R = 6371, K = 50
- Execute D1a: regenerate; re-measure atlas/far-ring/spawn-scan/heap A/B; raise/verify
  REANCHOR_TRIGGER; widen the edit-key doc contract (fid ≤ 15,000).
- Gates: the full existing FP suite green at the new R; atlas ≤ ledger; live crossing still O(1);
  worst-frame parity on real GPU (remote bridge A/B vs 3072).
- Risks: far-ring vertex/heap growth (fallback: per-old-face far-ring merging tiers); startup
  atlas warm_up time (measure; amortize if > budget).

### O4 — MOON (flag `MULTI_BODY`): BodySpec, SOI, dominant-body swap
- BodySpec/BodyAtlas generalization (the big refactor — de-static FacetAtlas/TerrainConfig behind
  a body index); Moon worldgen profile; patched-conic SOI transfers; dominant-frame swap
  (near-field unload/load + impostor swap); gear-3 cruise; Earth-in-moon-sky.
- Gates: atlas instances byte-identical for Earth vs the pre-refactor static (the equivalence
  gate); SOI round-trip state continuity; tidal-lock sub-Earth assert on the *rendered* moon;
  live Earth→Moon→Earth trip with landings.
- Risks: the de-static refactor touching worker-frozen tables (repeat the frozen-epoch discipline
  per body — build all tables before workers spawn); swap hitch (measured; veil acceptable v1).

### O5 — SYSTEM POLISH: heliocentric year, eclipses, soak
- Earth-Moon barycentric refinement (optional), eclipse pass, seasons hook (axial tilt slot),
  long-soak (a full game year), savegame of orbital states, docs.
- Gates: eclipse prediction == render; full-game-year soak headless (121.75 h fast-forwarded)
  with zero drift; NEVER-OOM ledger audit.

## 12. Risk register (cross-phase)

| # | Risk | Sev | Mitigation |
|---|---|---|---|
| 1 | Re-entry outruns terrain generation (~550 m/s orbital vs walk-tuned streaming) | H | drag terminal-speed cap co-tuned with the controller gate; commit-band pre-warm during descent; worst case: brief low-LOD ground under a landing player (LOD tiles are radial-complete) |
| 2 | BodyAtlas de-static refactor destabilizes the worker purity contract | H | per-body frozen tables built pre-worker (the shipped frozen-epoch pattern); equivalence gate proves Earth byte-identical before the Moon exists |
| 3 | D1 resize regresses live perf/heap (atlas, far ring, spawn scan) | M | O3 is its own phase with a hard A/B on real GPU + heap; fallback = D1b ratio-scale (architecture unchanged) |
| 4 | f32 jitter on sky impostors / far ring under anchor shifts | M | impostors are anchor-independent (direction × clamped distance from the camera); asserted sub-pixel by gate |
| 5 | Mode-handoff bugs (the ω×r term, SOI re-expression) | M | every handoff has an f64 continuity gate; handoffs are pure functions, headless-testable without a scene |
| 6 | Web worst-frame from the sky layer (light changes re-lighting the scene) | M | one directional light, shadows off (D11), environment ramp is O(1) uniforms; remote-bridge frame-delta A/B (never TIME_PROCESS — memory `voxiverse-web-time-process-invalid`) |
| 7 | Scope creep toward n-body/spin-stations/interstellar | M | this ledger: D3/D6 lock the fidelity line; extensions have named future slots |
| 8 | Godot 4.6 migration (memory `voxiverse-godot-migration`) landing mid-build | L | the orbital layer is pure GDScript + standard nodes (light/mesh/area) — engine-version-agnostic by construction |

## 13. What this design deliberately does not do

No n-body perturbations, no Lagrange points, no axial-tilt seasons v1 (slot exists), no rotating
habitats, no aerodynamic flight model (drag is isotropic), no reachable Sun, no interstellar
content, no multiplayer treatment (though on-rails ephemeris + pure-function worldgen are the
multiplayer-friendly choices — see docs/MULTIPLAYER-ARCHITECTURE.md when that resumes), and no
engine precision rebuild. Each is either a named future slot or explicitly rejected in §10.
