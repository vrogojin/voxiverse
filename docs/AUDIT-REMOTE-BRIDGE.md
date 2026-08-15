# AUDIT — Remote-Bridge Stack (agent-control pain points)

Read-only audit of the VOXIVERSE remote-control stack, root-causing three agent-control
pain points and mapping the exact fix sites. Feeds a Fable architecture design.

**Scope (files audited):**
- `tools/remote-bridge/relay.mjs` — Node WS relay (offer/grant/forward/ack, telemetry.jsonl + JPEG capture, control-op whitelist, request/response result sinks).
- `godot/src/net/remote_bridge.gd` — in-game bridge (~4 Hz telemetry, `?remote=`/`?telem=` config, `CONTROL_ENABLED`, control-op dispatch, JS-bridge eval, telemetry gather).
- `godot/src/world/world_manager.gd` — world-query surface (`block_id_at`/`cell_value_at`/`cell_solid`/`blocked`/`floor_under`/`aimed_voxel`).
- `godot/src/player/player.gd` — pose + telemetry accessors (`view_telemetry`/`nav_telemetry`/`space_telemetry`/`radial_altitude`, `remote_break`, DDA routing).

**Rebuild rule used throughout:** a change to `relay.mjs` (or a relay env var) is a **relay-JS-only** change — no game rebuild, restart the node process. A change to any `.gd` file needs the full `scripts/build.sh` is NOT required (GDScript is not compiled into templates) — but it DOES need a fresh **web export + deploy** (`scripts/export-web.sh` + `scripts/deploy.sh`) to reach the live site. Below, "GDScript = re-export" means export+deploy, no engine rebuild; "relay-only" means neither.

---

## (1) CONTROL LATENCY — end-to-end trace of one action

### The path, hop by hop

A single action `agent → outbox → relay → game → apply → result → agent`:

| # | Hop | Mechanism (file:line) | Typical | Worst |
|---|-----|------------------------|---------|-------|
| 1 | Agent writes `control/outbox/<seq>.json` (atomic tmp+rename) | ingested by `pollOutbox` `relay.mjs:537` | ~0 ms | ~0 ms |
| 2 | Relay picks up the file | `setInterval(pollOutbox, POLL_MS)` `relay.mjs:952`; `POLL_MS=500` `relay.mjs:86` | ~250 ms (½ interval) | ~500 ms |
| 3 | Relay validates + forwards over WS | `ingestFile`→`dispatchOrHold`→`forward` `relay.mjs:448` (requires an already-armed grant; else it HOLDS, unbounded) | ~1 ms | ~1 ms |
| 4 | WS transit relay→nginx→browser (wss, real-GPU host) | `conn.ws.send(entry.text)` `relay.mjs:461` | ~30 ms | ~120 ms |
| 5 | Game receives + validates + **acks** | `_dispatch_control` `remote_bridge.gd:1116` → `_on_cmd_seq` `:1225` → `_send_cmd_ack` `:1606`; drained once per frame in `_process` `:464` | ~16–33 ms (1 frame) | ~66 ms |
| 6a | **ACK downlink** back to relay → `control/results/<seq>/ack.json` | `routeControlEvent` `relay.mjs:694` → `writeResult` `:237` | ~30 ms | ~120 ms |
| 6b | **Effect observable via telemetry** (pose/state change) | `_send_telemetry` gated by `_win_acc >= _telem_interval`, `TELEMETRY_INTERVAL=0.25` `remote_bridge.gd:88,498` (→ `telemetry.jsonl` `relay.mjs:191`) | ~125 ms (½ window) | ~250 ms (1 s under `?telem=1hz`) |
| 7 | **Agent reads the result file** (ack.json / done.json / telemetry.jsonl) | no push — the agent polls the FS on its own cadence (harness side, not in these files) | ~250 ms | ~1000 ms |

### Sums (dominant terms in **bold**)

- **Await the ACK** (`control/results/<seq>/ack.json`, does NOT wait on the 4 Hz telemetry):
  1+2+3+4+5+6a+7 ≈ **576 ms typical, ~1730 ms worst.** Dominated by **hop 2 (outbox poll, 500 ms)** + **hop 7 (agent read poll)**.
- **Confirm the world effect via telemetry** (scrape `telemetry.jsonl` for the new `pos`/`cam_yaw_deg`):
  1+2+3+4+5+6b+7 ≈ **~715 ms typical, ~2020 ms worst** (grows to ~2.9 s worst under `?telem=1hz`).
- **Per-step / per-sequence completion** (`events.jsonl` `step_done`, `done.json` `seq_done`): same profile as the ACK path — these are downlink RESULT frames written by `appendEvent`/`writeResult` (`relay.mjs:717-726`), NOT gated by the telemetry window. **An agent that awaits `done.json` instead of scraping telemetry already avoids the 4 Hz tax.**

**Root cause of the felt latency:** two fixed-interval polls in series — the relay's 500 ms outbox poll (hop 2) and the agent's own file-read poll (hop 7) — plus, for anyone confirming via telemetry, the 250 ms window (hop 6b). The WS transit and in-game apply are minor (<200 ms combined worst).

### Biggest wins

**W1 — Outbox poll 500 ms → push/watch or lower interval. (relay-only, no rebuild.)**
- Fix site: `POLL_MS` default `relay.mjs:86`; poller `relay.mjs:952`.
- Cheapest: drop `REMOTE_BRIDGE_POLL_MS` to 50–100 ms (env, zero code). Saves ~200–450 ms off every action.
- Better: `fs.watch(OUTBOX_DIR)` to forward on-write, keeping the 500 ms poll only as a reconciliation backstop. The code comment at `relay.mjs:86,950` warns `fs.watch` is unreliable on bind mounts — so keep the poll as a floor and treat watch events as an accelerator, not a replacement. Halves hop 2 to near-0 typical.

**W2 — Explicit per-action ACK the agent awaits. (ALREADY EXISTS — document + use it.)**
- `cmd_ack` → `ack.json` (`relay.mjs:706`), `seq_done` → `done.json` (`relay.mjs:723`), `step_done` → `events.jsonl` (`relay.mjs:719`). Correlated to the seq via `resultsDirFor` (`relay.mjs:231`), which only writes into a dir the relay created on `forward` (`relay.mjs:453`) — so the ACK is bound to a real, consented command.
- Gap: there is no *low-latency* signal that a step's *observable effect* has settled (an ACK means "accepted/dispatched", `step_done` means "the executor finished the step"). For fast ops that is enough; for a `move` the agent still wants pose. See W3/W4.
- No change needed to enable — the agent loop should `await done.json` (and read `events.jsonl`) rather than tail `telemetry.jsonl`. This removes hop 6b entirely for completion detection.

**W3 — On-demand / higher-rate state (kill the 250 ms window for confirmation). (GDScript = re-export.)**
- Option A (cheap): raise the ambient rate — `TELEMETRY_INTERVAL` `remote_bridge.gd:88`. Costs bandwidth + the self-instrumentation already flags the snapshot cost (`telem_ms`), so 0.1 s is safe on a real GPU. Halves hop 6b.
- Option B (better): an **on-demand state query** — a `query`/`pose` op whose result is written to `control/results/<seq>/` exactly like the screenshot path (see §3). The agent gets a fresh, correlated pose snapshot at ACK latency (~500 ms) instead of waiting for the next window AND without raising the ambient rate. Fix sites: new op in `OP_WHITELIST` (`relay.mjs:95`, `remote_bridge.gd:75`) + a handler in `remote_bridge.gd` that calls the pose accessors and emits a `state_result` downlink; add the type to `RESULT_TYPES` `relay.mjs:690` + a `writeResult` branch in `routeControlEvent` `relay.mjs:704`. This is the same substrate as the voxel query (§3) — build them together.

**W4 — Request/response query path (the structural gap). (relay + GDScript.)**
- Today the op path is **fire-and-forget** (`forward` sends bytes, the executor runs, results trickle back as downlink events). There is no `request→typed-response` verb the agent can await for *data* (pose, blocks, raycast). The screenshot IS a de-facto response (`handleShotFrame` `relay.mjs:733` → `shot-*.jpg` in the seq dir), proving the substrate works — it just isn't generalized to structured data. Generalizing it is W3-B + §3. **This is the single highest-value architectural change** and the one the Fable design should center on.

---

## (2) ORIENTATION TELEMETRY

### Emitted TODAY (grep of `_merge_rich_state` `remote_bridge.gd:869` and its sub-calls)

| Field(s) | Source | Meaning |
|----------|--------|---------|
| `pos` = `[x,y,z]` | `remote_bridge.gd:872` (`player.global_position`) | player pos in the **active-facet LATTICE / scene frame** (NOT BCI world) |
| `cam_yaw_deg`, `cam_pitch_deg`, `look_world`="(x,y,z)" | `view_telemetry()` `player.gd:399-407`, merged `remote_bridge.gd:876` | body yaw (`rotation.y`) + camera pitch (`_pitch`) + **camera** forward unit vector (string) |
| `nav_mode`, `frame_v`, `|v_bci|`, `nav_frame` | `nav_telemetry()` `player.gd:994`, merged `remote_bridge.gd:883` | nav-frame machine state (mode + a frame-appropriate speed SCALAR) |
| `alt`, `v_circ`, `orbit_r`, `body`, `dev_nav`, `coasting`, `flying`, `on_ground`, `att` | `space_telemetry()` `player.gd:2767-2782`, merged `remote_bridge.gd:890` | radial altitude, circular-orbit speed, dominant body, attitude-machine name |
| `facet`, `cam_far` | `remote_bridge.gd:906,904` | active facet id; camera far plane |

**Key point:** the ONLY orientation vectors emitted are `cam_yaw_deg`/`cam_pitch_deg` and `look_world` (the **camera** forward). Everything velocity-related is a **scalar** (`|v_bci|`, `frame_v`, `v_circ`). There is no body basis, no camera right/up, no velocity direction, no planet-local up.

### MISSING for full body orientation in space

1. **Player body basis** — forward (`-basis.z`), right (`basis.x`), up (`basis.y`) of `player.global_transform.basis`. Only camera yaw/pitch is exposed; a rolled/tilted body (space attitude, dihedral crossing) is not reconstructable.
2. **Camera forward/right/up vectors** — `look_world` gives camera forward only; no right/up, so the camera roll about its forward axis is unknown.
3. **Velocity VECTOR** — `player.velocity` (CharacterBody3D, lattice frame) and/or the nav machine's `v_bci` vector. Today only magnitudes ship, so heading-of-travel is unknown.
4. **On-planet local up (radial)** — `normalize(P_bci)`. The planet centre is the **BCI world origin**, so the radial up is the normalized BCI position. Not emitted; `radial_altitude()` `player.gd:1009-1015` already computes `P_bci = FacetAtlas.lattice_to_world64(fid, pos.x,pos.y,pos.z)` internally and takes its length — the direction is thrown away.
5. **Heading relative to north/facet** — no compass bearing (the SN5b compass exists in-game but is not in telemetry).

### Where to add each (all GDScript = re-export; all ADDITIVE + empty-dict-guarded per the established byte-off pattern)

- **Body + camera bases + velocity:** extend `view_telemetry()` `player.gd:399`. It already returns a dict merged at `remote_bridge.gd:876-879`, so new keys ride the existing merge with zero relay change:
  ```gdscript
  var b := global_transform.basis
  "body_fwd":  _vec3s(-b.z), "body_right": _vec3s(b.x), "body_up": _vec3s(b.y),
  "cam_right": _vec3s(_camera.global_transform.basis.x),
  "cam_up":    _vec3s(_camera.global_transform.basis.y),
  "vel":       _vec3s(velocity),      # CharacterBody3D lattice-frame velocity
  ```
  (Keep the `"(%f,%f,%f)"`-string convention `look_world` uses, or switch to arrays — decide once for the whole block.)
- **Planet-local orientation:** add a new accessor `player.orientation_telemetry()` and merge it in `_merge_rich_state` beside `space_telemetry` (`remote_bridge.gd:890`). Returns `{}` off-faceted so the stream stays byte-identical:
  ```gdscript
  func orientation_telemetry() -> Dictionary:
      if not CubeSphere.FACETED: return {}
      var fid := TerrainConfig.active_facet()
      if fid < 0: return {}
      var w: Array = _FacetAtlasCls.lattice_to_world64(fid, position.x, position.y, position.z)
      var P := Vector3(w[0], w[1], w[2])          # BCI world; planet centre = origin
      var up := P.normalized()                     # local up (radial)
      var north := (Vector3.UP - Vector3.UP.dot(up) * up).normalized()  # spin-axis +Y projected to tangent
      var east := up.cross(north)
      var fwd := (-global_transform.basis.z)       # NB: body basis is in SCENE frame, north/east in BCI — map through ActiveFrame before dotting (see note)
      var fwd_t := (fwd - fwd.dot(up) * up).normalized()
      return {"up_radial": _vec3s(up),
              "heading_deg": snappedf(rad_to_deg(atan2(fwd_t.dot(east), fwd_t.dot(north))), 0.1)}
  ```
  **Math (planet-local):** `up = normalize(P_bci)`; tangent `north = normalize(Ŷ − (Ŷ·up)·up)` (spin axis +Y projected onto the tangent plane); `east = up × north`; `heading = atan2(fwd_t·east, fwd_t·north)` with `fwd_t = fwd − (fwd·up)·up`.
  **Caveat to hand Fable:** the body basis is in the **scene/ActiveFrame** frame while `up/north/east` above are in **BCI world**. To compare them, map the body forward into BCI (through the ActiveFrame the player rides — the same `_frame` seam `_current_target` uses at `player.gd:2015-2016`) OR compute `up` from the scene-frame position and use scene-frame `Ŷ`. Pick one frame and be consistent; `radial_altitude()` is the reference for the lattice→BCI hop.

---

## (3) VOXEL-DATA QUERY — confirmed gap + design

### Confirmation: NO structured voxel data crosses the bridge today

- In-engine, per-cell block lookup EXISTS: `WorldManager.block_id_at(cell)` `world_manager.gd:1628` (`= CellCodec.mat(cell_value_at(cell))`, `cell_value_at` `:1495`), plus `cell_solid` `:1638`, `blocked` `:4607`, `floor_under` `:4355`, and the DDA raycast `aimed_voxel(origin,dir,max_dist)` `:4716`.
- **None of these are reachable over the bridge.** The op whitelist (`relay.mjs:95`, `remote_bridge.gd:75`) has movement/screenshot/dev ops only — no read/query verb. Telemetry emits scalars + pose, never block arrays. The relay's telemetry sink is append-only (`writeTelemetry` `relay.mjs:191`); its only correlated request/response sink is the screenshot (`handleShotFrame` `relay.mjs:733`).
- So: an agent can SEE the world (JPEG frames) but cannot READ it structurally.

### The request/response substrate already exists (reuse it)

The screenshot IS a request→correlated-response: `forward` mkdirs `control/results/<seq>/` (`relay.mjs:453`); the game replies with a downlink frame; `resultsDirFor(seq)` (`relay.mjs:231`, gated to only-dirs-the-relay-created) validates it; `writeResult`/`handleShotFrame` land it in that dir; the agent reads `control/results/<seq>/{ack,done,shot}`. A voxel query is the same shape with a data payload instead of a JPEG.

### Design — two new query ops (`query_box`, `query_ray`)

**A. Relay plumbing (relay-only, no rebuild):**
1. Add `'query_box'`, `'query_ray'` to `OP_WHITELIST` `relay.mjs:95`.
2. Add `validateStep` cases `relay.mjs:266` with **hard NEVER-OOM caps**:
   - `query_box`: `half` (half-extents) each ≤ `QUERY_HALF_MAX` (e.g. 12) AND total cells `(2h+1)³ ≤ QUERY_CELLS_MAX` (e.g. 32768). Optional explicit `center` [x,y,z] finite, else player-centered.
   - `query_ray`: `dir` finite non-zero; `max_dist ≤ QUERY_RAY_MAX` (e.g. 64).
3. Add `'query_result'` to `RESULT_TYPES` `relay.mjs:690` and a `writeResult(obj.seq, 'query.json', obj)` branch in `routeControlEvent` `relay.mjs:704` (owner-gated by `ownsDownlink` exactly like the other results). For a large box, prefer a **binary tag** (`0x03 QUERY_TAG`, header = `{seq,id}` + payload = packed ids) handled like `handleShotFrame` `relay.mjs:733` so it bypasses the ~16 KB text expectations while staying under `MAX_FRAME_BYTES` (2 MiB) — 32768 ids at 1–2 bytes each fits comfortably.

**B. In-game handler (GDScript = re-export; `CONTROL_ENABLED`-gated):**
4. New op dispatch: `query_box`/`query_ray` land through the executor (like `screenshot`), or a direct branch in `_on_cmd_seq` `remote_bridge.gd:1225`. Re-validate caps in `_validate_cmd` `remote_bridge.gd:1247` (mirror the relay). Emit the result via a `_send_query_result(seq,...)` that mirrors `_send_shot_frame` (`remote_bridge.gd:1408`).
5. New batch method on WorldManager, sited beside `block_id_at` `world_manager.gd:1628`:
   ```gdscript
   func block_box(center: Vector3i, half: Vector3i) -> Dictionary:
       # NEVER-OOM: caller + relay both cap; assert the product here too and clamp/refuse.
       var nx := 2*half.x+1; var ny := 2*half.y+1; var nz := 2*half.z+1
       var ids := PackedInt32Array(); ids.resize(nx*ny*nz)  # or PackedByteArray if ids ≤ 255
       var i := 0
       for dy in range(-half.y, half.y+1):
           for dz in range(-half.z, half.z+1):
               for dx in range(-half.x, half.x+1):
                   ids[i] = block_id_at(center + Vector3i(dx,dy,dz)); i += 1
       return {"origin":[center.x-half.x,center.y-half.y,center.z-half.z],
               "dims":[nx,ny,nz], "order":"x-fastest", "ids":ids}
   ```
   Batches `block_id_at` (edit-overlay-else-generated — the ONE authoritative cell query per CLAUDE.md) so the returned neighborhood matches physics/render exactly.
6. Raycast/LOS query — **reuse `aimed_voxel`** `world_manager.gd:4716` (the SAME DDA the player break/place uses via `_current_target` `player.gd:2008`). Convert origin/dir to the lattice frame through the ActiveFrame seam exactly as `player.gd:2015-2016` (`_frame.g2l_point` / `_frame.g2l_dir`), then call `world.aimed_voxel(origin_lat, dir_lat, max_dist)`; return its `{hit, voxel, normal, position, surface_normal}` dict. Player-centered convenience: default origin = camera eye, default dir = camera forward (the aim ray).

**C. Agent read:** `control/results/<seq>/query.json` (or the binary `query-<id>.bin` if the binary tag is used), correlated to the seq the agent wrote — identical ergonomics to reading `shot-*.jpg`.

### Discipline notes for the implementer

- **`CONTROL_ENABLED` gate:** all inbound acting (including a read query) flows through `_dispatch_control` `remote_bridge.gd:1116`, which only runs when `CONTROL_ENABLED` `remote_bridge.gd:63` is true AND a grant is active. So a voxel query, though read-only, currently requires control-enabled + consent. **Decision for Fable:** either (a) keep queries under the grant (simplest, preserves the "observe = send-only" security invariant — recommended), or (b) design a separate consent-free read channel, which weakens the Phase-1 observe-only model and needs its own security review. Do NOT casually route a query onto the observe path.
- **Byte-off / FP_\* discipline:** every in-game addition must be inert when its gate is off. New telemetry fields (§2) follow the additive + empty-dict-guarded pattern (`view_telemetry`/`space_telemetry` return `{}` → merge nothing → byte-identical stream). New ops (§3) are dead unless `CONTROL_ENABLED` — the whitelists, `_dispatch_control`, and the executor are all already gated, so an OFF build is byte-for-byte the Phase-1 observe bridge.
- **NEVER-OOM:** the box query MUST be capped in THREE places (agent-side sanity, relay `validateStep`, in-game `_validate_cmd` + `block_box` itself) — the relay only routes, the rover never trusts it (`remote_bridge.gd:1230` comment). Prefer `PackedByteArray` for the id grid when ids fit in a byte.

---

## Summary of fix sites (for the Fable design)

| Change | File:line | Kind |
|--------|-----------|------|
| Lower/watch outbox poll | `relay.mjs:86,952` | relay-only |
| Use existing ACK/done/step results (no code) | `relay.mjs:237,706,717,723`; agent loop | none |
| Raise ambient telemetry rate | `remote_bridge.gd:88` | GDScript = re-export |
| On-demand pose query op | `relay.mjs:95,690,704` + `remote_bridge.gd:75,1225` + new handler | relay + GDScript |
| Body/camera bases + velocity vector | `player.gd:399` (`view_telemetry`) | GDScript = re-export |
| Planet-local up + heading | new `player.orientation_telemetry()` + merge `remote_bridge.gd:890` | GDScript = re-export |
| Voxel box query | `relay.mjs:95,266,690,704` + `remote_bridge.gd:75,1225` + `WorldManager.block_box` near `world_manager.gd:1628` | relay + GDScript |
| Raycast query (reuse DDA) | reuse `world_manager.gd:4716` via `_frame.g2l_*` (`player.gd:2015`) | relay + GDScript |

**One-line verdict:** the request/response substrate the agent needs already exists (the correlated `control/results/<seq>/` sink the screenshot uses); the three pain points are all solved by (a) shrinking the two serial poll intervals, (b) generalizing that screenshot-result substrate to typed pose/voxel responses, and (c) adding vector orientation + a batched `block_id_at` — all additive, byte-off, and consent-gated.
