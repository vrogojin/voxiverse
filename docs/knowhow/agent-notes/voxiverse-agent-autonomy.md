---
name: voxiverse-agent-autonomy
description: 2026-08-17 agent autonomy A1-A4 (break_cell/place_cell/aim_cell/goto/chop_tree) — the scripted play-loop that makes find→approach→aim→chop one call; SHIPPED byte-off, deployed+relay-swapped, live A/B pending browser
metadata:
  node_type: memory
  type: project
---

2026-08-17 user goal (after FP_FT_SKIN_CHOP shipped): the remote agent still couldn't do the "stupidly simple"
find-tree→approach→aim→chop loop. AWARENESS was solved (P2 query_box/query_ray/in_range + FP_AGENT_POSE); the gap
was ACTUATION + the autonomous loop. User asked: maybe a narrow Minecraft-playing MODEL? Answer (research + design):
NO — script the verbs.

VERDICT (docs/RESEARCH-MC-AUTONOMY.md + docs/COSMOS-AGENT-AUTONOMY-DESIGN.md, both by team agents): no narrow model.
Because VOXIVERSE already exposes structured state + a raycast, the field's capable agents (Voyager/GITM/Optimus-1)
are all frozen-LLM planners over SCRIPTED primitives + a skill library; VPT/STEVE-1 are pixels-only BC policies
(≈70k hrs video, 720 V100×9 days, GPU-in-loop 20Hz) that exist to RECONSTRUCT the structured state we ship for free.
Loop owner = hybrid: in-engine skill runner (physics-tick), LLM = goal selection (~1 call/task).

ROOT CAUSE of the live "break-by-cell no-ops" (verified in code): _target_arg (remote_control.gd:419) only converts
a {dx,dy,dz} DICT; a JSON [x,y,z] ARRAY falls through to `return "aim"` → the relay validTarget ACCEPTS the array →
the break silently executes as aim-break at nothing (worst failure class). Plus the dict form is a player-RELATIVE
feet offset, not absolute — no reach-aware absolute-cell break existed.

SHIPPED 2026-08-17 (impl-autonomy fork of me implemented per the design; I reviewed + independently re-gated) —
commit 43a94b6 on feat/voxiverse-agent-autonomy (off main 9c9d962), 2254 insertions, byte-off:
- A1 FP_AGENT_ACT break_cell/place_cell — reach-aware ABSOLUTE lattice cell via world.break_terrain/place_block +
  inventory, typed why (ok/out_of_reach/air/protected); + relay hardening: validTarget DROPS the Array branch so
  legacy break/place array targets nack `caps` (kills the silent aim-downgrade).
- A2 FP_AGENT_ACT aim_cell — player.remote_aim_solution pure-LATTICE yaw/pitch (ψ=atan2(-dx,-dz), θ=atan2(dy,|dh|)),
  eased through the existing look machinery, then VERIFIED by remote_query_ray (kills aim:none + 1-wide-trunk
  ray-threading via centre-aim).
- A3 FP_AGENT_NAV goto — NEW agent_nav.gd: bounded time-sliced A* over cell_solid/block_id_at (the ONE cell query),
  4-connected, step-up=planned JUMP (the ledge-stall fix; player.gd:1859 "no auto-step" is by design), drop≤3, no
  liquids, no dig-through v1; caps NAV_RANGE_MAX 64/NAV_NODE_CAP 4096/NAV_EXPAND_PER_FRAME 256/NAV_PATH_MAX 128;
  deterministic tie-break; follower drives remote_input/drive intent seam + auto-jump latch, stall→replan ≤3.
- A4 FP_AGENT_SKILL chop_tree — NEW agent_skills.gd: FIND(TreeGen.has_tree spiral + block_id_at overlay-alive-check)
  →GOTO(adjacent)→AIM(base+UP)→CHOP(bottom-up break_cell until air, cap 12). ARCHITECTURE NOTE: the fork built it as
  a POLLED skill driver (_skill_process/_skill_physics + phase() FSM in remote_control.gd) NOT the design's virtual-
  step-through-_finish_step routing — deliberately AVOIDING the re-entrancy risk Fable flagged. Better call. Progress
  via namespaced chop_tree/… step events (zero relay schema change); SKILL_WATCHDOG_S 120/SKILL_RETRY_MAX 1.
GATES GREEN (fork ran + I re-confirmed FLAT independently): verify_agent_act 17/0, verify_agent_nav 13/0,
verify_agent_skill 8/0 (FIND FACETED-skipped, phase-ladder+failure-injections FLAT-run via mock player/world),
validate_step.test.mjs 43/0, FLAT verify_feature 6042/0 byte-off. Fork de-typed agent_skills._player/setup Node3D→
untyped for the mock (no runtime change). All caps triple-enforced; freed on step end/abort. No C++ rebuild.
DEPLOYED live 2026-08-17: web build (new wasm 09:37 GMT, CS_FLAGS += FP_AGENT_ACT/NAV/SKILL) + RELAY SWAPPED
(update: cp worktree relay.mjs+validate.mjs → main checkout ~/voxiverse/tools/remote-bridge → docker
restart voxiverse-relay; the container bind-mounts the MAIN checkout, runs its relay.mjs). Relay confirmed routing
break_cell/goto/chop_tree. LIVE A/B (chop_tree demo) PENDING: browser session timed out 09:25 (ping_timeout) — needs
the user to reopen ?remote=<token> + re-arm consent. NOT PR'd yet (feat/voxiverse-agent-autonomy).
P2 chop-via-query_ray already PROVEN live this session (in_range loop → break first try — the chop that failed 5×
last session).

LIVE A/B GREEN 2026-08-17: chop_tree felled a tree AUTONOMOUSLY in ONE call (dur 15.65s, status ok) — player
walked ~20 blocks (pos -24766→-24786), turned yaw 0→53°, broke the trunk, canopy detached as a VoxelBody (visible
falling in the after-shot). FIND→GOTO→AIM→CHOP all ran. TWO bugs fixed to get there, both on feat/voxiverse-agent-
autonomy: (1) commit 8f7a515 — AgentSkills.setup(exec: RefCounted,...) REJECTED the RemoteControl arg (RemoteControl
`extends Node`, not RefCounted) so setup() silently no-ran → _player/_world null → no_world; fix = de-type the exec
param (the RefCounted-mock gate HID this). (2) commit d66b3a7 THE BIG ONE — goto returned no_path for EVERY tree
(0.14s, 0 moves): the executor fed player.position (PLAY space) into the nav, which reads block_id_at (CELL space).
**FRAME LAW: play y = cell y + s, s = WorldManager._datum_lift(xi,zi) (~6 blocks live; surface_y adds it, block_id_at
does NOT). X/Z carry NO lift on the facet plane (why FIND still found real trees by position.x/z).** A* thus started
~6 cells ABOVE ground, past NAV_DROP_MAX=3 → zero moves → instant no_path. Fix = WorldManager.play_y_to_cell_y +
RemoteControl._player_cell (convert + snap to nearest AgentNav._stand feet) for the A* `from` in _start_goto/
_tick_nav_plan; follower waypoint-advance + auto-jump gates via _pos_cell_y; agent_skills._cheb_to_player range.
Executor-only, s≡0 with FP_DATUM_BAKE off ⇒ FLAT identity. Gates: nav 13/0 skill 8/0 act 17/0 FLAT 6042/0 byte-off.
DIAGNOSIS TECHNIQUE that cracked it: query_box .bin (u8, order x-fastest,z,y, origin=center−half) decoded to a
surface-height profile — showed the corridor FLAT (no cliff) but player `from` cell floating 6 above ground; query_ray
normal [0,1,0] falsified the "Y-up-wrong-per-facet" theory first. LESSON: when a live nav/query cell seems wrong on
the faceted planet, suspect the PLAY↔CELL datum frame before geometry; player.position is PLAY, block_id_at is CELL.

MERGED to main 2026-08-17 as PR #74 (merge 1ecb538; 2 commits: 8f7a515 A1-A4+setup, d66b3a7 frame weld).

VERIFIED-FOR-REAL 2026-08-17 (PR #75, merge 02740d4) — user challenged "are you sure you chopped a tree? run again".
The PR#74 "success" was a screenshot inference; rigorous query_box before/after DIFF proved it had NOT felled a tree
(status:ok only means _broken>=1). TWO MORE datum-frame/policy bugs surfaced once goto delivered the agent to the tree:
(3) commit 8e8a917 — chop_tree returned "occluded" EVERY time: the skill required AIM (query_ray verify) to pass
before CHOP, but a trunk BASE is self-occluded by the logs above it from an adjacent ground stance. remote_break_cell
(player.gd:2440) is REACH-gated NOT line-of-sight → AIM is cosmetic → must be non-fatal. Fix: on_aim_done nudges aim
up the trunk ×2 then proceeds to CHOP regardless.
(4) commit d896d7e THE TWIN of the goto weld — after AIM fixed, CHOP broke 0 cells (why:blocked): remote_break_cell/
remote_place_cell/remote_aim_solution receive CONTENT cells (block_id_at/query_box frame) but compared to head_position/
position/eye which are PLAY space → reach read the base ~6.5 blk away (>break_reach 4) → out_of_reach. Fix: WorldManager.
cell_y_to_play_y (inverse of play_y_to_cell_y) + player._cell_play_center convert the content cell to play for reach/aim
geometry ONLY (break_terrain/cell_solid still take content). NOTE offset-path remote_break uses floor(position)+offset =
already play-frame → _remote_in_break_reach deliberately UNTOUCHED. Gates skill 9/0 act 17/0 FLAT 6042/0 byte-off.
IRONCLAD PROOF METHOD (the way to verify world-edits live): query_box a FIXED region (explicit center, NOT "player"
since the agent moves) → chop → query_box the SAME region → diff the u8 .bin block ids. id 4=LOG id 5=LEAF. T1 diff =
4 LOG + 21 LEAF solid→air (crown collapsed). REPEATABILITY: 3 consecutive chop_tree → 3 DISTINCT trees (FIND skips
chopped via block_id_at alive-check), cluster diff LOG 15→0 LEAF 63→0, 3 trunks→0. 4 trees felled / 4 calls, all proven.
LESSON: never claim a world-mutation from a screenshot — diff the voxel grid; and the datum PLAY↔CELL frame bites EVERY
seam that mixes player.position with a block_id_at cell (nav from, reach dist, aim vector) — audit all three per feature.

LESSON: relay swap = copy to MAIN checkout + docker restart (worktree
relay is NOT what the container runs); relay restart drops the grant + the browser stays on the OLD build until
reloaded (or it may auto-re-arm consent on reconnect, seen earlier). Follow-ups the design scoped out: dig-through
goto edge, goto_far w/ Baritone 2-bit cache, collect skill, fly-goto.
Related: [[voxiverse-agent-control-initiative]] [[voxiverse-remote-bridge]] [[voxiverse-fartree-chop-farrender]]
