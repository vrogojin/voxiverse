---
name: voxiverse-agent-autonomy-design
description: 2026-08-17 agent-autonomy design (task
metadata: 
  node_type: memory
  type: project
---

2026-08-17, design in `docs/COSMOS-AGENT-AUTONOMY-DESIGN.md` (deploy-cheats worktree), task #140.

**break target:[x,y,z] no-op ROOT CAUSE (3 layers):** (1) relay `validTarget` (relay.mjs:274) accepts
`[x,y,z]` arrays but executor `_target_arg` (remote_control.gd:419) only converts `{dx,dy,dz}` Dictionaries —
an array SILENTLY falls through to `"aim"`; (2) even the dict form is a player-RELATIVE feet-cell offset
(`_remote_offset_cell` player.gd:2337), no absolute-cell break exists; (3) frame trap: telemetry `pos` is
SCENE, feet cell is LATTICE. LESSON: a validated-and-forwarded command with silently different semantics
than sent is the worst failure class — validators on both ends must accept the SAME shapes.

**Verdict: NO narrow Minecraft-playing model** — scripted A*/skills + external LLM planner
(Mineflayer/Baritone/Voyager model). VPT/STEVE-1 are pixels-only BC (~70k h video, 720 V100×9 d) built to
reconstruct structured state VOXIVERSE already exposes. Confirmed independently by
`docs/RESEARCH-MC-AUTONOMY.md` §4.

**Staged plan:** A1 `break_cell`/`place_cell` (FP_AGENT_ACT, absolute LATTICE cells + relay array-target
nack) → A2 `aim_cell` (pure-lattice yaw/pitch, eased look + DDA verify; centre-aim kills 1-wide-trunk
ray-threading) → A3 `goto` (FP_AGENT_NAV, bounded time-sliced A* in new agent_nav.gd over cell_solid;
step-up = planned JUMP — ledge stall is by-design "no auto-step" player.gd:1859; caps 64 range/4096
nodes/256 exp-frame/128 path) → A4 `chop_tree` (FP_AGENT_SKILL, agent_skills.gd phase machine running
VIRTUAL steps through the unchanged executor; progress = namespaced step events, zero relay schema change).
All-LATTICE param rule (the frame query_* answers in) makes the frame trap structurally impossible.
Related: [[voxiverse-fallthrough-loc-bug]] (deploy_cheats.sh reverts remote_bridge.gd — merge before
cheat-flip), [[voxiverse-move-probe-cache]] (makes A* cell reads cheap).
