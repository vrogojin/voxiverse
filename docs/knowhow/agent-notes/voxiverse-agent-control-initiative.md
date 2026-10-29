---
name: voxiverse-agent-control-initiative
description: 2026-08-15 initiative — agent-grade remote control + situational awareness (low latency, orientation telemetry, direct voxel-data queries)
metadata:
  node_type: memory
  type: project
---

2026-08-15 user directive (during the FP_FT_SHELL_BAND A/B loop, after the remote chop-aim proved painfully slow/imprecise):
improve the REMOTE CONTROL + situational awareness of the AI agent that plays VOXIVERSE via the tools/remote-bridge
relay. THREE concrete pain points:
1. CONTROL LATENCY far too high — seconds between sense and act. Root: relay polls control/outbox every
   REMOTE_BRIDGE_POLL_MS=500ms + telemetry emits at ~4Hz (250ms) + screenshot round-trip. Want tens-of-ms loop.
2. NO player BODY-ORIENTATION telemetry — the agent can't read facing/pose in space (has been guessing via
   screenshots + look ops). Want pose: body basis / forward-right-up, camera forward, velocity, planet-local up
   (= normalize(pos - planet_centre)) + heading.
3. NO direct VOXEL/BLOCK DATA — agent perceives ONLY via JPEG screenshots. Want a structured query returning a 3D
   array of block ids over a box (neighborhood or arbitrary region), built from WorldManager.block_id_at, + a
   raycast/line-of-sight query. Image processing stays for debug but structured data drives navigation.

APPROACH (user: "with team agents in the background, use Fable wherever appropriate"): fan out research + audit,
then Fable synthesizes a design, then implement behind byte-off FP_* flags. Background agents spawned 2026-08-15:
- research-mc-agents → docs/RESEARCH-MC-AGENTS.md (Voyager/VPT/MineDojo/Malmo ObservationFromGrid/Mineflayer/etc:
  observation+action+loop-rate+pose+pathfinding patterns → VOXIVERSE recommendations)
- research-fps-awareness → docs/RESEARCH-FPS-AWARENESS.md (ViZDoom labels/depth, Habitat, ML-Agents raycasts,
  OpenAI Five/AlphaStar structured state, gym-vs-realtime, WS full-duplex, occupancy/voxel world-models)
- audit-remote-bridge → docs/AUDIT-REMOTE-BRIDGE.md (root-cause the 3 gaps + exact file:line fix sites: the latency
  chain, the missing pose fields + planet-local-up math, the absent request/response voxel-query surface)
Fable design DELIVERED (docs/COSMOS-AGENT-CONTROL-DESIGN.md, 632 lines) + user chose "all three together".
IMPLEMENTED byte-off 2026-08-15 (branch feat/voxiverse-agent-control, commit e5d2fea — NOT yet deployed/merged):
- P0 latency (relay-JS only, no rebuild): relay.mjs fs.watch(OUTBOX_DIR)→pollOutbox debounced + POLL_MS floor
  500→100 (env REMOTE_BRIDGE_WATCH/POLL_MS revert to old); agent awaits existing control/results/<seq>/{ack,done}.json
  NOT telemetry scrape; FP_TELEM_10HZ + ?telem=10hz raises snapshot 0.25→0.1s. ~576ms→~80-150ms.
- P1 orientation (FP_AGENT_POSE, additive+empty-dict-guarded): player.view_telemetry() adds SCENE body basis
  (fwd/right/up)+cam right/up+vel VECTOR+on_ground; NEW player.orientation_telemetry() = BCI frame (up/north/east/
  fwd/pos+heading_deg, keys _bci). FRAME DECISION: two blocks NEVER mixed — SCENE keys stay scene, _bci keys all BCI
  (body fwd mapped scene→lattice via _frame.g2l_dir then lattice→BCI via 2-pt lattice_to_world64 diff). BCI chosen =
  only frame stable across facet crossings. Merged in remote_bridge _merge_rich_state after view_telemetry.
- P2 query (FP_AGENT_QUERY, ALSO CONTROL_ENABLED+grant gated): query_box (WorldManager.block_box_slice batched
  block_id_at → binary 0x03 QUERY_TAG downlink, TIME-SLICED QUERY_CELLS_PER_FRAME=4096) + query_ray (player.remote_
  query_ray reuses aimed_voxel DDA; default=aim ray). Executor: query_requested signal + _query_* latch (mirror shot).
  Bridge _on_query_requested→_query_ray_answer/_query_box_async→_send_query_result/_send_query_frame. Triple-capped
  never-OOM: shared validator tools/remote-bridge/validate.mjs (relay validateStep delegates + rover _validate_query_step
  mirrors + block_box_slice clamps). QUERY_HALF_MAX 15/QUERY_CELLS_MAX 32768/QUERY_RAY_MAX 64.
GATES GREEN: verify_feature FLAT 6042/0 byte-off; verify_agent_query 19/0 (block_box_slice==direct block_id_at loop
INCL post place/break overlay, x-fastest,z,y ordering, 1-cell-budget resume-safe, over-cap clamp); verify_agent_pose
43/0 (BCI math: orthonormal, equatorial heading 0/90, pole+straight-down omit heading); validate_step.test.mjs 26/0.
deploy_cheats.sh CS_FLAGS += FP_TELEM_10HZ FP_AGENT_POSE FP_AGENT_QUERY (CONTROL_ENABLED already sed-flipped line 17).
LESSONS: (1) place_block runs _structural_update → a mid-air placed block DETACHES (reads 0) — gate must place on a
SUPPORTED surface (_surface_top scan). (2) GDScript match-arm indent: python-insert at wrong tab depth nests the arm
inside the prior case (parse error) — verify arm indent vs siblings. (3) relay `ws` dep is Docker-only (not local) →
extract pure validators to a ws-free module for unit-testable gates, don't spawn the relay. (4) committed BEFORE the
import parse-check caught the indent bug → had to amend; run --import BEFORE committing new match arms.
NEXT: deploy flag-on (deploy_cheats.sh) + reload + live A/B (query crosshair→break→re-query=air; assert pose telemetry
keys present; confirm control latency drop), then PR feat/voxiverse-agent-control → main. Update the agent HARNESS/relay
driver to await done.json + issue query_ray for aim (the chop-aim pain that motivated this).
Related: [[voxiverse-remote-bridge]] [[voxiverse-spacefly-selftest]] [[voxiverse-mission-control]] [[voxiverse-fartree-orbit-dropout]]
