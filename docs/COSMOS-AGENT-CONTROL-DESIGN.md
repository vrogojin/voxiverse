# COSMOS — Agent-Control + Situational-Awareness Design

**Status:** DESIGN (implementation to follow this doc). Author: Fable. Date: 2026-08-15.
**Inputs:** `docs/AUDIT-REMOTE-BRIDGE.md` (authoritative fix-site map — all file:line below re-verified
against this worktree), `docs/RESEARCH-FPS-AWARENESS.md`, `docs/RESEARCH-MC-AGENTS.md`.
**Scope:** the remote-bridge stack only — `tools/remote-bridge/relay.mjs`,
`godot/src/net/remote_bridge.gd`, `godot/src/net/remote_control.gd`, `godot/src/player/player.gd`,
`godot/src/world/world_manager.gd`. No engine (C++) rebuild anywhere in this design.

---

## 0. Executive summary

Three pain points, three staged fixes, each shippable alone:

| Stage | Pain point | Fix | Kind | Gate name |
|---|---|---|---|---|
| **P0** | sense→act ≈ **576 ms** typical (two serial file polls) | `fs.watch` outbox + 100 ms poll floor; agent awaits `results/<seq>/{ack,done}.json`; optional `?telem=10hz` | relay-only (+1 URL param) | env `REMOTE_BRIDGE_WATCH` / `REMOTE_BRIDGE_POLL_MS`; `FP_TELEM_10HZ` |
| **P1** | no body-orientation telemetry in space | body/camera bases + velocity vector in `view_telemetry()`; new `player.orientation_telemetry()` (BCI frame: radial up, tangent north/east, heading) | GDScript = re-export | `FP_AGENT_POSE` |
| **P2** | no structured voxel data (JPEG-only perception) | `query_box` (batched `block_id_at` → `PackedByteArray` grid, binary 0x03 downlink) + `query_ray` (reuse the `aimed_voxel` DDA; default = the aim ray) over the existing correlated `control/results/<seq>/` substrate | relay + GDScript | `FP_AGENT_QUERY` |

**New loop-latency budget:** action ack ≈ **80–150 ms typical** (vs ~576 ms audited), ≤ ~350 ms p99;
a full observe→decide→act cycle (one query round-trip + one action round-trip) ≈ **200–300 ms → a
3–5 Hz agent loop**, inside the 200–350 ms reaction budgets and ~5–10 Hz act cadences the reference
agents use (OpenAI Five 7.5 Hz/217 ms; AlphaStar ~350 ms; Malmo/Mineflayer 20 Hz native).

**Orientation-frame decision (audit §2 caveat resolved):** `view_telemetry` additions stay in the
**SCENE/global frame** (the frame `look_world` already uses — internally consistent, zero new math);
the new `orientation_telemetry()` block is **entirely BCI-world** (every key suffixed `_bci`), with the
body forward mapped scene→lattice→BCI through the exact seams `_current_target` and `radial_altitude`
already use. Two blocks, each internally consistent, frame named in the keys. §5.2 has the math.

**Query protocol shape:** queries are ordinary consent-gated `cmd_seq` steps (audit's recommendation
(a) adopted — **queries stay on the control channel**, the observe-only model is untouched, §7.3).
`query_ray` answers as a small JSON `query_result` text downlink → `results/<seq>/query-<id>.json`;
`query_box` answers as a binary `[0x03][u16 hlen][hdr JSON][u8 ids]` frame (the `handleShotFrame`
pattern) → `results/<seq>/query-<id>.bin` + sidecar `.json` header. Triple-capped never-OOM
(agent / relay `validateStep` / rover `_validate_cmd` + `block_box` itself), ≤ 32 768 cells ⇒
≤ 32 KiB payload, and the in-game fill is **time-sliced** (≤ 4096 cells/frame) so a max box never
hitches a frame.

**Byte-off discipline:** with `FP_AGENT_POSE`/`FP_AGENT_QUERY` off (and no `?telem=10hz`), the
game's wire behaviour — telemetry stream bytes, inbound handling, op acceptance — is identical to
today's observe bridge. The relay changes are host tooling (same rebuild rule as every prior relay
change) and default to behaviour-compatible (watch is an accelerator over the poll, not a replacement).

---

## 1. The audited baseline (what we are fixing)

From `AUDIT-REMOTE-BRIDGE.md` §1, one action `agent → outbox → relay → game → result → agent`:

- **Hop 2** — relay outbox poll: `POLL_MS = 500` (`relay.mjs:86`), `setInterval(pollOutbox, POLL_MS)`
  (`relay.mjs:952`) → ~250 ms typical wait.
- **Hop 7** — the agent's own result-file poll → ~250 ms typical.
- **Hop 6b** — anyone confirming via telemetry pays the `TELEMETRY_INTERVAL = 0.25` window
  (`remote_bridge.gd:88`, tick at `:498`).
- Everything else (WS transit, 1-frame in-game apply, ack downlink) is < 200 ms combined worst.

Total: **~576 ms typical / ~1730 ms worst** awaiting the ACK; **~715 ms / ~2020 ms** confirming via
telemetry. The felt "seconds" is real and is entirely plumbing — no engine cost involved.

The request/response substrate we need for P2 **already exists**: `forward` mkdirs
`control/results/<seq>/` (`relay.mjs:453`), downlink results are seq-correlated and owner-gated
(`resultsDirFor` `relay.mjs:231`, `ownsDownlink` check `relay.mjs:700`), and the commanded screenshot
is a working binary request→response (`handleShotFrame` `relay.mjs:733` ↔ `_send_shot_frame`
`remote_bridge.gd:1408`). P2 generalizes it to typed data; nothing structurally new.

---

## 2. Frame glossary (used throughout)

| Frame | What | Where it appears today |
|---|---|---|
| **LATTICE** | active facet's local voxel grid; cells are `Vector3i`; all `WorldManager` queries live here | `block_id_at` `world_manager.gd:1628`, `aimed_voxel` `:4716`, `player.position` |
| **SCENE/global** | Godot global space. With FP-FIXED-FRAME the player rides an `ActiveFrame`, so SCENE = ActiveFrame ∘ LATTICE; frame off ⇒ SCENE = LATTICE | `player.global_transform`, `look_world` (`player.gd:402`), camera |
| **BCI world** | body-centred-inertial f64 world; **planet centre = origin**; stable across facet crossings and frame re-anchors | `FacetAtlas.lattice_to_world64` (used by `radial_altitude` `player.gd:1013`), the nav kernel |

Conversion seams (all existing, all pure):
- SCENE → LATTICE: `_frame.g2l_point` / `_frame.g2l_dir` (`frame_adapter.gd:53,63`; identity when the
  fixed frame is off) — exactly what `_current_target` does at `player.gd:2015-2016`.
- LATTICE → BCI (points): `FacetAtlas.lattice_to_world64(fid, x, y, z)` (f64 Array) — exactly what
  `radial_altitude` does at `player.gd:1013`.
- LATTICE → BCI (**directions**): the facet placement is affine-rigid, so map two points and subtract:
  `dir_bci = w64(p + d) − w64(p)` — exact, no epsilon, no new API needed.

---

## 3. P0 — Latency (relay-JS-first; no export, no rebuild)

### 3.1 (a) Outbox: `fs.watch` on-write forwarding + a lowered poll floor

**Fix site:** `relay.mjs:86` (`POLL_MS`), `relay.mjs:537` (`pollOutbox`), `relay.mjs:952`
(`setInterval(pollOutbox, POLL_MS)`). **Relay-only.**

The code comment at `relay.mjs:86` is right that `fs.watch` is unreliable on bind mounts — so watch
is an **accelerator**, the poll remains the **reconciliation floor**:

```js
// P0-AGENT-LATENCY: forward on-write. fs.watch is unreliable on bind mounts (see POLL_MS note), so it
// only ACCELERATES the poll — the poll stays as the reconciliation floor and remains authoritative.
const WATCH_ENABLED = process.env.REMOTE_BRIDGE_WATCH !== '0';           // default ON
const POLL_MS = parseInt(process.env.REMOTE_BRIDGE_POLL_MS || '100', 10); // floor 500 → 100

let watchKick = null;
if (WATCH_ENABLED) {
  try {
    watch(OUTBOX_DIR, { persistent: false }, () => {
      // Coalesce bursts (tmp+rename fires 2 events); run through the SAME pollOutbox so ingest,
      // dedupe (ingestedFiles/seenSeqs), caps and audit are byte-for-byte the poll path.
      if (watchKick) return;
      watchKick = setTimeout(() => { watchKick = null; pollOutbox(); }, 5);
    });
    log('outbox watch armed (poll floor', POLL_MS + 'ms)');
  } catch (e) { log('fs.watch unavailable — poll-only:', e.message); }
}
```

Design points:
- The watch callback calls **`pollOutbox()` itself**, never a private ingest path — one code path,
  so validation/dedup/audit semantics cannot fork. `pollOutbox` is already idempotent
  (`ingestedFiles` guard `relay.mjs:541`, `seenSeqs` dedupe `:531`) and cheap (one `readdirSync` of a
  near-empty dir), so a 5 ms debounce + 100 ms floor costs nothing.
- Import `watch` from `node:fs` alongside the existing imports. `{ persistent: false }` so the
  watcher never keeps the process alive on shutdown.
- Poll floor 100 ms (not 50): the poll is now the *backstop*, not the latency path; 10 Hz directory
  listing is invisible and keeps bind-mount worst-case bounded at ~100 ms.

**Effect on hop 2:** ~250 ms typical → **~5–10 ms typical** (watch), ≤ ~100 ms worst (poll floor,
watch missed).

### 3.2 (b) Agent-side loop: await the correlated results, stop scraping telemetry

**No code change in this repo** — this is a protocol contract for the agent harness (and
`tools/remote-bridge/` driver scripts like `flight.mjs` should be updated to it when next touched).

The relay already writes, per forwarded `<seq>`:
- `control/results/<seq>/ack.json` — accepted (`cmd_ack` branch, `relay.mjs:705-706`); a nack also
  lands here plus a terminal `done.json` (`relay.mjs:711-714`).
- `control/results/<seq>/events.jsonl` — `step_start`/`step_done` (`relay.mjs:717-719`).
- `control/results/<seq>/done.json` — terminal, **always** written: normal completion
  (`relay.mjs:721-723`), nack (`:713`), preempt (`:456`), grant loss (`abortInFlight` `:590-596`).

**Contract:** after writing `outbox/<seq>.json` (atomic tmp+rename), the agent `fs.watch`es
`control/results/<seq>/`… except that dir doesn't exist until forward. So: watch
`control/results/` (the parent, which always exists — created at `relay.mjs:177`) for the `<seq>`
dir appearing, then watch inside it; fall back to a **20–25 ms poll** of the two file paths (same
bind-mount caveat as the relay). Await `ack.json` (accepted/rejected), then `done.json`
(completion), reading `events.jsonl` for per-step progress. **Never** tail `telemetry.jsonl` for
completion — `done.json` is not gated by the 250 ms telemetry window (audit W2).

**Effect on hop 7:** ~250 ms typical → **~5–25 ms**.

### 3.3 (c) Optional: `?telem=10hz` ambient-rate raise (GDScript = re-export)

**Gate:** `FP_TELEM_10HZ` (a `cube_sphere` flag const, default **true** is NOT allowed here — the
knob is the URL param itself; the flag only compiles the parser branch in, mirroring how
`FP_TELEM_FRAME_DECOMP` gates `?telem=1hz`). **Byte-off:** without the URL param the interval stays
0.25 s — the stream is wire-identical.

**Fix site:** the existing `?telem=` parse — `telem_1hz` capture at `remote_bridge.gd:252`, applied at
`remote_bridge.gd:352-355`. Add the symmetric branch:

```gdscript
# P0-AGENT-LATENCY (FP_TELEM_10HZ): ?telem=10hz raises the ambient snapshot to 10 Hz for an agent
# session. Param-gated (no param ⇒ 0.25 s, wire-identical); the snapshot cost is already self-timed
# (telem_ms), so a real-GPU session can verify the observer stays cheap at 10 Hz.
elif CubeSphere.FP_TELEM_10HZ and telem_10hz:
    _telem_interval = 0.1
```

Bandwidth sanity: a telemetry record is ~1–2 KB; 10 Hz ≈ 20 KB/s — trivial against the JPEG stream,
and well inside the relay's `MAX_MSG_PER_SEC = 60` (`relay.mjs:77`; 10 telemetry + ~0.5 frames + result
frames ≪ 60). Note this is **ambient freshness only** — completion/queries never wait on it after 3.2.

### 3.4 New sense→act budget (replaces audit §1 sums)

| # | Hop | Today | After P0 |
|---|-----|-------|----------|
| 1 | agent writes outbox | ~0 | ~0 |
| 2 | relay pickup | ~250 / 500 | **~5–10 / ~100** (watch / poll floor) |
| 3 | validate+forward | ~1 | ~1 |
| 4 | WS uplink | ~30 / 120 | ~30 / 120 |
| 5 | game ack (1 frame) | ~16–33 / 66 | ~16–33 / 66 |
| 6a | WS downlink → ack.json | ~30 / 120 | ~30 / 120 |
| 7 | agent reads result | ~250 / 1000 | **~5–25 / ~50** |
| | **Total (await ack)** | **~576 / ~1730** | **~80–150 typical / ~350 worst** |

Effect-confirmation via a P2 `query_*` result rides the same profile (it is a downlink result, not
telemetry), so "act, then read the world" is two of these round-trips ≈ 200–300 ms — a 3–5 Hz loop
with zero engine changes. That is the whole latency war: **won in the plumbing**, exactly as the
research predicts (RESEARCH-FPS-AWARENESS §3).

---

## 4. P1 — Orientation telemetry (GDScript = re-export)

**Gate:** `FP_AGENT_POSE` (new `cube_sphere` const, default **false** until gated + live-verified,
then flipped like every FP flag). All additions follow the established **additive +
empty-dict-guarded** telemetry pattern (`_merge_rich_state` `remote_bridge.gd:869`): flag off ⇒ the
accessors return exactly today's dicts ⇒ the merged stream is **byte-identical**.

### 4.1 `view_telemetry()` additions — SCENE frame (site: `player.gd:399`)

`view_telemetry` already returns `{cam_yaw_deg, cam_pitch_deg, look_world}` merged at
`remote_bridge.gd:876-879`; new keys ride that merge with zero bridge change. `look_world` is a
`"(%f, %f, %f)"` string (`player.gd:406`) — a restore-format quirk we keep for that one key; **all new
vector keys are `[x,y,z]` float arrays** (snapped 0.001), the format every other consumer wants.
Decide once, applied to every new key in P1+P2.

```gdscript
func view_telemetry() -> Dictionary:
    if _camera == null:
        return {}
    var fwd := (-_camera.global_transform.basis.z).normalized()
    var out := {
        "cam_yaw_deg": snappedf(rad_to_deg(rotation.y), 0.01),
        "cam_pitch_deg": snappedf(rad_to_deg(_pitch), 0.01),
        "look_world": "(%f, %f, %f)" % [fwd.x, fwd.y, fwd.z],
    }
    # FP_AGENT_POSE (COSMOS-AGENT-CONTROL §4.1): the full SCENE-frame pose an agent needs — body basis
    # (fwd/right/up), camera right/up (roll about forward is otherwise unknowable), velocity VECTOR.
    # ADDITIVE + flag-gated: off ⇒ exactly the three shipped keys (byte-identical stream).
    if CubeSphere.FP_AGENT_POSE:
        var b := global_transform.basis
        var cb := _camera.global_transform.basis
        out["body_fwd"]   = _v3a(-b.z)
        out["body_right"] = _v3a(b.x)
        out["body_up"]    = _v3a(b.y)
        out["cam_right"]  = _v3a(cb.x)
        out["cam_up"]     = _v3a(cb.y)
        out["vel"]        = _v3a(velocity)      # CharacterBody3D velocity, SCENE frame
        out["on_ground"]  = is_on_floor()
    return out

## [x,y,z] float array, snapped 0.001 — THE vector telemetry format (new keys only; look_world keeps
## its legacy string form for restore-compat).
func _v3a(v: Vector3) -> Array:
    return [snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001)]
```

Godot conventions (RESEARCH-FPS-AWARENESS §5): forward = `-basis.z`, right = `basis.x`,
up = `basis.y`. All six emitted vectors are SCENE-frame — the same frame as the existing
`look_world` and `pos` (`remote_bridge.gd:872`), so the block stays internally consistent.

### 4.2 New `player.orientation_telemetry()` — BCI frame (**the frame decision**)

**Decision (resolves audit §2 caveat):** this block is computed **entirely in BCI world**. Rationale:

1. BCI is the only frame **stable across facet crossings and fixed-frame re-anchors** — the SCENE
   basis jumps by the dihedral at every crossing (`apply_reframe` `player.gd:419`), which would make
   an agent's heading discontinuous mid-`move`; up/north/east are *natural* in BCI (planet centre =
   origin).
2. Mixing frames inside one block is exactly the bug the audit warned about; suffixing every key
   `_bci` makes the frame machine-checkable.
3. The scene→BCI hop reuses two shipped seams verbatim (`_frame.g2l_dir` from `_current_target`
   `player.gd:2015-2016`; `lattice_to_world64` from `radial_altitude` `player.gd:1013`) — no new
   transform code paths to trust.

New accessor beside `radial_altitude` (`player.gd:1009`); merged in `_merge_rich_state` beside the
`space_telemetry` merge (`remote_bridge.gd:890-893`) with the identical guarded pattern:

```gdscript
## FP_AGENT_POSE (COSMOS-AGENT-CONTROL §4.2): planet-local orientation, ENTIRELY in BCI world
## (planet centre = origin; keys suffixed _bci). up = radial; north = spin axis (+Y BCI) projected
## to the tangent plane; east = up × north (right-handed → east); heading = atan2(f·east, f·north).
## The body forward maps SCENE → lattice (_frame.g2l_dir, identity when the fixed frame is off)
## → BCI (affine two-point map through lattice_to_world64 — exact for the rigid facet placement).
## Returns {} off-faceted / flag-off / no active facet ⇒ byte-identical stream.
func orientation_telemetry() -> Dictionary:
    if not (CubeSphere.FP_AGENT_POSE and CubeSphere.FACETED):
        return {}
    var fid := TerrainConfig.active_facet()
    if fid < 0:
        return {}
    var w: Array = _FacetAtlasCls.lattice_to_world64(fid, position.x, position.y, position.z)
    var P := Vector3(w[0], w[1], w[2])
    var up := P.normalized()
    var y_dot := Vector3.UP.dot(up)
    if absf(y_dot) > 0.9999:                       # at a pole north is undefined — omit heading
        return {"up_bci": _v3a(up), "pos_bci": _v3a(P)}
    var north := (Vector3.UP - y_dot * up).normalized()
    var east := up.cross(north)
    # Body forward: SCENE → LATTICE → BCI. Direction map = affine two-point difference (exact).
    var f_lat := _frame.g2l_dir(-global_transform.basis.z)
    var w2: Array = _FacetAtlasCls.lattice_to_world64(fid,
        position.x + f_lat.x, position.y + f_lat.y, position.z + f_lat.z)
    var f_bci := Vector3(w2[0] - w[0], w2[1] - w[1], w2[2] - w[2]).normalized()
    var f_t := (f_bci - f_bci.dot(up) * up)
    var out := {"up_bci": _v3a(up), "north_bci": _v3a(north), "east_bci": _v3a(east),
                "fwd_bci": _v3a(f_bci), "pos_bci": _v3a(P)}
    if f_t.length() > 1e-4:                        # looking straight up/down ⇒ heading undefined
        out["heading_deg"] = snappedf(rad_to_deg(atan2(f_t.dot(east), f_t.dot(north))), 0.1)
    return out
```

Bridge merge (site: `remote_bridge.gd:893`, immediately after the `space_telemetry` merge, same
shape):

```gdscript
# FP_AGENT_POSE (COSMOS-AGENT-CONTROL §4.2): BCI planet-local orientation (up/north/east/fwd/heading).
# ADDITIVE + empty-dict-guarded — {} when flag-off/non-faceted ⇒ byte-identical stream.
if player.has_method("orientation_telemetry"):
    var ot = player.call("orientation_telemetry")
    if ot is Dictionary and not (ot as Dictionary).is_empty():
        msg.merge(ot as Dictionary)
```

**Exact key inventory after P1** (agent-facing contract):

| Key | Frame | Type | Source |
|---|---|---|---|
| `body_fwd`,`body_right`,`body_up` | SCENE | [x,y,z] | `view_telemetry` |
| `cam_right`,`cam_up` (+ existing `look_world`) | SCENE | [x,y,z] / string | `view_telemetry` |
| `vel`, `on_ground` | SCENE | [x,y,z] / bool | `view_telemetry` |
| `up_bci`,`north_bci`,`east_bci`,`fwd_bci`,`pos_bci` | BCI | [x,y,z] | `orientation_telemetry` |
| `heading_deg` | BCI tangent | float (0 = north, 90 = east) | `orientation_telemetry` |

### 4.3 P1 gate (headless, CPU-testable)

`godot/src/tools/verify_agent_pose.gd` (the `verify_feature.gd` pattern):
- **Math invariants:** |up_bci| = 1; up·north = 0 (≤1e-5); east == up×north; at a known equatorial
  pose, heading of the +north-facing body ≈ 0 and +east-facing ≈ 90 (place the player at fixed
  facet/pos/yaw, assert to 0.5°).
- **Frame-consistency:** with the fixed frame at identity, `fwd_bci` from the two-point map equals
  the directly rotated facet-basis forward (≤1e-4) — proves the seam mapping.
- **Byte-off:** with `FP_AGENT_POSE=false`, `view_telemetry()` returns exactly the 3 shipped keys
  and `orientation_telemetry()` returns `{}` (assert key sets, mirroring existing byte-off gates).
- **Degeneracy:** pole pose omits `heading_deg`/`north_bci`; straight-down look omits `heading_deg`.

---

## 5. P2 — Voxel-data query (the structural centrepiece; relay + GDScript)

**Gate:** `FP_AGENT_QUERY` (cube_sphere const). Also gated — like every op — behind
`CONTROL_ENABLED` (`remote_bridge.gd:63`) + a live grant (see §7.3 for the decision). Flag off ⇒
the two ops nack `caps` in `_validate_cmd` and the whitelist entries are dead strings; the wire
behaviour of an OFF build is identical to today.

### 5.1 Two ops, one substrate

Queries are **ordinary steps in a `cmd_seq`** — they ride the existing intake
(`ingestFile`→`validateCmd`→`forward`; `_on_cmd_seq` `remote_bridge.gd:1225` →
executor `begin_sequence` `remote_control.gd:113`), and answer through the existing correlated
result sink. They compose with actuation in one sequence
(`[look, query_ray, break, query_box]`), which is exactly what an agent loop wants.

**`query_box`** — a 3D block-id array over a bounded box.
```jsonc
{"op": "query_box",
 "center": [x, y, z] | "player",     // lattice cell; "player" (default) = the player's cell
 "half": [hx, hy, hz],               // half-extents; dims = 2h+1 per axis
 "id": 1}                            // step-local result id (like screenshot's shot id)
```
**`query_ray`** — the DDA raycast; default = **the aim ray** (camera eye + camera forward), which
alone answers "which cell does my crosshair hit" before a break/place.
```jsonc
{"op": "query_ray",
 "origin": [x,y,z] | "eye",          // SCENE-frame point; "eye" (default) = camera eye
 "dir": [x,y,z] | "look",            // SCENE-frame direction; "look" (default) = camera forward
 "max_dist": 8.0,                    // ≤ QUERY_RAY_MAX
 "id": 2}
```

### 5.2 Relay plumbing (relay-only)

1. **`OP_WHITELIST`** `relay.mjs:95`: add `'query_box', 'query_ray'` (with a P2 design-doc comment in
   the style of the existing dev-op annotations).
2. **`validateStep`** `relay.mjs:266` — hard NEVER-OOM caps beside the existing const block
   (`relay.mjs:89-109`):
   ```js
   const QUERY_HALF_MAX  = 15;      // per-axis half-extent  (dim ≤ 31)
   const QUERY_CELLS_MAX = 32768;   // Π(2h+1) — 31³=29791 fits; ids are u8 ⇒ ≤ 32 KiB payload
   const QUERY_RAY_MAX   = 64.0;    // blocks
   ```
   ```js
   case 'query_box': {
     if (st.center !== undefined && st.center !== 'player' &&
         !(Array.isArray(st.center) && st.center.length === 3 &&
           st.center.every((n) => typeof n === 'number' && isFinite(n))))
       return rej('caps', 'query_box.center must be "player" or [x,y,z]');
     const h = st.half;
     if (!(Array.isArray(h) && h.length === 3 &&
           h.every((n) => Number.isInteger(n) && n >= 0 && n <= QUERY_HALF_MAX)))
       return rej('caps', `query_box.half must be 3 ints in [0,${QUERY_HALF_MAX}]`);
     const cells = (2 * h[0] + 1) * (2 * h[1] + 1) * (2 * h[2] + 1);
     if (cells > QUERY_CELLS_MAX) return rej('caps', `query_box ${cells} cells > ${QUERY_CELLS_MAX}`);
     return okEst(0.5 + cells / 32768);          // time-sliced fill (§5.4) ⇒ ≤ ~1.5 s worst
   }
   case 'query_ray': {
     if (st.origin !== undefined && st.origin !== 'eye' && !finiteVec3(st.origin))
       return rej('caps', 'query_ray.origin must be "eye" or [x,y,z]');
     if (st.dir !== undefined && st.dir !== 'look' &&
         !(finiteVec3(st.dir) && Math.hypot(...st.dir) > 1e-6))
       return rej('caps', 'query_ray.dir must be "look" or a non-zero [x,y,z]');
     if (st.max_dist !== undefined &&
         !(typeof st.max_dist === 'number' && st.max_dist > 0 && st.max_dist <= QUERY_RAY_MAX))
       return rej('caps', `query_ray.max_dist must be in (0,${QUERY_RAY_MAX}]`);
     return okEst(0.3);
   }
   ```
3. **Text result** (`query_ray` + small-box fallback): add `'query_result'` to `RESULT_TYPES`
   `relay.mjs:690`, and a branch in the `routeControlEvent` switch `relay.mjs:704` (after `cmd_nack`),
   owner-gated exactly like its siblings (the `ownsDownlink` check at `:700` already covers it):
   ```js
   case 'query_result': {
     const idPart = safeId(String(obj.id)) ? String(obj.id) : 'x';
     writeResult(obj.seq, `query-${idPart}.json`, obj);
     audit('query_result', { seq: obj.seq, id: idPart, kind: obj.kind });
     return true;
   }
   ```
4. **Binary result** (`query_box`): a third binary tag beside `FRAME_TAG`/`SHOT_TAG` (`relay.mjs:82-83`):
   ```js
   const QUERY_TAG = 0x03;   // query payload [0x03][u16 hlen BE][hdr JSON {seq,id,kind,origin,dims,order,fmt}][payload]
   ```
   and a `handleQueryFrame(conn, data)` mirroring `handleShotFrame` `relay.mjs:733` line-for-line:
   parse `[u16 hlen]` header; `resultsDirFor(hdr.seq)` gate; `ownsDownlink` gate; validate
   `hdr.fmt === 'u8'` and `payload.length === dims[0]*dims[1]*dims[2]` (reject + audit on mismatch);
   write `query-<id>.bin` (payload) + `query-<id>.json` (the header, as the agent-readable sidecar)
   into the seq dir. Dispatch: the binary-frame switch that routes `SHOT_TAG` gains the `QUERY_TAG`
   case. Size: ≤ 32 KiB ≪ `MAX_FRAME_BYTES` (2 MiB, `relay.mjs:78`) — no backpressure interplay.

### 5.3 In-game handler (GDScript = re-export)

**Dispatch path — the screenshot pattern, verbatim:** the executor treats `query_*` like
`screenshot` (an async op the *bridge* fulfils, because the bridge owns `world`, `player`, and the
socket — `remote_control.gd` has only `player`):

- `remote_control.gd`: new signal `query_requested(seq, id, spec)` beside `shot_requested` (`:37`);
  `_start_step` match (`:434`) emits it (like the screenshot arm at `:438-443`) and `_process`
  (`:151-167`) polls a `_query_done/_query_ok` latch with a deadline, mirroring the
  `"screenshot"` arm at `:155-159`; bridge calls back `notify_query(id, ok)` (mirror of
  `notify_shot` `:138`).
- `remote_bridge.gd`: connect the signal in `_ensure_executor` (`:1427`, beside `shot_requested`
  `:1436`); re-validate caps in `_validate_cmd` (`:1247`) — **mirror the relay caps exactly**, plus
  the flag gate:
  ```gdscript
  # FP_AGENT_QUERY (COSMOS-AGENT-CONTROL §5): rover-side re-cap — never trust the relay (same
  # discipline as MAX_MOVE_BLOCKS above). Flag off ⇒ caps-nack: wire behaviour identical to today.
  if op == "query_box" or op == "query_ray":
      if not CubeSphere.FP_AGENT_QUERY:
          return "caps"
      # … QUERY_HALF_MAX / QUERY_CELLS_MAX / QUERY_RAY_MAX re-checks (consts mirrored beside
      # MAX_STEPS/MAX_MOVE_BLOCKS at remote_bridge.gd:72-74) …
  ```
  and add the two op names to the rover `OP_WHITELIST` `remote_bridge.gd:75`.
- Result send: `_send_query_result(seq, id, dict)` (text, for `query_ray`) mirroring the guarded
  text sends; `_send_query_frame(seq, id, hdr, payload)` (binary 0x03) mirroring `_send_shot_frame`
  `remote_bridge.gd:1408` including the `OUTBOUND_BACKPRESSURE_BYTES` check the shot path uses
  (`:1366`).

**`query_ray` execution** (in the bridge handler): resolve defaults from the player's camera, then
the *exact* `_current_target` seam (`player.gd:2013-2016`):
```gdscript
var origin: Vector3 = camera_eye if spec_origin == "eye" else Vector3(ox, oy, oz)   # SCENE frame
var dir: Vector3 = cam_fwd if spec_dir == "look" else Vector3(dx, dy, dz).normalized()
var res: Dictionary = world.aimed_voxel(_frame_of(player).g2l_point(origin),
                                        _frame_of(player).g2l_dir(dir), max_dist)
```
Reply `{type:"query_result", seq, id, kind:"ray", hit, voxel:[x,y,z], normal:[x,y,z],
position:[x,y,z], surface_normal?, block_id: world.block_id_at(voxel), in_range: dist <= player.break_reach}` —
`aimed_voxel` (`world_manager.gd:4716`) already returns hit/voxel/normal/position (+
`surface_normal` for shaped cells, `:4773-4779`); we add `block_id` (one `block_id_at` call) and the
Malmo-style `in_range` so "look + click" becomes one query (RESEARCH-MC-AGENTS §7). Positions in the
reply are lattice-frame cells/points — cells are frame-invariant, and the agent addresses
`query_box`/`break`/`place` by cell, so no back-mapping is needed.

**`WorldManager.block_box`** — new batch method sited beside `block_id_at` (`world_manager.gd:1628`):

```gdscript
## COSMOS-AGENT-CONTROL §5 (FP_AGENT_QUERY): batched block_id_at over a box — THE agent neighborhood
## query. Composes the ONE authoritative cell query (edit-overlay-else-generated), so the returned
## grid matches physics/render/DDA exactly (CLAUDE.md rule 1 — never a parallel "what's solid").
## NEVER-OOM: caller + relay + rover all cap; asserted again here — an over-cap request returns {}.
## `budget` cells are filled per call (time-slice seam, §5.4); `state` carries the cursor between
## calls. x-fastest, then z, then y (matches the dy/dz/dx loop order — document in `order`).
func block_box_slice(center: Vector3i, half: Vector3i, state: Dictionary, budget: int) -> bool:
    # state: {"ids": PackedByteArray (pre-resized), "i": int}; returns true when complete.
    # inner loop: for dy → for dz → for dx: ids[i] = block_id_at(center + Vector3i(dx,dy,dz))
    # BlockCatalog ids fit u8 today; assert id ≤ 255 once (fail the query, never truncate silently).
```
Header for the 0x03 frame: `{"seq", "id", "kind":"box",
"origin":[cx-hx, cy-hy, cz-hz], "dims":[2hx+1, 2hy+1, 2hz+1], "order":"x-fastest,z,y", "fmt":"u8"}`.

### 5.4 Cost control: the fill is time-sliced (NEVER a frame hitch)

A naive 29 791-cell loop through `cell_value_at` is a main-thread stall (the move-probe lesson:
un-memoized `cell_value_at` cost 8.8 ms for far fewer probes — `FP_MOVE_PROBE_CACHE`,
`world_manager.gd:306`). So the bridge handler fills the box **across frames** via
`block_box_slice` with `QUERY_CELLS_PER_FRAME := 4096` (≈1–3 ms/frame on web; tune at gate time),
driven from the same polled-async structure the screenshot uses. Max box ⇒ ~8 frames ≈ 130 ms —
inside the step estimate; typical agent boxes (5³=125, 9³=729) complete in **one frame** and return
at ack latency. The executor's existing watchdog bounds the worst case; `stop`/abort frees the
in-progress state dict (a few KB — trivially never-OOM).

### 5.5 Agent read

- `control/results/<seq>/query-<id>.json` — ray results and every box header (sidecar).
- `control/results/<seq>/query-<id>.bin` — the u8 id grid; decode with the sidecar's
  `origin/dims/order/fmt`.
Same ergonomics (and the same §3.2 watch/poll) as `ack.json`/`shot-*.jpg`.

### 5.6 P2 gates

**Headless (CPU, `verify_feature.gd` pattern — `verify_agent_query.gd`):**
- `block_box_slice` equality: for random boxes, the assembled grid equals a direct
  `block_id_at` loop — **including after `break_block`/`place_block` edits** (proves the overlay
  layer, the whole point of routing through `block_id_at`).
- Ordering: a marked cell (place a unique block) lands at the computed x-fastest index.
- Caps: over-cap `half` refused at `_validate_cmd` (nack `caps`) and by `block_box_slice` itself.
- Ray: `query_ray("eye","look")` result equals `_current_target`'s terrain branch for the same pose.
- Byte-off: `FP_AGENT_QUERY=false` ⇒ both ops nack `caps`; no 0x03 frame ever emitted.

**Relay (node, offline):** a `tools/remote-bridge/test/validate_step.test.mjs` driving
`validateStep` with the cap matrix (accept/reject table), plus a `latency_probe.mjs` that writes an
outbox file and measures time-to-`sent/` rename: **< 20 ms** with watch, < ~600 ms poll-only
(P0's acceptance number).

**Live A/B (the WS round-trip; real-GPU host):** scripted grant session (the `flight.mjs` pattern):
(1) `query_ray` defaults → assert `hit` + `block_id` matches the block the crosshair shows in a
paired `screenshot`; (2) `break` that cell → `query_box(center=cell, half=[1,1,1])` → assert the
cell reads air (id 0) — the full observe→act→verify loop; (3) log per-step
`_rx − issued` deltas from `events.jsonl` and assert the §3.4 budget (p50 < 200 ms, p99 < 500 ms
for query steps).

---

## 6. Agent-side usage — the new observe→decide→act loop

```text
loop (~3–5 Hz):
  1. OBSERVE  write outbox/<seq>.json:
              steps=[{op:"query_ray", id:1}, {op:"query_box", half:[4,3,4], id:2}]
              await results/<seq>/done.json (fs.watch + 20 ms poll fallback)
              read query-1.json (crosshair cell + in_range), query-2.bin (occupancy grid)
              read latest telemetry record for pose (body_fwd/vel/up_bci/heading_deg) — ambient,
              10 Hz under ?telem=10hz; never used for completion
  2. DECIDE   plan on structured state (A* over the id grid, aim math on the BCI frame keys)
  3. ACT      write outbox/<seq+1>.json: e.g. [{op:"turn",...},{op:"move",...},{op:"break",target:"aim"}]
              await ack.json (accepted), stream events.jsonl (per-step), await done.json
  4. VERIFY   (when it matters) one query step re-reads the affected cells — at ack latency,
              never waiting on the telemetry window
```
JPEG screenshots demote to a debug/VLM side-channel (the research consensus: Voyager/GITM-class
agents never decide from pixels — RESEARCH-MC-AGENTS §6.1).

---

## 7. Never-OOM + security

### 7.1 Never-OOM
- **Triple caps** on every query: agent sanity → relay `validateStep` (§5.2) → rover
  `_validate_cmd` + `block_box_slice`'s own assert (§5.3). The relay only routes; the rover never
  trusts it (`remote_bridge.gd:71` discipline, unchanged).
- Payload ceiling: u8 ids × ≤ 32 768 cells = **≤ 32 KiB** per result, one result in flight per step,
  sequences capped at `MAX_STEPS 64` and one-seq-in-flight (`relay.mjs:484-488`) ⇒ bounded by
  construction. The shot path's `OUTBOUND_BACKPRESSURE_BYTES` guard applies to 0x03 sends.
- Time-sliced fill (§5.4) bounds per-frame CPU; state freed on abort/override.
- Relay: results live under the existing per-seq dirs (operator-pruned, same as shots);
  `ingestedFiles`/`seenSeqs` pruning (`relay.mjs:545-565`) is untouched; the watch adds one timer.
- 10 Hz telemetry ≈ 20 KB/s and stays inside `MAX_MSG_PER_SEC` (§3.3).

### 7.2 Byte-off inventory
| Gate | Off ⇒ |
|---|---|
| `REMOTE_BRIDGE_WATCH=0` + `REMOTE_BRIDGE_POLL_MS=500` | today's relay, exactly |
| no `?telem=10hz` (or `FP_TELEM_10HZ` false) | 0.25 s stream, wire-identical |
| `FP_AGENT_POSE` false | `view_telemetry` = 3 shipped keys; `orientation_telemetry` = `{}` ⇒ byte-identical telemetry |
| `FP_AGENT_QUERY` false | query ops nack `caps`; no 0x03 frames; wire-identical |
| `CONTROL_ENABLED` false | everything above P0 is dead code — the Phase-1 observe bridge |

### 7.3 The CONTROL_ENABLED decision (audit's open question — resolved)

**Queries stay on the consented control channel** (audit option (a)). Justification:
1. The observe path's security model is **send-only**: pre-grant inbound is drained-and-discarded
   (`remote_bridge.gd:460-474`). Any consent-free query verb would make every live session execute
   attacker-triggerable compute (a 30 k-cell fill) on inbound frames — a DoS/probe surface that
   today structurally cannot exist. Do not weaken it.
2. Queries disclose world state at agent-chosen coordinates (including the player-edit overlay —
   what the player built/dug). That is agent-session data, appropriately behind the same
   consent + control-token + nonce-bound-grant machinery as acting (`relay.mjs:143-173`).
3. The entire substrate (results dirs bound to forwarded seqs `relay.mjs:231`, `ownsDownlink`
   forge-rejection `:700`, audit trail) exists **only** on the control path; a parallel read channel
   duplicates the attack surface for zero agent benefit — an agent that can't obtain a grant can't
   act on what it reads anyway.
Cost accepted: a pure observer cannot query. If that need ever materializes, it is a separate
security review (a read-only grant class), not a rider on this design.

### 7.4 Other security notes
- Both new ops go through the same whitelists (`relay.mjs:95`, `remote_bridge.gd:75`), grant gating,
  per-socket result-owner tagging, and audit events (`query_result` audited like `shot`).
- `handleQueryFrame` re-validates header ids via `safeId` and payload length vs dims before any
  disk write — a malformed game frame is dropped + audited, mirroring `handleShotFrame`.
- No new secrets, no change to the token/grant/HMAC machinery, no change to the fail-closed
  `CONTROL_AVAILABLE` law (`relay.mjs:157-161`).

---

## 8. Staging + risks

| Stage | Ships | Depends on | Kind | Verification |
|---|---|---|---|---|
| **P0** | watch+poll-floor relay; agent await-results contract; `?telem=10hz` | — | relay-only (+1 param re-export if 10hz taken) | `latency_probe.mjs` < 20 ms; live: `events.jsonl` `_rx − issued` p50 < 200 ms |
| **P1** | `FP_AGENT_POSE`: scene bases + vel, BCI orientation block | — (P0 independent) | GDScript = re-export | `verify_agent_pose.gd` (math + byte-off) |
| **P2** | `FP_AGENT_QUERY`: `query_box`/`query_ray` end-to-end | P0 recommended (latency), P1 not required | relay + GDScript | `verify_agent_query.gd` + `validate_step.test.mjs` + live A/B (§5.6) |

Each stage is byte-off/behaviour-compatible alone; P2 without P0 still works (at today's poll
latency); P1 keys are useful the moment they stream regardless of P0/P2.

**Risks**
1. **`fs.watch` on bind mounts** — known-unreliable (the `relay.mjs:86` comment). Mitigated by
   design: watch only accelerates; the 100 ms poll floor is authoritative. Worst case = watch never
   fires ⇒ still 5× better than today.
2. **`block_box` main-thread cost on web** — mitigated by the §5.4 time-slice; the gate measures
   ms/4096-cell slice on the live host and tunes `QUERY_CELLS_PER_FRAME` down if needed. Do NOT
   "optimize" by bypassing `block_id_at` — the overlay consistency is the product.
3. **Frame-confusion regressions** — the classic class in this codebase (pose/facet desync memories).
   Contained by the two-block rule (§4): SCENE keys and `_bci` keys never mix, and the BCI hop
   reuses shipped seams only. The P1 gate's frame-consistency assert pins it.
4. **Telemetry record growth** (P1 adds ~11 keys ≈ 300 B) — negligible at 4 Hz, fine at 10 Hz;
   `telem_ms` self-instrumentation already reports the snapshot cost if it ever isn't.
5. **Deploy-worktree drift** — the live pck is exported from THIS worktree; per the established
   lesson, verify served flags by pck dump after deploy (`FP_AGENT_*` present + values), and
   remember `deploy_cheats.sh` git-checkout-reverts `remote_bridge.gd` — the P1/P2 bridge edits must
   land in the file *before* the cheat-flip step, or they silently vanish from the served build.

**Explicit non-goals (this design):** WS-push telemetry at 20 Hz to the agent process (files +
watch are within budget; revisit only if a <100 ms full loop is ever required), entity lists
(trees/VoxelBodies — the natural P3, the enumerators exist), `goto`/A*-in-game verbs (the agent can
A* over `query_box` output first; promote to an in-game verb only if round-trips dominate), and any
consent-free read channel (§7.3).
