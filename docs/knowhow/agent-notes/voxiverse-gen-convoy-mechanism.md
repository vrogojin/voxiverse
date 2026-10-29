---
name: voxiverse-gen-convoy-mechanism
description: 2026-08-30 ground-walk jerkiness Layer B (the deep root) PINNED via wf_* telemetry + 3 engine censuses = WASM dlmalloc single-global-lock convoy from WORKER-side per-block alloc storm (6-7 CoW PackedArray surface arrays/block + 1 gen vector + VoxelBuffer, ×6 workers); NOT main-thread apply (budgeted). Fix = partition allocator lock within NEVER-OOM +120MB (what mimalloc couldn't).
metadata:
  node_type: memory
  type: project
---

2026-08-30. Layer B of the ground-walk jerkiness ([[voxiverse-ground-walk-perf]] 3-layer split; user picked the deep
one) is now MECHANISM-PINNED via FP_WORST_FRAME_ATTR wf_* telemetry + 3 read-only engine censuses (peer sessions
ConvoyPatch/Cpp/Gd + 2 census subagents). Definitive chain:

ROOT = the WASM **dlmalloc single-global-lock convoy** ([[voxiverse-walk-perf-root-cause]] confirmed at engine level).
While walking, crossing into new chunks fires a gen-burst: up to 6 voxel worker threads generate+mesh simultaneously.
Per meshed 16³ block each worker does ~7-8 heap allocs: (1) the FP_CPPGEN C++ generator = just 1 std::vector<Vector4>
(voxel_generator_cosmos.cpp:2001, per-column profile); (2) the MESHER returns 6-7 fresh CoW PackedArray surface arrays
(PackedVector3Array positions/normals + PackedVector2Array uvs + PackedColorArray colors + PackedInt32Array indices +
Array, each copy_to'd = 1 heap block, voxel_mesher_blocky.cpp:1176-1213) — NOTE the mesher SCRATCH is already
thread_local+reused (get_tls_cache voxel_mesher_blocky.cpp:663, 0 steady-state scratch allocs — Zylann already arenas
that), so the 6-7 are the ESCAPING output arrays only; (3) the per-block VoxelBuffer channel alloc. ×6 workers ×many
blocks/burst = an alloc storm that saturates the ONE dlmalloc lock; the MAIN thread then stalls ~430ms/spike waiting on
that lock for ANY of its own allocations (rAF/render/GDScript). That stall IS the unmetered worst_ms.

RULED OUT (measured/censused): NOT main-thread apply — wf_vox_main mean 1/max 60 at spikes (near-zero), and the apply
IS on the main thread on web (gl-compat: is_threaded_graphics_resource_building_enabled()==false → ArrayMesh built in
apply_mesh_update, voxel_engine.cpp:87-117, a SECOND alloc wave add_surface_from_arrays re-copies the PackedArrays into
GPU buffers = web pays TWICE) BUT it's TIME-BUDGETED to main time_budget_ms=4 via TimeSpreadTaskRunner which releases
its mutex during run() — no busy-wait, no lock held during copy (time_spread_task_runner.cpp:27-78). So apply is bounded,
not the spike. Apply-slicing = OFF THE TABLE. A worker SCRATCH arena = WORTHLESS (scratch already reused).

FIX DIRECTION = PARTITION THE ALLOCATOR LOCK for the worker transient allocs (the escaping surface arrays + gen vector
+ VoxelBuffer) so 6 workers stop serializing vs each other + vs main — WITHIN the hard NEVER-OOM ≤+120MB peak (over the
~412MB dlmalloc baseline) that KILLED mimalloc (per-thread heaps → measured +398MB, arena_reserve is per-step SIZE not
total, wasm decommit is a no-op → unbounded growth; see [[voxiverse-mimalloc-arena-root]]). Candidate levers under
evaluation (ConvoyCpp writing docs/COSMOS-GEN-CONVOY-ALLOCATOR-FEASIBILITY.md): (1) -sMALLOC=emmalloc via the EXISTING
scons knob (patch godot/0002-web-malloc-option) if it's lower-contention + bounded-heap; (2) a CUSTOM bounded per-worker
free-list/arena for the hot PackedArray-backing sizes, reused per task, hard-capped (obstacle: PackedArrays are Godot CoW
types that escape to main → can their backing be pooled without patching Godot core?); (3) segregated/sharded small-object
front-end over dlmalloc. Secondary win: eliminate the web worker→main double-copy of surface data (gl-compat only).
Design lives in docs/COSMOS-GEN-CONVOY-DESIGN.md (Fable). Any C++ fix needs the ~24-min build.sh rebuild (patch drop in
docker/engine/patches/{godot,godot_voxel}/NNNN-*.patch, no manifest, order load-bearing; build knob = 0002 scons pattern,
upstream-safe default = byte-off). A/B via [[voxiverse-deploy-cheats-pipeline]] + the ~3s walk spike as the metric.

CONVERGED VERDICT (2026-08-30, ConvoyCpp feasibility docs/COSMOS-GEN-CONVOY-ALLOCATOR-FEASIBILITY.md + ConvoyGd pipeline).
ALLOCATOR-SWAP IS DEFINITIVELY DEAD (source-confirmed, do NOT revisit): mimalloc = decommit no-ops on wasm → permanent
growth (the 842MB); emmalloc = single global spinlock busy-wait (emmalloc.c:124-128), same one-lock shape as dlmalloc but
worse under storm; dlmalloc's lock is one global pthread_mutex that busy-waits the browser main thread = THE convoy. No
stock -sMALLOC gives BOTH low-contention AND bounded-heap. THE FIX = reduce lock TRAFFIC (alloc COUNT), not swap the lock.
LEAD (ConvoyCpp Option 1, cheapest, no core patch, heap goes DOWN so trivially ≤+120MB): MODULE transient-alloc DIET in
godot_voxel — thread_local the generator std::vector (voxel_generator_cosmos.cpp:2243) + recycle VoxelBuffer/task objects
+ collapse the 6-7 CoW PackedArray materializations on the worker (voxel_mesher_blocky.cpp:1184-1205: defer to the already
time-budgeted main-thread apply, or single-buffer mesh_add_surface, the module's own TODO :1173). Cuts ~8→~2 lock
acquisitions/block (~75%). ESCALATION (Option 2, only if residual stays CoW-bound): sharded small-object free-list at Godot
CORE Memory::alloc_static (new patch 0003, hard ≤4MB/thread → +96MB worst) — the only bounded way to lock-partition
PackedArray CoW backing (CowData hardcodes Memory::alloc_static→malloc, cowdata.h:313/368/424). emmalloc = ride a free
falsification/heap arm in the same build. BURST MULTIPLIER (ConvoyGd): the wf_vox_gen 1000-2186 is ×(FP_M1_POOL live
slots) — POOL_MAX_NEIGHBOURS=4 → up to 5 VoxelTerrain slots (1 active+4), FP2_LIVE_CAP=2 tightens steady to ~2-3 on a
border walk, EACH own gen+mesher, all sharing ONE VoxelViewer; the diet's benefit multiplies by the same 2-3×. STILL-OPEN
GATE = H1/H2 (ConvoyPatch): is FP_CPPGEN's C++ gen actually LIVE (module_world.gd:4101, setup accept) or silently fallen
back to GDScript gen (:4162, ~800 allocs/block)? If H2 → a NO-REBUILD GDScript alloc-diet (terrain_config.gd:1848
_quantized_targets f-Array ~512/block + :877 column_profile memo Dict ~330/block) is Stage 0, do FIRST. Plan: resolve
H1/H2 → (H2? cheap GDScript diet first) → Stage-1 module alloc-diet engine rebuild (+ emmalloc datapoint arm) → walk A/B.

H1 TRIPLE-CONFIRMED + Q2 REFINEMENT (2026-08-30, ConvoyPatch + my checks). H1 (C++ gen LIVE) is airtight 3 ways:
(a) static — all 4 VoxelGeneratorCosmos::setup() refusal gates pass for the faceted-flat cfg (noise_stack all 6 present,
cube_arid/block_ids non-empty post-bake, flat_world=true, faceted atlas valid w/ facet_r_blocks=6371>0); (b) runtime —
verify_cppgen 58/0, 0/141840 cells mismatched; (c) EMPIRICAL — gen_ct_*/gen_ms_* telemetry (emitted ONLY by the GDScript
gen's _gen_acc; C++ binds no gen_stats) are ABSENT from the entire walk capture. So NO cheap-GDScript escape; rebuild-class.
Q2 REFINES THE LEVER: the VoxelBuffer CHANNEL data (blocky = exactly 1 channel, TYPE, 8KiB/block) is ALREADY POOLED +
self-warming (VoxelMemoryPool ALLOCATOR_POOL, pow2 free-lists, recycled; malloc only when a size-class free-list is empty).
So "enlarge the channel pool" is NOT the persistent fix. THE PERSISTENT per-gen-task convoy = the UN-POOLED small objects
hitting the global dlmalloc lock every task: (a) the VoxelBuffer WRAPPER object + shared_ptr control block
(make_shared_instance<VoxelBuffer>, generate_block_task.cpp:48, ~1-2 allocs/block, freed on stream-out); (b) the C++ gen's
std::vector<Vector4> profs resize 256 (1 malloc+1 free/block, voxel_generator_cosmos.cpp:2001); (c) the GenerateBlockTask
object; (d) escaping mesh surface arrays (secondary — few mesh tasks at spike). ×2-3 FP_M1_POOL slots. FIX STAGE 1 =
thread_local the profs vector (cheap) + a per-thread free-list/recycler for the buffer-wrapper + task objects — OR, since
the churn is many small HETEROGENEOUS objects, ConvoyCpp OPTION 2 (a size-bucket small-object front-end at Godot core
Memory::alloc_static, patch 0003, hard ≤4MB/thread → +96MB worst) covers ALL of (a)-(d) generically in ONE patch —
reconsider Option 2 as the LEAD, not just escalation. CHEAP complementary lever (same build): PRE-RESERVE VoxelMemoryPool
to the peak in-flight block count so the FIRST/over-peak crossing doesn't spill channel data to dlmalloc (1000-2186 blocks
in-flight can exceed a cold pool), AND confirm nothing calls VoxelMemoryPool::clear_unused_blocks() between crossings (if it
trims, every burst re-colds = a real bug). Docs: COSMOS-GEN-CONVOY-DESIGN.md (Fable, finalizing), -ALLOCATOR-FEASIBILITY.md
(ConvoyCpp), -ALLOC-CENSUS.md (ConvoyPatch, mesh-surface count still landing).

BUILD #1 SHIPPED-TO-BUILD (2026-08-30): engine rebuilt behind 3 patches — godot/0003-web-alloc-probe (core
memory.cpp per-thread alloc wall-time probe + scons alloc_probe option), godot_voxel/0015-cosmos-gen-convoy-diet
(profs thread_local + VoxelMemoryPool prewarm), godot_voxel/0016-cosmos-alloc-probe-surface (dequeue timer +
get_stats surface). Build knob: versions.env WEB_ALLOC_PROBE=yes compiles the probe in — AND scripts/build.sh (OUTER
wrapper) needed `-e WEB_ALLOC_PROBE` added to its docker run env-list (I fixed it; the inner build-engine.sh + versions.env
were already wired — same baked-knob-passthrough trap as [[voxiverse-mimalloc-fit-build]]; verify BUILD-INFO shows
web_alloc_probe:yes). Runtime flags (GDScript consts, sed-at-export): FP_GEN_ALLOC_PROBE (bool, gates BOTH C++ accumulation
AND remote_bridge wf_alloc_* emission — template↔source MUST match or probe silently doesn't emit), FP_GEN_PROFS_TLS (bool),
FP_GEN_POOL_PREWARM (INT block count e.g. 2500, sed `:= 0`→`:= 2500`). Recycler (lever 2, FP_GEN_SMALLOBJ_POOL) HELD for
Build #2 pending the probe. FLAT 6042/0.
PROBE-READ PLAYBOOK for the A/B (ConvoyCpp): wf_alloc_* counters are CUMULATIVE — difference consecutive worst-frame
snapshots for per-window delta. (1) BASELINE arm (all FP_GEN_* off, FP_GEN_ALLOC_PROBE on): if wf_alloc_main_ms +
wf_alloc_workers_ms account for the bulk of the ~430ms gap (main = victim: high wf_alloc_main_ms while wf_alloc_workers_n
huge) → CONFIRMS dlmalloc convoy. If wf_dequeue_ms dominates → apply-bound not alloc-stall (reopen §4.I, don't build
recycler). If neither → re-attribute, ship nothing. (2) DIET arm (+profs +prewarm): gate = spike worst_ms ↓ AND
wf_alloc_workers_n ↓ AND wf_alloc_main_ms ↓. (3) BUILD #2 TRIGGER: if residual still worker-alloc-stall dominant
(wf_alloc_workers_ms large share + worst_ms NOT ↓≥50%) → build recycler; Candidate B core-slab if CoW-heavy, deleter
partial (VoxelBuffer object, module-only lower-risk) if buffer-object-heavy — wf_alloc_workers_n magnitude discriminates.
HEAP: peak ≤ dlmalloc baseline +120MB (prewarm ~+20MB @2500, profs/probe ~0). A/B on no-village config isolates Layer B.

PROBE BASELINE RESULT (2026-08-30, arm 1 = probe ON diet OFF, live no-village walk, 62 probe frames alt 7-10). CONVOY
CONFIRMED + MAIN-SIDE: differencing the cumulative wf_alloc counters over the walk, during gen-burst seconds the MAIN
thread spends up to ~350ms/sec (≈35% of wall-clock) inside malloc, vs workers only 5-86ms — the main thread is the
VICTIM (its ordinary per-frame allocs stall on the single dlmalloc lock while workers churn it). wf_dequeue_ms tiny
(0-8ms) ⇒ NOT apply-bound (apply-slicing ruled out, matches wf_vox_main≈0). Fix side = allocator/worker-traffic,
confirmed. CAVEAT: probe counters are CUMULATIVE + telemetry is 1Hz, so attribution is per-SECOND clean but per-single-
FRAME aliased (a window's Δalloc_main can exceed that window's worst_ms — it's window-total not frame). Deploy the int
prewarm flag via GEN_PREWARM env added to deploy_novillage.sh (git-checkout wipes a manual CS sed, so the int sed must
run INSIDE the deploy after the checkout — same wipe-trap as the consts). NEXT = diet arm (FP_GEN_PROFS_TLS + GEN_PREWARM
=2500) walk → compare Δalloc_main rate baseline-vs-diet; if it drops materially the direction is proven → build the
recycler (Build #2) for the big cut; if flat, the worker profs/prewarm allocs aren't the contention driver → the
VoxelBuffer-wrapper/task-object churn (recycler target) is, or the main-thread's own alloc mix dominates. Gen-convoy
Build #1 committed 0068a56 on feat/voxiverse-fartier-walk.

DIET A/B VERDICT (2026-08-30) — ALLOC-CONVOY FALSIFIED AS THE DOMINANT GROUND-JERKINESS CAUSE. Baseline (diet OFF,
n=223 windows) vs Diet (FP_GEN_PROFS_TLS + FP_GEN_POOL_PREWARM=2500, n=45): worst_ms median 127→128, p90 290→292
UNCHANGED (felt floor unmoved); max 1723→1146 + main-alloc PEAK 1780→378 ms/sec (prewarm killed cold-pool channel
spills = a real but tail-only win). Main-alloc is only ~14% of wall-clock even at baseline; workers ~4 ms/sec;
wf_dequeue ~0 (apply exonerated again). ⇒ per the design's FALSIFICATION EXIT: do NOT build the recycler (Build #2) —
eliminating ALL alloc-stall caps at ~14% and the cheap diet already proved the median doesn't budge. The prewarm+profs
levers are cheap byte-off tail-wins (ship-optional). RE-ATTRIBUTION (mined existing wf_ snapshots, user chose to chase
the 86%): the spike frames are NOT GPU (wf_draws 94 vs calm 111 LOWER; wf_prims 381k vs 473k LOWER), NOT apply
(wf_vox_main≈0), NOT alloc-majority. They ARE worker-flooded GENERATION bursts: wf_vox_gen 394 vs 8 (51×), wf_pool_active
3-6 vs 0 (20×). So the ~86% = the MAIN THREAD busy-spinning (can't Atomics.wait on WASM) on a NON-MALLOC engine lock
contended by the 6 busy workers — prime suspect the VoxelData/VoxelDataMap RWLock the streaming/query path holds while
workers write generated blocks, and/or the task-queue mutex. NEXT = a lock-wait probe (ConvoyCpp, extends the 0003
alloc-probe technique to time main-thread acquire-wait on the hot engine mutexes → wf_lock_*_ms) to confirm; if it
matches the gap, the fix is finer-grained/lock-free engine data access OR throttling the worker burst (fewer concurrent
gen tasks → less contention, GDScript-side, cheaper). METHODOLOGY WIN: the probe stopped a wasted recycler build + the
free mining stopped a wasted GPU-timing probe (draws are LOWER on spikes). [[voxiverse-web-time-process-invalid]]

LOCK-WAIT PROBE VERDICT (2026-08-30, patch 0017 FP_GEN_LOCK_PROBE, live walk) — ENGINE LOCKS FALSIFIED TOO. On spike
windows wf_lock_rwlock_ms=0% AND wf_lock_mutex_ms=0% — the VoxelData map RWLock and the ThreadedTaskRunner
_completed_tasks_mutex carry ESSENTIALLY ZERO main-thread wait. So the ground-jerkiness main-thread stall is NOT the
VoxelData lock, NOT the task mutex, NOT alloc-majority (~15-35%), NOT apply/dequeue (~0%), NOT GPU-draw (wf_draws LOWER
on spikes). ~65-83% of spike frame-time is UNMETERED by every engine-level timer. Some biggest one-offs (1963ms) had
ZERO of everything measured = a BROWSER/RUNTIME-level stall (WASM linear-memory growth copying the whole heap, memory-
bandwidth saturation from 6 worker threads churning during the burst, or the emscripten pthread proxy) — NOT a surgical
engine lock/alloc bug. CONCLUSION: the gen-burst ground jerkiness is largely the WEB-PLATFORM cost of running the heavy
multithreaded generation burst; no allocator/lock fix moves it (all measured small/zero — two would-be builds saved).
The remaining lever is REDUCING THE BURST WORK (fewer chunks generated per crossing: tighter view-ramp / slower pool
spawn / wider move-hysteresis → smaller bursts → smaller spikes), GDScript-side, no engine rebuild. Build knob (godot/0003
lock_probe.cpp NOT auto-globbed — util/thread/ is enumerated file-by-file in common.py:get_sources(), register new
util/thread .cpp explicitly, mirrors patch 0007; caught only at LINK not apply-check). Gen-convoy instrumentation stack
committed 646bae4 (0003+0015+0016+0017, all byte-off) on feat/voxiverse-fartier-walk.

BURST-THROTTLE PIVOT (2026-08-30, user: "go burst-throttling, GDScript first then native"). Design
docs/COSMOS-GEN-BURST-THROTTLE-DESIGN.md (Fable). CHOKE POINT found: the single VoxelViewer is a plain child of the
player (module_world.gd:3085-3114, add_child :3111) — it free-runs every tick; the frame it crosses a 16-voxel
data-block cell, C++ VoxelTerrain::process diffs the box and enqueues the WHOLE strip for all 2-3 pool slots in ONE pass
(~160-220 tasks/axis-step → 1000-2186 total). Why the shipped controller/inflight-gate MISS it: stream_pace + INFLIGHT
actuate ONLY the view-RAMP grow legs (module_world.gd:438-444,:581-604); at steady walking view_f==view_target so no
ramp active → credit multiplies nothing; and the 0.25s tick is 15× slower than the 1-frame C++ diff. Walking moves the
view CENTRE and NOTHING paces that (the fall path paces the target only). LEVER = FP_WALK_STEP_GATE (GDScript-only, byte-
off): hold the VoxelViewer on a committed ANCHOR; advance it toward the player ONE axis × one 16-voxel quantum per
admitted STEP, admitted only when tasks.generation < WALK_STEP_OPEN(128) AND ≥0.2s since last step; FORCED step at
24-voxel lag; SNAP to player on discontinuity/teleport or speed>12 b/s (walking-only — fast motion ungated). 4 edit
sites: cube_sphere consts + world_manager.gd:~1358 speed-EMA + walk_gate_update call in the always-run SAFETY HEAD
(~:1391) + module_world walk_gate_update moving the viewer node. EXPECTED ~4-6× burst reduction (peak ~350 vs 1000-2186);
rim terrain ≤~1s later, frontier deficit bounded 40 voxels. SAFETY: physics analytic (block_id_at/floor_under never read
mesh → no fall-through); frontier ≥88 voxels ahead (≥16s at run speed); un-meshed rim keeps far-tier backstop cover.
GDScript caps burst CADENCE (serializes steps) but can't shrink one step's ~100-block/slot strip → if A/B still spikes,
NATIVE fallback = per-process admission budget in VoxelTerrain::process_viewers (engine patch). Impl in flight (Opus,
verify_walk_step_gate gate, FLAT 6042/0). A/B = no-village walk, probe on: success = spike worst_ms p90/max ↓≥40% +
wf_vox_gen per-window peak ≲450 + forced-step share <20% + no walk-into-hole. Deploy = sed-at-export flag (NO rebuild).

BURST-THROTTLE A/B VERDICT + BIG REFRAME (2026-08-30/31) — FP_WALK_STEP_GATE FAILED + THE REAL PROBLEM ISN'T GEN AT ALL.
Live throttle-arm walk (probe on): worst_ms median 118 vs baseline 121 (UNCHANGED), gen-burst peak still 1915 (throttle
did NOT cap it). NEGATIVE result. DECISIVE: **635 of 656 frames had wf_vox_gen==0 (NO generation) yet median worst_ms 116,
spikes to 1195** — the user's report "even standing still and turning around is extremely jerky" is CONFIRMED in data. So
the pervasive ground jerkiness is NOT the gen burst (which only spikes when crossing into new chunks) — it's a
STANDING-STILL / CAMERA-ROTATION rendering-or-frame-pacing FLOOR present at rest. Cross-arm no-gen floor: baseline seg0
median 121, throttle 118 (SAME → pre-existing, NOT throttle-caused), but one segment ran median 43 (SMOOTH) → jerkiness
is SITUATIONAL (location/state/camera), i.e. fixable not a platform wall. THE ENTIRE gen-convoy arc (alloc probe, lock
probe, diet, recycler-held, burst throttle — 3 engine builds) chased the SPIKES (gen bursts) but the pervasive floor the
user actually feels is the turn-in-place cost, a DIFFERENT root. "Turning is jerky" (camera rotates, position fixed, zero
gen) points at the FAR-TIER RE-EMITTING ON CAMERA ROTATION (far-ring shell / smooth_v2 commit / far-tree cull are all
camera/view-driven — the known re-emit-churn class, cf [[voxiverse-orbit-perf-farring-churn]] FP_UNSINK_DRIFT_CALM,
[[voxiverse-forest-fps-root]] FacetFarTrees unconditional rebuild, [[voxiverse-stream-idle-diet]] FP_APPLIED_PROBE_CALM)
and/or raw render/frame-pacing. wf_ on worst no-gen frames: sv2=11.76 (smooth_v2 commit ~every frame) + phys 8-30 + prims
425-549k + draws 45-162; worst_ms 400-1195 mostly unmetered (the biggest = browser stalls). NEXT (pending user) = pivot to
instrument what re-runs on a PURE camera ROTATION while stationary; strong prior = the far-tier re-emits on view change.
Throttle reverted live (FP_WALK_STEP_GATE off, committed default-false 2cf0b6f; probe stays on). All work committed on
feat/voxiverse-fartier-walk. LESSON: should have A/B'd standing-still worst_ms BEFORE the whole gen-burst arc — the floor
was always the pervasive complaint ("jerkiness everywhere" way back), the gen spikes were a distraction.

TURN-IN-PLACE DIAGNOSIS (2026-08-31, docs/COSMOS-TURN-IN-PLACE-DESIGN.md Fable). FAR-TIER-RE-EMIT-ON-ROTATION FALSIFIED:
source-complete trace shows every far-tier rebuild keys on camera POSITION/membership/epoch, NOT view basis (apply_camera_set
uses normalize(cam−centre); far-trees gate FT_DELTA_MIN_MOVE; smooth_v2 crossing-only; all feeds pass .origin). The ONLY
camera-BASIS consumer = M2 frustum-want selector facet_lod_mesher.gd:321-327 but it's RETIRED LIVE (FP_NO_NEAR_LOD=true,
_lod_mesher null). Also confirmed wf_smooth_v2_commit_ms≈11.8 is a STALE LATCH (re-reads _last_commit_ms facet_smooth_v2.gd:594),
NOT a per-frame commit — a telemetry artifact like st_bms. AND my direct check: on idle/turn worst frames EVERYTHING is static
(wf_ftr_rb flat +0, prims const ~550k, draws const ~162, objects 132, pool 0) → nothing churns; the 110-234ms idle worst_ms is
a ~1Hz periodic window-worst hitch. REAL turn-cost CANDIDATES (ranked): H1 first-draw GL materialization of walk-accumulated
never-drawn near chunks (rotation-correlated → first-revolution-only spikes); H2 SNOW/weather ~20-25ms situational per-frame
(design's pick for the 43-vs-116 median split — test by toggling precip/weather off); H3 browser/GL stalls. PLUS my OBSERVER-
EFFECT hypothesis: the relay telemetry + FP_WORST_FRAME_ATTR/alloc/lock probes (all ON in every jerky arm) query expensive
stats ~1Hz — cf KNOWN [[voxiverse-forest-fps-limiter]] "rest stall = 4Hz telemetry + controller floor-trap; FP_TELEM_FRAME_DECOMP".
CHEAP DISCRIMINATORS (do before any build): (1) bare-URL load (no ?remote= → relay/probe dormant) + stand+turn → smooth ⇒
observer effect; (2) snow/weather-off arm → smooth ⇒ snow floor. Design's instrument if real = FP_TURN_ATTR probe (wf_cam_rot_dps
+ wf_sv2_commits + wf_ring_emits + wf_snow/weather_ms, byte-off, GDScript). Pending user bare-URL test.

★ RESOLUTION (2026-08-31) — OBSERVER EFFECT CONFIRMED, THE GROUND JERKINESS WAS OUR OWN TELEMETRY. User loaded the BARE URL
(plain https://voxiverse.game-host.org/, NO ?remote= → relay + probes dormant), waited 2-3 min to warm: "NO jerkiness on
the surface, very little bit jerkiness during the fall from orbit." So the pervasive ground/turn/walk jerkiness the user
reported ALL SESSION was the OBSERVER EFFECT of the remote-bridge telemetry (the ~1-4Hz observe stream + FP_WORST_FRAME_ATTR
worst-frame snapshot querying RenderingServer/get_stats/per-thread alloc counters) — it was heavy enough to BE the ~1Hz
110-234ms idle hitch. The SURFACE PERF IS ACTUALLY FINE; the deep-perf arc (gen-convoy alloc/lock probes, diet, recycler,
burst throttle — 3 engine builds + many deploys) chased an artifact of our own measurement rig. The measurements were all
internally-consistent (alloc 14%, locks 0%, etc.) but the DOMINANT unmetered ~86% was the telemetry overhead itself, which
no in-engine timer could see. Real residual = a LITTLE de-orbit fall jerkiness (small; de-orbit big stalls already fixed by
PR#83). CRITICAL LESSON: run the NO-TELEMETRY / bare-URL A/B FIRST when perf is reported on an instrumented build — the relay
observe path is a known rest-stall source ([[voxiverse-forest-fps-limiter]] "rest stall = 4Hz telemetry"; [[voxiverse-web-time-process-invalid]]).
The whole session's premise ("PERF is UNACCEPTABLE" ground jerkiness) was largely measurement overhead; should have been
caught turn 1. ACTION: for the user's normal cheats play, deploy with the heavy telemetry OFF (FP_WORST_FRAME_ATTR + probes
off; keep CONTROL_ENABLED for set_time if the control path alone is light) OR just play bare-URL. Shipped build (no relay)
is already smooth. All instrumentation (0003/0015/0016/0017 patches + FP_ flags) stays byte-off default so it never ships.

DE-ORBIT FALL MEASURED + ARC CLOSED (2026-08-31). Deployed a LIGHT-telemetry build (villages + de-orbit CLITE + FP_TELEM_LITE,
NO FP_WORST_FRAME_ATTR/probes) to measure the fall with less observer effect. RESULT — even FP_TELEM_LITE (1Hz) STILL hitches
the frame ~200-456ms on the idle surface (where bare-URL is smooth) → the RELAY CONNECTION ITSELF is the observer effect, not
just the heavy probes; the relay can't resolve anything below its ~400ms noise floor. Live de-orbit fall watched via Monitor:
descent from orbit (alt 490→150) stayed 200-370ms = WITHIN the observer floor, NO orbital-knee stall (PR#83 pre-warm fix holds;
historical 600-3555ms knee GONE). The only real bump = NEAR-SURFACE LANDING (alt 74-146) peaking ~550-563ms WITH a near-field
gen flood (vox_gen 4000-4938 as the ground materializes) — subtract the ~400ms observer floor ⇒ genuine residual ~150ms, a brief
touchdown hitch (the surface streaming in; partly inherent; existing levers FP_LANDING_STREAM_KICK/FP_SUMMIT_STREAM). Matches
user's bare-URL "very little bit jerkiness during the fall." VERDICT: perf arc CLOSED — surface smooth (observer effect was the
"jerkiness"), de-orbit big stalls fixed, near-surface landing residual minor. Full smooth build restored live (villages+de-orbit,
no telemetry). LESSON reinforced: the remote-bridge relay is a ~400ms-per-hitch observer effect even in LITE mode — perf must be
judged bare-URL/subjectively or via a FUNDAMENTALLY lighter telemetry (off-main-thread emit / batched binary), not the current
per-tick relay. [[voxiverse-remote-bridge]]
