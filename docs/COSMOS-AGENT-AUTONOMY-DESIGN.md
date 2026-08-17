# COSMOS — Agent Autonomy Design (find tree → goto → aim → chop, in one call)

**Status:** DESIGN (implementation to follow this doc). Author: Fable. Date: 2026-08-17.
**Inputs:** `docs/COSMOS-AGENT-CONTROL-DESIGN.md` (P0/P1/P2 — all merged + live),
`docs/RESEARCH-MC-AGENTS.md`, `docs/RESEARCH-FPS-AWARENESS.md`, and
`docs/RESEARCH-MC-AUTONOMY.md` (landed mid-design; incorporated — its §4 verdict, §1.2 Baritone
cost model, §3.3 recovery hierarchy, and §6 recommendations are cited below and agree with this
design's independent conclusions on every decision point).
**Scope:** the remote-bridge stack + one new nav module — `tools/remote-bridge/relay.mjs`,
`tools/remote-bridge/validate.mjs`, `godot/src/net/remote_control.gd`, `godot/src/net/remote_bridge.gd`,
`godot/src/net/agent_nav.gd` (new), `godot/src/net/agent_skills.gd` (new),
`godot/src/player/player.gd`, `godot/src/world/world_manager.gd` (read-only reuse),
`godot/src/world/tree_gen.gd` (read-only reuse). No engine (C++) rebuild anywhere.

---

## 0. Executive summary

Perception is solved (P2: `query_box`/`query_ray`/pose). The "stupidly simple" loop —
**find a tree → walk to it → aim at the trunk → chop it** — still fails on **actuation**:

| # | Verified failure | Root cause (§2) | Fix (stage) |
|---|---|---|---|
| 1 | `break target:[x,y,z]` never fells a cell | `_target_arg` (`remote_control.gd:419`) maps only `{dx,dy,dz}` Dictionaries; a `[x,y,z]` Array — which the relay explicitly accepts (`relay.mjs:274`) — **silently degrades to `"aim"`**. And the dict form is a *player-relative feet-cell offset* (`player.gd:2337`), not an absolute cell. There is no absolute-cell break at all. | **A1 `break_cell`/`place_cell`** (§4) |
| 2 | `aim: none` ≠ no tree; ray threads past 1-wide trunks | no way to point the crosshair at a *chosen* cell; the agent guesses yaw/pitch from a mixed-frame pose | **A2 `aim_cell`** (§5) |
| 3 | `move forward` stalls on 1-block ledges | by design "going up requires a JUMP — no auto-step" (`player.gd:1859-1863`); the `move` op never jumps | **A3 `goto`** A\* + follower with auto-jump (§6) |
| 4 | the LLM drives every perceive→act micro-step over the wire | `cmd_seq` has no loops/conditionals (deliberately); a chop is ~10+ round-trips | **A4 `chop_tree`** server-side composite skill (§7) |
| 5 | frame trap: telemetry `pos` is SCENE, cells are LATTICE | mixing the two frames when computing offsets | all new ops take **absolute LATTICE cells** (the frame `query_*` already answers in); §3 |

**Architecture verdict (§1): NO narrow Minecraft-playing model.** Scripted navigation + named
skills in-engine, planned by the existing external LLM — the Mineflayer/Baritone/Voyager
architecture, which is exactly what fits a game that already exposes structured state and an
authoritative raycast. VPT/STEVE-1-class policies are pixels-only behavioural cloning: wrong data
regime (≈70k hours of human video that does not exist for VOXIVERSE), wrong loop rate (20 Hz GPU
policy vs our 3–5 Hz file-relay loop), wrong reliability class (stochastic policy vs deterministic
A\*), and they would *bypass* the structured interface we just built.

**Loop owner (§8): hybrid.** Primitives (`break_cell`, `aim_cell`, `goto`) + ONE composite skill
(`chop_tree`) resolve **server-side in the executor** (Voyager-skill style — the loop that must be
tight lives next to the physics tick); the LLM keeps the outer plan and calls one op per goal.
`cmd_seq` stays loop-free and dumb. Progress reports ride the existing
`step_start`/`step_done`/`done.json` sink with phase-suffixed op names — **zero relay event-schema
change**.

**Gates:** `FP_AGENT_ACT` (break_cell/place_cell/aim_cell), `FP_AGENT_NAV` (goto),
`FP_AGENT_SKILL` (chop_tree) — all `cube_sphere` consts, default **false**, nacking `caps` when off
(the `FP_AGENT_QUERY` pattern, `remote_bridge.gd:1319-1326`); everything also behind
`CONTROL_ENABLED` + grant. Byte-off ⇒ wire behaviour identical to today.

**Staging:** A1 → A2 → A3 → A4, each shippable + gated alone; A4 is the one-call demo
(`chop_tree` → tree felled autonomously).

---

## 1. The architecture decision: scripted skills + LLM planner, not a narrow model

The user's question, answered head-on: **do we need a special narrow-scoped "plays-the-game" model?
No.** The correct architecture for VOXIVERSE is scripted navigation + parameterized skills executed
in-engine, with the existing LLM as the planner. Grounds (all from `docs/RESEARCH-MC-AGENTS.md`):

1. **The narrow models exist to solve a problem we don't have.** VPT, STEVE-1, DreamerV3 are
   pixels-only policies emitting native keyboard/mouse at 20 Hz (RESEARCH-MC-AGENTS §1.6, §2.1).
   They exist because MineRL-class environments *deliberately withhold* structured state — the
   agent must reverse-engineer geometry from RGB. VOXIVERSE just shipped the opposite: an
   authoritative block grid (`query_box` over `block_id_at` — the ONE cell query), an exact aimed
   raycast with `in_range` (`query_ray`), and full pose in two clean frames. A game that exposes
   Malmo/Mineflayer-grade observations is played by Malmo/Mineflayer-grade agents — and **none of
   the capable structured-state agents (Voyager, GITM, JARVIS-1, Optimus-1) uses a learned
   low-level policy for block tasks; they call scripted verbs** (§2.2, §6.1).
2. **Data.** VPT needed ~70,000 hours of labelled human Minecraft video for behavioural cloning.
   VOXIVERSE has zero hours, different physics (analytic collision, mass-based pushes, structural
   collapse), different worldgen. Collecting/curating that corpus dwarfs the entire engine effort.
3. **Compute + latency.** A visuomotor policy needs a GPU in the act loop at ~20 Hz ≈ 50 ms.
   Our loop is a browser → WS → file-relay at 3–5 Hz (COSMOS-AGENT-CONTROL §3.4) on a host with
   **no GPU** (established constraint). A* over a 64-block grid costs microseconds-to-milliseconds
   of CPU in-engine and is immune to loop latency because it runs *next to the physics tick*.
4. **Reliability.** `chop_tree` as a deterministic state machine either works or reports exactly
   which phase failed (`no_tree` / `unreachable` / `occluded`). A cloned policy fails silently and
   un-debuggably. For an engine whose product gate is "the live demo must work in a browser",
   determinism wins.
5. **The field's own trajectory agrees.** The strongest long-horizon systems are LLM planners over
   scripted primitives + a skill library (Voyager writes JS against Mineflayer; GITM emits
   structured actions; mineflayer-pathfinder/Baritone do A\* with dig/place/parkour move rules —
   RESEARCH-MC-AGENTS §5, §6). The LLM decides *what*; scripts decide *how*.
   `RESEARCH-MC-AUTONOMY.md` §4 reaches the identical verdict independently and quantifies the
   narrow-model cost pole: VPT = ~70k filtered hours of video + a 0.5 B-param model on
   720 V100s × 9 days, pixels-only by design — machinery that exists to *reconstruct* the
   structured state VOXIVERSE already exposes. Its "hybrid" option (c) degenerates to (a) here:
   the hard-to-script set (reflex combat) is empty in today's VOXIVERSE.

**Trade-off accepted:** scripted skills don't generalize by themselves — each new behaviour
(mine ore, build shelter) is a new skill or a new LLM-composed sequence of primitives. That is the
Voyager model working as intended: the skill *library* grows, and the LLM composes it. If a future
milestone genuinely needs reactive low-level control (combat, moving targets), the revisit point is
a small distilled policy for that verb only — never a whole-game model.

---

## 2. The verified actuation diagnosis (root causes, with code)

### 2.1 `break target:[x,y,z]` no-ops — the silent aim-downgrade + the missing absolute mode

The live observation ("8 wood cells survived teleport + cell-break") has a three-layer root cause:

1. **The array form was never wired.** The relay accepts an `[x,y,z]` target explicitly
   (`validTarget`, `relay.mjs:274-278`: string `"aim"`/`"look"`, `[x,y,z]` number array, or any
   object). The executor's resolver:
   ```gdscript
   ## remote_control.gd:419 — the bug
   func _target_arg(t: Variant) -> Variant:
       if t is Dictionary:
           var d: Dictionary = t
           return Vector3i(int(d.get("dx", 0)), int(d.get("dy", 0)), int(d.get("dz", 0)))
       return "aim"          # ← a JSON [x,y,z] Array falls THROUGH to "aim"
   ```
   So `break target:[x,y,z]` executes as `break target:"aim"` — it breaks whatever the crosshair
   happens to hit (usually nothing), and reports `blocked`. A validated-and-forwarded command with
   *silently different semantics* than sent — the worst failure class.
2. **Even the working dict form is relative, not absolute.** `remote_break(Vector3i)` treats the
   vector as a **player-relative offset from the feet cell** (`_remote_offset_cell`,
   `player.gd:2337-2338`), then reach-checks (`player.gd:2340`). An agent passing absolute lattice
   coordinates as `{dx,dy,dz}` gets feet_cell + cell — kilometres away — `out of reach` → `0` →
   `blocked`. There is **no reach-aware break-by-absolute-cell anywhere**.
3. **The frame trap compounds it.** Telemetry `pos` is SCENE/global (`remote_bridge.gd` merge);
   the feet cell is `player.position` = LATTICE (`player.gd:2338`). With FP-FIXED-FRAME on,
   SCENE = ActiveFrame ∘ LATTICE, so an offset computed from telemetry `pos` minus a `query_*`
   lattice cell mixes frames and is wrong whenever the frame is non-identity.

**Fix shape (§4):** a new op that takes an **absolute LATTICE cell** (the exact frame `query_ray`'s
`voxel` and `query_box`'s grid already answer in — closing the loop with zero agent-side frame
math), reach-checked, routed through the same `WorldManager.break_terrain` pipeline. Plus: tighten
the relay's `validTarget` to **reject** arrays for the legacy `break`/`place` (they never worked;
better a loud nack pointing at `break_cell` than a silent aim-downgrade).

### 2.2 The ledge stall

`player.gd:1855-1888`: terrain walls are enforced analytically; the comment is explicit — *"only
upward steps block, so going up requires a JUMP (intended — no auto-step)"*. The `move` op drives
the intent seam with a fixed heading and never jumps, so a 1-block grass ledge stalls it; the
executor's stall detector (`MOVE_STALL_MS` 1500, `remote_control.gd:51`) then reports `blocked`.
Correct primitive behaviour — wrong *composition*. The fix is not auto-step in the player (that
changes human gameplay); it is a navigator that **plans** the step-up and issues the jump (§6).

### 2.3 No loop verb

`cmd_seq` is a validated linear script (by design — the relay can bound cost). A chop loop
(query → aim → break → re-query …) is ~10 round-trips × ~200–300 ms. The research answer is the
Voyager/pathfinder one: promote the *whole loop* to a named server-side verb; keep the wire
protocol loop-free (§7, §8).

---

## 3. Frame + convention contract for every new op

One rule, stated once and applied to all four ops: **every cell parameter and every cell in a
result is an absolute LATTICE cell** (`Vector3i`, the active facet's grid — the frame of
`block_id_at`, `aimed_voxel`'s `voxel`, `query_box`'s `origin`, and `teleport{x,y,z}`). Rationale:

- It is what the agent already *has*: P2 query results answer in lattice cells. `find → act` needs
  zero agent-side frame conversion — the frame trap (§2.1.3) becomes structurally impossible.
- Cells are invariant under fixed-frame re-anchors (the frame maps SCENE↔LATTICE; the lattice grid
  itself doesn't move), and the executor already handles crossing-reframes for continuous state
  (`_tick_move` rotates `_move_h`, `remote_control.gd:257`).
- SCENE never appears in any new op. BCI never appears (surface-walk scope; space nav already has
  its own verbs).

Facet-crossing caveat: a lattice cell is only meaningful on the facet it was read on. `goto` is
capped at 64 blocks (§6.5) — well inside a facet interior span — and the follower finishes
`blocked (reframed)` if a crossing occurs mid-path (the skill replans from fresh queries). This is
the same conservatism the P2 design applied to `query_box`.

Reach conventions (existing, reused verbatim): `break_reach` 4.0 / `reach` 8.0 (`player.gd:45,50`);
reach anchor = `head_position()` to the cell centre (`player.gd:2340-2344`).

---

## 4. A1 — `break_cell` / `place_cell` (gate: `FP_AGENT_ACT`)

### 4.1 Op shapes

```jsonc
{"op": "break_cell", "cell": [x, y, z], "id": 1}
{"op": "place_cell", "cell": [x, y, z], "block": "oak_log" | 7, "id": 2}   // block 0/absent = selected slot
```

Both resolve synchronously in `_start_step` (like the legacy `break`/`place` arm,
`remote_control.gd:501-510`). Status stays in the existing vocabulary (`ok`/`blocked`); the
step_done `extra` carries the discriminant the agent needs:

```jsonc
// step_done extras
{"why": "ok", "block_id": 6}            // break_cell: felled, id captured (inventory credited)
{"why": "out_of_reach", "dist": 6.2}    // reach-aware refusal — THE signal "walk closer" (goto)
{"why": "air"}                          // cell already empty (e.g. collapse got there first — chop-loop terminator)
{"why": "protected"}                    // corner-lock / rules refusal (world_manager.gd:1952)
```

### 4.2 Player method (site: `player.gd`, beside `remote_break` `:2349`)

```gdscript
## AGENT-AUTONOMY §4 (FP_AGENT_ACT): break the ABSOLUTE lattice cell — the reach-aware cell break the
## {dx,dy,dz} offset mode never was. Same pipeline as _try_break/remote_break: WorldManager.break_terrain
## (rules + collapse) + inventory credit. Returns {"why": String, "block_id": int, "dist": float}.
func remote_break_cell(cell: Vector3i) -> Dictionary:
    var dist := head_position().distance_to(Vector3(cell) + Vector3(0.5, 0.5, 0.5))
    if dist > break_reach:
        return {"why": "out_of_reach", "block_id": 0, "dist": snappedf(dist, 0.01)}
    if not world.cell_solid(cell):
        return {"why": "air", "block_id": 0, "dist": snappedf(dist, 0.01)}
    var oid := world.break_terrain(cell, global_position)     # rules + snow-first + collapse, world_manager.gd:1951
    if oid <= 0:
        return {"why": "protected", "block_id": 0, "dist": snappedf(dist, 0.01)}
    if inventory != null:
        inventory.add(oid, 1)
    return {"why": "ok", "block_id": oid, "dist": snappedf(dist, 0.01)}
```

`remote_place_cell(cell, block_id)` mirrors it: reach = `reach` (8.0), plus the existing
`_cell_intersects_player` guard and `place_block` (`world_manager.gd:1988`) + selected-slot
consumption — i.e. `remote_place`'s Vector3i branch (`player.gd:2387-2397`) with the offset seam
replaced by the absolute cell.

**Scope note — terrain only.** Cells inside detached `VoxelBody` rigid bodies live in body-local
frames under free rigid transforms; addressing them by lattice cell is ill-defined. The `"aim"`
break already handles wood bodies via the physics ray (`_current_target` `player.gd:2117-2136`),
and the chop skill needs `break_cell` only for *attached trunk cells* (which ARE terrain —
`TreeGen.block_at` composes into `generated_block`/`block_id_at`; CLAUDE.md rule 1). Felling the
lower trunk detaches the canopy via `_collapse_unsupported`, which is the product behaviour.

### 4.3 Executor + gates + relay

- `remote_control.gd` `_start_step`: two new synchronous cases calling the player methods,
  finishing `"ok"` iff `why == "ok"`, else `"blocked"` with the dict merged into `extra`.
- `remote_bridge.gd`: add both ops to `OP_WHITELIST` (`:76`); `_validate_cmd` (`:1274`) gains the
  flag + shape gate, exactly the `FP_AGENT_QUERY` pattern (`:1319-1326`):
  `FP_AGENT_ACT` off ⇒ `caps`; `cell` must pass `_is_vec3_num` (`:1362`) with integer components;
  `place_cell.block` a number or String.
- `relay.mjs`: ops into `OP_WHITELIST` (`:103`); `validateStep` cases beside `break` (`:370`):
  `cell` = 3 finite integers, `okEst(0.5)`. **Plus the hardening:** `validTarget` (`:274`) drops
  the `Array.isArray` branch — legacy `break`/`place` array targets nack `caps` with detail
  `"array target never breaks by cell — use break_cell"`. (Relay-only; host-tooling rebuild rule.)
- `cube_sphere.gd`: `const FP_AGENT_ACT := false` beside `FP_AGENT_QUERY` (`:3985`).

---

## 5. A2 — `aim_cell` (gate: `FP_AGENT_ACT`, same stage)

Puts the crosshair on the **centre** of a chosen cell — killing both aim failures at once
(guessed yaw/pitch, and the DDA threading past a 1-wide trunk edge: a centre-aimed ray hits the
trunk cell by construction).

### 5.1 Op shape + math

```jsonc
{"op": "aim_cell", "cell": [x, y, z], "verify": true, "id": 3}
```

All math is pure LATTICE, computed in the player (site: beside `remote_set_view` `player.gd:511`):

```gdscript
## AGENT-AUTONOMY §5 (FP_AGENT_ACT): absolute (yaw, pitch) that centres cell in the crosshair.
## Pure LATTICE: position/rotation.y/_pitch are all lattice-frame (the player rides the ActiveFrame),
## and the camera eye is position + eye_height (cam_local translation is on the yaw axis, player.gd:646).
## Godot conventions: fwd = -Z; yaw about +Y maps -Z → (-sin ψ, 0, -cos ψ) ⇒ ψ = atan2(-dx, -dz);
## +_pitch looks UP (camera.rotation.x = _pitch) ⇒ θ = atan2(dy, |dh|). Gate asserts both signs.
func remote_aim_solution(cell: Vector3i) -> Dictionary:
    var eye := position + Vector3(0.0, eye_height, 0.0)
    var d := Vector3(cell) + Vector3(0.5, 0.5, 0.5) - eye
    var h := Vector2(d.x, d.z).length()
    return {"yaw": atan2(-d.x, -d.z), "pitch": clampf(atan2(d.y, h), deg_to_rad(-85.0), deg_to_rad(85.0)),
            "dist": d.length()}
```

### 5.2 Execution — reuse the look easing, then verify with the real DDA

`_start_step` case `"aim_cell"` (executor): call `remote_aim_solution`, then drive the **existing**
turn/look machinery (`remote_control.gd:295-335`) — `_turn_remaining = wrapf(sol.yaw − player.rotation.y,
-PI, PI)`, `_pitch_active = true`, `_pitch_target = sol.pitch`, deadline `LOOK_WATCHDOG_S`; the
`"turn","look"` match arm in `physics_tick` (`:205`) gains `"aim_cell"`. On easing completion, if
`verify` (default **true**): run `player.remote_query_ray({})` (the aim ray, `player.gd:471`) and
finish:

```jsonc
{"why": "ok",        "hit": [x,y,z], "in_range": true}    // hit cell == requested cell
{"why": "occluded",  "hit": [x,y,z], "in_range": ...}     // something nearer intercepts — agent re-plans
{"why": "no_hit"}                                          // beyond max_dist / air path
```

status `"ok"` only for `why:"ok"` with `in_range:true`; else `"blocked"` + extra. So
`[aim_cell, break {target:"aim"}]` becomes *reliable* — and the chop skill uses exactly that pair's
server-side internals. Note `aim_cell` is surface-scope: in SPACE regimes the camera is
emancipated from `rotation.y/_pitch` (`player.gd:638-646`), so the op finishes `blocked
(why:"space")` when the attitude machine owns the camera — same inert-guard style as `dev_nav`.

Validation: bridge + relay mirror `break_cell`'s cell checks; `okEst(1.0)` (a ≤180° ease at
120°/s).

---

## 6. A3 — `goto`: bounded A\* over the authoritative grid + a jump-aware follower (gate: `FP_AGENT_NAV`)

The mineflayer-pathfinder/Baritone model (RESEARCH-MC-AGENTS §5), sized to VOXIVERSE's analytic
movement contract and the never-OOM law.

### 6.1 Op shape

```jsonc
{"op": "goto", "cell": [x, y, z], "goal": "stand" | "adjacent", "gait": "walk" | "run", "id": 4}
```

- `"stand"` (default): finish standing *in* the target column (GoalBlock).
- `"adjacent"`: finish in any stand cell horizontally adjacent to the target column with the target
  cell within `break_reach` (GoalGetToBlock — what `chop_tree` uses).

### 6.2 Traversability model (the load-bearing spec)

New module `godot/src/net/agent_nav.gd` (`class_name AgentNav`, RefCounted) — planner only, no
node, unit-testable headless. Every world read routes through the ONE cell query family
(`block_id_at`/`cell_solid`, `world_manager.gd:1631,1679`) — the same overlay-else-generated truth
physics uses, so the plan can never disagree with `blocked()` about what is solid (CLAUDE.md
rule 1; the per-tick move-probe cache `FP_MOVE_PROBE_CACHE` makes the reads cheap).

A cell `c` is a **stand cell** iff:
```text
supported:  cell_solid(c + DOWN)                       # floor under the feet cell
clear:      not cell_solid(c) and not cell_solid(c+UP) # 2-cell body clearance (PLAYER_HEIGHT 1.8)
not liquid: block_id_at(c) not in {water, lava, powder_snow} and same for c+UP
            # solidity_of < 0.5 makes liquids "passable" to the clear test — exclude them explicitly
            # (mineflayer's blocksToAvoid): never path THROUGH liquids in v1.
```

**Moves** from stand cell `c` (4-connected; no diagonals in v1 — the analytic wall test probes
axis-aligned leading edges (`player.gd:1877-1888`) and a diagonal plan can wedge on a corner the
prober blocks; 4-connectivity is what the follower can always execute):

| Move | Condition | Cost |
|---|---|---|
| flat step `c → n` (same y) | `n` is a stand cell | 1.0 |
| step-UP `c → n+UP` | `n+UP` is a stand cell AND `not cell_solid(c + 2·UP)` (jump headroom over the source) | 2.0 (jump = time + the §2.2 stall risk) |
| step-DOWN `c → n−k·UP`, k ∈ 1..3 | `n−k·UP` is a stand cell AND the swept column `n, n−UP … n−(k−1)·UP` all non-solid + non-liquid | 1.0 + 0.4·k |

Drop cap 3: no fall damage exists (Baritone's default fall cap is also 3 —
RESEARCH-MC-AUTONOMY §1.2), and a deeper analytic fall mid-path risks streaming-lag floor races
(the fall-through memory class) — conservative, revisit later. The cost shape is Baritone's
time-based model (cost ≈ traversal time, jump penalized — §1.2 ibid.), minus its dig-through /
place-to-bridge edges: **v1 never breaks or places blocks to move** (routing around is always
preferred; a dig-through edge is a natural later extension once `break_cell` is proven, with
Baritone's ~1 s-equivalent penalty). Long-range planning beyond the 64-block cap (a future
`goto_far`) should adopt Baritone's 2-bit AIR/SOLID/WATER/AVOID traversability cache rather than
raising `NAV_NODE_CAP` — noted as the scaling path, out of v1 scope. Heuristic: Manhattan XZ +
1·|Δy| (admissible against the table). Shaped/ramp cells: `cell_solid` gates on material solidity
(a ramp IS solid, `world_manager.gd:1672-1680`), so ramps read as stand support; where a ramp's
sub-cell surface lets the follower glide instead of jump, the planned step-up simply completes
cheaper. Residual mismatches surface as a follower stall → replan (§6.4) — the recovery path, not
a planner special case.

### 6.3 The bounded A\* (never-OOM by construction)

```gdscript
## agent_nav.gd — bounded, time-sliced A*. state carries open/closed/g/parent between slices
## (the block_box_slice pattern, world_manager.gd:1641). Hard caps — see §9 table.
func plan_slice(world, from: Vector3i, goal: Vector3i, mode: String, state: Dictionary, budget: int) -> bool:
    # expand ≤ budget nodes; neighbours per §6.2 (≤ ~10 block_id_at reads each);
    # STOP + state.result = "no_path" when expansions > NAV_NODE_CAP, |cell−from|∞ > NAV_RANGE_MAX,
    # or open empties; reconstruct ≤ NAV_PATH_MAX waypoints on goal pop (else no_path).
```

Executor arm: `"goto"` is an async step like `query_box` — `_start_step` seeds the state, a
per-frame slice call (`NAV_EXPAND_PER_FRAME` 256 ⇒ ≤ ~2560 cached cell reads ≈ 1–2 ms web, same
budget class as `QUERY_CELLS_PER_FRAME`) runs from `_process` until planned, then the follower
takes over in `physics_tick`. Worst-case plan latency: 4096/256 = 16 frames ≈ 270 ms — inside the
step estimate. Memory: ≤ 4096 nodes × ~3 small Variants ≈ well under 1 MB, freed on step end/abort.

### 6.4 The follower (site: `remote_control.gd`, beside the `move` machinery)

Per `physics_tick` while a `goto` runs (mirrors `_tick_move` `remote_control.gd:252` structure):

1. `cur = floor(player.position)` (feet cell — lattice, `player.gd:2338`'s convention).
2. Waypoint reached (horizontal dist to centre < 0.35 AND |Δy| ≤ 0.6) → advance; path exhausted →
   finish `ok` (extra: `{waypoints, replans, remaining: 0}`).
3. Steer: `dir_lat = (wp_centre − position)` flattened; body-local wish
   `input = player.transform.basis.inverse() * dir_lat` normalized → `remote_input` + `remote_drive`
   (the §4.2 intent seam the human path consumes; re-reading the basis every tick makes crossings
   self-correcting). No yaw change — the wish vector strafes; facing is `aim_cell`'s job.
4. Auto-jump: next waypoint one above current cell AND `is_on_floor()` → latch `remote_jump`
   (consumed at the next grounded tick, `remote_control.gd:344`) — **the ledge-stall fix**.
5. Stall (the `MOVE_STALL_BLOCKS/MS` model, per-waypoint): replan from `cur` (fresh A\*, counts
   toward `NAV_REPLANS` 3) — handles a mid-path edit/collapse/loose-body shove; replans exhausted →
   finish `blocked` (extra: `{why:"stalled", at:[…], remaining}`).
6. Reframe (facet crossing) during the step → finish `blocked (why:"reframed")` (§3).
7. Watchdog: `est = path_len/speed·3 + plan_time + 2 s`, capped 60 s (the `move` formula).

Preconditions: `flying` or SPACE regime ⇒ `blocked (why:"mode")` — surface-walk scope only
(fly-goto is trivial later: straight-line + `set_fly`, not in v1).

Validation: bridge + relay — cell ints; `goal` enum; Chebyshev distance from the *player's last
telemetry cell* is unknown to the relay, so the relay caps nothing spatial; the **rover** enforces
`NAV_RANGE_MAX` in `_validate_cmd`-adjacent code at start (distance from current cell) and nacks
`caps`. Relay `okEst(range≈64/5.5·3 ≈ 35 s)` conservative constant.

---

## 7. A4 — `chop_tree`: the one-call skill (gate: `FP_AGENT_SKILL`)

### 7.1 Op shape + phases

```jsonc
{"op": "chop_tree", "max_range": 48, "id": 5}          // max_range ≤ NAV_RANGE_MAX
```

Server-side phase machine (new `godot/src/net/agent_skills.gd`, owned by the executor):

| Phase | What | Reuses |
|---|---|---|
| **FIND** | spiral the tree grid (10-block cells) out from the player's cell to `max_range`; candidate iff `TreeGen.has_tree(gx,gz)` (`tree_gen.gd:130`) AND `world.block_id_at(tree_info.base)` is still a log id (**overlay-aware alive-check** — a chopped tree reads air, `tree_info` `tree_gen.gd:235`). Nearest candidate wins; none ⇒ finish `blocked (why:"no_tree")`. ≤ ~(2·48/10+1)² ≈ 121 `has_tree` hashes + a few cell reads — sub-ms, synchronous. | `TreeGen` placement law, `block_id_at` |
| **GOTO** | `goto {cell: base, goal:"adjacent"}` | §6 verbatim |
| **AIM** | `aim_cell {cell: base + UP}` (second trunk cell — grass/snow-fill at the base can shadow the lowest cell; `verify:true`) | §5 verbatim |
| **CHOP** | bottom-up: `break_cell(base)`, `break_cell(base+UP)`, … while the next cell reads a log id AND is in `break_reach`; stop early when it reads **air** — the structural collapse (`_collapse_unsupported` via `break_terrain`) has detached the canopy as a `VoxelBody`, which IS the felled state. Hard cap `CHOP_MAX` 12 (> max trunk 11). | §4 verbatim |
| *(collect)* | **not in v1** — `break_terrain` already credits the inventory per broken cell (§4.2); detached canopy bodies are physical debris with no pickup mechanic today. A future `collect` skill is a separate design. | — |

step_done extra: `{"why":"ok", "tree":[x,y,z], "species":…, "broken":N, "phases":{...durations}}`;
failures carry the phase + its `why` (`no_tree` / `unreachable` (goto blocked) / `occluded` (aim) /
`protected`).

### 7.2 Execution structure — virtual steps through the existing machinery

The skill does **not** duplicate any actuation. `AgentSkills` is a driver that feeds the executor
**virtual steps** — the same Dictionaries a `cmd_seq` would carry (`{op:"goto",…}`, `{op:"aim_cell",…}`,
`{op:"break_cell",…}`):

- `_start_step` case `"chop_tree"`: runs FIND synchronously, then sets `_skill = AgentSkills.new(...)`
  and starts the first virtual step via the normal `_start_step` path on the virtual dict.
- `_finish_step` (`remote_control.gd:587`): when `_skill != null`, the completion routes to
  `_skill.on_step_done(rec)` instead of `_next_step`; the skill returns the next virtual step, a
  retry, or the terminal record. The skill's own step (`chop_tree`, the real `_cur`) finishes only
  on the skill's terminal.
- **Progress**: each virtual step emits ordinary `step_start`/`step_done` events with the op
  namespaced `"chop_tree/goto"`, `"chop_tree/aim_cell"`, `"chop_tree/break_cell#3"` and the parent
  step's `id` — they flow through the untouched bridge send + relay `appendEvent` into
  `results/<seq>/events.jsonl`, and `done.json` stays terminal-only. **Zero event-schema change**;
  the agent watches phase progress with the P0 watch/poll contract it already has.
- Watchdogs: every virtual step keeps its own (move/look/etc.); the skill adds an outer
  `SKILL_WATCHDOG_S` 120. Abort/override/grant-loss: the existing `abort()` path finishes the
  in-flight virtual step, and `_finish_step`'s non-`ok` routing lets the skill emit its terminal —
  intent zeroed first, as always (`remote_control.gd:590`).
- Error recovery inside the skill — the three-level hierarchy every serious system converges on
  (RESEARCH-MC-AUTONOMY §3.3): **(a)** mechanical failures re-planned *silently below the skill*
  (the goto follower's stall→replan, §6.4); **(b)** the skill retries what it can and then returns
  a **typed failure** — GOTO `blocked` → one FIND re-pick excluding that tree, then one full retry
  (`SKILL_RETRY_MAX` 1); AIM `occluded` → re-aim at `base+2·UP` once, else next tree; CHOP
  `out_of_reach` mid-loop → one `goto adjacent` re-approach to the *current* chop height's column,
  then give up with partial `broken` count; **(c)** the LLM re-plans only on the typed failure in
  `done.json` — never on raw mechanics. Target-moved is impossible (trees are terrain);
  target-*chopped*-by-collapse is the normal early-exit.

### 7.3 Validation

Bridge: `FP_AGENT_SKILL` off ⇒ `caps`; `max_range` int ∈ [8, NAV_RANGE_MAX]. Relay: whitelist +
`okEst(60)` (bounded by the outer watchdog; `MAX_TOTAL_DURATION_S` 180 leaves room for a two-skill
sequence). One `chop_tree` per sequence (relay counts, rejects more — keeps `est` honest).

---

## 8. The loop owner — decided

**In-engine skill runner for the inner loop; external LLM for the outer loop.** Rationale:

1. The inner loop (waypoint follow, jump timing, chop-until-air) needs the physics tick, not a
   200–300 ms file round-trip. That is why every reference stack puts pathfinding in-process
   (mineflayer-pathfinder ticks inside the bot; Baritone inside the client) while the LLM sits
   outside (Voyager, GITM — RESEARCH-MC-AGENTS §5, §2.2; RESEARCH-MC-AUTONOMY §6.4: "the game
   owns the fast loop; the LLM owns only goal selection — ~one model call per task, not per tick").
2. The wire protocol stays dumb and boundable: `cmd_seq` remains a loop-free validated script, all
   cost caps still hold (`est`-based, `MAX_TOTAL_DURATION_S`), no interpreter surface appears in
   the consent-gated channel (security posture unchanged).
3. The agent still owns *policy*: it can drive the primitives itself (`query_box` → own A\* →
   `move`/`turn`) when it wants fine control — the composite is an accelerator, not a cage.
4. Completion/progress reporting reuses the P0 result sink verbatim (§7.2) — the agent's existing
   `ack.json`/`events.jsonl`/`done.json` watch loop needs no new client code.

Explicitly rejected: an in-`cmd_seq` conditional/loop mini-language (an interpreter on the consent
channel = new attack surface + unbounded est), and agent-side-only looping (works today, stays as
the fallback, but is 10× the wall clock and melts under the 1-wide-trunk aim problem the server-side
`aim_cell` verify solves at tick rate).

---

## 9. Never-OOM caps + safety + byte-off

### 9.1 Caps (all triple-enforced: relay `validate.mjs` where checkable → rover `_validate_cmd` → module)

| Const (cube_sphere, mirrored in validate.mjs where relay-checkable) | Value | Bounds |
|---|---|---|
| `NAV_RANGE_MAX` | 64 | Chebyshev blocks, start→goal (rover-checked; §6.4) |
| `NAV_NODE_CAP` | 4096 | A\* expansions ⇒ ≪ 1 MB state, freed on step end |
| `NAV_EXPAND_PER_FRAME` | 256 | ≈ 1–2 ms/frame planning slice (web) |
| `NAV_PATH_MAX` | 128 | waypoints |
| `NAV_REPLANS` | 3 | per goto step |
| `CHOP_MAX` | 12 | breaks per chop_tree |
| `SKILL_WATCHDOG_S` / `SKILL_RETRY_MAX` | 120 / 1 | outer skill bound |
| chop_tree per sequence | 1 | relay-counted |

Everything transient lives in the executor/skill objects — freed on `abort`, override, grant loss,
link loss (the existing `_free_executor` teardown). No new allocations survive a step.

### 9.2 Security

No new channel, no new consent state, no protocol schema change: four new whitelisted ops through
the SAME intake (`ingestFile`→`validateCmd`→`forward`→`_validate_cmd`→executor), same grant/nonce/
override machinery, same audit trail. The only *removed* behaviour is the silent array→aim
downgrade (§4.3) — replaced by a loud nack. Human override semantics are untouched: any local
input aborts a running skill exactly as it aborts a `move` today (`override` → `abort` →
`_zero_intent`).

### 9.3 Byte-off inventory

| Gate | Off ⇒ |
|---|---|
| `FP_AGENT_ACT` false | break_cell/place_cell/aim_cell nack `caps` at `_validate_cmd`; no player method reachable |
| `FP_AGENT_NAV` false | goto nacks `caps`; `agent_nav.gd` never instantiated |
| `FP_AGENT_SKILL` false | chop_tree nacks `caps`; `agent_skills.gd` never instantiated |
| `CONTROL_ENABLED` false | all of the above is dead code (executor never exists) |

Legacy ops (`break`, `place`, `move`, …) byte-identical with all three flags off; the one relay
change (array-target nack) is host tooling under the established relay rebuild rule.

**Deploy caveat (the recurring lesson):** `deploy_cheats.sh` git-checkout-reverts
`remote_bridge.gd` (and `cube_sphere.gd` per the memory) during the cheat-flip — the A1–A4 edits
must be merged into the file *before* that step or they silently vanish from the served pck.
Post-deploy: pck-dump the served flags (`FP_AGENT_ACT/NAV/SKILL` present + values), the
established verification.

---

## 10. Gate plan

**Headless (CPU, `verify_feature.gd` pattern):**

1. `verify_agent_act.gd` — seed terrain + edits via WorldManager directly:
   - `remote_break_cell` on a seeded solid cell fells exactly that cell (`block_id_at` → air after;
     neighbours untouched); inventory credited; repeat ⇒ `why:"air"`.
   - out-of-reach cell refused (`why:"out_of_reach"`, world untouched); corner-locked column ⇒
     `why:"protected"`.
   - `remote_aim_solution` sign pins: a cell dead-ahead ⇒ yaw≈rotation.y, pitch≈0; a cell below ⇒
     pitch<0; behind ⇒ |Δyaw|≈π; then `aimed_voxel` along the solution from the eye hits the
     requested cell for a spread of offsets **including a 1-wide pillar at 3.9 blocks** (the
     trunk-threading regression test).
   - byte-off: flag false ⇒ `_validate_cmd` nacks `caps` for all three ops (key-set asserts).
2. `verify_agent_nav.gd` — synthetic + real-worldgen grids:
   - flat run: straight path, length = Manhattan.
   - wall: path routes around; 1-high ledge: path contains a step-UP move (**the ledge-stall
     gate**); 4-deep pit between: no path through (drop cap).
   - liquid pool: never a waypoint in/over water; over-cap range/`no_path` under `NAV_NODE_CAP`
     asserted via instrumented expansion count; path ≤ `NAV_PATH_MAX`.
   - determinism: same grid ⇒ same path (no dict-order nondeterminism — sort ties).
3. `verify_agent_skill.gd` — FIND on seeded worldgen: nearest live tree found; overlay-chopped
   tree skipped (the alive-check); no-tree region ⇒ `no_tree`. Phase machine driven with scripted
   step_done records: happy path emits goto→aim→break* and terminates on air-read; each failure
   injection (`goto blocked`, `aim occluded`, cap exhaustion) lands the specified terminal.
   (The executor/follower wiring is live-A/B scope — the executor never exists headless, by design.)
4. Relay: `validate_step.test.mjs` matrix for the four ops (accept/reject + the array-target nack).

**Live A/B (real-GPU host, scripted grant session — the `flight.mjs` pattern):**

- A: `query_box` → pick a surveyed solid cell → `break_cell` → re-`query_box` ⇒ cell now air
  (closing the §2.1 verified failure).
- B: teleport to a known ledge line that stalls `move forward` today → `goto` across ⇒ `ok`,
  events show the jump.
- C: **the demo**: one `chop_tree` step from ~30 blocks out ⇒ `done.json ok`, `broken ≥ 1`, wood
  in inventory telemetry, paired screenshots before/after show the tree gone; events.jsonl shows
  the phase ladder with per-phase durations.
- D: byte-off A/B: flags-off build wire-identical (existing harness).

---

## 11. Staging + fix-site table

| Stage | Ships | Gate flag | Depends on | Kind |
|---|---|---|---|---|
| **A1** | `break_cell`/`place_cell` + relay array-target nack | `FP_AGENT_ACT` | — | relay + GDScript (re-export) |
| **A2** | `aim_cell` (+ verify) | `FP_AGENT_ACT` | A1 (shared flag), P2 (`remote_query_ray`) | GDScript |
| **A3** | `agent_nav.gd` A\* + goto follower | `FP_AGENT_NAV` | — (A1/A2 not required) | relay + GDScript |
| **A4** | `agent_skills.gd` + `chop_tree` | `FP_AGENT_SKILL` | A1+A2+A3 | relay + GDScript |

Each stage independently shippable, gated, and byte-off; A1 alone already un-breaks the verified
cell-break failure; A3 alone un-breaks ledge navigation.

| Fix site | Change |
|---|---|
| `godot/src/cosmos/cube_sphere.gd:3985` (beside `FP_AGENT_QUERY`) | `FP_AGENT_ACT`/`FP_AGENT_NAV`/`FP_AGENT_SKILL` + the §9.1 NAV/CHOP/SKILL consts |
| `godot/src/player/player.gd` (beside `remote_break` `:2349`, `remote_set_view` `:511`) | `remote_break_cell`, `remote_place_cell`, `remote_aim_solution` |
| `godot/src/net/remote_control.gd` `_start_step:450`, `_process:160`, `physics_tick:199`, `_finish_step:587` | 4 op cases; goto plan-slice poll + follower tick; aim_cell easing arm; `_skill` routing in `_finish_step` |
| `godot/src/net/agent_nav.gd` (new) | bounded time-sliced A\* (§6.2–6.3) |
| `godot/src/net/agent_skills.gd` (new) | chop_tree phase machine over virtual steps (§7.2) |
| `godot/src/net/remote_bridge.gd` `OP_WHITELIST:76`, `_validate_cmd:1274` (the `:1319` pattern) | 4 ops whitelisted; flag + shape + `NAV_RANGE_MAX` gates |
| `tools/remote-bridge/relay.mjs` `OP_WHITELIST:103`, `validateStep:370` area, `validTarget:274` | 4 ops + est; cell-shape checks; **array-target nack** |
| `tools/remote-bridge/validate.mjs` | shared cell/range validators + consts (the `QUERY_*` pattern) |
| `godot/src/tools/verify_agent_{act,nav,skill}.gd` (new), `tools/remote-bridge/test/` | §10 gates |
| `godot/src/world/world_manager.gd`, `godot/src/world/tree_gen.gd` | **no changes** — reused read-only (`block_id_at`, `cell_solid`, `break_terrain`, `place_block`, `aimed_voxel`, `has_tree`, `tree_info`) |

---

## 12. Risks

1. **Follower/planner mismatch on shaped cells** (ramps, snow fill): the full-cell A\* approximates
   the sub-cell analytic surface. Contained: mismatch ⇒ stall ⇒ replan (bounded), and the gate
   pins the flat/ledge/pit cases. Do NOT teach the planner sub-cell shapes in v1 — that duplicates
   `_occ_span` and will drift from it.
2. **Frame edge cases** — the codebase's classic class. Contained by the §3 all-LATTICE rule (no
   scene/BCI math anywhere in A1–A4) + the crossing bail-out; the aim-sign gate pins the yaw/pitch
   conventions against `player.gd:646`.
3. **Skill/step re-entrancy** in `_finish_step` routing (virtual steps vs `_next_step`): the one
   genuinely new control-flow seam. Keep `_skill` handling in exactly two places (`_start_step`
   dispatch, `_finish_step` routing) and gate-test the abort/override/grant-loss matrix on it.
4. **Planning cost on web** — bounded by `NAV_EXPAND_PER_FRAME` + the move-probe cache; the live
   gate measures the slice ms and tunes down exactly as `QUERY_CELLS_PER_FRAME` did.
5. **Deploy-worktree drift** — §9.3's `deploy_cheats.sh` caveat; pck-dump the served flags.
