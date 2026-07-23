# COSMOS — Climate/Weather Simulation + Climate-Driven Biomes (Design)

Status: **DESIGN ONLY** (overnight tasks 3+4, 2026-07-19). No engine code changed.
Basis: main checkout `deploy/perf-plus-sky` @ 8f1686c — natural Earth/1000
(R_BLOCKS = 6371, ÷√1000 clock, DAY_GAME ≈ 2732.6 s ≈ 45.5 min, `axial_tilt`
slot reserved at 0 in `CosmosEphemeris.BODIES`).

The user's decision: a **more physical** simulation (wind fields, pressure
fronts, moisture transport) over a purely procedural one — under the absolute
**NEVER-OOM** law (memory safety outranks visual quality; zero-extra-memory
default; every costly system flag-gated OFF behind a measured A/B with explicit
ceilings that bind on real bytes). This document reconciles the two: a **coarse
prognostic global grid** (the smallest state that still *transports* heat and
moisture and lets rain/storms/fog *emerge*), with everything below grid scale
derived deterministically, and every allocation enumerated in §8's ledger.

Architecture rule 2 (CLAUDE.md) binds throughout: **rendering and gameplay read
the sim; they never drive it.** Climate lives in `godot/src/sim/`; clouds and
precip are read-only views of it, exactly like the thermometer HUD.

---

## 0. What already exists (the design builds on, not around, these)

| Existing piece | File | Role in this design |
|---|---|---|
| Latitude climate `t` (spin axis +Z, `1−2·|sin φ|` + noise) | `terrain_config.gd _latitude_temperature` | The **static climate normal** biomes classify on; the field the weather grid relaxes toward |
| Humidity noise (SEED+103) | `terrain_config.gd _humidity` | The static moisture normal (flat-world moisture; sphere moisture pre-sim) |
| ONE temperature authority (climate base + 0.224 °C/block lapse) | `sim/climate_model.gd` | Gains one **seasonal offset** term (sim-side only, §3) |
| Per-voxel field queries (temperature/light/pressure stubs) | `sim/per_voxel_environment.gd` | Gains humidity/wind/precipitation/cloud queries; pressure stub fleshed out |
| Bounded deterministic weather precedent (SEED+105 storm gate, 200 k-cell edit budget, tile rotation, per-step caps) | `sim/snowfall_system.gd` | The pattern every new stepped system copies; its `is_snowing` gate is upgraded to read the grid |
| 11-biome first-match chain + biome→material tables | `terrain_config.gd _biome/_biome_top/_biome_filler` | Extended to the full Whittaker table (§6), flag-gated |
| Species-per-biome trees (oak/birch/spruce, hash-deterministic) | `world/tree_gen.gd` | Extended with acacia/jungle/palm/cactus (§6.4) |
| Biome-keyed far/shell colours through `profile_at_dir` | `world/far/far_palette.gd`, `facet_far_ring.gd` | New biomes = new palette rows → globe bands from orbit for free (§6.5) |
| f64 ephemeris with reserved `axial_tilt` slot | `cosmos/cosmos_ephemeris.gd` | Seasons = filling the slot with 23.4° (§3) |
| Sun/sky ramp + fog/altitude compose | `cosmos/cosmos_sky.gd` | Seasonal sun arcs automatic; fog density becomes a weather output |

The single most important structural fact: **worldgen (`generated_cell` /
`profile_at_dir`) is a pure function of (SEED, position)** — both render paths,
the analytic physics, and the C++ port depend on that. Therefore **seasons and
weather may never feed back into worldgen**. Biomes classify on *annual-mean*
climate (static); everything time-varying lives in the sim layer and, where it
must persist (snow), rides the already-budgeted `_edits` overlay via
SnowfallSystem. This is the one line that makes the whole design safe.

---

## 1. The bounded weather architecture — one coarse prognostic cube-sphere grid

### 1.1 Grid geometry

The same cube-sphere the planet uses, at weather resolution: **6 faces ×
N_w×N_w cells, N_w = 32** → **6144 cells**. With R = 6371 blocks the
circumference is ≈ 40 030 blocks, a face edge ≈ 10 000 blocks → **one weather
cell ≈ 313 × 313 blocks** — comfortably above the 256-block render radius, so a
player usually stands inside one cell and weather varies *locally* through the
deterministic downscale (§1.6), while fronts/storms span several cells and
genuinely *move*.

Cell directions come from the existing `CubeSphere.face_cell_to_dir` fold at
N_w; the 4-neighbour adjacency across face edges is precomputed **once at init
on the main thread** (the same edge-fold discipline as `warm_edge_tables` —
no worker ever first-touches it) into a flat `PackedInt32Array` (6144 × 4).
Wind is stored in **(east, north)** components (latitude/longitude are global
and well-defined: spin axis +Z, φ = asin(d.z)), so no per-face vector bases are
needed; crossing a face edge re-expresses nothing.

### 1.2 Per-cell state (the prognostic core) — exact bytes

Two buffers (current/next) of 8 `f32` fields per cell, in preallocated
`PackedFloat32Array`s — never resized, never reallocated:

| Field | Meaning | Prognostic / diagnostic |
|---|---|---|
| `T` | surface-air temperature anomaly vs the static climate normal (°C) | prognostic |
| `q` | specific humidity (0..q_max) | prognostic |
| `cw` | cloud water (condensed, not yet precipitated) | prognostic |
| `soil` | land wetness 0..1 (ocean cells pinned 1) | prognostic |
| `u`, `v` | wind east/north (blocks/s) | diagnostic, stored for readers |
| `p` | pressure anomaly (thermal low/high) | diagnostic, stored for readers |
| `inst` | instability index (storm potential) | diagnostic, stored for readers |

**Bytes: 6144 cells × 8 fields × 4 B × 2 buffers = 393 216 B ≈ 384 KiB.**

Static per-cell basis, computed once at init (§1.7), single buffer:

| Field | Bytes |
|---|---|
| `sinlat`, `coslat`, `lon` | 3 × 4 B |
| mean terrain height `h̄` (from `profile_at_dir` at the cell centre) | 4 B |
| land fraction (0/1 from centre sample, then one neighbour-smoothing pass) | 4 B |
| static climate normal `t_norm` (= the `profile_at_dir` t at centre) + moisture normal `q_norm` | 2 × 4 B |
| 4-neighbour indices | 4 × 4 B |

= 44 B/cell → **270 336 B ≈ 264 KiB**, fixed.

**Grid total ≈ 648 KiB, allocated once, zero growth paths.** (A future
quality bump to N_w = 48 (13 824 cells) would be ≈ 1.42 MiB — the hard ceiling
this design reserves; anything above is out of scope.)

### 1.3 The physics (what is real, what is parameterized — disclosed)

One shallow "surface weather layer" per cell; the vertical dimension is
*diagnostic* (the existing lapse rate gives the temperature aloft; nothing 3-D
is stored). Per sweep (one full-grid update):

1. **Insolation forcing** — the only external driver, straight from the
   ephemeris: solar elevation at the cell = f(latitude, longitude, spin angle,
   **subsolar latitude δ(t)** from §3). `T` relaxes toward an equilibrium
   anomaly `T_eq = A_diurnal·max(0, sinElev) − A_night + A_season·sinlat·sin δ`
   with a **land/ocean heat-capacity split**: land τ ≈ 0.5 game-hour (deserts
   swing hard day/night), ocean τ ≈ 10 game-days (maritime damping). This alone
   produces continental vs maritime climates, day/night temperature waves that
   sweep west with the terminator, and the seasonal hemisphere see-saw.
2. **Pressure (diagnostic)** — `p = −k_p · (T − zonal mean of T)`: warm columns
   are thermal lows. No mass conservation is solved (traded fidelity, §9).
3. **Wind (diagnostic)** — three composed terms:
   `wind = HadleyBackground(lat, δ) + k_g · rot(∇p) · sign(lat) + k_f · (−∇p)`
   — the analytic trade-wind/westerlies/polar-easterlies profile whose ITCZ
   tracks the subsolar latitude δ (seasonal monsoon shift for free), plus a
   geostrophic-like deflected gradient term (cyclonic flow around lows, with
   the correct hemisphere sign) plus a friction term that lets air actually
   flow *into* lows (so moisture converges where it should). This is the
   headline "physically-motivated but bounded" trade: **diagnostic wind from
   the pressure field, not prognostic momentum** — no CFL instability, no
   gravity waves to resolve, and it cannot blow up.
4. **Moisture** — evaporation `E = k_e·wind_speed·max(0, q_sat(T_abs) − q)·
   (land? soil·0.3 : 1.0)` (oceans are the source; wet soil re-evaporates);
   **semi-Lagrangian advection** of `q`, `cw`, `T` by the wind (upstream sample
   via the neighbour table + bilinear — unconditionally stable at any dt);
   **condensation** where `q > q_sat(T_at_condensation_level)` → `cw`;
   **orographic term**: `lift = wind · ∇h̄` — a positive lift multiplies the
   condensation rate (windward rain), a negative one dries and *warms* the cell
   (föhn/leeward desert). Rain-out: `cw` above a hold threshold precipitates at
   a rate that returns to `soil` on land; precipitation removes `q+cw` and
   deposits latent heat into `T` (storm self-heating → the feedback that lets
   cells organize).
5. **Instability (diagnostic)** — `inst = (Γ_actual − Γ_moist_ref) + k_L·latent
   release`, a CAPE proxy: hot wet surface under the (lapse-cooled) upper level.
   `inst` over a threshold with `cw` available flags the cell **convective**
   (cumulonimbus, §4.4): stronger rain-out, gusts, hail if the freezing level
   (from the lapse) sits low, lightning flashes.

Every constant is a named `const` in one file; all clamps hard (`q ∈ [0, q_max]`,
`T ∈ [−60, +60]`, `cw ∈ [0, cw_max]`) so state is bounded by construction and a
runaway parameter can saturate but never NaN/overflow.

### 1.4 Time stepping + the CPU budget (web-real numbers)

- Fixed **grid sweep period = 1.0 s real** (SnowfallSystem's fixed-accumulator
  pattern). Weather advances on `CosmosClock` game-time internally (dt_game =
  1 s × TIME_WARP × √1000-consistent rates folded into the constants), so
  weather ↔ day/night ↔ seasons all sit on the ONE clock.
- The sweep is **sliced**: `CELLS_PER_FRAME = 128` cells per rendered frame
  (6144/128 = 48 frames ≈ 0.8 s at 60 fps — one sweep per period with slack;
  at 30 fps a sweep takes 1.6 s and the accumulator simply runs sweeps back-to-
  back without ever doubling work — a slow sweep is a slow weather clock, never
  a spiral). Double-buffering makes a mid-sweep read always see a consistent
  *previous* field.
- **Cost**: a cell update is ~60–100 GDScript ops. Measured WASM penalty class
  (~25× native, `voxiverse-gen-class-costs`) puts it at ~2–4 µs/cell on web →
  **128 cells ≈ 0.25–0.5 ms/frame**. Budget line: **≤ 0.7 ms/frame amortized,
  main thread**, asserted by the stage gate (G-W1-CPU) with real timing on the
  headless build (native numbers × 25 as the web projection, the established
  convention). If a live A/B measures worse, `CELLS_PER_FRAME` halves (weather
  clock slows; correctness unchanged) — the knob degrades time-resolution,
  never memory. A later C++ port of the sweep kernel (L5 pattern) is the
  escape hatch, not a prerequisite.
- **Determinism**: the sweep is a pure function of (previous state, sweep
  index, SEED); the init state is the static normals. Two headless runs with
  the same step count hash identically (G-W1-DET). Cross-session the weather
  phase restarts (state is not persisted — same disclosed rule as
  SnowfallSystem's `step_counter`); accumulated *snow* persists via `_edits`.

### 1.5 Where it lives (sim-layer integration)

New `godot/src/sim/weather_system.gd` (`WeatherSystem`), owned and stepped by
`WorldManager._process` exactly like `SnowfallSystem`. **All reads go through
`PerVoxelEnvironment`** (engine rule 2 — the HUD, the material state machine,
clouds, and precip all query the same interface):

- `humidity(pos)` — grid `q` downscaled (§1.6); flag off → the static
  `q_norm` (humidity noise). Fleshes a stub.
- `wind(pos) -> Vector3` — grid `(u,v)` mapped into the local frame + gust
  noise; flag off → `Vector3.ZERO`. New field, physically-sane default.
- `pressure(pos)` — `101.325·exp(−y/H_SCALE) + p_anomaly` — fleshes the stub
  with the altitude term (matches the SN4 fog scale height) + weather.
- `precipitation(pos) -> {rate, kind}` — kind (rain/snow/hail) resolved by
  **`ClimateModel.surface_temperature` + season offset** — the one zero-
  crossing authority, so rain/snow agrees with the snow-cap/melt boundary by
  construction.
- `cloud_cover(pos, layer)` — the §4 cloud field, for gameplay/HUD.
- `temperature(pos)` — unchanged path, plus the §3 season offset and a
  **bounded** weather anomaly term (`+ clamp(T_cell, ±8 °C)` under the flag).

`SnowfallSystem.is_snowing(x,z)` upgrades under the flag from the SEED+105
noise gate to "grid precip > 0 AND kind == snow at this column" (the noise
becomes the *sub-cell* structure, §1.6) — the accumulation machinery, budgets,
and persistence stay verbatim.

### 1.6 Deterministic sub-cell downscale (313-block cell → per-column weather)

Grid values are bilinear-interpolated across cells, then modulated by salted
FastNoiseLite fields advected by the cell wind (domain offset = wind × time —
cheap Lagrangian look): salt **SEED+106** (cloud/precip texture, ~0.004 freq
like today's storm field) and **SEED+107** (gusts). Salts 106–108 are claimed
in TerrainConfig's salt registry (105 = SnowfallSystem, recorded there
already). Pure functions of (SEED, grid state, position) — no new state.

### 1.7 Init (the one startup cost)

The static basis needs one `profile_at_dir` sample per cell (6144 calls, ~50 µs
each on web) — **amortized 32 cells/frame ≈ 1.6 ms/frame over ~3.2 s** during
startup streaming (when the far ring is building anyway). Until the basis is
complete the sim holds at the static normals (weather = "climatology"), so
there is no wrong transient. Gate G-W1-INIT asserts the spread and the byte
count of every array after init.

---

## 2. Why not more physics (the explicit reconciliation)

Rejected designs, for the record:

- **3-D atmospheric grid** (even 6×32×32×4 levels): ×4–8 state and a
  prognostic vertical momentum/moisture exchange — >3 MiB + multi-ms sweeps on
  web. The single-layer + diagnostic lapse keeps 90% of the *visible* behaviour
  (fronts, orographic rain, storms, fog) at 1/8 the cost. **Traded**: no jet
  stream, no realistic cloud-top dynamics, no vertical wind shear.
- **Prognostic momentum (real shallow-water)**: needs CFL-bounded substeps
  (~10× more sweeps) and can go unstable — the failure mode is a frozen tab,
  which the NEVER-OOM ethic extends to CPU. Diagnostic wind cannot blow up.
  **Traded**: no inertial cyclone spin-down, fronts move at the diagnostic
  wind, hurricanes are "storm complexes" not true vortices.
- **Per-column weather state** (Minecraft-style per-chunk): unbounded with
  exploration — exactly the growth NEVER-OOM forbids. The grid is position-
  independent: explore forever, weather RAM constant.

What is genuinely physical and *emergent* in the kept design: moisture is
**conserved-in-transport** (evaporated ocean water travels downwind and rains
where lifted/cooled — windward-wet/leeward-dry falls out of the `wind·∇h̄`
term, deserts sit in descent zones of the Hadley profile), storms **self-
organize** (latent heat → instability → convective flag), fog appears where
`q ≈ q_sat` at low wind and low sun, monsoon-ish reversal follows the ITCZ
crossing the equator with the seasons. Nothing is scripted per-phenomenon —
rain/snow/fog/storm/hail are all threshold read-outs of (T, q, cw, inst).

---

## 3. Seasons — real obliquity on the one clock

Real Earth seasons are **axial obliquity**, nothing else: the spin axis is
tilted ε = 23.4° from the orbit normal and stays fixed in inertial space, so
the **subsolar latitude** oscillates δ(t) = asin(sin ε · sin λ(t)) with λ the
orbital longitude from the vernal equinox — +23.4° at the June solstice,
−23.4° in December, 0 at equinoxes. Summer = your hemisphere leans sunward:
higher sun, longer days, more insolation. The model does exactly this:

1. **Ephemeris**: fill the reserved slot — `BODIES.earth.axial_tilt = 0.4084`
   rad (23.4°). New pure accessors `subsolar_latitude(t)` (the formula above,
   with λ = orbit_angle(earth)+π viewed Sun→Earth) and `sun_declination_dir()`.
   `dir_to_bodyfixed` composes the tilt: the body-fixed frame becomes
   R_spin(θ) · R_tilt(ε) — one extra constant rotation about the equinox line
   (f64, exact; the tilt axis is fixed inertially so tidal/spin logic is
   untouched). With tilt=0 flag-off, R_tilt = I → **byte-identical**.
2. **Sky (automatic)**: `CosmosSky` already places the sun from
   `dir_to_bodyfixed` — seasonal sun arcs (low winter sun, high summer sun,
   polar day/night above |lat| > 66.6°) need **zero sky code**; day length
   changes fall out of the geometry.
3. **Climate**: `ClimateModel` gains `season_offset(sinlat, δ) =
   SEASON_GAIN · sinlat · sin δ` (≈ ±10 °C at mid-latitudes for
   SEASON_GAIN ≈ 25 — real mid-latitude seasonal swing), exposed as a static
   function plus **one main-thread-only static var** `current_sin_delta`
   written once per frame by WorldManager from the clock. **Only sim-layer
   callers add it** (PerVoxelEnvironment temperature, SnowfallSystem's
   surface-temperature check, FarPalette? — NO: see below). The pure
   `surface_temperature(y, t)` signature stays untouched so **worldgen and the
   C++ port never see time** (G-SEAS-PURE asserts `generated_cell` is
   clock-independent).
4. **What moves with the seasons** (all bounded): the SnowfallSystem
   accumulate/melt line (its `ts < 0` test picks up the offset → snow advances
   in winter and retreats in summer, inside the existing 200 k-cell budget and
   48-column radius — the *global* snow line does NOT restamp worldgen);
   weather-grid forcing (§1.3 term 1); rain/snow kind selection. **What does
   not move**: worldgen snow caps, the frozen-ocean ice sheet, biome
   boundaries, far/shell colours — all annual-mean, all static. Disclosed
   trade: distant mountains keep their annual-mean cap through winter; only
   the near, simulated field breathes. (A live-only later idea: a *palette*
   winter tint on the far ring driven by the same offset — property-level, but
   it re-emits far meshes, so it stays out of this design's scope.)

**Calendar**: the ephemeris year is 2π/ω_orbit(earth) ≈ 9.981×10⁵ game-s =
365.3 game days ≈ **11.55 real days per year → ~2.9 real days per season**.
Real and correct, but slow for playtesting — `SEASON_WARP` (a multiplier on λ
only, default 1.0, dev-flag) is the one disclosed self-consistent deviation
knob (warping λ desyncs the year from the orbit ephemeris; at default 1 there
is no deviation).

---

## 4. Clouds — semi-cubic smoothed, multi-type, multi-altitude

Look: the terrain's own language — **blocky prisms with smoothed/ramped
corners** (the SLOPE-family aesthetic), not billboards, not volumetrics.
Renderer reads the sim (rule 2): cloud geometry is a pure function of the grid
`cw`/`inst` fields + the SEED+106 downscale noise.

### 4.1 The layer lattice

Per altitude band, one **camera-following, world-snapped tile lattice**:
64×64 tiles of 32×32 blocks → a 2048-block cloud dome around the player
(covers the visible near field; beyond it the horizon fades in fog / the far
ring). A tile's cloud value = grid `cw` bilinear + noise(SEED+106, advected by
the cell wind); present iff over the layer threshold. Corner heights sample
the same field at tile corners → quantized to half-blocks → each tile emits a
prism with ramped top edges exactly like the terrain's corner-height family
(shared math, new small mesher). Interior runs of full tiles are greedy-merged
per row, so the worst case (full overcast) is the *cheapest* mesh, not the
worst (G-W2-BYTES asserts the emitted vertex bound for synthetic full-cover).

Because tiles are world-snapped, a standing player sees clouds *move* only as
the field advects (wind), and a moving player never forces a full rebuild —
only the entering edge row re-emits.

### 4.2 Types and altitudes (all below the ATMO_TOP = 384 ceiling)

| Layer | Altitude (blocks) | Type | Source field | Look |
|---|---|---|---|---|
| L0 | 128–160 | **cumulus** (fair weather) / **cumulonimbus** (storm) | `cw` mid-range; `inst` flag upgrades | chunky prisms, 1–2 blocks thick; storm tiles extrude upward to ~256 with darker vertex colour |
| L1 | 208–224 | **stratus/altostratus** | `cw` high + low `inst` | flat wide slabs, thin (0.5–1 block), soft grey |
| L2 | 300–320 | **cirrus** | high `q` with low `cw` (moist but not condensing) | sparse thin streaks, elongated along the wind vector, high threshold |

Cumulonimbus (§1.3's convective flag): a capped set (≤ 64 tiles/layer) of L0
tiles extrudes to a towering prism topping out near L1 with an anvil row —
same mesh, bounded extra vertices. Vertex-colour darkening encodes thickness
(unshaded/vertex-colour material like the far ring — cheap on gl_compat).

**Draw calls: exactly 3** (one mesh instance per layer, one material each) —
within the ~204-draw ceiling by a wide margin. Meshes are rebuilt
incrementally: one layer per 16 frames round-robin, into **reused**
scratch `PackedVector3Array`/`PackedColorArray` (allocated once at worst-case
capacity, §8 row 4) then `mesh.clear_surfaces()` + one `add_surface` — the
established far-ring rebuild pattern; no per-rebuild allocation growth.

### 4.3 From orbit (later substage W5, optional)

The whole-globe cloud picture is already *in* the grid: bake `cw` into a
6×32×32 **RGBA8 ImageTexture (24 KiB, updated in place** once per sweep) and
let the shell/far material sample it as a translucent white overlay modulated
by the same latitude bands. This is the only path that shows clouds from
space; it is deferred behind its own flag because it touches the shell
material (owned by the shell stream) — listed here so the grid is designed
texture-bake-ready (it is: the field is already a flat array per face).

---

## 5. Phenomena read-outs (rain, snow, fog, wind, thunder, hail)

All are threshold views of grid state — no phenomenon has its own simulation:

- **Rain/snow**: one reused precipitation node around the camera (a
  `GPUParticles3D` box — supported on gl_compat since 4.3 — with a hard
  `amount` cap of 1024; **CPUParticles3D fallback** at 512 if a live A/B shows
  a compat-path cost). `amount_ratio` = local precip rate; mesh/velocity swap
  rain streaks ↔ snow flakes ↔ hail pellets by `precipitation().kind`. One
  node, fixed pool, zero growth. Snow *accumulation* is SnowfallSystem's
  existing budgeted machinery (§1.5).
- **Fog**: no new object — drive the existing `Environment` fog density
  (composing *multiplicatively* with SN4a's altitude ramp so space stays
  clear): `fog_mult = 1 + k·smoothstep(q/q_sat → 1) · calm · low-sun`.
  Radiation fog appears on clear calm mornings and burns off — emergent from
  the same fields. Property writes only.
- **Wind (gameplay)**: `PerVoxelEnvironment.wind(pos)` — an optional small
  force on the Player and on awake `VoxelBody`s (flag substage; caps at a few
  N so it's flavour, not a griefing physics input), and the visual driver for
  cirrus elongation + particle drift + cloud advection.
- **Thunderstorm**: convective cells flash — a 2-frame ambient/directional
  energy pulse (property write) with distance-delayed thunder (one
  `AudioStreamPlayer`, optional). A visible bolt (one reused ImmediateMesh
  polyline) is LIVE-ONLY garnish behind the same flag.
- **Hail**: convective + freezing level below ~L0 altitude (from the lapse) →
  particle kind hail. No world edits (no ice-block littering — bounded by
  decision, not budget).

---

## 6. Task 4 — Biomes by climate/latitude (the Whittaker table)

### 6.1 Classification = pure function, computed where it always was

Biome stays **exactly where it is**: resolved inside
`profile_at_dir`/`column_profile` per column, on demand, **zero per-voxel or
per-column storage** — the existing architecture already satisfies the
determinism/cheapness requirement. The change is the *classifier*: today's
first-match chain becomes a temperature × moisture Whittaker table under flag
`FP_CLIMATE_BIOMES` (off → verbatim today's chain, byte-identical world).

Inputs (all already computed in `profile_at_dir`): `t` = latitude-anchored
temperature (annual mean — **never** the season offset, §3), `h` = humidity
noise, `c` = continentalness, `g` = height, `mtn` = mountain factor. The
guards keep their precedence — ocean, beach, pillar, mountains first,
unchanged — then:

```
                 h < −0.45      −0.45..0.0     0.0..0.4        > 0.4
t > 0.45         BADLANDS       DESERT         SAVANNA (new)   JUNGLE (new)
0.15..0.45       DESERT         SAVANNA (new)  FOREST          SWAMP (h>0.5) / FOREST
−0.15..0.15      PLAINS         PLAINS         FOREST          FOREST (birch-rich)
−0.55..−0.15     TAIGA          TAIGA          TAIGA           TAIGA
t < −0.55        SNOWY          SNOWY          SNOWY           SNOWY
```

On the sphere the latitude anchor (`_LAT_GAIN` 0.8) makes these **bands**:
equator jungle/savanna/desert (by moisture), subtropics desert/badlands
(the Hadley descent zone — matching where §1's model dries), mid-latitudes
forest/plains/swamp, then taiga, then polar snowy/tundra + the frozen-ocean
ice caps that already exist. Altitude keeps its existing independent effects
(B_MOUNTAINS + the surface_temperature<0 snow caps whiten peaks in any band).
Two new biome consts append: `B_SAVANNA := 11`, `B_JUNGLE := 12` (appending
after B_PILLAR — never renumbering, the same frozen-id discipline as the
catalog).

### 6.2 Consistency with the climate sim — both directions, by construction

- Sim → biome: the weather grid's forcing normals (`t_norm`, `q_norm`, §1.2)
  are sampled from the *same* `profile_at_dir` fields the classifier reads —
  so the sim's hot+dry equilibrium cells **are** the desert cells; gate
  G-B2-CONSIST samples K columns and asserts ≥ 90 % class agreement between
  the grid's relaxed annual state and the worldgen biome.
- Biome without sim: the classifier reads only static noise + latitude —
  **climate sim OFF changes nothing about the world** (the task's hard
  fallback requirement, trivially true because worldgen never reads the sim).

### 6.3 Blocks — a data change, as the architecture demands

Per architecture rule ("adding a material is a data change"): new rows in
`assets/blocks.json` (append-only ids, frozen-core untouched):
`acacia_log`, `acacia_leaves` (olive-green), `jungle_log`, `jungle_leaves`
(saturated green), `cactus` (solidity 1, low break_force, green swatch),
`palm_log`/`palm_leaves` (optional, beach garnish). Surface tables extend:

- `_biome_top`: SAVANNA → grass (dry look comes from sparse acacias +
  the existing grass; a `savanna_grass` tint variant is a possible later data
  tweak), JUNGLE → grass (podzol-hash variant like taiga, salt reuse 741).
- `_biome_filler`: both → dirt(3), the temperate default.
- `_underwater_floor`: both → default gravel path (no change needed).

### 6.4 Trees — extend the proven hash-deterministic species machine

`TreeGen._species_for` gains: SAVANNA → SP_ACACIA (sparse grid — reuse the
existing patch-hash gates with a lower density), JUNGLE → SP_JUNGLE (dense,
tall: trunk 8–12 + wide 5×5 canopy — raise `TREE_MAX_HEIGHT` accordingly and
re-verify the viewer vertical budget; the existing mountains slab already
streams to y≈112 so canopy@~20 is free), B_DESERT → SP_CACTUS (1×1 column,
height 1–3, very sparse — technically "a tree" to the generator, which is
exactly why it's cheap), B_BEACH → SP_PALM (optional, curved trunk approximated
straight + fan canopy). All shapes are new `_*_block` functions in the
existing per-cell overlay form — deterministic, both render paths agree by
construction. New salts from the TreeGen family registry.

### 6.5 The globe view — palette rows + one C++ note

`FarPalette` gains `biome_base` rows: SAVANNA → grass↔sand lerp (tan
grassland), JUNGLE → grass↔jungle_leaves lerp (deep green). Because the far
ring, the skin tier, and the orbital shell all colour through
`FarPalette.color_for` on the same `profile_at_dir` funnel, **the planet shows
jungle/savanna/desert/taiga/snow bands from orbit automatically**. One caveat
found in review: the C++ generator port freezes a 14-colour `FarColor` enum
(`frozen_colors()`); new biomes need either (a) a 2-entry enum extension in
the C++ module (small patch, recompile) or (b) an interim GDScript-side
mapping of SAVANNA/JUNGLE onto nearest existing entries (grass/leaf) for the
C++ fast path while the GDScript path shows true colours. The design picks
(a) with (b) as the fallback if a rebuild isn't scheduled; gate G-B1-PAL
asserts every B_* id returns a palette colour on the GDScript path either way.

---

## 7. Staged, flag-gated plan (every stage default-OFF, measured A/B, ordered)

| Stage | Flag (CubeSphere.*) | Contents | Depends |
|---|---|---|---|
| **W0** | `FP_SEASONS` | ephemeris tilt 23.4° + `subsolar_latitude` + tilted `dir_to_bodyfixed` + `ClimateModel.season_offset` (sim-side only) + SnowfallSystem seasonal snow line | — |
| **W1** | `FP_CLIMATE_GRID` | WeatherSystem grid (state, init basis, sliced sweep) + PerVoxelEnvironment humidity/wind/pressure/precip queries; **no rendering** | W0 (uses δ; runs with δ=0 if W0 off) |
| **W2** | `FP_CLOUDS` | 3-layer semi-cubic cloud meshes off the grid | W1 |
| **W3** | `FP_PRECIP` | particle rain/snow + fog-density drive + SnowfallSystem `is_snowing`→grid coupling | W1 |
| **W4** | `FP_STORMS` | convective flag → cumulonimbus extrusion + lightning flash/thunder + hail + optional gameplay wind force | W2+W3 |
| **W5** | `FP_SHELL_CLOUDS` | 24 KiB global cloud texture on shell/far (LIVE-heavy, optional) | W1 + shell stream |
| **B1** | `FP_CLIMATE_BIOMES` | Whittaker classifier + B_SAVANNA/B_JUNGLE + blocks.json rows + TreeGen species + FarPalette rows (+ C++ FarColor extension or fallback map) | — (independent of W*) |

W* and B1 are **independent flag families** (biomes never read the sim), so
they can land, A/B, and ship in any order; B1 changes worldgen output (a
*new-world look* change — the flag flip is the A/B and the byte-identical
proof is flag-off).

### Headless gates per stage (extend `verify_feature` pattern; new `src/tools/verify_climate.gd`)

- **G-SEAS-TILT**: δ(t) = +23.4°/0/−23.4° at solstice/equinox quarter-year
  marks; day length at 45° lat longer at summer solstice (pure geometry from
  `dir_to_bodyfixed` samples); tidal-lock + existing O1 gates still green
  (tilt must not perturb them).
- **G-SEAS-PURE**: `generated_cell`/`profile_at_dir` hashes identical across
  two different `current_sin_delta` values — **worldgen never sees the clock**.
- **G-W1-BYTES**: sum of every WeatherSystem array's real bytes
  (`.size() × 4`) == the ledger numbers in §8, asserted after init; no array
  identity changes across 1000 sweeps (no silent reallocation).
- **G-W1-CPU**: mean sliced-step time over 1000 frames ≤ budget (native ×25
  projection rule).
- **G-W1-DET**: two runs, same sweep count → identical state hash.
- **G-W1-PHYS**: after spin-up (~30 game-days): equator mean T > pole mean T;
  ocean-adjacent downwind cells wetter than continental interiors; a synthetic
  ridge cell shows windward precip > leeward; all fields inside clamps; total
  `q+cw` bounded (no moisture explosion).
- **G-W1-ITCZ**: the latitude of max zonal-mean precip tracks δ within ±10°
  across a synthetic year (the seasons-drive-weather proof).
- **G-W2-BYTES/DRAWS**: synthetic full-overcast → emitted vertex count under
  the cap; exactly 3 cloud mesh instances; scratch arrays identity-stable.
- **G-W3-COUPLE**: precip kind == snow ⇔ (surface_temperature+season) < 0 at
  the sample column; SnowfallSystem budget/caps unchanged (its existing verify
  stays green with the grid gate substituted).
- **G-W4-EMERGE**: forcing a cell hot+wet raises `inst` over threshold and
  flags convective; cold or dry does not (storms emerge from state, not
  script).
- **G-B1-DET**: `biome_at` byte-stable across runs; flag OFF → world hash
  identical to today (the byte-identical proof).
- **G-B1-BANDS**: sampled great-circle pole→equator: biome sequence is
  monotone-band-ordered (snowy→taiga→temperate→tropical members only, no
  desert at 70° lat, no snowy at the equator outside mountains).
- **G-B1-TREES**: new species height ≤ TREE_MAX_HEIGHT; species deterministic;
  desert/badlands still tree-free except cactus.
- **G-B2-CONSIST** (needs W1+B1): ≥ 90 % Whittaker-class agreement between
  grid annual normals and worldgen biome over K sampled cells.

### LIVE-ONLY (cannot be proven headless — flagged for the user's session)

Cloud *look* (silhouette quality, layer heights reading right from the
ground and from orbit), precip feel/density, fog mood, storm drama
(flash timing, gust feel), the seasonal sun arc at high latitude, actual
web worst-frame under W2+W3+W4 together (the measured A/B each flag needs
before defaulting ON), and the W5 shell-cloud look.

---

## 8. NEVER-OOM ledger (every new allocation; the make-or-break table)

All buffers allocated **once** at flag-on setup, identity-asserted by gates
(no realloc paths exist — no `append` on any state array anywhere in the
design). "Evict" = what happens at the cap; none of these can *reach* a cap at
runtime because none grow.

| # | Allocation | Type | Bytes (exact) | Lifetime | Growth path | Cap/eviction |
|---|---|---|---|---|---|---|
| 1 | Weather state ×2 buffers (8 f32 × 6144) | PackedFloat32Array ×16 | **393 216** | session (flag-on) | none (fixed size) | n/a — cannot grow |
| 2 | Static basis (7 f32 + 4 i32 × 6144) | PackedFloat32/Int32Array | **270 336** | session | none | n/a |
| 3 | Downscale noises (SEED+106/107) | 2 × FastNoiseLite | ~200 B | session | none | n/a |
| 4 | Cloud scratch (verts/colors/indices, worst-case cap: 3 layers × 4096 tiles pre-merge bound → capped emit 24 k verts/layer) | reused Packed arrays | **≤ 3 × 24 576 × 32 B ≈ 2.36 MiB** allocated at worst-case once | session (W2 on) | none (fixed capacity; over-cap tiles skipped, gate-asserted) | emit stops at cap (visual: a far cloud tile missing — never memory) |
| 5 | Cloud ArrayMesh GPU surfaces ×3 | ArrayMesh | ≤ the row-4 bytes mirrored GPU-side | session | rebuilt in place (`clear_surfaces`) | same cap |
| 6 | Precip particles | 1 node, `amount` ≤ 1024 | ~fixed pool (engine-side, ≤ ~200 KiB) | session (W3 on) | none | hard `amount` const |
| 7 | Storm extrusion | inside row-4 cap (≤ 64 tiles/layer share the vert budget) | 0 extra | — | none | tile cap const |
| 8 | Lightning bolt / audio | 1 reused ImmediateMesh + 1 player | < 50 KiB | session (W4 on) | none | n/a |
| 9 | Season state | a few static floats | < 100 B | session | none | n/a |
| 10 | Seasonal/live snow cells | **existing** SnowfallSystem `_edits` | 0 new | — | already budgeted | existing `SNOW_EDIT_BUDGET` 200 000 cells |
| 11 | W5 shell cloud texture (optional) | Image+ImageTexture 6×32×32 RGBA8 | **24 576** + texture copy | session (W5 on) | updated in place | n/a |
| 12 | New biome/tree data (B1) | blocks.json rows + catalog states | ~a few KiB in the existing fixed-capacity (65536) session table | session | append-only registration at boot | existing catalog capacity |

**Total worst case, every flag ON: ≈ 3.1 MiB RAM + ≈ 2.4 MiB GPU — fixed,
position-independent, exploration-independent.** Default (all flags OFF):
**zero bytes, zero CPU** — the classes aren't even instantiated
(SnowfallSystem-style: WorldManager constructs them only under the flag).

Per-frame CPU ledger (amortized, main thread, web-projected): grid slice
≤ 0.7 ms (W1) + cloud layer rebuild ≤ 0.5 ms on its 1-in-16 frames (W2) +
downscale/particle/fog property writes ≤ 0.1 ms (W3) + season/ephemeris
≈ negligible (W0). Each number is a gate, not a hope.

---

## 9. Risks (NEVER-OOM first) and disclosed fidelity trades

1. **(top) Cloud mesh worst case** — the only allocation with a shape
   dependence. Mitigated three ways: greedy row merge makes overcast cheap,
   a hard emit cap makes the bound unconditional, and G-W2-BYTES asserts it
   on synthetic full cover. Residual risk: visual pop at the cap — accepted.
2. **WASM sweep cost drift** — if the ×25 projection is optimistic, the knob
   is `CELLS_PER_FRAME` (halves cost, slows weather time); the escape hatch is
   an L5-style C++ sweep kernel. Never a memory trade.
3. **Season leakage into worldgen** would break byte-determinism and the C++
   port's frozen epoch — structurally prevented (pure signatures untouched;
   offset added only in sim-layer callers) and gate-pinned (G-SEAS-PURE).
   This is the highest-*severity* risk even though its likelihood is low.
4. **Tilt perturbing shipped orbital gates** — R_tilt touches
   `dir_to_bodyfixed` used by the sky and SN nav overlays; W0's gate re-runs
   the O1/tidal-lock suite. Flag-off is byte-identical.
5. **B1 changes the world** (intended, but it invalidates "byte-identical"
   comparisons and any saved `_edits` semantics near changed columns) — B1
   ships as a new-world flag; the off-state proof is the compatibility story.
6. **C++ FarColor enum freeze** — new biome colours on the C++ skin path need
   a module recompile; interim fallback maps them to grass/leaf (globe bands
   slightly less distinct until the rebuild). Small, scheduled, disclosed.
7. **Cross-face advection at cube corners** — the 4-neighbour fold at the 8
   corners is irregular (3-face meeting); the semi-Lagrangian upstream sample
   just uses the folded neighbour and accepts O(cell) distortion there —
   weather at 313-block resolution cannot resolve it anyway. Gate G-W1-PHYS
   samples corner cells for clamp violations.

**Where the "more physical" ambition was bounded, and what was traded**
(the explicit list the user asked for): single layer instead of a 3-D
atmosphere (no jets/shear/realistic cloud tops); diagnostic wind instead of
prognostic momentum (no true cyclone dynamics; fronts move with the diagnosed
wind); no global moisture/energy closure (fields clamped instead of conserved
exactly — local transport is real, global budgets are approximate); seasonal
snow/ice breathes only in the simulated near-field ring and the static world
keeps annual means at distance (no global winter restamp — that would be a
worldgen-time dependence and a restream bomb); N_w = 32 cell size (~313
blocks) means no weather feature smaller than ~a cell exists except as
deterministic noise texture. Everything else — latitude bands, land/sea
contrast, orographic rain shadows, ITCZ/monsoon seasonality, emergent storms,
diurnal waves, fog — is genuinely modelled.

---

## 10. File plan (for the implementing stream; no code in this pass)

- `godot/src/cosmos/cosmos_ephemeris.gd` — tilt value + `subsolar_latitude` +
  tilted `dir_to_bodyfixed` (W0).
- `godot/src/sim/climate_model.gd` — `season_offset` + `current_sin_delta`
  (W0).
- `godot/src/sim/weather_system.gd` — NEW: grid state, init, sliced sweep
  (W1).
- `godot/src/sim/per_voxel_environment.gd` — humidity/wind/precip/cloud
  queries + pressure flesh-out (W1).
- `godot/src/sim/snowfall_system.gd` — `is_snowing` grid coupling (W3).
- `godot/src/world/cloud_layers.gd` — NEW: the 3-layer semi-cubic mesher
  (W2); `world/weather_fx.gd` — NEW: particles/fog/flash (W3/W4).
- `godot/src/world/terrain_config.gd` — Whittaker `_biome` under flag +
  B_SAVANNA/B_JUNGLE + surface-table rows (B1).
- `godot/src/world/tree_gen.gd` — acacia/jungle/cactus/palm species (B1).
- `godot/src/world/far/far_palette.gd` — two rows (B1); C++ FarColor +2
  (B1, module rebuild).
- `assets/blocks.json` — new material rows (B1).
- `godot/src/tools/verify_climate.gd` — NEW: all §7 gates.
- `godot/src/cosmos/cube_sphere.gd` — the 7 flags, default false.
