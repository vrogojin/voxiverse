---
name: voxiverse-agent-control-design
description: "2026-08-15 agent-control+awareness DESIGN done (docs/COSMOS-AGENT-CONTROL-DESIGN.md in deploy-cheats worktree) — P0 fs.watch outbox + await ack/done (576→~100ms), P1 FP_AGENT_POSE two-frame telemetry, P2 FP_AGENT_QUERY query_box/query_ray on the screenshot result substrate"
metadata: 
  node_type: memory
  type: project
---

Agent-control design (2026-08-15, in `docs/COSMOS-AGENT-CONTROL-DESIGN.md`, deploy-cheats worktree; impl pending):

- **P0 (relay-only):** `fs.watch(OUTBOX_DIR)` accelerator + poll floor 500→100 ms (`relay.mjs:86,537,952`; watch calls `pollOutbox()` — ONE code path); agent contract = await `control/results/<seq>/{ack,done}.json` (already exists, bypasses the 4 Hz telemetry tax); optional `?telem=10hz` behind FP_TELEM_10HZ. Budget: ack loop 576→~80-150 ms typ; observe→act cycle ≈ 200-300 ms (3-5 Hz agent loop).
- **P1 (FP_AGENT_POSE, re-export):** TWO-frame rule resolves the audit's frame caveat — `view_telemetry` additions (body/cam bases, `vel`, `on_ground`) stay SCENE frame; new `orientation_telemetry()` is ENTIRELY BCI, keys suffixed `_bci`; body fwd maps SCENE→lattice (`_frame.g2l_dir`, player.gd:2015 seam) →BCI via affine two-point diff through `lattice_to_world64` (exact, no epsilon). Never mix frames in one block.
- **P2 (FP_AGENT_QUERY, relay+re-export):** `query_box`/`query_ray` as consent-gated cmd_seq steps on the screenshot correlated-result substrate; box = u8 grid, binary tag 0x03, caps HALF≤15/axis, cells≤32768 (≤32 KiB), triple-enforced; fill TIME-SLICED 4096 cells/frame (the [[voxiverse-move-probe-cache]] lesson — bulk `cell_value_at` in one frame hitches). Queries STAY on the control channel (observe path remains send-only — security decision, do not relitigate).

**Why:** the three agent pain points (seconds latency, no body orientation, JPEG-only sensing) were all plumbing + missing wire exposure — the engine already had `block_id_at`/`aimed_voxel`/pose.
**How to apply:** implementation must follow the doc's fix-sites verbatim; remember [[voxiverse-fallthrough-loc-bug]]'s trap — `deploy_cheats.sh` git-checkout-reverts `remote_bridge.gd`, so bridge edits must land before the cheat flip or they vanish from the served build.
