# Agent-Grade Perception & Low-Latency Control for FPS / 3D Embodied Games

**Research report — how AI agents gain comprehensive situational awareness and act in
first-person / 3D embodied games, and how to build a tight sense→think→act loop.**
Written to inform the VOXIVERSE agent-control redesign (a browser-hosted Godot 4.4 voxel
planet driven by an external agent over a Node.js WebSocket relay). Research + synthesis
only — no game code was changed.

Every non-obvious claim carries an inline primary-source link; a consolidated source list is
at the end. Where a number is contested across sources or is an engineering inference rather
than a verbatim quote, it is explicitly flagged **[flagged]**.

---

## 0. TL;DR — the five things that matter for VOXIVERSE

1. **Winning game agents observe *structured state*, not pixels.** OpenAI Five and AlphaStar
   both read a game-API state vector (unit lists, positions, health, cooldowns), never a
   rendered frame. Every embodied-AI simulator (ViZDoom, Habitat, Unity ML-Agents) ships a
   *structured* observation path — object-label buffers, depth buffers, raycast hit vectors,
   and an explicit **agent pose** — precisely so the policy never has to reverse-engineer
   geometry from RGB. VOXIVERSE today forces its agent to screen-scrape JPEGs; this is the
   single biggest perception gap.
2. **Pose (position + orientation + velocity) is a first-class observation everywhere.**
   ViZDoom exposes `POSITION_*`, `ANGLE/PITCH/ROLL`, `VELOCITY_*`; Habitat exposes
   `AgentState.position` + a rotation quaternion; MuJoCo pairs `qpos` (incl. orientation
   quaternion) with `qvel` (linear+angular). VOXIVERSE telemetry currently carries `pos` and
   `yaw_deg` only — no pitch, no velocity, no forward vector. That is not enough to aim or to
   lead a moving target.
3. **Latency is dominated by the loop architecture, not the wire.** The relay's WebSocket leg
   is already full-duplex and forwards command bytes in sub-millisecond time. The seconds of
   lag come from (a) the **500 ms outbox *file* poll** that is the agent→relay ingress, (b)
   the **~4 Hz telemetry** emit, and (c) the **batch `cmd_seq` scripted model** (fire a
   multi-step script, wait for `done.json`). None of these is a network limit.
4. **The field's answer to "fast loop" is: push, don't poll; stream compact binary state at
   30–60 Hz; and either step the sim synchronously or rate-cap the agent (frame-skip /
   `step_mul`) so it is never flooded.** A 500 ms poll adds ~250 ms average latency for free
   **[flagged: half-interval is an inference]**; server push removes it. 4 Hz telemetry = 250 ms
   between samples; 30 Hz = ~33 ms.
5. **Spatial awareness is built from cheap structured primitives** — a depth/raycast fan, a
   semantic/label buffer, and an agent-maintained occupancy/voxel map registered by pose —
   not from a photographic understanding of each frame. VOXIVERSE already has the ground truth
   (`WorldManager.block_id_at`, a DDA raycast, `TreeGen`, `PerVoxelEnvironment`); it just needs
   to *expose* them as queries.

---

## 1. Structured observation vs screen-scraping

### 1.1 The core principle

Across every mature platform, the agent is given a **structured, engine-authoritative
observation** — numbers and label buffers straight from the simulation — rather than being
asked to infer world state from a rendered image. Pixels are one *optional* modality; the
default, high-signal path is structured. The two most famous real-time game agents skip pixels
entirely (§1.8). The reason is signal-to-noise and latency: structured state is exact, tiny,
and free of a perception round-trip.

### 1.2 ViZDoom — the canonical FPS research interface

`get_state()` returns a `GameState` object bundling everything the engine knows this tic:
`number` (state index), `tic` ("1 tic = 1/35 second"), `game_variables`, the parallel buffers
`screen_buffer` / `depth_buffer` / `labels_buffer` / `automap_buffer` / `audio_buffer`, and the
structured object lists `labels` (a vector of `Label`), `objects` (vector of `Object`), and
`sectors`. ([ViZDoom GameState](https://vizdoom.farama.org/api/python/game_state/))

- **Screen buffer** — the RGB frame (the pixel path); `ScreenFormat` selects channel order /
  `GRAY8` / `DOOM_256_COLORS8`.
- **LABELS buffer** — a per-pixel image where every *visible* object (enemies, pickups,
  barrels) is painted with a unique value, delivered alongside a vector of `Label` structs that
  give, per object: `object_id`, `object_name` (e.g. `"Medkit"`, `"Cacodemon"`), the `value`
  used in the buffer, full pose (`object_position_x/y/z`, `object_angle/pitch/roll`,
  `object_velocity_x/y/z`), and a bounding box (`x`, `y`, `width`, `height` in buffer pixels).
  The parallel `objects` list mirrors these fields for every object. This is **free,
  ground-truth instance segmentation + object state** — no learned perception. Enable with
  `set_labels_buffer_enabled`.
  ([ViZDoom GameState](https://vizdoom.farama.org/api/python/game_state/),
  [labels example](https://github.com/mwydmuch/ViZDoom/blob/master/examples/python/labels_buffer.py))
- **DEPTH buffer** — an 8-bit single-channel image giving per-pixel distance from the player
  (obstacle/geometry sense without inferring it from RGB). Enable with `set_depth_buffer_enabled`.
  ([ViZDoom docs](https://vizdoom.farama.org/api/python/doom_game/),
  [buffers example](https://github.com/mwydmuch/ViZDoom/blob/master/examples/python/buffers.py))
- **Automap buffer** — a top-down map view (`AutomapMode` {NORMAL, WHOLE, OBJECTS,
  OBJECTS_WITH_SIZE}) for allocentric context.
- **Game variables** — scalars read via `get_game_variable(GameVariable.X)` after
  `add_available_game_variable(...)`: player pose (`POSITION_X/Y/Z`, `ANGLE`, `PITCH`, `ROLL`,
  `VIEW_HEIGHT`), velocity (`VELOCITY_X/Y/Z`), player state (`HEALTH`, `ARMOR`, `DEAD`,
  **`ON_GROUND`**, `ATTACK_READY`, `ALTATTACK_READY`), weapons/ammo (`SELECTED_WEAPON`,
  `SELECTED_WEAPON_AMMO`, `AMMO0..9`, `WEAPON0..9`), score (`KILLCOUNT`, `FRAGCOUNT`,
  `HITCOUNT`, `DAMAGECOUNT`, `ITEMCOUNT`, `SECRETCOUNT`), a full **camera** pose
  (`CAMERA_POSITION_X/Y/Z`, `CAMERA_ANGLE/PITCH/ROLL`, `CAMERA_FOV`), and `USER1..60` custom
  slots. ([ViZDoom enums](https://vizdoom.farama.org/api/python/enums/))

ViZDoom also runs **synchronously** and headless for speed (up to ~7000 fps single-thread in
sync mode; see §2.4), which is why it is the standard testbed for reaction-time and
frame-skip studies. ([ViZDoom modes](https://vizdoom.farama.org/api/cpp/enums/)) Note the
completeness of the *structured* channel: an agent can read every object's id, name, world pose,
velocity, and screen bounding box **without touching a pixel** — the model VOXIVERSE should
aim at.

### 1.3 DeepMind Lab

DeepMind Lab is a first-person 3D learning environment whose observation set is declared by
name in the env spec. The visual names are `RGB_INTERLEAVED` (HxWx3), `RGBD_INTERLEAVED`
(HxWx4 — **depth is carried in the RGBD variants; there is no standalone `DEPTH` observation**),
their planar `RGB`/`RGBD` forms, and `BGR*` variants. Structured/custom names (added via
`custom_observations.decorate`) include `VEL.TRANS` ("player relative velocity", 3 doubles),
`VEL.ROT` ("player relative angular velocity", 3 doubles), `INSTR` (textual level instruction),
and `TEAM.SCORE`. Debug channels expose ground-truth pose: **`DEBUG.POS.TRANS`** ("player's
world position in game units, x,y,z") and **`DEBUG.POS.ROT`** ("world orientation in degrees:
pitch, yaw, roll"), plus top-down / player-view debug cameras.
([DeepMind Lab observations](https://github.com/google-deepmind/lab/blob/master/docs/users/observations.md))
Its role here is the early demonstration that a 3D FPS-style environment exposes a
*configurable* structured observation set — velocity and world pose as first-class named
channels — rather than pixels-only.

### 1.4 Habitat / Habitat-Sim / Habitat 3.0

Habitat is the reference embodied-navigation simulator and ships a full **sensor suite**
produced in a single render pass, plus explicit agent state and a navmesh:

- **RGB, DEPTH, and SEMANTIC sensors.** Depth = per-pixel range (clipped to a configurable
  max). Semantic = a per-pixel image whose value is the object/instance (or category) id of
  the surface seen, aligned with RGB/depth — grounds object categories for object-goal
  navigation. ([Habitat-Sim](https://github.com/facebookresearch/habitat-sim))
- **Agent state.** `habitat_sim.agent.AgentState.position` (`numpy.ndarray`, 3-vector) and
  `.rotation` (unit **quaternion**), plus `.sensor_states: Dict[str, SixDOFPose]` for per-sensor
  6-DOF pose. In habitat-lab the base `AgentState.rotation` is "typically a yaw rotation" on
  the navmesh. ([AgentState](https://aihabitat.org/docs/habitat-sim/habitat_sim.agent.AgentState.html),
  [SixDOFPose](https://aihabitat.org/docs/habitat-sim/habitat_sim.agent.SixDOFPose.html),
  [habitat-lab AgentState](https://aihabitat.org/docs/habitat-lab/habitat.core.simulator.AgentState.html))
  Sensor types are enumerated in `SensorTypes` {COLOR, DEPTH, SEMANTIC, NORMAL, POSITION,
  HEADING, ...}, and observations come back as a dict keyed by each sensor's uuid (commonly
  `"rgb"`, `"depth"`, `"semantic"`).
  ([habitat-lab simulator](https://aihabitat.org/docs/habitat-lab/habitat.core.simulator.html))
- **GPS+Compass sensor** — the standard PointNav observation. `PointGoalWithGPSCompassSensor` is
  2-D in **polar form**: the goal's (distance, angle) **in the agent's own reference frame**.
  Decomposed, `EpisodicGPSSensor` = the horizontal-plane vector from start to current position
  (meters) and `EpisodicCompassSensor` = the angle (radians) turned about vertical since start —
  i.e. an egocentric goal bearing derived from pose.
  ([IntegratedPointGoalGPSAndCompassSensor](https://aihabitat.org/docs/habitat-lab/habitat.tasks.nav.nav.IntegratedPointGoalGPSAndCompassSensor.html),
  [Habitat, arXiv 1904.01201](https://arxiv.org/pdf/1904.01201))
- **PathFinder / navmesh** (Recast/Detour under the hood, §3.5): `find_path(ShortestPath)`
  returns the shortest path between two navmesh points and populates `ShortestPath.points` +
  `geodesic_distance` (**geodesic**, i.e. traversable length, not Euclidean); `is_navigable(pt,
  max_y_delta=0.5)` tests whether a point is on the navmesh; `snap_point(point)` returns the
  closest navigable location (searching a 4×8×4 cube; `{NaN,NaN,NaN}` if none);
  `get_random_navigable_point()` and `island_radius()` support sampling/connectivity; and
  `GreedyGeodesicFollower.next_action_along()` returns the next discrete action (turn/forward) to
  greedily follow the path.
  ([PathFinder](https://aihabitat.org/docs/habitat-sim/habitat_sim.nav.PathFinder.html),
  [nav module](https://aihabitat.org/docs/habitat-sim/habitat_sim.nav.html),
  [GreedyGeodesicFollower](https://aihabitat.org/docs/habitat-sim/habitat_sim.nav.GreedyGeodesicFollower.html))
- **Throughput.** Batched shaders render >4000 fps at 128×128 RGB single-process, >10,000 fps
  multi-process — depth/semantic training at scale is cheap.
  ([Habitat-Sim](https://github.com/facebookresearch/habitat-sim))

Habitat 3.0 extends this to **human-robot multi-agent** embodied tasks (an articulated humanoid
sharing the scene), but the observation philosophy is unchanged: structured sensors + explicit
pose + navmesh queries. ([Habitat papers: arXiv 1904.01201, 2106.14405, 2310.13724])

### 1.5 Unity ML-Agents

ML-Agents is the closest analog to VOXIVERSE's situation (a game engine driving an external
policy), so its design choices are the most directly transferable:

- **Vector observations** — the agent implements `CollectObservations(VectorSensor sensor)` and
  pushes floats (`sensor.AddObservation(...)`): its own pose, velocities, relative positions of
  goals, etc. This is a hand-authored structured state vector, exactly analogous to a compact
  telemetry block.
- **RayPerceptionSensor3D** — a **raycast fan**: it casts `1 + 2 * RaysPerDirection` rays (one
  forward, the rest fanned symmetrically out to `MaxRayDegrees`). Each ray returns a vector of
  `(NumDetectableTags + 2)` floats: a one-hot of the detectable tag it hit, a "hit nothing"
  flag, and the **normalized (0–1) distance** to the hit (1.0 = nothing hit). Total obs =
  `(stacks) × (1 + 2·RaysPerDirection) × (NumDetectableTags + 2)`. This is a cheap,
  low-dimensional, structured substitute for vision that yields *distance + object class per
  ray* directly.
  ([ML-Agents agent design](https://unity-technologies.github.io/ml-agents/Learning-Environment-Design-Agents/),
  [RayOutput API](https://docs.unity3d.com/Packages/com.unity.ml-agents@2.0/api/Unity.MLAgents.Sensors.RayPerceptionOutput.RayOutput.html),
  [sensor source](https://github.com/Unity-Technologies/ml-agents/blob/main/com.unity.ml-agents/Runtime/Sensors/RayPerceptionSensor.cs))
- **The step loop.** ML-Agents steps in lockstep with Unity's physics: by default the
  **Academy** signals every agent each `FixedUpdate()` via `EnvironmentStep()`; an agent calls
  `RequestDecision()` / `RequestAction()`, and a **`DecisionRequester`** component automates
  this on a configurable **`DecisionPeriod`** (its built-in frame-skip), with a
  **"Take Actions Between Decisions"** flag that repeats the last action on skipped steps.
  Actions arrive at `OnActionReceived(ActionBuffers)` and execute **synchronously** in that
  call; the env steps in lock-step with the trainer.
  ([Academy](https://docs.unity3d.com/Packages/com.unity.ml-agents@1.0/api/Unity.MLAgents.Academy.html),
  [Agent](https://docs.unity3d.com/Packages/com.unity.ml-agents@2.0/api/Unity.MLAgents.Agent.html),
  [ML-Agents agent guide](https://github.com/Unity-Technologies/ml-agents/blob/main/docs/Learning-Environment-Design-Agents.md))

The lesson: ML-Agents gives the policy a **hand-authored vector obs + a raycast sensor + an
explicit decision cadence** — never a screenshot by default.

### 1.6 Gymnasium & PettingZoo (the interface contracts)

- **Gymnasium** defines the single-agent RL contract: `env.step(action) → (observation,
  reward, terminated, truncated, info)`, with an `observation_space` (often a `Dict` of named
  sub-spaces mixing image and vector modalities). `step()` is **synchronous and blocking** —
  the environment does not advance until the agent supplies an action (§2.1). On
  `terminated`/`truncated` the caller must `reset()`. ([Gymnasium Env](https://gymnasium.farama.org/api/env/))
- **PettingZoo** is the multi-agent counterpart, offering two APIs: **AEC** (Agent-Environment
  Cycle — agents act *sequentially*, one at a time) and **Parallel** (all agents submit actions
  for the same step simultaneously). ([PettingZoo](https://pettingzoo.farama.org/)) For a
  single-controller game like VOXIVERSE the single-agent Gymnasium-style contract is the right
  mental model; PettingZoo matters only if multiple agents share the world later.

### 1.7 MuJoCo / NVIDIA Isaac (physics-state observations)

- **MuJoCo** exposes the physical state directly: `qpos` (generalized positions — for a free
  body, 3 translation + a 4-component **orientation quaternion** = 7) and `qvel` (6: 3 linear +
  3 angular). Gymnasium's MuJoCo envs return the flattened concat of `qpos` + `qvel`.
  ([MuJoCo docs](https://mujoco.readthedocs.io/),
  [Gymnasium MuJoCo](https://gymnasium.farama.org/environments/mujoco/))
- **NVIDIA Isaac Gym / Isaac Lab** run thousands of environments **in parallel on the GPU** and
  hand the policy observations as **GPU tensors** (state stays on-device, no CPU round-trip),
  which is the extreme end of "structured, zero-copy observation." ([Isaac Gym, arXiv 2108.10470])

### 1.8 API-level state agents — OpenAI Five and AlphaStar

These are the proof that, at the top of the field, **agents observe structured game state and
never a pixel** — and the cadence numbers set a realistic bar for "how fast is fast enough."

**OpenAI Five (Dota 2)** — observation is structured state from Valve's Bot API:

- **~16,000 values observed per hero per timestep** ("mostly floats and categorical values
  with hundreds of possibilities"); the popular whole-system framing is **~20,000 numbers**
  ("all information a human is allowed to get access to"). Both are real, different scopes
  (per-hero vs whole-system). Contents: units' **health, position, mana, cooldowns, items** and
  other game-state features — no rendered pixels.
  ([Dota 2 with Large Scale Deep RL, arXiv 1912.06680](https://arxiv.org/abs/1912.06680),
  [OpenAI Five (Wikipedia)](https://en.wikipedia.org/wiki/OpenAI_Five))
- **Acts on every 4th frame** ("although the Dota 2 engine runs at 30 fps, OpenAI Five only
  acts on every 4th frame which we call a timestep") ⇒ **7.5 actions/sec ≈ one action every
  ~133 ms** (frame-skip, §2.2). ~20,000 timesteps per ~45-min episode.
  ([arXiv 1912.06680](https://arxiv.org/abs/1912.06680))
- **217 ms average reaction time** to a game event ("does not vary depending on game state";
  the paper notes typical human visual reaction ~250 ms). ([arXiv 1912.06680](https://arxiv.org/abs/1912.06680))
- **[flagged]** The often-quoted "80 ms / 5 obs-per-sec" is the *earlier 2018* configuration and
  is superseded by the 4-frame-skip / 7.5 Hz / 217 ms figures in the 2019 paper.

**AlphaStar (StarCraft II)** — observation is structured state via the SC2 API / PySC2:

- Through the **raw interface** it receives "a list of units and their properties," seeing its
  own and the opponent's visible units directly without moving the camera; state is also
  exposed as **feature layers** (spatial minimap/screen planes: unit type, hit points, owner,
  visibility) per the SC2LE spec.
  ([AlphaStar blog](https://deepmind.google/blog/alphastar-mastering-the-real-time-strategy-game-starcraft-ii/),
  [SC2LE, arXiv 1708.04782](https://arxiv.org/pdf/1708.04782),
  [PySC2](https://github.com/google-deepmind/pysc2))
- **~10^26 legal actions at every timestep** — the structured action space is enormous.
  ([AlphaStar blog](https://deepmind.google/blog/alphastar-mastering-the-real-time-strategy-game-starcraft-ii/))
- **Fairness rate cap**: limited to **≤ 22 non-duplicate ("agent") actions per 5-second
  window**; average **~280 APM** in pro matches. Two delay sources: an observe-to-act
  processing delay, plus the agent **self-schedules its next observation** (mean **~370 ms**,
  occasionally seconds), so it can react late to surprises.
  ([Nature: Grandmaster level in StarCraft II](https://www.nature.com/articles/s41586-019-1724-z),
  [AlphaStar PDF](https://storage.googleapis.com/deepmind-media/research/alphastar/AlphaStar_unformatted.pdf),
  [AlphaStar blog](https://deepmind.google/blog/alphastar-mastering-the-real-time-strategy-game-starcraft-ii/))
- **[flagged]** A single reaction-ms figure conflicts across DeepMind's two blog posts (~110 ms
  observe-to-act in the Jan-2019 demo vs ~350 ms summarized later) — different pipeline
  versions. Cite the **cap (≤22/5 s)** and the **~370 ms inter-observation delay** rather than a
  single reaction number.

### 1.9 Comparison — observation modality and update rate

| System | Primary observation | Pixels? | Pose exposed | Decision / update cadence |
|---|---|---|---|---|
| ViZDoom | Game variables + LABELS + DEPTH + automap buffers | optional | `POSITION/ANGLE/PITCH/ROLL/VELOCITY` | synchronous per-tic (35 tic/s game; up to ~7000 fps headless) |
| DeepMind Lab | RGB/RGBD + custom/debug obs | yes | via debug obs | synchronous step |
| Habitat | RGB + DEPTH + SEMANTIC + GPS/Compass + navmesh | optional | `AgentState.position` + quaternion | synchronous step; >4000 fps render |
| Unity ML-Agents | Vector obs + RayPerception fan | optional | author-supplied in vector obs | Academy `FixedUpdate` step; `DecisionPeriod` frame-skip |
| Gymnasium | `observation_space` (Dict of vectors/images) | task-dependent | task-dependent | synchronous blocking `step()` |
| MuJoCo / Isaac | `qpos`+`qvel` state (Isaac: GPU tensors) | no (default) | quaternion in `qpos` | synchronous / GPU-parallel |
| **OpenAI Five** | **~16k structured values/hero (Bot API)** | **no** | positions in state | **acts every 4th frame ≈ 7.5 Hz / 133 ms; 217 ms reaction** |
| **AlphaStar** | **unit list + feature layers (SC2 API)** | **no** | unit positions | **≤22 actions/5 s; ~370 ms self-scheduled obs** |
| **VOXIVERSE today** | **JPEG frames (~2 Hz) + JSON telemetry (~4 Hz)** | **only path** | **`pos` + `yaw_deg` only** | **500 ms outbox file-poll; batch `cmd_seq`** |

The last row is the gap this report targets.

---

## 2. Latency & the sense→think→act loop

### 2.1 Synchronous `step()` vs real-time asynchronous control

There are two loop regimes:

- **Synchronous / stepped** (Gym, ML-Agents training): the simulation **blocks** until the
  agent returns an action; time only advances on `step()`. Deterministic and reproducible, and
  the agent is *never* under time pressure — but it requires the sim to be pausable.
  ([Gymnasium Env](https://gymnasium.farama.org/api/env/)) ML-Agents steps agents in lockstep
  with `FixedUpdate` and can wait synchronously for the policy.
  ([Academy](https://docs.unity3d.com/Packages/com.unity.ml-agents@1.0/api/Unity.MLAgents.Academy.html))
- **Real-time / asynchronous** (a live game, VOXIVERSE): the world **keeps moving** whether or
  not the agent has decided. Here latency is a real adversary and the design must minimize the
  sense→act delay and keep the agent from falling behind.

VOXIVERSE is inherently real-time (it is a live browser game a human can also play), so it
cannot use the pure blocking-`step()` trick. The mitigations below apply instead.

### 2.2 Action repeat / frame-skip

The standard technique to bound decision frequency: the agent perceives + decides every *k*-th
frame and repeats its last action on the skipped frames. The original DQN used **k=4** ("agent
sees and selects on every 4th frame; the last action is repeated on the 3 skipped frames"),
cutting decision compute ~4× "without sacrificing much performance, since Atari does not
require frame-perfect inputs," and giving temporal abstraction. ALE/Gymnasium defaults encode
this: `ALE/{rom}-v5` uses `frameskip=4`; `NoFrameskip-v4` uses `frameskip=1`.
([frame-skip writeup](https://danieltakeshi.github.io/2016/11/25/frame-skipping-and-preprocessing-for-deep-q-networks-on-atari-2600-games/),
[ALE envs](https://ale.farama.org/environments/)) SC2/PySC2 has the analog `step_mul` (game
steps per agent action): `step_mul=8 ≈ 180 APM`, `step_mul=20 ≈ 50 APM` — it caps the decision
rate to a human-plausible frequency. ([PySC2 environment](https://github.com/google-deepmind/pysc2/blob/master/docs/environment.md))
**Relevance:** OpenAI Five's "act every 4th frame" and this pattern say the agent does **not**
need to act every frame — 7.5–15 Hz is competitive. The goal is *low latency per decision*, not
maximum decision rate.

### 2.3 Decoupling render from logic (fixed timestep)

Gaffer on Games' "Fix Your Timestep!" prescribes advancing the simulation in **fixed `dt`
increments** while rendering at a variable framerate, via the accumulator pattern:

```
accumulator += frameTime
while (accumulator >= dt):
    integrate(state, t, dt); accumulator -= dt; t += dt
alpha = accumulator / dt          # leftover → interpolation factor for smooth render
```

"The renderer *produces* time and the simulation *consumes* it in discrete `dt`-sized steps."
Fixed `dt` gives determinism/reproducibility (variable steps diverge under float error).
([Fix Your Timestep](https://gafferongames.com/post/fix_your_timestep/)) The lesson for a
control channel: **the state-emit / control rate should be a fixed logic tick decoupled from the
render framerate** — you can push agent state at a steady 30 Hz even if the GPU frame rate
wobbles. (This dovetails with VOXIVERSE's existing "TIME_PROCESS invalid on threaded web — use
real deltas" note.) Headless/off-screen rendering is the standard speedup for training loops
(ViZDoom offers off-screen + frame-skip). ([ViZDoom FAQ](https://vizdoom.farama.org/faq/index.html))

### 2.4 Interface round-trip cost — in-process vs socket vs screen-capture

Three cost tiers, ~3 orders of magnitude apart:

- **In-process function call** (Gym `env.step()`): microsecond-scale dispatch, no
  serialization. ([Gymnasium Env](https://gymnasium.farama.org/api/env/))
- **Local socket / shared memory** (ViZDoom, SC2/PySC2): sub-millisecond to low-millisecond.
  ViZDoom hits up to **~7000 fps single-thread in sync mode** (the game *waits* for the agent),
  implying sub-ms per-step round-trips; PySC2 crosses a protobuf-over-socket bridge.
  ([ViZDoom docs](https://vizdoom.farama.org/api/python/doom_game/),
  [PySC2](https://github.com/google-deepmind/pysc2))
- **Screen-capture + vision round-trip**: capture → JPEG encode → decode → vision model →
  action, in the **tens-to-hundreds of milliseconds** range. **[flagged: engineering estimate;
  no single authoritative measured number found — the contrast to the µs/sub-ms tiers is the
  load-bearing point.]** This is exactly VOXIVERSE's current perception path.

### 2.5 Real-time bot reaction times (the human/bot bar)

- **Human simple visual reaction time ≈ 200–250 ms** (general pop ~250 ms; pro gamers/F1
  ~150–180 ms; <200 ms is "fast"). Breakdown: ~20–25 ms sensory transit, ~120–200 ms brain
  processing (the bulk), ~10–20 ms motor transit.
  ([reaction-time guide](https://reactiontimetest.net/blog/is-200ms-reaction-time-good-fast-vs-slow-score-guide),
  [benchmark](https://mindbenchmark.com/reaction-time/average))
- **Quake III bots** take an explicit reaction-time parameter and injectable per-bot network
  lag (e.g. `/addbot Xaero 5 red 250` = a simulated 250 ms ping).
  ([Quake 3 bots](https://quake.fandom.com/wiki/Quake_3_Bots),
  [Quake III Arena Bot paper](https://www.cs.rochester.edu/users/faculty/brown/242/docs/QuakeIII.pdf))
- **DeepMind's Quake III CTF agents (Science 2019)** were trained with a deliberate **267 ms
  (quarter-second) inbuilt delay before observing the world** — "comparable with reported
  reaction times of human video game players" — and still beat humans, showing the edge was
  coordination, not raw reflex.
  ([DeepMind CTF](https://deepmind.google/blog/capture-the-flag-the-emergence-of-complex-cooperative-agents/),
  [Science](https://www.science.org/doi/10.1126/science.aau6249))

**Bar for VOXIVERSE:** a sense→act latency in the **~100–250 ms** band is already human-grade;
getting the loop into the **tens of ms** puts the agent ahead of human reflex, so the effort
should target *tens of ms*, which is entirely achievable off the network (§2.7).

### 2.6 WebSocket full-duplex push vs HTTP polling

- **WebSocket (RFC 6455)** is a full-duplex, persistent, single-TCP-connection channel with
  **event-driven server push** — the server sends state the instant it changes, with no client
  request. A single connection can carry, *simultaneously*, a server→client state stream, a
  client→server action stream, and request/response queries.
  ([WebSocket guide](https://websocket.org/guides/road-to-websockets/),
  [MDN WebSockets](https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API))
- **Polling penalty.** With a poll interval `P`, an event ready at a random moment waits on
  average `P/2` (worst case `P`) before the next poll picks it up. A **500 ms poll adds ~250 ms
  mean latency purely from poll-wait**; server push removes it entirely. **[flagged: the
  half-interval is a correct inference from the polling model, not a verbatim source quote.]**
  ([long-polling comparison](https://websocket.org/comparisons/long-polling/))
- **Binary vs JSON framing.** An RFC 6455 server→client frame header is just **2 bytes** for
  payloads ≤125 bytes; binary framing (~1–3 ms/msg) avoids JSON parse cost. Framing is normally
  dwarfed by network RTT + backend processing.
  ([WS vs SSE vs polling](https://theinfinity.dev/articles/websocket-vs-sse-vs-polling))
- **Localhost/low-RTT round-trip is sub-ms to low-ms.** Over a simulated 50 ms link a
  WebSocket delivered at ~26 ms mean (≈ half the RTT = one-way push); on loopback the network
  component collapses to sub-millisecond.
  ([WS latency](https://ankitbko.github.io/blog/2022/06/websocket-latency/))

### 2.7 Cutting a "500 ms poll + 4 Hz telemetry" loop to tens of ms

Concretely, in priority order:

1. **Kill the poll; push instead.** Replace the agent→relay **outbox file poll** with a direct
   in-band action frame over the already-open WebSocket. Removes the ~250 ms average poll-wait.
2. **Raise the state rate and push it.** 4 Hz = 250 ms between samples. A fixed-timestep
   (§2.3) state push at **30–60 Hz drops inter-sample latency to ~16–33 ms**. Push on change /
   on tick, don't wait to be asked.
3. **Full-duplex multiplex** one connection for state-stream + actions + request/response
   queries, instead of separate polled round-trips.
   ([WS guide](https://websocket.org/guides/road-to-websockets/))
4. **Binary frames** (2-byte header, no JSON parse) for the high-rate state stream.
   ([WS vs SSE](https://theinfinity.dev/articles/websocket-vs-sse-vs-polling))
5. **Ack-based flow control + coalescing** so the agent is never flooded and there is no
   catch-up storm — the async analog of frame-skip/`step_mul` rate-capping (§2.2).

Net: the wire is capable of **single-digit-ms** loopback and **tens-of-ms** over a real link;
today's seconds of latency are entirely the poll + emit-rate + batch-script architecture.

---

## 3. Spatial awareness & world models

### 3.1 Depth buffers (RGB-D)

A depth sensor gives per-pixel **range**, the cheapest direct geometry signal. Habitat's DEPTH
sensor and ViZDoom's DEPTH buffer (8-bit gray, per-pixel distance) both feed obstacle/geometry
reasoning without inferring depth from RGB.
([Habitat-Sim](https://github.com/facebookresearch/habitat-sim),
[ViZDoom buffers](https://vizdoom.farama.org/api/python/doom_game/))

### 3.2 Raycast sensors

The lowest-dimensional structured spatial sensor: a fan of rays returning **distance + object
class per ray** (ML-Agents `RayPerceptionSensor3D`, §1.5). For an agent that only needs "what
is in front of me and how far," a raycast fan replaces a whole vision stack at a tiny fraction
of the cost. ([ML-Agents](https://unity-technologies.github.io/ml-agents/Learning-Environment-Design-Agents/))

### 3.3 Semantic segmentation / semantic sensors

Per-pixel object/category ids: Habitat's SEMANTIC sensor and ViZDoom's LABELS buffer (§1.2,
§1.4). These hand the agent *what each surface is* as ground truth — used e.g. as a training
signal in "Semantic Curiosity for Active Visual Learning."
([Semantic Curiosity, arXiv 2006.09367](https://arxiv.org/pdf/2006.09367))

### 3.4 Occupancy grids / voxel maps / 2.5D maps

The standard way an agent turns partial views into a persistent spatial model: back-project
depth pixels to 3D points, bin them into an egocentric top-down **occupancy grid**
(free/occupied/unknown), and register successive grids into an allocentric map using the
agent's pose.

- **Active Neural SLAM** (Chaplot et al., ICLR 2020): a learned Neural-SLAM module maps RGB(+pose)
  to a top-down 2D **occupancy map** + pose; an analytic planner + global/local policies drive
  exploration — learned mapping + classical planning.
  ([arXiv 2004.05155](https://arxiv.org/pdf/2004.05155),
  [project](https://devendrachaplot.github.io/projects/Neural-SLAM))
- **Occupancy Anticipation** (Ramakrishnan et al., ECCV 2020): projects egocentric RGB-D into a
  top-down occupancy patch and a CNN **anticipates occupancy beyond the visible region**
  (occluded/unseen cells), accumulating an allocentric map — beats geometry-only mapping on
  exploration and PointNav.
  ([arXiv 2008.09285](https://arxiv.org/pdf/2008.09285),
  [project](https://vision.cs.utexas.edu/projects/occupancy_anticipation/))

For a **voxel** game this is native: the occupancy grid *is* the block grid. The agent doesn't
need to reconstruct it — it can be handed a bounded voxel neighborhood directly (§5.2).

### 3.5 Navmeshes / pathfinding

- **Recast & Detour** — the industry-standard navmesh toolset: Recast voxelizes the scene and
  builds the navmesh; Detour does runtime A* pathfinding + spatial queries.
  ([recastnavigation](https://github.com/recastnavigation/recastnavigation),
  [intro](https://recastnav.com/md_Docs_2__1__Introduction.html))
- Habitat's PathFinder wraps Recast/Detour to return **geodesic** shortest paths, and
  `GreedyGeodesicFollower` converts a path into the next discrete action (§1.4). Geodesic (not
  Euclidean) distance is the correct navigation metric on a real surface.

### 3.6 Egocentric vs allocentric maps

- **Egocentric** = body-centered, action-oriented, updates every step ("what's in front of
  me?"). **Allocentric** = world-centered, persistent, observer-independent ("the map of the
  region"). Converting egocentric observations into a stable allocentric map requires
  integrating over time using the agent's **pose** — which is why exposing pose is a
  prerequisite for map-building.
  ([spatial memory](https://cheryyunl.github.io/blog/spatial-memory.html),
  [allocentric/egocentric composition](https://journals.plos.org/ploscompbiol/article?id=10.1371/journal.pcbi.1013905))

### 3.7 Agent internal map memory (differentiable spatial memory)

- **Neural Map** (Parisotto & Salakhutdinov, 2017): a 2D memory "image" indexed by the agent's
  `(x,y)`; the write operator writes at the cell for the current location — a map-like memory
  that persists over long horizons, unlike an LSTM.
  ([arXiv 1702.08360](https://arxiv.org/pdf/1702.08360))
- **Cognitive Mapping and Planning** (Gupta et al., CVPR 2017): a differentiable mapper builds a
  top-down belief map from first-person views (registered by ego-motion) and a
  value-iteration-network planner acts on it, planning under incomplete observation.
  ([arXiv 1702.03920 / CVPR PDF](https://openaccess.thecvf.com/content_cvpr_2017/papers/Gupta_Cognitive_Mapping_and_CVPR_2017_paper.pdf))
- **MapNet** (Henriques & Vedaldi, CVPR 2018): an allocentric 2D grid memory; localization = a
  **convolution** of the current embedding against the map (find best-matching pose), mapping =
  a **deconvolution** writing the observation back at that pose — end-to-end joint
  localization+mapping.
  ([CVPR 2018](https://openaccess.thecvf.com/content_cvpr_2018/html/Henriques_MapNet_An_Allocentric_CVPR_2018_paper.html))

The common thread: **write observations into a spatially-indexed memory using pose**, then plan
on it. An LLM/agent driving VOXIVERSE can do the same at the symbolic level — maintain a running
dict/grid of "what block is where" keyed by cell, filled from voxel-neighborhood queries.

### 3.8 SLAM from partial observation

Classical SLAM (PTAM, ORB-SLAM, VINS-Mono) incrementally builds a map while localizing, by
matching features across frames — precise but sensitive to viewpoint/illumination and prone to
drift. Learned/Neural SLAM (DROID-SLAM, NeRF-SLAM) replaces pipeline stages with trained nets
that are more invariant, at higher compute cost. The **invariant loop** in both: at each step
fuse the new partial observation into the running map using the estimated pose, expanding
coverage as the agent moves.
([SLAM survey](https://www.mdpi.com/2072-4292/14/13/3010),
[deep-learning SLAM survey, arXiv 2108.04097](https://arxiv.org/pdf/2108.04097)) In a voxel game
the localization half is *free* (the engine knows the player's exact pose), so VOXIVERSE only
needs the *mapping* half — trivially served by exposing the authoritative voxel grid.

---

## 4. Player pose exposure

### 4.1 ViZDoom game variables

Pose is a set of scalar game variables read each tic: `POSITION_X/Y/Z`, `ANGLE` (yaw), `PITCH`,
`ROLL`, and `VELOCITY_X/Y/Z` — the full position + orientation + linear velocity set. (Units
not stated in the enum docs — conventionally Doom map units and degrees; **[flagged: confirm in
C++ source before relying on units]**.)
([ViZDoom enums](https://vizdoom.farama.org/api/python/enums/),
[DoomGame](https://vizdoom.farama.org/api/python/doom_game/))

### 4.2 Habitat agent state

`AgentState.position` (`numpy.ndarray`, xyz) + `AgentState.rotation` (unit **quaternion**), with
per-sensor `SixDOFPose` (position + quaternion). Orientation is stored as a quaternion
throughout, not Euler angles.
([AgentState](https://aihabitat.org/docs/habitat-sim/habitat_sim.agent.AgentState.html),
[SixDOFPose](https://aihabitat.org/docs/habitat-sim/habitat_sim.agent.SixDOFPose.html))

### 4.3 Orientation representations (and Godot specifics)

Four common encodings: **Euler yaw/pitch/roll** (3 angles, intuitive but suffers **gimbal
lock** when two axes align), a single **forward unit vector** (enough to aim, loses roll), a
**quaternion** (4 numbers, no singularities, interpolates cleanly), and a **3×3 rotation
matrix / basis** (three transformed axis vectors). Habitat, MuJoCo, and Godot all store
orientation as quaternion/basis to avoid gimbal lock.

For the **target engine (Godot 4)**:

- `Transform3D` = a `Basis` (3×3 rotation/scale) + an `origin` (`Vector3`). The basis columns
  `basis.x/basis.y/basis.z` are the transformed local **right / up / back** axes. Godot is
  right-handed: **+X right, +Y up, −Z forward**, so the **forward vector is
  `-global_transform.basis.z`**. `Transform3D.looking_at(target, up)` builds an orientation
  whose −Z points at a target — a built-in aim-at-point.
  ([Transform3D](https://docs.godotengine.org/en/stable/classes/class_transform3d.html),
  [using transforms](https://docs.godotengine.org/en/stable/tutorials/3d/using_transforms.html))
- yaw+pitch → forward (Godot −Z frame):
  `forward = (cos(pitch)·sin(yaw), sin(pitch), −cos(pitch)·cos(yaw))`, equivalently
  `Basis.from_euler(Vector3(pitch, yaw, 0))` then `-basis.z`.

### 4.4 Velocity

`MuJoCo` `qvel` = 6 for a free body (3 linear + 3 angular; note the frame subtlety — linear in
global frame, angular in local body frame).
([MuJoCo types](https://mujoco.readthedocs.io/en/stable/APIreference/APItypes.html),
[qvel frames](https://github.com/google-deepmind/mujoco/issues/691)) **Why velocity belongs in
the observation:** position alone is **non-Markov** — you cannot tell which way the agent (or a
target) is moving from one position sample. Velocity makes the state Markov, enables one-step
prediction, and is required for **lead/deflection targeting** of a moving target. ViZDoom
exposes `VELOCITY_*` directly and ships a "Predict Position" scenario built on leading a moving
target.

### 4.5 Using pose for aiming and navigation

- **Aiming:** `delta = target_pos − pos`; `desired_yaw = atan2(delta.x, delta.z)`;
  `desired_pitch = atan2(delta.y, sqrt(delta.x² + delta.z²))` (axis-convention dependent); the
  turn/look action is `(desired − current)`, clamped to the per-tick turn rate. RL FPS agents
  typically emit orientation **deltas** (`Gun_yaw`, `Gun_pitch` action heads), not absolute
  pose. ([FPS RL aiming, arXiv 2410.04936](https://arxiv.org/html/2410.04936v1))
- **Navigation:** same `atan2` bearing but on the ground plane — `position + heading + goal →`
  turn to reduce heading error, then move forward. Habitat PointNav does exactly this from
  `AgentState` position+rotation vs the goal.

### 4.6 Reading pose from Godot nodes (directly applicable to VOXIVERSE)

- `CharacterBody3D.velocity` (`Vector3`) — current velocity, used/modified by `move_and_slide()`.
- `global_position` (`Vector3`) and `global_transform` (`Transform3D`; `.basis` = world
  orientation; forward = `-global_transform.basis.z`) from `Node3D`.
- FPS convention: **yaw on the body** (`rotation.y` on the `CharacterBody3D`), **pitch on the
  child `Camera3D`** (`camera.rotation.x`, clamped ~±90°) — keeps axes independent and avoids
  roll/gimbal. The true aim direction is the camera's `-global_transform.basis.z` (Godot 4 has
  no built-in `forward()` helper).
  ([CharacterBody3D](https://docs.godotengine.org/en/stable/classes/class_characterbody3d.html),
  [Transform3D](https://docs.godotengine.org/en/stable/classes/class_transform3d.html))

VOXIVERSE already computes all of this in `remote_control.gd::_snapshot()` — it reads
`player.global_position` and `rad_to_deg(player.rotation.y)` (yaw). Pitch lives on the camera
and velocity on the `CharacterBody3D`; both are one field-read away from being exposed.

---

## 5. Recommendations for VOXIVERSE

### 5.0 Where the loop actually loses time (grounding)

From `tools/remote-bridge/relay.mjs` and `godot/src/net/remote_control.gd`:

- **Agent → relay ingress is a 500 ms *file* poll.** The agent writes `control/outbox/<seq>.json`;
  the relay `setInterval(pollOutbox, POLL_MS)` with `POLL_MS = 500` picks it up (deliberately
  polling, not `fs.watch`, "because fs.watch is unreliable on bind mounts"). This adds ~0–500 ms
  (avg ~250 ms) before a command even reaches the wire.
- **The WebSocket leg is already full-duplex and fast.** On grant, `forward()` does
  `conn.ws.send(entry.text)` immediately — sub-ms locally. The relay→game and game→relay paths
  are a live `wss` connection. **The transport is not the bottleneck.**
- **Telemetry is ~4 Hz JSON** (`fps`, `worst_ms`, `pos [x,y,z]`, `facet`, `stream_credit`,
  `lod`), and **frames are ~2 Hz JPEG**. Pose in telemetry is **`pos` + (in step snapshots)
  `yaw_deg` only** — no pitch, no velocity, no forward vector.
- **The control model is batch `cmd_seq`** — a multi-step script (≤64 steps, Σ ≤180 s) that the
  agent fires and then waits for `done.json`. This is a *scripted-flight* model, not a reactive
  per-tick loop; it is the deepest reason the agent "senses in seconds."

So the redesign is **not** "make the network faster" — it is: **push instead of poll, stream
compact structured state at high rate, add a reactive control lane alongside the batch one, and
add query lanes for spatial data** — while preserving the existing consent/security model
(observe token ≠ control token, human-armed grant, default-deny, never-OOM caps), which is
well-built and must not be regressed.

### 5.1 (a) A low-latency bidirectional protocol

Keep the current WebSocket + the two-secret consent model. Change *what rides it* and *how the
agent's intent gets in*. Introduce **typed message lanes multiplexed on the one socket**, each a
small JSON (or binary) frame with a `lane`/`type` tag:

**Lane 1 — high-rate state stream (game → agent, push).**
A compact **state tick** pushed by the game on a **fixed logic tick at 20–30 Hz** (not the
render rate, §2.3), superseding the 4 Hz telemetry. Prefer a **binary** encoding (fixed-layout
`Float32`/`Int16` struct, §2.6) for the hot fields; keep a JSON variant for debugging. Relay
writes the latest to `state-latest.bin` (atomic tmp+rename, like `frame-latest.jpg`) **and**
appends a capped/rolled `state.jsonl` — so the agent reads the *latest* state in one file-read,
exactly the ergonomics it already uses for frames.

**Lane 2 — reactive action (agent → game, push).**
A single-step **`act` frame** (one op: `move/turn/look/thrust/break/place/...`) delivered the
instant the agent writes it — **no 500 ms poll**. Two ingress options, in order of preference:
1. **Preferred:** the agent process holds its **own authenticated control WebSocket** to the
   relay and sends `act` frames directly; the relay forwards them under the existing grant gate.
   This removes the file-poll entirely.
2. **Incremental (keeps the filesystem trust anchor):** keep `control/outbox/` but drop
   `POLL_MS` to ~20–30 ms for a dedicated **single-step `act` file** lane (validated with the
   same caps), while `cmd_seq` scripts keep the 500 ms poll. Cheap, preserves "command ingress
   is the host filesystem only," buys ~15× on ingress latency.
Every `act` gets an **`ack`** (applied / rejected + reason + the tick it was applied on) so the
agent has closed-loop confirmation instead of inferring from telemetry.

**Lane 3 — request/response queries (agent → game → agent, correlated).**
Synchronous-feel queries the agent issues on demand, each with a `qid` the response echoes:
`raycast` (LOS/aim target), `voxel_region` (bounded neighborhood grid), `entities` (nearby
trees/structures/loose bodies), `inventory`. These are **read-only** and can bypass the control
grant (they leak no more than a screenshot already does) — but keep them behind the **observe
token** and rate-cap them.

**Keep `cmd_seq` as Lane 4** for scripted flights/tests (it is proven and consent-gated);
reactive play uses Lanes 1–3.

**Target latencies:**

| Segment | Today | Target |
|---|---|---|
| Agent decision → command on wire | ~0–500 ms (file poll) | **< 30 ms** (direct WS) or ~20–30 ms (fast-poll act file) |
| Command on wire → applied in game | sub-ms + 1 frame | **< 20 ms** (unchanged transport; apply on next tick) |
| World change → agent observes it | ~250 ms avg (4 Hz) | **~16–33 ms** (30 Hz push) |
| Full sense→think→act round trip | **seconds** | **~50–100 ms** (agent compute dominates), transport tens-of-ms |

That lands the loop in the human-grade-to-superhuman band (§2.5) with headroom for the agent's
own inference time.

### 5.2 (b) The structured observation an agent needs

Replace "read a JPEG and guess" with an engine-authoritative observation. VOXIVERSE already
computes every field below; this is an *exposure* task, not new simulation.

**In every state tick (Lane 1), compact:**
- **Pose** — `pos [x,y,z]` (already present) **plus the missing fields**: `yaw_deg`
  (body `rotation.y`), **`pitch_deg`** (camera `rotation.x`), a **`forward [x,y,z]`** unit vector
  (`-camera.global_transform.basis.z`) and/or the **basis/quaternion** for full orientation, and
  **`vel [x,y,z]`** (`CharacterBody3D.velocity`). Add `on_ground`, `flying`, and the radial
  **`up [x,y,z]`** (this is a planet — "up" is not global +Y; the engine already tracks the
  radial up-vector).
- **Situational scalars** — `facet` (active), `alt` (altitude over surface), `nav_mode`/`att`
  when the space-nav machine is live (these already stream during flights), `health`/temperature
  from `PerVoxelEnvironment` at the player cell, `time_of_day`, `biome`.
- **Inventory** — selected hotbar slot + counts (the `Inventory` model already exists).

**On request (Lane 3):**
- **`raycast` / line-of-sight target** — VOXIVERSE already has the **DDA raycast** used for
  break/place. Expose it: given an origin+direction (default = camera forward), return the
  first hit **cell `[x,y,z]`**, the **block id** there (via `WorldManager.block_id_at`), the
  **hit distance**, and the **face** hit. This is the aim/interaction primitive (§4.5) and
  removes all screenshot-based aiming.
- **`voxel_region` neighborhood grid** — the native occupancy map (§3.4). Given a center
  (default = player cell) and a **bounded** half-extent `r` (hard cap, e.g. `r ≤ 16` ⇒ ≤ 33³ ≈
  36k cells; smaller default like `r=8` ⇒ 17³ ≈ 5k), return the block ids over that box from
  `WorldManager.block_id_at` (edit-overlay-else-generated — the one authoritative query per
  CLAUDE.md). Encode as a **run-length or palette-indexed byte array** (voxel worlds are highly
  repetitive) to stay tiny. This is the single highest-value perception addition: the agent gets
  exact local geometry with zero vision.
- **`entities` list** — nearby trees (`TreeGen`), structures (the structure registry /
  union-find already built), and loose `VoxelBody` rigid bodies, each as `{type, pos, id}`,
  **capped** to the N nearest (e.g. ≤64).

**Why this set:** it is exactly the union of what the reference platforms expose — pose +
velocity (ViZDoom/MuJoCo/Habitat), a raycast target (ML-Agents), a local occupancy grid
(Active Neural SLAM / Occupancy Anticipation), semantic/entity labels (ViZDoom LABELS / Habitat
SEMANTIC), and inventory/game-vars (ViZDoom) — mapped onto VOXIVERSE's already-authoritative
data sources.

### 5.3 (c) Keeping it web/WASM-friendly and bounded (never-OOM)

The engine's non-negotiable is memory safety over fidelity ("never-OOM web constraint"). Bake
the bounds into the protocol so an agent (or a bug) can never blow the heap:

- **Fixed-size state ticks.** The Lane-1 struct is a fixed byte layout; no per-tick allocation.
  At 30 Hz a ~128-byte binary tick is <4 KB/s — negligible.
- **Hard-capped queries.** `voxel_region` half-extent `r` is clamped server-side (reject
  oversize, like the relay already rejects oversize `cmd_seq`); `entities` capped to N-nearest;
  `raycast` max range clamped. Every query result is **O(cap)**, never O(world).
- **Palette/RLE encoding** for `voxel_region` keeps even the max box small on the wire and in
  the browser (voxel data compresses heavily; a mostly-air or mostly-stone box is a few bytes).
- **Reuse the relay's existing never-OOM machinery** verbatim: rolled/capped `*.jsonl`
  (`TELEMETRY_CAP_BYTES`), atomic `*-latest` files, the frame ring, per-connection message-rate
  caps (`MAX_MSG_PER_SEC`), bounded frame size (`MAX_FRAME_BYTES`), and pruned run-lifetime maps.
  The new lanes must inherit the same caps — a high-rate state stream needs its own byte-rate
  cap and its own rolled sink.
- **Rate-cap the agent (frame-skip analog, §2.2).** Bound in-flight `act` frames with the
  existing ack/one-in-flight discipline so a runaway agent can't flood the game thread; drop or
  coalesce excess rather than queue unboundedly.
- **Zero cost when inactive.** Preserve the current "dead in normal play" property — the whole
  observation/query surface exists only when `?remote=<token>` dials in; a normal visitor pays
  nothing.
- **Threading note.** State assembly must respect the "TIME_PROCESS invalid on threaded web —
  use real deltas + p90" rule and read pose/velocity on the main thread where the transforms are
  valid; the state tick is a cheap field-gather, not a simulation step.

### 5.4 Suggested staging

1. **Pose+velocity in telemetry** (smallest, highest leverage): add `pitch_deg`, `forward`,
   `vel`, `up`, `on_ground` to the existing ~4 Hz stream. Unblocks aiming/navigation immediately.
2. **Raise state rate + push** to 20–30 Hz binary on Lane 1 (`state-latest.bin`).
3. **`raycast` + `voxel_region` queries** (Lane 3) — the perception jump from pixels to grid.
4. **Reactive `act` lane** (Lane 2) — direct WS or fast-poll act-file, with acks.
5. **`entities`/`inventory` queries**; keep `cmd_seq` for scripted tests.

Each step is independently shippable, preserves the security model, and moves the loop closer to
the tens-of-ms, structured-observation regime the rest of the field already runs in.

---

## Sources

**Structured observation / platforms**
- ViZDoom docs: https://vizdoom.farama.org/api/python/doom_game/ · GameState/Label/Object https://vizdoom.farama.org/api/python/game_state/ · enums https://vizdoom.farama.org/api/python/enums/ · modes https://vizdoom.farama.org/api/cpp/enums/ · FAQ https://vizdoom.farama.org/faq/index.html · labels example https://github.com/mwydmuch/ViZDoom/blob/master/examples/python/labels_buffer.py · buffers example https://github.com/mwydmuch/ViZDoom/blob/master/examples/python/buffers.py
- DeepMind Lab: https://github.com/google-deepmind/lab · observations spec https://github.com/google-deepmind/lab/blob/master/docs/users/observations.md
- Habitat-Sim: https://github.com/facebookresearch/habitat-sim · AgentState https://aihabitat.org/docs/habitat-sim/habitat_sim.agent.AgentState.html · SixDOFPose https://aihabitat.org/docs/habitat-sim/habitat_sim.agent.SixDOFPose.html · habitat-lab simulator/AgentState https://aihabitat.org/docs/habitat-lab/habitat.core.simulator.html · PathFinder https://aihabitat.org/docs/habitat-sim/habitat_sim.nav.PathFinder.html · nav module https://aihabitat.org/docs/habitat-sim/habitat_sim.nav.html · GreedyGeodesicFollower https://aihabitat.org/docs/habitat-sim/habitat_sim.nav.GreedyGeodesicFollower.html · GPS+Compass sensor https://aihabitat.org/docs/habitat-lab/habitat.tasks.nav.nav.IntegratedPointGoalGPSAndCompassSensor.html · Habitat papers arXiv 1904.01201, 2106.14405, 2310.13724
- Unity ML-Agents: agent design https://unity-technologies.github.io/ml-agents/Learning-Environment-Design-Agents/ · agent guide (md) https://github.com/Unity-Technologies/ml-agents/blob/main/docs/Learning-Environment-Design-Agents.md · RayOutput API https://docs.unity3d.com/Packages/com.unity.ml-agents@2.0/api/Unity.MLAgents.Sensors.RayPerceptionOutput.RayOutput.html · sensor source https://github.com/Unity-Technologies/ml-agents/blob/main/com.unity.ml-agents/Runtime/Sensors/RayPerceptionSensor.cs · Academy https://docs.unity3d.com/Packages/com.unity.ml-agents@1.0/api/Unity.MLAgents.Academy.html · Agent https://docs.unity3d.com/Packages/com.unity.ml-agents@2.0/api/Unity.MLAgents.Agent.html
- Gymnasium Env: https://gymnasium.farama.org/api/env/ · basic usage https://gymnasium.farama.org/introduction/basic_usage/ · MuJoCo envs https://gymnasium.farama.org/environments/mujoco/ · PettingZoo AEC https://pettingzoo.farama.org/api/aec/ · PettingZoo Parallel https://pettingzoo.farama.org/api/parallel/
- MuJoCo: https://mujoco.readthedocs.io/ · types https://mujoco.readthedocs.io/en/stable/APIreference/APItypes.html · qvel frames https://github.com/google-deepmind/mujoco/issues/691 · Isaac Gym tensors https://junxnone.github.io/isaacgymdocs/programming/tensors.html · Isaac Lab ObservationManager https://isaac-sim.github.io/IsaacLab/main/source/api/lab/isaaclab.managers.html · Isaac Gym arXiv 2108.10470

**API-level state agents**
- OpenAI Five: arXiv 1912.06680 https://arxiv.org/abs/1912.06680 · Wikipedia https://en.wikipedia.org/wiki/OpenAI_Five
- AlphaStar: Nature https://www.nature.com/articles/s41586-019-1724-z · PDF https://storage.googleapis.com/deepmind-media/research/alphastar/AlphaStar_unformatted.pdf · blog https://deepmind.google/blog/alphastar-mastering-the-real-time-strategy-game-starcraft-ii/ · SC2LE arXiv 1708.04782 https://arxiv.org/pdf/1708.04782 · PySC2 https://github.com/google-deepmind/pysc2 · environment doc https://github.com/google-deepmind/pysc2/blob/master/docs/environment.md

**Latency / control loop**
- Frame-skip: https://danieltakeshi.github.io/2016/11/25/frame-skipping-and-preprocessing-for-deep-q-networks-on-atari-2600-games/ · ALE envs https://ale.farama.org/environments/ · Machado et al. 2018 arXiv 1709.06009
- Fixed timestep: https://gafferongames.com/post/fix_your_timestep/
- Reaction time: https://reactiontimetest.net/blog/is-200ms-reaction-time-good-fast-vs-slow-score-guide · https://mindbenchmark.com/reaction-time/average
- Quake III bots: https://quake.fandom.com/wiki/Quake_3_Bots · bot paper https://www.cs.rochester.edu/users/faculty/brown/242/docs/QuakeIII.pdf · DeepMind CTF https://deepmind.google/blog/capture-the-flag-the-emergence-of-complex-cooperative-agents/ · Science https://www.science.org/doi/10.1126/science.aau6249
- WebSocket: RFC 6455 / guide https://websocket.org/guides/road-to-websockets/ · MDN https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API · long-polling https://websocket.org/comparisons/long-polling/ · WS vs SSE vs polling https://theinfinity.dev/articles/websocket-vs-sse-vs-polling · WS latency https://ankitbko.github.io/blog/2022/06/websocket-latency/

**Spatial world models**
- Active Neural SLAM arXiv 2004.05155 https://arxiv.org/pdf/2004.05155 · project https://devendrachaplot.github.io/projects/Neural-SLAM
- Occupancy Anticipation arXiv 2008.09285 https://arxiv.org/pdf/2008.09285 · project https://vision.cs.utexas.edu/projects/occupancy_anticipation/
- Recast/Detour https://github.com/recastnavigation/recastnavigation · intro https://recastnav.com/md_Docs_2__1__Introduction.html
- Neural Map arXiv 1702.08360 https://arxiv.org/pdf/1702.08360 · CMP CVPR 2017 https://openaccess.thecvf.com/content_cvpr_2017/papers/Gupta_Cognitive_Mapping_and_CVPR_2017_paper.pdf · MapNet CVPR 2018 https://openaccess.thecvf.com/content_cvpr_2018/html/Henriques_MapNet_An_Allocentric_CVPR_2018_paper.html · Semantic MapNet arXiv 2010.01191
- Semantic Curiosity arXiv 2006.09367 https://arxiv.org/pdf/2006.09367 · SLAM survey https://www.mdpi.com/2072-4292/14/13/3010 · DL-SLAM survey arXiv 2108.04097 https://arxiv.org/pdf/2108.04097 · egocentric/allocentric https://cheryyunl.github.io/blog/spatial-memory.html · https://journals.plos.org/ploscompbiol/article?id=10.1371/journal.pcbi.1013905

**Player pose / orientation**
- Godot Transform3D https://docs.godotengine.org/en/stable/classes/class_transform3d.html · using transforms https://docs.godotengine.org/en/stable/tutorials/3d/using_transforms.html · CharacterBody3D https://docs.godotengine.org/en/stable/classes/class_characterbody3d.html
- FPS RL aiming (Gun_yaw/Gun_pitch heads) arXiv 2410.04936 https://arxiv.org/html/2410.04936v1

**Flagged (verify before load-bearing use):** OpenAI Five "80 ms/5 Hz" (superseded by 2019
paper); AlphaStar single reaction-ms (blog posts disagree 110 vs 350 ms — cite the ≤22/5 s cap +
~370 ms inter-observation delay instead); screen-capture vision round-trip "tens-to-hundreds of
ms" (engineering estimate, no single measured source); polling "half-interval" average latency
(correct inference from the polling model, not a verbatim quote); ViZDoom pose-variable units
(deg/Doom-units conventional, confirm in C++ source).

---

*Compiled from five parallel web-research streams (structured-observation APIs; OpenAI
Five/AlphaStar structured state; latency & the sense-think-act loop; spatial world models;
player-pose exposure), cross-checked against the VOXIVERSE relay (`tools/remote-bridge/relay.mjs`)
and `godot/src/net/remote_control.gd`. Research + synthesis only; no game code modified.*
