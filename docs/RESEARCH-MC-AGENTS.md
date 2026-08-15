# How AI Agents Play Minecraft — Observation, Action, Latency, Navigation — and What Transfers to VOXIVERSE

**Status:** research reference (no code changes). Author: `research-mc-agents`. Date: 2026-08-15.
**Audience:** the VOXIVERSE agent-control layer (remote-bridge relay + telemetry/command protocol).

---

## 0. Executive summary

Every capable Minecraft agent in the literature falls on a spectrum between two poles:

- **Structured-state agents** (Malmo, MineDojo `voxels`, Mineflayer, and everything built on Mineflayer: Voyager, GITM) receive the world as *symbolic data* — a 3D array of block names around the player, an entity list with positions, the player's pose (x/y/z + yaw + pitch), inventory, health, and an explicit line-of-sight target block. They act through **high-level verbs** ("dig block at xyz", "goto", "place", "craft"). This is the cheap, low-latency, high-reliability path.
- **Pixel/low-level agents** (VPT, STEVE-1, DreamerV3, MineRL policies) receive only an **RGB frame** and emit the **native human interface** — 20 binary key states + a 2-axis mouse delta, at **20 Hz**. This is human-fair and general but data-hungry and needs a GPU policy in the loop.

The strongest **long-horizon** systems (Voyager, GITM, JARVIS-1, Optimus-1, Plan4MC) are LLM planners sitting on top of a structured or hybrid interface, plus a **memory/skill library** and a **spatial/world model**.

**The single most important finding for VOXIVERSE:** the systems that an *external LLM agent* (like this one) can drive well — Voyager, GITM — do **not** look at pixels to decide actions. They read a **structured world-state snapshot** (pose + a queryable block neighborhood + entities + inventory + an LOS target) and issue **named commands**. VOXIVERSE's three pain points (seconds of latency, no body-orientation telemetry, screenshot-only sensing) are exactly the three things those systems solved with a structured observation channel and a request/response command channel. Recommendations are in §8.

---

## 1. Observation spaces — what each agent actually receives

### 1.1 The taxonomy

| System | Pixels | Structured world-state | Voxel/block-grid query | Pose (yaw/pitch) | LOS target |
|---|---|---|---|---|---|
| Project Malmo | optional | yes (rich, opt-in handlers) | `ObservationFromGrid` | `ObservationFromFullStats` | `ObservationFromRay` |
| MineDojo | yes (`rgb`) | yes | `voxels` (3³ default, configurable) | `location_stats.yaw/pitch` | via `voxels` + `rgb` |
| MineRL (competition) | yes (`pov`) | minimal (inventory, compass, equipped) | **no** | **not exposed** (agent-relative camera only) | no |
| Mineflayer | no | yes (full server world state) | `bot.blockAt`, `bot.findBlocks` | `bot.entity.yaw/pitch` | `bot.blockAtCursor` |
| Voyager | no (uses Mineflayer state) | yes (via Mineflayer + injected helpers) | Mineflayer block queries | Mineflayer | Mineflayer |
| VPT | **yes only** | no | no | no | no |
| STEVE-1 | **yes only** (+ goal embedding) | no | no | no | no |
| DreamerV3 | **yes only** | no (learns latent world model) | no | no | no |
| GITM | text-abstracted | yes (structured observation) | yes (text-described surroundings) | yes | yes |
| JARVIS-1 | yes (multimodal) + text | yes | via MineDojo-style backend | yes | — |
| Optimus-1 | yes (MLLM) | yes | — | yes | — |

### 1.2 Malmo (Microsoft) — the richest opt-in structured observation API

Malmo exposes observations through XML "observation producer" handlers you attach to the mission; the agent then reads a JSON blob each tick. This is the closest published analogue to what VOXIVERSE needs. ([Malmo MissionHandlers schema](https://microsoft.github.io/malmo/0.21.0/Schemas/MissionHandlers.html), [Malmo tutorial](https://microsoft.github.io/malmo/0.14.0/Python_Examples/Tutorial.pdf))

- **`ObservationFromGrid`** — the voxel-neighborhood-as-array API. You declare one or more named `Grid` elements with `min`/`max` relative offsets (or `absoluteCoords="true"` for world coords). Malmo returns, per grid, **a named JSON element containing a 1-D array of block-type name strings, ordered along x, then z, then y**. So a `Grid name="floor3x3" min=(-1,-1,-1) max=(1,-1,1)` returns a 9-element array of the block names in the 3×3 slab under the player; a 3×3×3 volume returns 27 strings. ([schema](https://microsoft.github.io/malmo/0.21.0/Schemas/MissionHandlers.html))
- **`ObservationFromRay` (LineOfSight)** — the crosshair/LOS target. Returns a JSON object with `hitType` ("block"/"entity"/"item"), `x`,`y`,`z` (precise intersection point), `type` (block/entity name), `inRange` (boolean — within reach), `distance`, plus `variant`, `colour`, `facing`, `stackSize`, and `prop_*` block properties. An `includeNBT` flag can return the NBT compound for tile entities. ([schema](https://microsoft.github.io/malmo/0.21.0/Schemas/MissionHandlers.html), [PR #192](https://github.com/Microsoft/malmo/pull/192/files))
- **`ObservationFromFullStats`** — pose + vitals. Fields: **`XPos`, `YPos`, `ZPos`, `Pitch`, `Yaw`**, plus `Life`, `Score`, `Food`, `Air`, `XP`, `IsAlive`, `Name`, `WorldTime`, `TotalTime`, `DistanceTravelled`, `TimeAlive`, `MobsKilled`, `DamageTaken`. ([schema](https://microsoft.github.io/malmo/0.21.0/Schemas/MissionHandlers.html))
- **`ObservationFromNearbyEntities`** — the entity list. You declare a `Range name xrange yrange zrange` (e.g. ±10 x, ±1 y, ±10 z) plus an `update_frequency`, and get back a list of entities each with `name`, `x`, `y`, `z`, `quantity`, and (added later) **`yaw`, `pitch`, and `life`**. ([schema](https://microsoft.github.io/malmo/0.21.0/Schemas/MissionHandlers.html), [PR #192](https://github.com/Microsoft/malmo/pull/192/files))

**Takeaway for VOXIVERSE:** Malmo's four handlers map almost one-to-one onto the observation fields VOXIVERSE is missing: a block-grid array, an LOS target with `inRange`, a full pose (yaw/pitch), and an entity list — all as small JSON, all opt-in per query cost.

### 1.3 MineDojo — the `voxels` observation, with exact shapes

MineDojo (built on Malmo/Minecraft) publishes a documented `gym`-style observation dict. Exact fields and shapes ([MineDojo Observation Space docs](https://docs.minedojo.org/sections/core_api/obs_space.html)):

- **`obs["rgb"]`** — shape `(3, H, W)`, `uint8`, egocentric with hand + HUD.
- **`obs["voxels"]`** — the 3D block neighborhood. **Default 3×3×3** around the agent, each a `(3,3,3)` array:
  - `block_name` `(3,3,3)` `str`
  - `block_meta` `(3,3,3)` `int64`
  - `is_collidable`, `is_tool_not_required`, `blocks_movement`, `is_liquid`, `is_solid`, `can_burn`, `blocks_light` — each `(3,3,3)` boolean
  - `cos_look_vec_angle` `(3,3,3)` `float32` in `[-1,1]` — cosine between the player's look vector and the direction to each voxel (i.e. "which of these blocks am I looking toward"). ([docs](https://docs.minedojo.org/sections/core_api/obs_space.html))
  - A **larger region** is enabled with `use_voxel=True` and `voxel_size={xmin,xmax,ymin,ymax,zmin,zmax}` (offsets relative to the agent) — e.g. a 10×10×10 window. ([Privileged Observation docs](https://docs.minedojo.org/sections/customization/privileged_obs.html))
- **`obs["location_stats"]`** — pose & context:
  - `pos` `(3,)` `float32` (xyz), **`yaw` `float32`, `pitch` `float32`**, `biome_id` `(1,)` `int64`, `light_level` `(1,)` `float32` `[0,15]`, `can_see_sky` bool. ([docs](https://docs.minedojo.org/sections/core_api/obs_space.html))
- **`obs["life_stats"]`** — `life`, `armor`, `food`, each `(1,)` `float32` `[0,20]`.
- **`obs["inventory"]`** — `name` `(36,)` `str`, `quantity` `(36,)` `int64` `[0,64]`.
- **`obs["nearby_tools"]`** — `table` bool, `furnace` bool (is a crafting table / furnace within reach).
- **`obs["damage_source"]`** — `damage_amount` `(1,)` `float32`, `is_explosion` bool.

This is the cleanest published template for "agent-grade awareness": a small structured dict with a **queryable voxel grid + pose + inventory + vitals**, alongside (not instead of) pixels.

### 1.4 MineRL / MineRL BASALT — deliberately impoverished observation

MineRL (the NeurIPS competition environment) is the opposite design: it restricts observations to be human-fair for imitation learning. ([MineRL env docs](https://minerl.readthedocs.io/en/v0.4.4/environments/handlers.html), [MineRL general info](https://minerl.readthedocs.io/en/latest/environments/index.html))

- Most environments: **`Dict(pov: Box(low=0, high=255, shape=(360,640,3)))`** — an RGB image only. ([docs](https://minerl.readthedocs.io/en/latest/environments/index.html))
- `MineRLNavigate-v0` adds `compassAngle` (a single float, "0 = behind-left … 0.5 = in front … 1 = behind-right") and a small `inventory` dict (e.g. dirt count). ([docs](https://minerl.readthedocs.io/en/latest/environments/index.html))
- Equipment: `equipped_items.mainhand.type` as an enum. ([handlers](https://minerl.readthedocs.io/en/v0.4.4/environments/handlers.html))
- **No block grid, no absolute position, no yaw/pitch** are exposed — the agent must infer orientation from pixels and the compass. **BASALT** goes further: fuzzy tasks ("build a house", "find a cave") with **no reward function**, evaluated by human preference, forcing learning-from-pixels + human feedback. ([BEDD/BASALT dataset paper](https://arxiv.org/pdf/2312.02405))

This is exactly the trap VOXIVERSE is in today (pixels-only) — MineRL chose it deliberately to make RL hard-mode; VOXIVERSE's agent has no such reason to accept it.

### 1.5 Mineflayer — direct, complete server world-state (no pixels at all)

Mineflayer is a JavaScript bot framework that maintains a **client-side mirror of the server's world state** from the Minecraft protocol, so the agent queries data structures rather than perceiving. This is the substrate under Voyager and GITM. ([Mineflayer API](https://github.com/PrismarineJS/mineflayer/blob/master/docs/api.md))

- **`bot.entity`** — the player: `position` (Vec3), `velocity` (Vec3), **`yaw`** (radians, around vertical), **`pitch`** (radians, negative = looking up), `onGround` (bool).
- **`bot.entities`** — dict of all tracked entities by id; **`bot.players`** — connected players. (entity list with positions/pose — the "who/what is near me")
- **`bot.blockAt(point: Vec3, extraInfos=true)`** — the point block query: returns the `Block` at world coords (type, name, metadata, position, boundingBox). This is the direct analogue of VOXIVERSE's `WorldManager.block_id_at(cell)`.
- **`bot.findBlock(options)` / `bot.findBlocks(options)`** — spatial search: options `{ matching: id|id[]|fn, maxDistance, count, point }`; returns nearest matching block(s). ([blockfinder](https://github.com/Darthfett/mineflayer-blockfinder))
- **`bot.blockAtCursor(maxDistance=256)`** — raycast from the eye along the look vector → the targeted block (LOS). **`bot.entityAtCursor(maxDistance=3.5)`** — same for entities. **`bot.canSeeBlock(block)`** — boolean LOS test.
- **`bot.inventory`**, **`bot.health`** (0–20), **`bot.food`** (0–20), **`bot.time`** (`timeOfDay`, `day`, `isDay`, `moonPhase`, `age`).
- **`bot.look(yaw, pitch, force)`** — set head orientation (radians; yaw 0 = south, π/2 = west; pitch negative = up).

**Mineflayer is the single best structural model for VOXIVERSE's agent channel**, because both are "an external process holding a queryable mirror of an authoritative voxel world," and Mineflayer already routes every query through a single `blockAt(vec3)` — exactly VOXIVERSE's `block_id_at(cell)` invariant (CLAUDE.md rule 1).

### 1.6 VPT, STEVE-1, DreamerV3 — pixels only

- **VPT (OpenAI Video PreTraining)** consumes only video: 720p contractor recordings downsampled to **360p at 20 Hz**. No structured state at all — the whole point is to learn from unlabeled human video via an inverse dynamics model. ([VPT paper](https://arxiv.org/pdf/2206.11795), [OpenAI VPT](https://openai.com/index/vpt/))
- **STEVE-1** = instruction-tuned VPT: input is pixels **plus a goal embedding** (a MineCLIP text/video latent) — still no symbolic world state. ([STEVE-1 paper](https://arxiv.org/abs/2306.00937))
- **DreamerV3** learns a **latent world model** from pixels (+ low-dim inputs), imagines rollouts in latent space, and was the **first system to mine a diamond from scratch with no human data or curriculum**. The "world model" here is *learned latent state*, not a queryable voxel grid. ([DreamerV3 paper](https://arxiv.org/pdf/2301.04104), [ar5iv](https://ar5iv.labs.arxiv.org/html/2301.04104))

These are relevant to VOXIVERSE only as a contrast: they prove pixels *can* work, but they require training a policy network — not viable for an external LLM tele-operator that needs to act *now*.

---

## 2. Action interfaces

### 2.1 Low-level native interface (VPT / MineRL / STEVE-1 / DreamerV3)

The "human-fair" interface is **keyboard + mouse at 20 Hz**:

- **VPT** action space: **~20 binary buttons + 2 mouse axes, each mouse axis binned into 11 bins** (with camera bins spaced non-linearly). The full factored joint is ~1.2×10⁸ combos, so VPT prunes mutually-exclusive presses (forward+back cancel; inventory is exclusive with everything). Later work (e.g. GROOT/JARVIS-VLA) uses a **hierarchical button-space + camera-space** factorization (≈8,461 button combos × 121 camera bins), and **µ-law binning** of mouse dx/dy into ~21 bins/axis. ([VPT paper](https://arxiv.org/pdf/2206.11795), [GROOT](https://arxiv.org/pdf/2310.08235), [JARVIS-VLA](https://arxiv.org/pdf/2503.16365))
- **MineRL** action space: a `Dict` of keyboard booleans (`forward`, `back`, `left`, `right`, `jump`, `sneak`, `sprint`, `attack`, `use`, …) plus **`camera: Box(2) = [Δpitch, Δyaw]`** in degrees, clamped to `[-180, 180]`, plus `equip`/`craft` enums. ([MineRL handlers](https://minerl.readthedocs.io/en/v0.4.4/environments/handlers.html))

Cost: a trained neural policy that outputs these at 20 Hz. Not what an external LLM does.

### 2.2 High-level structured verbs (Malmo / Mineflayer / Voyager / GITM)

- **Malmo** offers both **continuous** commands (`move`, `strafe`, `pitch`, `turn`, `jump`, `crouch`, `attack`, `use` with real-valued rates) and **discrete** commands (`movenorth 1`, `turn 1`), plus **`AbsoluteMovementCommands`** (teleport to x/y/z/yaw/pitch) and **`ChatCommands`**. You pick the command handler per mission. ([Malmo tutorial](https://microsoft.github.io/malmo/0.14.0/Python_Examples/Tutorial.pdf))
- **Mineflayer** exposes semantic verbs: `bot.dig(block)`, `bot.placeBlock(refBlock, faceVector)`, `bot.equip`, `bot.activateItem`, `bot.attack(entity)`, `bot.lookAt`, and — via **mineflayer-pathfinder** — `bot.pathfinder.goto(goal)`. The agent names *what*, the library resolves *how*. ([Mineflayer API](https://github.com/PrismarineJS/mineflayer/blob/master/docs/api.md))
- **Voyager** takes this to the limit: GPT-4 **writes JavaScript** against the Mineflayer API (e.g. `mineBlock`, `craftItem`, `combatZombie`), and successful programs are stored as reusable skills. The "action" is *a whole program*, not a keypress. ([Voyager paper](https://arxiv.org/abs/2305.16291), [Voyager site](https://voyager.minedojo.org/))
- **GITM** decomposes goals → sub-goals → **structured actions** (text-described) → finally keyboard/mouse operations at the bottom layer. The LLM never touches raw input; it emits structured actions that a controller executes. ([GITM paper](https://arxiv.org/abs/2305.17144))

**This is the model for VOXIVERSE:** the agent should emit high-level, named, parameterized commands (`goto`, `dig`, `place`, `look_at`, `set_yaw_pitch`), and the game/relay resolves them — exactly like VOXIVERSE already resolves break/place through `WorldManager`.

### 2.3 The sense→act loop rate

- **Malmo** ticks at **50 ms = 20 Hz by default** (`MsPerTick`, configurable down to 25/10/5/1 ms); with `MsPerTick=5` the loop can run at 200 Hz, subject to the trainer keeping up. Observations are delivered per tick. ([gym-minecraft tuning wiki](https://github.com/tambetm/gym-minecraft/wiki/Tuning), [tsmatz Malmo/MineRL](https://tsmatz.wordpress.com/2020/07/09/minerl-and-malmo-reinforcement-learning-in-minecraft/))
- **MineRL / VPT / STEVE-1**: **20 Hz** (one Minecraft tick = 50 ms), frame-locked. ([VPT paper](https://arxiv.org/pdf/2206.11795))
- **Mineflayer**: **event-driven, real-time** — the bot's world mirror updates as protocol packets arrive (physics tick ~20 Hz), and the agent can query state or issue commands at any moment; pathfinder runs its own tick loop.

The key number: **20 Hz (50 ms/tick) is the Minecraft-native cadence** that all the reference systems operate at or above. VOXIVERSE's current 500 ms poll + ~4 Hz telemetry is **10–25× slower** than the field standard.

---

## 3. Player orientation (yaw/pitch/forward vector)

Every capable agent exposes orientation explicitly; only the pixels-only RL crowd hides it:

- **Malmo**: `Yaw`, `Pitch` in `ObservationFromFullStats`; nearby entities also carry `yaw`/`pitch`. Absolute-movement commands set yaw/pitch directly. ([schema](https://microsoft.github.io/malmo/0.21.0/Schemas/MissionHandlers.html))
- **MineDojo**: `location_stats.yaw` and `.pitch` (`float32`, degrees, −180…180), plus `cos_look_vec_angle` in the `voxels` block telling the agent which surrounding voxels lie along its gaze — a ready-made "am I aimed at this block" signal. ([docs](https://docs.minedojo.org/sections/core_api/obs_space.html))
- **Mineflayer**: `bot.entity.yaw`/`.pitch` (radians; yaw measured from due-east/south by convention), forward vector derivable as `dir = (-sin(yaw)cos(pitch), sin(pitch), -cos(yaw)cos(pitch))`. Aiming = `bot.look(yaw, pitch)` or `bot.lookAt(point)`; the library computes the yaw/pitch to face a target. ([Mineflayer API](https://github.com/PrismarineJS/mineflayer/blob/master/docs/api.md))
- **MineRL**: orientation is **not** exposed as state — only a relative `camera` action and, in Navigate, a `compassAngle` scalar. Agents must integrate their own heading. ([MineRL docs](https://minerl.readthedocs.io/en/latest/environments/index.html))

**Direct hit on VOXIVERSE pain point #2 (no body-orientation telemetry):** the entire structured-agent family treats yaw+pitch (and a forward vector / look-cosine) as first-class observation fields. Aiming ("dig the block I'm looking at") is impossible without them, and `bot.blockAtCursor` / `ObservationFromRay` / `cos_look_vec_angle` all depend on knowing the look direction server-side.

---

## 4. Latency & the observe→act round-trip

Two regimes:

1. **Synchronous `gym.step()`** (MineRL, MineDojo, most RL). The env blocks: `obs, reward, done, info = env.step(action)` advances exactly one tick and returns the new observation. The world *waits* for the agent, so wall-clock latency is irrelevant to correctness but caps throughput at how fast the policy runs. **Frame-skip / action-repeat** (repeat one action for k ticks) is the standard trick to cut policy calls; MineRL/VPT commonly hold an action for several ticks. ([MineRL docs](https://minerl.readthedocs.io/en/latest/environments/index.html))
2. **Real-time async** (Malmo default, Mineflayer). The world keeps ticking at 20 Hz whether or not the agent has replied; the agent reads the latest observation and posts commands. Here the sense→act round-trip *is* wall-clock-critical: a slow loop means acting on stale state. Malmo mitigates this by letting you (a) lower `MsPerTick` and (b) run **in-process** so observations are a function call, not a socket hop. ([gym-minecraft tuning](https://github.com/tambetm/gym-minecraft/wiki/Tuning), [Malmo position-lag issue #371](https://github.com/Microsoft/malmo/issues/371))

**How tightness is kept:** (a) **in-process or local-socket** transport (Malmo runs a Mod inside the JVM; Mineflayer speaks the raw TCP protocol with no polling delay); (b) **push, not poll** — observations are emitted every tick / on state-change, not fetched on a timer; (c) **frame-skip** to amortize expensive policy calls; (d) **structured deltas** instead of re-encoding a JPEG each frame.

**VOXIVERSE pain point #1 (seconds of latency):** the current design has *three* serial latency sources stacked — 500 ms relay **poll** interval + ~4 Hz (250 ms) telemetry cadence + JPEG frame encode/decode. None of the reference systems poll on a timer or ship an image as the primary observation. The fixes are structural (push telemetry over a socket, high tick rate, structured state instead of pixels) — see §8.

---

## 5. Navigation

- **Mineflayer-pathfinder** is the canonical block-grid navigator: **A\*** over walkable moves, configured by a **`Movements`** object (`canDig`, `allowParkour`, `allowSprinting`, `maxDropDown`, `digCost`, `placeCost`, `blocksToAvoid`, `blocksCantBreak`, scaffolding blocks, …). Goals are declarative: **`GoalBlock(x,y,z)`, `GoalNear(x,y,z,r)`, `GoalXZ(x,z)`, `GoalNearXZ`, `GoalY(y)`, `GoalGetToBlock` (adjacent, for chests), `GoalFollow(entity,r)`, `GoalInvert`, `GoalCompositeAny/All`, `GoalPlaceBlock`, `GoalLookAtBlock`**. You call `bot.pathfinder.goto(goal)` (promise) or `setGoal(goal, dynamic)`; it can dig/place to open a route and re-plans dynamically. ([mineflayer-pathfinder](https://github.com/PrismarineJS/mineflayer-pathfinder))
- **Voyager & GITM** navigate by calling that pathfinder (or equivalent `move`/`explore` primitives) from LLM-generated code — the LLM reasons about *where* to go and delegates *how* to A\*. Voyager's automatic curriculum ("What should I explore next?") drives goal selection; the skill library caches working navigation programs. ([Voyager paper](https://arxiv.org/abs/2305.16291), [GITM paper](https://arxiv.org/abs/2305.17144))
- **Spatial / world-model memory:**
  - **GITM** keeps **text-based knowledge + memory** of the world and recipes to plan sub-goals. ([GITM](https://arxiv.org/abs/2305.17144))
  - **JARVIS-1** adds a **multimodal memory** (visual observations + instructions → plans), retrieving both pre-trained knowledge and lived game experience to plan. ([JARVIS-1 paper](https://arxiv.org/html/2311.05997))
  - **Optimus-1** builds a **Hybrid Multimodal Memory**: a **Hierarchical Directed Knowledge Graph** (explicit world knowledge, e.g. the crafting/tech tree) + an **Abstracted Multimodal Experience Pool** (summarized history for in-context reference), driving a Knowledge-guided Planner + Experience-Driven Reflector — beating a GPT-4V baseline on long-horizon tasks with no weight updates. ([Optimus-1 paper](https://arxiv.org/abs/2408.03615), [site](https://cybertronagent.github.io/Optimus-1.github.io/))
  - **Plan4MC** learns **three fine-grained skill types** (Finding, Manipulation, Crafting) with RL, then **plans over a skill graph pre-generated by an LLM**, solving ~24 long-horizon MineDojo tasks that chain 10+ skills. ([Plan4MC paper](https://ar5iv.labs.arxiv.org/html/2303.16563))
- **DreamerV3** navigates via its **learned latent world model** — an *implicit* occupancy/dynamics model rather than an explicit voxel map or A\* grid. ([DreamerV3](https://arxiv.org/pdf/2301.04104))
- **MineCLIP** (the reward/representation backbone under MineDojo agents and STEVE-1) is a **contrastive video-text model** that scores how well a video clip matches a language goal — used as a dense reward and as the goal-embedding space, not a navigator per se. ([MineDojo/MineCLIP](https://docs.minedojo.org), [STEVE-1](https://arxiv.org/abs/2306.00937))

**Pattern:** explicit block-grid A\* for local movement + an LLM/graph for high-level goal ordering + a persistent memory of "what's where / what I've learned." VOXIVERSE already has the authoritative grid (`block_id_at`) to run A\* on; it lacks the *query channel* to expose it.

---

## 6. Cross-cutting observations for VOXIVERSE

1. **The successful *external-LLM* agents (Voyager, GITM, JARVIS-1, Optimus-1) never decide actions from pixels.** They read structured state and emit named verbs. VOXIVERSE's agent is architecturally a Voyager/GITM-class controller, so it should be fed a Voyager/GITM-class observation: structured, not a JPEG.
2. **A queryable block neighborhood is the load-bearing sensor.** Malmo `ObservationFromGrid`, MineDojo `voxels`, and Mineflayer `blockAt`/`findBlocks` are the same idea in three dresses. VOXIVERSE already has the one true source (`WorldManager.block_id_at(cell)`, edit-overlay-else-generated) — it only needs to be *exposed over the wire*.
3. **Pose (x/y/z + yaw + pitch + velocity) + a look/forward vector is mandatory** and is exactly VOXIVERSE's missing pain point #2. Without it there is no aiming, no "dig what I'm looking at," no dead-reckoning between updates.
4. **An explicit LOS target ("the block/entity under the crosshair, with `inRange`") collapses most interaction logic** — it's how Malmo, MineDojo (via `cos_look_vec_angle`), and Mineflayer (`blockAtCursor`) turn "look + click" into one query. VOXIVERSE already computes a DDA raycast for break/place; surface its result.
5. **20 Hz (50 ms) is the reference cadence; push, don't poll.** Everything in the field runs at 20 Hz or faster over in-process/local sockets. VOXIVERSE's 500 ms file-poll + 4 Hz telemetry is the outlier.
6. **Command channel = request/response with acks, not fire-and-forget files.** Mineflayer verbs return promises; Malmo commands advance a tick. VOXIVERSE's JSON-file drop + 500 ms poll gives neither timing nor completion feedback.

---

## 7. Quick reference — the exact observation fields to copy

| Need | Malmo | MineDojo | Mineflayer | → VOXIVERSE field |
|---|---|---|---|---|
| Position | `XPos/YPos/ZPos` | `location_stats.pos (3,)` | `bot.entity.position` | `pos: [x,y,z]` (world + cell) |
| Orientation | `Yaw`,`Pitch` | `location_stats.yaw/pitch` | `bot.entity.yaw/pitch` | `yaw`,`pitch` (rad+deg) + `forward:[x,y,z]` |
| Velocity | (derive) | (derive) | `bot.entity.velocity` | `vel:[x,y,z]`, `on_ground` |
| Block neighborhood | `ObservationFromGrid` (1-D name array, x→z→y) | `voxels.block_name (N,N,N)` + flags | `bot.blockAt(v)` / `findBlocks` | `voxel_grid` around player (ids + flags) + on-demand `block_at(cell)` |
| LOS target | `ObservationFromRay` (`hitType,x,y,z,type,inRange,distance`) | `cos_look_vec_angle` | `bot.blockAtCursor` | `los: {cell, block_id, point, in_range, distance, normal}` |
| Entities/trees | `ObservationFromNearbyEntities` (`name,x,y,z,yaw,pitch,life`) | — | `bot.entities`,`bot.players` | `entities:[{kind,id,pos,...}]` (VoxelBodies, trees) |
| Inventory | inventory handler | `inventory.name/quantity (36,)` | `bot.inventory` | `inventory:[{id,count}]` + `selected` |
| Vitals/context | `Life,Food,Air` | `life_stats`, `light_level`, `biome_id`, `can_see_sky` | `bot.health`,`bot.food` | `vitals` + `temperature`/`light` from `PerVoxelEnvironment` |

---

## 8. RECOMMENDATIONS FOR VOXIVERSE

VOXIVERSE already has the hard part: a single authoritative world query (`WorldManager.block_id_at(cell)`, CLAUDE.md rule 1), a DDA raycast, an analytic pose, and a `PerVoxelEnvironment`. What's missing is a **structured observation/query/command protocol over a low-latency socket**. Adopt the Mineflayer+Malmo model.

### 8.1 Observation payload (push every tick — target 20 Hz)

Emit a compact JSON (or binary/CBOR) **state snapshot**, not a JPEG, as the primary channel. Fields, grounded in §7:

```jsonc
{
  "t": 1234567,                       // monotonic tick / ms
  "pose": {
    "pos": [x, y, z],                 // world coords  (MineDojo location_stats.pos)
    "cell": [cx, cy, cz],             // voxel cell of the player
    "yaw": 1.57, "pitch": -0.2,       // radians (Mineflayer) — PAIN POINT #2
    "yaw_deg": 90, "pitch_deg": -11,  // convenience (MineDojo degrees)
    "forward": [fx, fy, fz],          // unit look vector (derive from yaw/pitch)
    "up": [ux, uy, uz],               // matters on a faceted planet (radial up ≠ world up)
    "vel": [vx, vy, vz], "on_ground": true
  },
  "los": {                            // from the existing DDA raycast (Malmo ObservationFromRay / Mineflayer blockAtCursor)
    "hit": true, "cell": [bx, by, bz], "block_id": 12,
    "point": [px, py, pz], "normal": [0,1,0],
    "distance": 3.4, "in_range": true // in_range gates break/place, exactly like Malmo
  },
  "voxels": {                         // queryable neighborhood (Malmo ObservationFromGrid / MineDojo voxels)
    "origin": [cx-2, cy-2, cz-2],
    "size": [5, 5, 5],                // default small (3³–5³); larger on request (MineDojo use_voxel/voxel_size)
    "ids": [ /* row-major ids, document axis order like Malmo x→z→y */ ],
    "solid": [ /* optional bool plane, from is_solid/blocks_movement */ ]
  },
  "entities": [                       // Malmo ObservationFromNearbyEntities
    {"kind":"voxel_body","id":7,"pos":[...],"mass":40,"vel":[...]},
    {"kind":"tree","id":3,"pos":[...],"species":"acacia"}
  ],
  "inventory": {"slots":[{"id":4,"count":9}], "selected": 0},   // MineDojo inventory
  "vitals": {"temperature": 14.2, "light": 15, "biome": "B_MOUNTAINS", "can_see_sky": true} // PerVoxelEnvironment
}
```

Design rules, each traceable to a reference system:
- **Pose with yaw/pitch/forward/up is non-negotiable** (§3). On VOXIVERSE's faceted planet, also emit **radial `up`** — unlike flat Minecraft, world-up ≠ local-up, and the agent needs it to interpret "forward" and to fly/orbit (this is a VOXIVERSE-specific superset of the Mineflayer/MineDojo pose).
- **`voxels`** mirrors MineDojo's `voxels` and Malmo's `ObservationFromGrid`: default a **small window (3³–5³)** every tick for cheapness; support an **on-demand larger box** (§1.3, `use_voxel`/`voxel_size`) and an **on-demand point/region query** for planning. Read straight from `block_id_at(cell)` so overlay + generated + trees stay consistent (never a parallel "what's solid" — CLAUDE.md rule 1).
- **`los`** is a direct dump of the existing DDA raycast result, with `in_range` gating interaction exactly like Malmo's `ObservationFromRay.inRange` — this is pain point #3 solved with data you already compute.
- **`entities`** exposes `VoxelBody` rigid bodies and `TreeGen` trees (VOXIVERSE's analogue of mobs/entities) as Malmo-style nearby-entity records.
- Keep the JPEG frame as an **optional, throttled side-channel** (debug / VLM fallback), never the primary sense loop.

### 8.2 Action / query protocol (request→ack→result over the socket)

Two message classes, both **named + parameterized** (Mineflayer/Malmo verbs, §2.2), each with an id and a completion ack (fixing "fire-and-forget files, no feedback"):

- **Instant queries** (no tick cost): `block_at(cell)`, `region(min,max)`, `find_blocks({match, max_dist, count})` (Mineflayer `findBlocks`), `raycast(from,dir)` , `nearest_entities(range)`.
- **Actuation verbs**: `look_at(cell|point)` / `set_yaw_pitch(y,p)` (Mineflayer `look`), `move({fwd,strafe,jump,sprint})` (continuous, Malmo-style) **or** `goto(goal)` where goal ∈ {`GoalBlock`, `GoalNear(cell,r)`, `GoalXZ`, …} backed by **A\* over `block_id_at`** (mineflayer-pathfinder, §5), `dig(cell)`, `place(cell, block_id)`, `select_slot(i)`. Return `{id, status: started|done|failed, reason}`.

This lets the LLM operate like Voyager/GITM: reason over structured state, emit a high-level verb, get an ack — while low-level control (pathfinding, aiming, stepping) stays inside the game where it's cheap and reliable.

### 8.3 Loop rate & transport

- **Replace the 500 ms file-poll with a WebSocket push** (the relay already is a WebSocket relay). Telemetry **pushed at 20 Hz (50 ms)** matches the Minecraft-native cadence every reference system uses (§2.3, §4); commands sent immediately, not polled.
- **Target the sense→act round-trip at ≤ 50–100 ms.** Delete the three stacked latency sources (§4): poll interval, JPEG encode, low telemetry Hz. Structured JSON at 20 Hz over WS is a few KB/tick — cheaper than one JPEG.
- **Frame-skip / decimate on the agent side**, not the game side: the game pushes at 20 Hz; the LLM consumes at its own pace but always sees *fresh* state and can dead-reckon from `pose.vel` between decisions (the async-realtime pattern, §4).
- **Give commands completion acks** (Mineflayer promises, Malmo tick-advance) so the agent knows when `goto`/`dig` finished instead of guessing from screenshots.

### 8.4 Memory / world model (later, optional)

Once the observation channel exists, VOXIVERSE's agent can adopt the GITM/Optimus-1/JARVIS-1 pattern (§5): keep a **persistent occupancy/landmark memory** (block edits, discovered structures, tree locations) and a small **knowledge graph** of the block/crafting tree (VOXIVERSE's `BlockCatalog` + `generated_block` rules already are that graph), enabling long-horizon planning without re-sensing. Not required for the latency/awareness fix, but it's the natural next rung and the field's consensus for multi-step autonomy.

### 8.5 Priority order

1. **Pose telemetry (yaw/pitch/forward/up/vel)** — pain point #2, trivial to emit, unblocks all aiming/navigation. (§3)
2. **WebSocket push at 20 Hz replacing the 500 ms poll** — pain point #1, structural. (§4, §8.3)
3. **`los` target + `voxels` neighborhood + `block_at`/`region` queries** — pain point #3, reuse `block_id_at` + the DDA raycast. (§1.5, §8.1–8.2)
4. **Named actuation verbs with acks** (`goto`/`dig`/`place`/`look_at`). (§2.2, §8.2)
5. **A\* `goto` over the block grid** (mineflayer-pathfinder-style). (§5)
6. **Persistent memory / knowledge graph** (GITM/Optimus-1). (§5, §8.4)

---

## Sources

- Malmo observation handlers (Grid / Ray / FullStats / NearbyEntities): [MissionHandlers schema](https://microsoft.github.io/malmo/0.21.0/Schemas/MissionHandlers.html) · [Malmo tutorial PDF](https://microsoft.github.io/malmo/0.14.0/Python_Examples/Tutorial.pdf) · [nearby-entities yaw/pitch PR #192](https://github.com/Microsoft/malmo/pull/192/files) · [Mission schema](https://microsoft.github.io/malmo/0.14.0/Schemas/Mission.html)
- Malmo tick rate / MsPerTick / latency: [gym-minecraft tuning wiki](https://github.com/tambetm/gym-minecraft/wiki/Tuning) · [tsmatz: Malmo & MineRL](https://tsmatz.wordpress.com/2020/07/09/minerl-and-malmo-reinforcement-learning-in-minecraft/) · [position-lag issue #371](https://github.com/Microsoft/malmo/issues/371)
- MineDojo observation space (`voxels`, `location_stats`, etc.): [Observation Space docs](https://docs.minedojo.org/sections/core_api/obs_space.html) · [Privileged Observation](https://docs.minedojo.org/sections/customization/privileged_obs.html) · [Simulation customization](https://docs.minedojo.org/sections/customization/sim.html)
- MineRL observation/action spaces + BASALT: [env handlers](https://minerl.readthedocs.io/en/v0.4.4/environments/handlers.html) · [general info / POV shape](https://minerl.readthedocs.io/en/latest/environments/index.html) · [BEDD/BASALT dataset](https://arxiv.org/pdf/2312.02405)
- Mineflayer API + pathfinder: [bot API](https://github.com/PrismarineJS/mineflayer/blob/master/docs/api.md) · [mineflayer-pathfinder](https://github.com/PrismarineJS/mineflayer-pathfinder) · [blockfinder](https://github.com/Darthfett/mineflayer-blockfinder)
- VPT: [paper (arXiv 2206.11795)](https://arxiv.org/pdf/2206.11795) · [OpenAI VPT](https://openai.com/index/vpt/) · [GitHub](https://github.com/openai/Video-Pre-Training)
- Voyager: [paper (arXiv 2305.16291)](https://arxiv.org/abs/2305.16291) · [project site](https://voyager.minedojo.org/) · [code](https://github.com/minedojo/voyager)
- DreamerV3: [paper (arXiv 2301.04104)](https://arxiv.org/pdf/2301.04104) · [ar5iv](https://ar5iv.labs.arxiv.org/html/2301.04104)
- GITM: [paper (arXiv 2305.17144)](https://arxiv.org/abs/2305.17144)
- JARVIS-1: [paper (arXiv 2311.05997)](https://arxiv.org/html/2311.05997) · [site](https://craftjarvis-jarvis1.github.io/)
- STEVE-1 + MineCLIP: [STEVE-1 paper (arXiv 2306.00937)](https://arxiv.org/abs/2306.00937) · [site](https://sites.google.com/view/steve-1)
- Plan4MC: [paper (arXiv 2303.16563)](https://ar5iv.labs.arxiv.org/html/2303.16563) · [code](https://github.com/PKU-RL/Plan4MC)
- Optimus-1: [paper (arXiv 2408.03615)](https://arxiv.org/abs/2408.03615) · [site](https://cybertronagent.github.io/Optimus-1.github.io/)
- VPT-derived action-space factorizations: [GROOT (arXiv 2310.08235)](https://arxiv.org/pdf/2310.08235) · [JARVIS-VLA (arXiv 2503.16365)](https://arxiv.org/pdf/2503.16365)
