# COSMOS FOREST-FPS — the ~30 fps residual: root cause + fix design

**Task #119.** The warm forest (facet 1754, pos ≈ (8665,10,14212), fully warmed: fm_baked
3456/3456, tex_baked 3456) sits at fps p50 ≈ 30 and will not climb, after BOTH prior
suspects were removed (FP_LEAF_CUTOUT V2 restored draws to 171; FP_SNOW_PRECIP_GATE cut
snow_ms to ~0.3). This doc identifies the real limiter with telemetry + source evidence
and designs a byte-off fix. **Design only — nothing deployed.**

---

## 1. The measurement set

`tools/remote-bridge/results/telemetry.jsonl`, 3,642 windows (0.25 s each,
`remote_bridge.gd:88`) over ~920 s, **player perfectly stationary** the whole time
(1 unique `pos`, 1 unique camera orientation), scene fully warm and static
(`draws` 171–179, `prims` 709,461 ± 2, `objects` 117 — all constant).

| series | p10 | p50 | p90 | max |
|---|---|---|---|---|
| fps | 22.2 | **30.1** | 41.5 | 46.9 |
| min_fps | 9.4 | 14.6 | 28.0 | 36.7 |
| worst_ms (per window) | 35.7 | **68.5** | 105.8 | 230 |
| phys_ms | 7.5 | 9.4 | 15.2 | 86.9 |
| every instrumented subsystem (snow, ctrl, env, vt_*, smooth_*, main_commit) | — | **≈ 0.02–0.4 ms** | — | — |

Two facts frame everything:

1. **fps is continuous 22→47, not quantized 30/20/15** → this is NOT a vsync-ladder
   lock (candidate 3 in the brief is out).
2. **A static scene with constant draws/prims oscillating 7→47 fps** → the variance is
   main-thread CPU, not GPU load (a GPU-bound constant scene gives flat fps).

### The stall signature is BIMODAL and event-like

`worst_ms` histogram over capture-free windows (cap=0; the scheduled 2 s frame captures
`remote_bridge.gd:96` are marked and excluded — cap=1 windows are only 82 of 2,841 and
the bimodality survives without them):

```
mode 1 (clean):  30–50 ms   ~1,000 windows   mean 39.8 ms
mode 2 (stall):  80–110 ms  ~  950 windows   mean 97.3 ms   → Δ ≈ 57.6 ms
```

A discrete **~57 ms extra stall** lands in about half of all 0.25 s windows
(1.55 events/s), in **bursts of consecutive windows** (dominant inter-event gap = one
window) alternating with clean stretches of seconds. Not a fixed-period timer — a
bistable regime.

---

## 2. ROOT CAUSE — the FacetFarTrees 250 ms full rebuild, PWM-gated by the stream controller

### 2.1 The smoking-gun correlation

`stream_credit` (the StreamLoadController admission credit, in every telemetry window)
vs stall (worst_ms > 75):

| | credit > 0 | credit = 0 |
|---|---|---|
| stall | 965 | 634 |
| no stall | 35 | 2,008 |

**P(stall | credit>0) = 0.96 — P(stall | credit=0) = 0.24.**
Credit *precedes* the stall (lag-1 P = 0.84), and `corr(fps, stream_credit) = −0.35`:
frames are *worse when credit flows*. With the player stationary and the near field
fully meshed, there is exactly **one** perpetual credit-gated consumer: the far-trees
tier step.

### 2.2 The mechanism (source)

`FacetFarRing._process` steps the tier every frame
(`godot/src/world/facet_far_ring.gd:1334-1335`):

```gdscript
if _far_trees != null:
    _far_trees.step(_load_settled, _stream_credit_ok, _ft_cam)
```

`FacetFarTrees.step` (`godot/src/world/facet_far_trees.gd:442-478`):

- `:452` — `if not settled or not credit_ok: return` ← **the credit gate**
- `:455` — `if now - _last_step_ms < CubeSphere.FAR_TREES_STEP_MS: return`
  with `FAR_TREES_STEP_MS := 250` (`cube_sphere.gd:897`) ← fires every 0.25 s,
  **exactly the telemetry window** — hence "a stall in every window where it runs"
- `:465` — `_wanted_facets(cam_abs)` (`:567-590`): scans **all 3,456 Earth facets**
  (6·K², K=24 — matches fm_want 3456) computing `cell_dir` + distance each, then
  `sort_custom` with a **lambda** (the recorded GDScript-closure trap) — every step
- `:471-474` — `_rebuild_meshes(...)` + `_rebuild_cards(...)` are called
  **UNCONDITIONALLY — there is no "anything changed?" gate anywhere in the tier.**

Each rebuild pass (`_rebuild_cards :624-680`, `_rebuild_meshes :712-780`):

- walks **every record of every cached facet** — LRU capacity
  `FAR_TREES_CACHE_FACETS := 64` (`cube_sphere.gd:896`) × ~600–1,200 trees/forest-facet
  ≈ **40–75 k records, walked twice** (once per rung), per-record sqrt + fade +
  `_is_chopped` (`:420-423`: a **Callable into WorldManager + a Vector3i alloc per
  in-band record** — live under FP_FAR_TREES_FADE)
- reallocates the full buffers every time: cards `8192 × 16` floats (512 KB) + meshes
  6 species × `512 × 20` floats (245 KB with COLORFIX) — ~0.76 MB of PackedFloat32Array
  churn through the shared WASM allocator (the dlmalloc-convoy class), then
- `MultiMesh.set_buffer` re-uploads all of it to the GPU.

On web/WASM GDScript at ~1 µs+/record this is **~50–70 ms of main thread — matching the
measured Δ ≈ 57.6 ms** — spent recomputing a result that is bit-identical to the
previous one, because with a static camera, unchanged cache, and unchanged edits every
input to the rebuild is unchanged.

### 2.3 The limit cycle (why fps oscillates instead of just sitting lower)

`StreamLoadController` (`godot/src/world/stream_load_controller.gd:132-141`) compares
`frame_worst_ema` to the adaptive setpoint (`clamp(floor_p10 × margin, 18, 45)`;
measured live: setpoint 37.7–43.4, floor_p10 19.4):

1. rebuild fires → ~97 ms worst frames → `frame_worst_ema` climbs over the setpoint →
   **overload → credit cut to 0**
2. `step()` `:452` gates the tier **off** → clean ~40 ms windows → ema recovers →
   **credit restored**
3. → goto 1.

The load controller — built to protect the frame — ends up **PWM-modulating the very
subsystem that is stalling it**, producing the observed bursts, the fps 22↔45
oscillation around p50 30, min_fps 6–11, and ~8 "hitches"/s (HITCH_MS := 33,
`remote_bridge.gd:118`, so at a ~33 ms median frame the counter partly re-states the
median). This is the same feedback-trap class as obs-2, one layer further out.

### 2.4 Exonerated candidates (brief items 1–6, verdicts)

| candidate | verdict | evidence |
|---|---|---|
| far-trees **rebuild** (item 1) | **GUILTY — the stall** | §2.1–2.3. The `farring build_ms 1093 / verts 489k` event is a different, rare async far-ring rebuild — zero `type:"farring"` events in this whole capture; red herring. |
| gl_compat draw-submit CPU (item 2) | not the limiter | draws constant 171–179 across fps 7→47; corr(fps,draws) = −0.03 |
| vsync 30-lock (item 3) | **falsified** | fps continuous 22–47, no 30/20/15 quantization |
| WASM allocator convoy (item 4) | contributory, not primary | the ~0.76 MB/step buffer churn in §2.2 IS an allocator load, but it rides the rebuild — same fix removes it |
| phys_ms spikes (item 5) | secondary (floor, §3) | p50 9.4 ms steady; the 27–92 spikes are rare (11 samples); the 8.4→14.1 ms fast-vs-slow-window delta is 60 Hz tick backlog (more ticks per slow frame), an amplifier not a cause |
| env / smooth_v2 residual (item 6) | exonerated | env_converge 0.02 ms; smooth_v2_commit_ms 21.3 is a LATCHED last-commit value (constant all capture); smooth_drive/step/commit all 0 |

---

## 3. The honest frame budget (what sums to ~33 ms)

**Clean mode** (credit=0 stretches — the natural "tree-rebuild off" A/B already in the
data): avg frame ≈ 24 ms (fps ≈ 41.5 p90, 46.9 max), worst ≈ 36–40 ms.

| component | ms | evidence |
|---|---|---|
| physics ticks (60 Hz × ~1.4 ticks/frame × ~5–6 ms/tick) | ~8.4 | phys_ms fast-window p50; each tick runs the full `update_streaming` tail — skin update + candidate-fid array + Callable plumbing + 4× block-LOD `place` — with **no stationary early-out** (`world_manager.gd:1155-1264`, called per tick from `player.gd:822`) |
| instrumented scripts (snow+ctrl+env+vt+weather poll) | ~1 | telemetry |
| uninstrumented per-frame scripts + render submit + rAF/GPU (709 k prims incl. the 489 k-vert FULL_COVER far-ring backstop) + browser compositor | ~14 (residual) | floor_p10 = 19.4 ms is the controller's own long-window best-frame measure; not decomposable from this capture — see A/B probes §6.3 |
| **clean-mode total** | **~24** | fps ≈ 42 |
| **+ far-trees rebuild, amortized** (~57 ms × up to 4/s under PWM) | **~+9 avg, +57 on the stall frame** | §2 |
| **stall-mode total** | **~33 → p50 30 fps, min_fps 9–14** | matches the series |

---

## 4. THE FIX — `FP_FAR_TREES_DELTA`: rebuild on change, not on timer

### 4.1 Principle

Every input to `_rebuild_meshes` + `_rebuild_cards` is: camera position, the record
cache, the edit overlay (chop filter), and the off-surface latch. If none changed since
the last completed rebuild, the output buffers are **bit-identical** — skipping the
rebuild is **pixel-identical by construction**. (Fades are functions of
`dist(cam, tree)` only — `card_fade(d, hue)` / `mesh_fade(d)` `:308,:329` — so a static
camera means static fades; nothing in the tier is time-animated on the CPU side.)

### 4.2 Injection site (one function, ~20 lines)

`FacetFarTrees.step` (`facet_far_trees.gd`), immediately after the `:455-457` rate cap:

```gdscript
# FP_FAR_TREES_DELTA: skip the (unconditionally re-run today) full instance-set rebuild
# when NOTHING it reads has changed — camera still, cache epoch unchanged, edits
# unchanged, no offsurf flip. Output would be bit-identical ⇒ skipping is pixel-identical.
if CubeSphere.FP_FAR_TREES_DELTA and not _rebuild_inputs_changed(cam_abs):
    return
```

`_rebuild_inputs_changed(cam_abs) -> bool` returns true (and re-latches) when ANY of:

- `cam_abs.distance_to(_last_rebuild_cam) >= CubeSphere.FT_DELTA_MIN_MOVE` (2.0 blocks —
  at the band floor of 448 blocks that is a 0.26° angular error, sub-pixel at 2400)
- `_cache_epoch != _last_rebuild_cache_epoch` — a new `int` bumped in `_reap_enum`
  (`:493-497`, a facet landed) and in the dwell/LRU evictions (`_advance_dwell` /
  `_evict_lru_overflow :590-620`)
- `_edits_rev != _last_rebuild_edits_rev` — `WorldManager.edit_count()` already exists
  (`world_manager.gd:607`); plumb it exactly like the chop query
  (`world_manager.gd:414` → `facet_far_ring.gd:5150` → a new
  `set_edits_rev_query(Callable)`) so a fresh chop still invalidates within one step
- `_stale` (the COLORFIX offsurf→onsurf latch `:434-435`) — first post-flip rebuild
  always runs
- no rebuild has ever completed (`_last_rebuild_cam` unset)

Also inside the same flag: cache `_wanted_facets` (the 3,456-facet scan + lambda sort,
`:567-590`) and recompute it only when the camera has moved ≥ 64 blocks since the set
was computed OR the cache/edits epoch changed — the enumeration dispatch and dwell
advance keep running every step off the cached set, so streaming-in of missing facets
is untouched.

`planet_centre` shader-param pushes (`:460-463`) stay unconditional (two cheap uniform
sets — they must track crossings/re-anchors).

### 4.3 New constants (`cube_sphere.gd`, beside the FAR_TREES block :886-897)

```gdscript
const FP_FAR_TREES_DELTA := false   # rebuild-on-change gate for the far-trees tier
const FT_DELTA_MIN_MOVE := 2.0      # blocks of camera motion that re-arm a rebuild
const FT_DELTA_WANTED_MOVE := 64.0  # camera motion that re-computes the wanted-facet scan
```

### 4.4 Byte-off proof

The only executable change on the hot path is
`if CubeSphere.FP_FAR_TREES_DELTA and ...` — with the const `false` the `and` never
evaluates its right side, no state is written (`_rebuild_inputs_changed` latches only
when called), and every shipped line runs verbatim. The wanted-facets cache is inside
the same guard. The `set_edits_rev_query` plumb is a stored Callable, dead unless the
flag reads it. Standard pck byte-compare (flag-off export vs HEAD) in the gate.

### 4.5 Perf estimate

- Stationary/looking-around forest (the measured scenario): the entire mode-2 stall
  disappears → windows become mode-1 everywhere → **fps p50 30 → ~38-42, min_fps p50
  14.6 → ≥ 20-25**, and the controller limit cycle unwinds (credit stops PWM-ing, so
  streaming response on a subsequent walk-off improves too).
- Walking: unchanged from today (camera moves ≥ 2 blocks/250 ms at walk speed → rebuild
  fires at the shipped cadence). That residual is P1's job.

### 4.6 P1 (follow-up, only if walking-forest fps needs it): stagger + off-thread build

Same flag family (`FP_FAR_TREES_WORKER`): move the record walk + buffer fill to
`WorkerThreadPool` (the enumeration worker `:510+` already proves the
TreeGen/FacetAtlas surface is worker-safe; snapshot the chopped-cell set on the main
thread at dispatch so `_is_chopped` needs no cross-thread Callable), main thread pays
only `set_buffer`. Cheaper interim: alternate cards/meshes on successive steps (halves
the per-step walk; a 250 ms stale half-band at ≥ 448 blocks is invisible). Not designed
in detail here — P0 first, measure, then decide.

### 4.7 P2 (independent, the static floor): `FP_STREAM_IDLE_DIET`

`WorldManager.update_streaming` runs its full tail 60×/s from every physics tick
(`player.gd:822` → `world_manager.gd:1155-1264`) with no stationary guard — skin
update + `_skin_candidate_fids()` array alloc + Callable construction + 4× block-LOD
`place` every tick. Design: when `player_pos` is within 0.25 blocks of the last
processed position AND no dirty latch (edits, crossing, regime change), run the tail at
a 5 Hz heartbeat instead. Expected phys_ms p50 9.4 → ~5-6, worth ~+2-4 fps on the
clean-mode floor. Separate flag, separate A/B — do not couple to P0.

---

## 5. Gates

Extend `godot/src/tools/verify_far_trees.gd` (700 lines, 40/0 today) with a rebuild
counter exposed behind the flag (`_dbg_rebuild_count`):

- **G-FTD-1 static-skip** — flag on: two `step()`s, same cam, warm cache → exactly 1
  rebuild; card + mesh buffers of a forced 3rd rebuild bit-equal the 1st
  (`_last_buf`/`_last_mesh_bufs` compare).
- **G-FTD-2 move-rearm** — cam +3.0 blocks → rebuild fires on the next step.
- **G-FTD-3 chop-rearm** — static cam, `edit_count` bump (chop a cached tree's base
  cell) → rebuild fires and the tree is gone from the buffer.
- **G-FTD-4 cache-rearm** — a facet lands via `_reap_enum` → rebuild fires.
- **G-FTD-5 flag-off parity** — flag off: rebuild count == step count (shipped
  behaviour), plus the pck byte-compare.
- Existing 40 far-trees gates must stay green with the flag on (band handoff, caps,
  bijection are all unchanged — only rebuild *frequency* changes).

## 6. Live A/B (forest facet 1754, remote session)

1. **Baseline is already captured** (this jsonl). Deploy flag-on, same spot, ≥ 5 min
   stationary telemetry.
2. **Pass:** fps p50 ≥ 38 (target 45 stretch), min_fps p50 ≥ 20, `worst_ms` histogram
   unimodal (mode-2 mass 80–110 ms < 10% of windows), `stream_credit` no longer PWM
   (p50 > 0), hitches/s < 3.
3. **Look check:** screenshot pair (baseline vs fix) of the far tree band — identical;
   then a 100-block walk: trees fade/hand-off exactly as today (rebuild re-arms on
   motion); chop one near tree with far band visible behind → no far-ghost.
4. **Floor probes (decompose the residual ~24 ms clean frame, §3):** with the fix live,
   remote-toggle `visible=false` for 10 s each on (a) the far-ring backstop node,
   (b) the far-trees MultiMeshes, (c) halve viewport scale — the fps response
   apportions GPU vertex/fill vs main-thread cost and decides whether a P3
   (backstop decimation) is worth designing.

## 7. Honest ceiling verdict

The fix removes the dominant, evidenced stall (Δ ≈ 57 ms × up to 4/s) and should lift
the stationary forest from p50 30 to the clean-mode ~38-42. It does **not** buy 60:
the measured static floor is 19.4 ms (floor_p10) — ~8.4 ms physics-tick tax (P2
addresses ~3-4 ms of it) plus ~14 ms of render-submit + GPU + uninstrumented
per-frame scripts on a 2-effective-core web client (`os_cores` 2 vs `cores` 8,
`facet_tex_baker.gd:2109`). Reaching a stable 50-60 in a full forest needs the §6.4
probe results and likely one architectural item (backstop vertex diet or engine-level
batching) — to be decided on measurement, not designed speculatively here.
