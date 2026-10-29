# Live feature flags of the VOXIVERSE web build

The served game world runs with a few hundred GDScript `const` feature flags switched ON. The committed
source keeps those flags at their defaults (`false`). The deploy script that switched them on at export
time lived only in a session scratchpad and was lost. This folder recovers the flag set from the last
archived live web build and makes the world reproducible again.

| File | What it is |
|---|---|
| `live-flags.json` | Machine-readable record of every top-level bool `const` in the pack: `file`, `const`, `source_default`, `live_value`, `line`. |
| `extract_pck_flags.py` | The parser that produced the JSON (Godot 4.4 PCK directory plus the GDScript binary-token format). Standard library only. |
| `../../../scripts/deploy_cheats.sh` | Rebuilt export pipeline. It reads the flag list from `live-flags.json`. |

## Result

- **Flags switched ON in the live build: 234.** 233 are in `godot/src/cosmos/cube_sphere.gd` and 1
  (`CONTROL_ENABLED`) is in `godot/src/net/remote_bridge.gd`. Each one is `false` in source and `true` in
  the pack.
- **Bool consts in the pack: 370**, across 15 scripts (311 scripts decoded in total).
  - 234 have source `false` and live `true`. These are the flags-ON set.
  - 45 have source `true` and live `true` (listed below).
  - 91 have source `false` and live `false`. This includes the must-stay-OFF set.
  - 0 have source `true` and live `false`.
  - 0 are in the pack but not in source, and 0 are in source but not in the pack.
- Pack: `index.pck`, Godot 4.4.1, pack format 2, GDScript tokenizer version 100, sha256 `b5050e421cf7cd0a4167d3eb569a622ad78eae8f4ed014a0e8a50f11a01306d0`.
  The build is dated 2026-09-07.
- Source compared: `origin/main` at `f305400`. `cube_sphere.gd` and `remote_bridge.gd` last changed in
  `37c38db` (2026-09-07, "FP_OR_COMMIT_PARTIAL finish"). Comparing against that commit gives identical
  records. **All 370 consts sit on the same line numbers in the pack as in the source.** The pack has
  exactly the same 311 scripts as the source tree. So the export was built from this source revision
  with in-place line flips.

### Why 234 and not "about 217"

The pipeline notes give about 217 names for the script's `CS_FLAGS` string. Further families were added
per A/B arm through the `CLITE_FLAGS` environment variable. The de-orbit stack from PR #83 is an example:
`FP_SHELL_STAGE_REEMIT`, `FP_SHELL_PREWARM_DESCENT`, `FP_SHELL_SECTOR_FINE`, `FP_FARRING_EMIT_ACCUM`,
`FP_SV2_SHELL_YIELD`, `FP_STRUCT_NEAR_HOLD` and `FP_STRUCT_BAKE_STAGE`. All seven are ON in the pack. The
pack records only the union of the two lists, so it cannot tell which flags came from `CS_FLAGS` and
which from `CLITE_FLAGS`. `live-flags.json` holds that union, which is the actual served world.

Of the surface-entry PR #84 flags, `FP_OR_COMMIT_PARTIAL` is ON. `FP_OR_FLIP_STAGE` and
`FP_OR_WORKER_DECODE` are OFF in this build.

## How it was derived (evidence)

1. **PCK directory.** The header is `GDPC`, format 2, version 4.4.1, flags 0, then `file_base` and 697
   entries (path, offset, size, md5, flags). Offsets are relative to `file_base`. **Every extracted file
   matches its recorded md5**, which proves the offset base is right.
2. **GDSC container.** Each file has the magic `GDSC`, the tokenizer version (100) and the decompressed
   size, followed by a zstd body. libzstd is called through ctypes. All 311 scripts are compressed.
3. **Body layout.** This was established and then checked on every script. The parser raises an error
   on any mismatch.
   - 5 u32 counts: identifiers, constants, line entries, a reserved word that is always 0, tokens.
   - Identifiers: UTF-32 code points, each byte XOR `0xB6`.
   - Constants: `encode_variant` values.
   - Line table and column table.
   - Tokens: a u32 with `0x80` set on the first byte (or a single byte), then a u32 end line.

   The stream must end exactly at the end of the buffer. Every identifier and constant index must be in
   range, and every line-table entry must point inside the stream. `NEWLINE`/`INDENT`/`DEDENT` are not
   stored; top level means "the token starts a line at column 1".
4. **Token-type enum anchors**, read against known source lines:
   - line 1 `extends RefCounted` gives `EXTENDS`=59.
   - line 2 `class_name CubeSphere` gives `CLASS_NAME`=56.
   - line 21 `const QUARTER_PI := PI / 4.0` gives `TK_CONST`=57, `COLON`=83, `EQUAL`=28, `CONST_PI`=90,
     `SLASH`=26, `LITERAL`=3.
5. **How `true`/`false` are encoded.** A bool is a `LITERAL` token whose payload indexes the constant
   table. That entry is a Variant of type 1 (BOOL) whose u32 payload is 0 or 1. The constant table is
   deduplicated, so each script holds at most one `false` and one `true` entry, and every flag points at
   one of the two:

   | Script | false entry (raw bytes) | true entry (raw bytes) |
   |---|---|---|
   | `cube_sphere.gdc` | const[4] = `01 00 00 00 00 00 00 00` | const[5] = `01 00 00 00 01 00 00 00` |
   | `remote_bridge.gdc` | const[54] (false) | const[2] (true) |

   Example tokens:
   - `FACETED` (line 47): `CONST IDENT COLON EQUAL LITERAL#5` (true).
   - `FP_CLOUDS` (line 4032): `... LITERAL#4` (false).
   - `CONTROL_ENABLED` (line 63): `... LITERAL#2` (true).
6. **Control checks** (`extract_pck_flags.py PACK --self-test` passes):
   - `FP_RADIAL_DATUM`, `FP_CLOUDS`, `FP_PRECIP`, `FP_STORMS` and `FP_TIER_DEPTH_BIAS` all decode
     `false`.
   - `CONTROL_ENABLED` decodes `true`.

   There is also independent evidence. Constants enter the table in order of first use. In
   `remote_bridge.gdc` the `true` constant comes at index 2, near the top of the file, and `false` only
   at index 54. That order only works if line 63 already said `true` when the file was exported.
7. **Earlier design doc.** `docs/COSMOS-LOD-LADDER-SMOOTH-DESIGN.md` §1 is an older snapshot of
   CS_FLAGS.
   - It lists as ON: `FP_M2_LOD`, `FP_NB_FULLRES`, `FP_BLOCKY_FARRING`, `FP_FARRING_FULL_COVER`,
     `FP_FARRING_UNCOVERED_TRUE`, `FP_FARRING_ACTIVE_NOBLACK`, `FP_SMOOTH_V2`, `FP_SMOOTH_V2_REACH`,
     `FP_ORBIT_RELIEF` and `FP_CTRL_ADAPTIVE`. All are ON in the pack.
   - It lists as OFF: `FP_BLOCK_LOD*`, `FP_FAR_SMOOTH`, `FP_MID_DENSE`, `FP_FARRING_LIMB_DENSE`,
     `FP_SMOOTH_V2_EXCL_BLKLOD` and `FP_SMOOTH_V2_LIT`. All are OFF in the pack.

## Flags ON in the live build, by theme

The themes follow `docs/knowhow/agent-notes/voxiverse-<name>.md`, and review notes live under
`docs/knowhow/agent-reviews/`. Within each theme, flags are in source order. Nine flags have no mention in
the imported notes: `FP_DATUM_EDGE_WELD`, `FP_FAR_TREES_CARDS`, `FP_FAR_TREES_MESH`, `FP_FAR_TREES_SNOW`,
`FP_PREFILL_112`, `FP_VEL_PREDICT`, `SN_NO_CEILING_BOUNCE`, `SN_ATMO_BRAKING` and `FP_COAST_BATCH`. The
pack still shows each of them as ON.

### Faceted planet core and near world (12)

Notes: faceted-planet, gen-convoy-mechanism, near-radius-diet, atlas-staging, climate-w0-w4, slope-material-design.

`FACETED` `FP_M1_POOL` `FP_NB_FULLRES` `FP_NB_WELD` `FP_M2_LOD` `FP_BULK_UNDERGROUND` `FP_CPPGEN` `FP_CLIMATE_BIOMES` `FP_NO_NEAR_LOD` `FP_NEAR_RADIUS_DIET` `FP_ATLAS_MATERIAL` `FP_SLOPE_ALL_MATERIALS`

### Far ring, shell re-emit and tier envelope (22)

Notes: orbit-perf-farring-churn, deorbit-shell-reemit, facet-seams, live-review-2026-07-20, lod-texture, terminator-sun-fix.

`FP_FARRING_FAST_REBUILD` `FP_FARRING_ASYNC_REBUILD` `FP_FARRING_BULK_EMIT` `FP_FARRING_SECTORS` `FP_FARRING_EMIT_ACCUM` `FP_SHELL_STAGE_REEMIT` `FP_SHELL_PREWARM_DESCENT` `FP_SHELL_SECTOR_FINE` `FP_FARRING_FULL_COVER` `FP_SHELL_WELD` `FP_DATUM_BAKE` `FP_DATUM_EDGE_WELD` `FP_TIER_STICKY_BACKSTOP` `FP_TIER_ENVELOPE` `FP_TIER_WARM_CONVERGE` `FP_ENV_ALL` `FP_ENV_WARM_ASYNC` `FP_ENV_FALLBACK_EMIT` `FP_ENV_FLOORED_ASYNC` `FP_FARRING_ACTIVE_NOBLACK` `FP_FARRING_UNCOVERED_TRUE` `FP_FARRING_APPLIED_COVER`

### Far skin: textures, block colour, tile bake (16)

Notes: block-lod-design, far-skin-block-color, cpp-tile-bake-block-exact, textured-lod-design, far-render-overhaul, far-lod-ladder-defects.

`FP_FACET_TEX` `FP_SKIN_TEXTURE_MEAN` `FP_SKIN_BLOCK_EXACT` `FP_FAR_COLOR_UNIFIED` `FP_SKIN_BLOCK_COLOR` `FP_BLOCKY_FARRING` `FP_BLOCKY_TEX` `FP_BAND_BLOCK_MAP` `FP_SKIN_FLATCOLOR` `FP_BAND_META_TEX` `FP_PLANET_MAP` `FP_CPP_TILE_BAKE` `FP_FT_SKIN_CHOP` `FP_SKIN_SHADE_PACK` `FP_FARLOD_QUALITY` `FP_SKIN_SSE`

### Smooth far geometry, applied cover and background prebake (22)

Notes: far-smooth-geometry, lod-ladder-smooth, lod-ladder-midband, far-height-72-73, bg-prebake-design, prebake-pacing-p7, grassbase-backstop, mesa-viewband.

`FP_SMOOTH_V2_PACE` `FP_SV2_SHELL_YIELD` `FP_SMOOTH_V2_ASYNC_MERGE` `FP_FINE_BAKE_SURFACE_PAUSE` `FP_BG_PREBAKE` `FP_BG_PREBAKE_CPP` `FP_BG_OFFSURF_CALM` `FP_PREBAKE_COAST_CAP` `FP_PREBAKE_VIEW_SCOPE` `FP_SMOOTH_V2` `FP_SMOOTH_V2_REACH` `FP_M2_SMOOTH_DEFER` `FP_M2_EDGE_DIST` `FP_SMOOTH_V2_NEARFILL` `FP_V2_NEARFILL_UNSINK` `FP_V2_EDGE_APRON` `FP_FAR_TERMINATOR_WELD` `FP_VIEWER_RELIEF_REACH` `FP_APPLIED_PROBE_CALM` `FP_UNSINK_DRIFT_CALM` `FP_APPLIED_PROBE_SLAB` `FP_APPLIED_VIEW_BAND`

### Orbit relief (planet seen from orbit) (4)

Notes: orbit-relief-g3, far-geometry-prebake, far-near-coverage; PR #84 body.

`FP_GLOBAL_RELIEF_DATA` `FP_ORBIT_RELIEF` `FP_OR_COMMIT_PARTIAL` `FP_ORBIT_RELIEF_SURFACE_HIDE`

### Far trees (18)

Notes: far-trees-design, fartree-align, fartree-frame, fartree-polish132, far-trees-colorfix, forest-fps-limiter.

`FP_FAR_TREES` `FP_FAR_TREES_CARDS` `FP_FAR_TREES_MESH` `FP_FAR_TREES_FADE` `FP_FAR_TREES_SNOW` `FP_FAR_TREES_COLORFIX` `FP_FAR_TREES_DELTA` `FP_FT_MOVE_HYST` `FP_FAR_TREES_ALIGN` `FP_FAR_TREES_NEARCULL` `FP_FT_FRAME_WELD` `FP_FT_XFADE_COMPL` `FP_FT_NEAR_GUARD` `FP_FT_TEXMEAN_COLOR` `FP_FT_STALE_REBUILD` `FP_FT_SHELL_BAND` `FP_FT_SHELL_FLIP_CALM` `FP_LEAF_CUTOUT`

### Structures and villages (far cards, LOD skin handoff) (21)

Notes: structures-design, village-bake-memo, object-lod, ground-walk-perf; codex-*-review notes, PR #84 body.

`FP_OBJ_LOD` `FP_OBJ_LOD_DEBRIS` `FP_STRUCT_DETECT` `FP_STRUCT_FAR` `FP_STRUCT_NEAR_GUARD` `FP_STRUCT_GEN` `FP_STRUCT_LOD` `FP_STRUCT_COARSE_FAR` `FP_STRUCT_SHELL_BAND` `FP_STRUCT_NEAR_HOLD` `FP_STRUCT_BAKE_STAGE` `FP_STRUCT_GATE_MEMO` `FP_STRUCT_WALK_CALM` `FP_STRUCT_HANDOFF_HYST` `FP_STRUCT_REG_EPOCH` `FP_STRUCT_CARDS` `FP_STRUCT_CARD_ALT_BAND` `FP_SKIN_READY_GATE` `FP_SKIN_HANDOFF_PREWARM` `FP_STRUCT_CARD_STAGE` `FP_STRUCT_EDIT_DEBOUNCE`

### Loading, streaming and frame pacing (25)

Notes: fast-load-design, fall-stream-pacing, summit-stream-priority, sharp-slope-manifest-stale, unattended-perf-2026-07-21, forest-snow-warmskip, web-perf-architecture.

`FP_DEM_DEFER` `FP_LOAD_DEFER` `FP_STREAM_TICK_ONCE` `FP_JOB_LANE` `FP_TEX_BAKE_WORKER` `FP_CTRL_ADAPTIVE` `FP_CTRL_FLOOR_VSYNC` `FP_FIXED_FRAME` `FP_PREFILL_112` `FP_VEL_PREDICT` `FP_INFLIGHT_GATE` `FP_LOAD_RAMP` `FP_BOOT_ASYNC` `FP_MANIFEST_SLICE` `FP_SLOPE_MANIFEST_HEAL` `FP_LANDING_STREAM_KICK` `FP_APPROACH_ANCHOR` `FP_SUMMIT_STREAM` `FP_SNOW_SKIP_AIRBORNE` `FP_WARM_TRUE_BUDGET` `FP_SNOW_SLICED` `FP_SNOW_PRECIP_GATE` `FP_ALT_REGIME` `FP_EDIT_FID_INDEX` `FP_SHRINK_PACED`

### Orbit, space shell and flight modes (17)

Notes: orbital-shell, orbit-real-space, orbital-o1o4-staging, orbit-decay, unattended-perf-2026-07-21.

`ORBITAL_SKY` `FP_M3_ORBIT` `FP_SCALED_BODY` `FP_SHELL_CAMERA_SET` `FP_SHELL_SURF_CAP` `FP_SHELL_PREWARM` `FP_SHELL_ORBIT_IDLE` `FP_SHELL_FALL_HOLD` `FP_SHELL_CLIMB_NO_CHURN` `CRUISE_MODE` `FP_CRUISE_LOOKDIR` `ORBIT_ATTITUDE` `ORBIT_6DOF_FLY` `ORBIT_LAND_RECOVER` `ORBIT_COAST` `FP_COAST_FULL_DT` `FP_COAST_BATCH`

### Sky, sun, atmosphere and lighting (31)

Notes: atmo-sky-design, atmo2-design, overnight-2026-07-19, terminator-sun-fix, flight-fallthrough-sun, night-terrain-centre, border-shade-weld.

`FP_SHADE_UNIFIED` `FP_TWILIGHT_AMBIENT` `ATMO_VISUAL_RAMP` `SN_SUN_OCCLUSION` `SKY_MOONSHINE` `SKY_MOONSHINE_LIGHT` `SKY_SCATTER_RAMP` `FP_SKY_DSKY_R` `FP_SKY_DSKY_ALT` `FP_SKY_PLANET_CENTRE` `FP_HUD_VACUUM_TEMP` `FP_SEASONS` `FP_SN3_MAIN_LIVE` `FP_SKY_PLANET_OCCLUDE` `FP_SUN_PRESENCE` `FP_TERM_SUN_CONT` `FP_ATMO_SPACE_ZERO` `FP_LIGHT_ABSOLUTE` `FP_SHELL_ABSOLUTE` `FP_ATMO_SHELL` `FP_SUN_PATHLIGHT` `FP_SUN_DISC_WARM` `FP_SUN_APPARENT` `FP_FOG_ARBITER` `FP_MOON_PRESENCE` `FP_ATMO_PATH_SHELL` `FP_ATMO_GROUND_BUDGET` `FP_ATMO_RIM` `FP_NEAR_DAYLIGHT` `FP_NIGHT_TERRAIN_CENTRE` `FP_BORDER_SHADE_WELD`

### Navigation, facet crossing and floor welds (19)

Notes: spacenav-design, facet-seams, fallthrough-loc-bug, floor-surface-root-cause, seam-slope-weld, seam-mask-fallthru-law, upvector-strip-tilt.

`SN_NAV_MODES` `SN_DEVNAV` `FP_DEVNAV_GUIDE_FRAME` `SN_HUD_NAV` `FP_CROSS_KEEP_HEADING` `FP_TWIST_FRAME_AWARE` `FP_CROSS_CORNER_COMMIT` `SN_NO_CEILING_BOUNCE` `SN_ATMO_BRAKING` `SN_FOFF_RADIAL_FALL` `FP_DEV_TP_REFRAME` `FP_TP_FLOOR_WELD` `FP_DESCENT_FACET_RESYNC` `FP_QUERY_FRAME_GUARD` `FP_FLOOR_SURFACE_WELD` `FP_SEAM_SLOPE_WELD` `FP_FALLTHRU_PROBE` `FP_UPVECTOR_FACET_HEAL` `FP_CAMERA_RADIAL_LEVEL`

### Physics, falling and tree chopping (15)

Notes: tree-bugs-rootcause, deorbit-phys-fix, motion-phys-root, move-probe-cache, fall-instrumentation, physics-scale.

`FP_BIOME_SPACE_FIX` `FP_GRAV_BOX_COVER` `FP_CHOP_COLLIDER_CARVE` `FP_CHOP_DEBRIS_CALM` `FP_LOOSE_BODY_ANALYTIC_FLOOR` `FP_FREEFALL_RAILS` `FP_FALL_ATT_GATE` `FP_FLOOR_BOUNDED` `FP_FLOOR_MEMO` `FP_MOVE_PROBE_CACHE` `FP_ANALYTIC_COL_MEMO` `FP_ENV_FALL_HOLD` `FP_LAND_RAMP_HOLD` `FP_ENV_RESUME_PACED` `FP_TREEPHYS_BOUND`

### Telemetry and agent control (12)

Notes: agent-control-design, agent-control-initiative, agent-autonomy, fall-instrumentation; remote_bridge.gd.

`FP_TELEM_FRAME_DECOMP` `FP_FALL_TIMING` `FP_WORST_FRAME_ATTR` `FP_WF_TIER_ATTR` `FP_TELEM_10HZ` `FP_TELEM_LITE` `FP_AGENT_POSE` `FP_AGENT_QUERY` `FP_AGENT_ACT` `FP_AGENT_NAV` `FP_AGENT_SKILL` `CONTROL_ENABLED`

## Must stay OFF

`FP_RADIAL_DATUM` `FP_CLOUDS` `FP_PRECIP` `FP_STORMS` `FP_TIER_DEPTH_BIAS`. These are listed in
`live-flags.json` under `must_stay_off`, and `deploy_cheats.sh` checks that they stay false.

Every other `cube_sphere.gd` flag that is OFF in the live build is listed here. `deploy_cheats.sh` also
checks that each one is still false, unless it is named in `CLITE_FLAGS`:

`FACETED_SPIKE` `FACET_TWIST` `FP_R0` `FP_COLBULK` `FP_STAMP` `FP_GEN_PROFS_TLS` `FP_GEN_ALLOC_PROBE` `FP_GEN_LOCK_PROBE` `FP_FULLRES_256` `FP_SHELL_ASCENT_LAZY` `FP_OFFSURF_MAT_PREWARM` `FP_FARRING_LIMB_DENSE` `FP_RADIAL_DATUM` `FP_TIER_DEPTH_BIAS` `FP_MID_DENSE` `FP_SKIN_TIER` `FP_BLOCK_DETAIL` `FP_DETAIL_GRID` `FP_CPP_FINE_BAKE` `FP_OBJ_LOD_SPACE` `FP_CPP_SMOOTH_BAKE` `FP_SKIN_RELIEF_SHADE` `FP_RELIEF_REEMIT` `FP_OR_FLIP_STAGE` `FP_OR_WORKER_DECODE` `FP_FT_WALK_CALM` `FP_FT_NEARCULL_XFADE` `FP_FT_STALE_PARKED` `FP_STRUCT_SHADER_LITE` `FP_STRUCT_CULL_BACK` `FP_STRUCT_VIS_ABTEST` `FP_STRUCT_XFADE` `FP_FAR_SMOOTH` `FP_FAR_SMOOTH_OVERHANG` `FP_SMOOTH_NORMAL_LIT` `FP_SMOOTH_RIM` `FP_SMOOTH_STICKY` `FP_SMOOTH_MESH_INC` `FP_SMOOTH_SKIN_SLOT` `FP_SMOOTH_HORIZON_COVER` `FP_SMOOTH_IDLE` `FP_SHELL_SNAP_GEN` `FP_SMOOTH_TXN` `FP_SLOT_INDIRECT` `FP_SMOOTH_WELD_REFRESH` `FP_SMOOTH_SNAP_SELFHEAL` `FP_RING_QUIESCE` `FP_ENV_DEMAND_DISC` `FP_WARM_EMIT_SPLIT` `FP_RIM_NEAR_WELD` `FP_SMOOTH_SLOT_MESH` `FP_SMOOTH_TILE_SURF` `FP_RIM_CHEAP` `FP_SMOOTH_GROW_PACE` `FP_SMOOTH_V2_LIT` `FP_SMOOTH_V2_EXCL_BLKLOD` `FP_BAND_SHOT` `FP_FARRING_CULL_COVERED` `FP_FARRING_LEVEL` `FP_BLOCK_LOD` `FP_BLOCK_LOD_RINGS` `FP_BLOCK_LOD_GLOBAL` `BLOCK_LOD_EXPANDED_ENABLED` `FP_BLOCK_LOD_ORBIT` `FP_FACET_TEX_CLOSEUP` `FP_PAGES_SHOT` `FP_WALK_STEP_GATE` `FP_REENTRY_BACKLOG_GATE` `FP_REENTRY_REGROW_DEFER` `SHELL_TERMINATOR_TINT` `FP_BODY_LOD` `FP_MOON_RING` `FP_SUN_GLOW` `FP_CLIMATE_GRID` `FP_CLOUDS` `FP_PRECIP` `FP_STORMS` `FP_WEATHER_THREAD` `FP_FALL_CAMFAR_HOLD` `FP_FALL_ATMO_THROTTLE` `FP_FALL_RING_HOLD` `FP_FALL_SHELL_OFF` `FP_FALL_SCALE_FREEZE` `M5C_CORNER` `MULTI_BODY` `SOI_SWAP` `M5_RENDER` `M5_REAL` `DEV_HIDE_NEAR`

Outside `cube_sphere.gd`, two consts are false in both source and live: `NEAR_COVER_ENABLED` in
`module_world.gd`, and `LIVE_RADIAL_DATUM` in the `verify_seam_slope_weld.gd` tool.

## Consts that default to true and stay true (45)

- `cube_sphere.gd` (7): `FP_NEIGHBOUR_SEAM_POLISH`, `BG_VIEWFIRST`, `POOL_CROSSING_PREGEN`,
  `FP_FALL_FREEZE_CAM`, `FP_FALL_FREEZE_RING`, `M5C_TELEPORT`, `FLAT_WORLD`.
- `remote_bridge.gd`: `CAPTURE_THREADED_ENCODE`.
- World scripts:
  - `far_terrain.gd`: `ENABLED`, `HANDOFF_ENABLED`.
  - `terrain_config.gd`: `SMOOTHING_ENABLED`, `DOWNWARD_REACH_CLAMP_ENABLED`.
  - `facet_far_ring.gd`: `ENABLED`.
  - `cosmos_border_overlay.gd`: `DEV_BORDERS`.
  - `world_manager.gd`: `CORNER_EDIT_LOCK`.
- Verify tools (30): the `LIVE_*` mirrors in `verify_applied_band`, `verify_applied_slab`,
  `verify_far_trees`, `verify_leaf_cutout`, `verify_lod_ladder` and `verify_seam_slope_weld`, plus
  `CORNER_CANONICAL_FIX` in `verify_cosmos_seam`.

The deploy script does not touch any of these.

## Recreating the live world

```bash
scripts/deploy_cheats.sh --dry-run    # flip + verify in a temp copy of HEAD; prints counts
scripts/deploy_cheats.sh              # flip, verify, scripts/export-web.sh, restore the two files
scripts/deploy_cheats.sh --deploy     # same, then scripts/deploy.sh --no-build
CLITE_FLAGS="FP_X FP_Y" scripts/deploy_cheats.sh   # an A/B arm with extra cube_sphere.gd flags
```

A real run first refuses if `cube_sphere.gd` or `remote_bridge.gd` has uncommitted changes. The restore
step is a `git checkout --` and would wipe them (see `agent-notes/voxiverse-deploy-cheats-cs-rb-revert-trap.md`).
After the export it scans the log for GDScript parse errors, because the Godot export does not fail on
them, and it checks the HTML shell markers.

A dry run on this tree gives:
- 234 flags ON: 233 changed lines in `cube_sphere.gd` and 1 in `remote_bridge.gd`.
- 89 live-OFF consts in those two files are still false.
- Whole-file match against the pack: 331/331 consts.

It fails as it should when `CLITE_FLAGS=FP_CLOUDS` is set (must-stay-OFF) or an unknown flag is named.

To regenerate the JSON from the pack and check that it reproduces byte for byte:

```bash
python3 docs/knowhow/live-flags/extract_pck_flags.py path/to/index.pck --self-test
python3 docs/knowhow/live-flags/extract_pck_flags.py path/to/index.pck \
    --git-repo . --git-rev f305400 --json docs/knowhow/live-flags/live-flags.json
```

## Limitations

- **Scope of the recovery.** Only top-level consts whose value is a plain `true`/`false` literal are
  recovered (`const N := b`, `const N = b`, `const N: bool = b`). Consts computed from other flags, flags
  inside inner classes, and `var` toggles are not covered. Scanning the source finds no other
  `const ... true|false` lines except four where the word appears in a comment.
- **Not covered.** The engine side is not covered: `index.wasm`, `docker/engine/versions.env`, build knobs
  such as `WEB_ALLOC_PROBE`, and the engine patches. Project settings and resources in the pack are not
  compared either. This file covers the GDScript flag layer only.
- **Point in time.** This is the last archived build (2026-09-07). An arm deployed after it would not
  appear here. The CS_FLAGS/CLITE_FLAGS split cannot be recovered, only their union.
- **Other Godot versions.** The token-type enum and layout are pinned to Godot 4.4.x (tokenizer version
  100). A different engine version needs the anchors in step 4 checked again. The parser refuses unknown
  pack versions and stops on any structural mismatch.
- **Changed source.** Re-applying the list to a newer source tree assumes the flag names still mean the
  same thing. The dry run fails on any renamed or removed flag.
