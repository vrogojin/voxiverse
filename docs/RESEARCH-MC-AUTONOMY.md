# Autonomous Play in Minecraft-like Worlds — Navigation, Actuation & the Closed Task Loop, and the "Do We Need a Special Model?" Verdict

**Status:** research reference (no code changes). Companion to `docs/RESEARCH-MC-AGENTS.md`
(observation/action/latency) and `docs/RESEARCH-FPS-AWARENESS.md` (structured perception).
Date: 2026-08-17.
**Audience:** the VOXIVERSE agent-autonomy layer — turning "find a tree → walk to it → aim at
the chop point → chop it" into a single reliable operation, and deciding whether that needs a
trained model.

Every non-obvious claim carries an inline primary-source link; a consolidated list is at the end.
Where a number is an inference rather than a verbatim quote it is flagged **[inference]**.

---

## 0. The gap this report closes

The two companion reports established VOXIVERSE's **perception** answer: the winning external-LLM
agents (Voyager, GITM, JARVIS-1) never look at pixels to decide — they read a structured
world-state snapshot (pose + queryable block grid + entities + an LOS/crosshair target) and emit
named verbs. VOXIVERSE now *has* that perception: `query_box` (a voxel grid), `query_ray` (the
exact crosshair cell + `in_range`), and `FP_AGENT_POSE` telemetry (tasks #134–#136).

Perception was only half the loop. The agent can *see* the tree and *know* it's out of reach, but
it still cannot **close the loop**: it has no primitive that moves the body to the tree, no
primitive that turns the head onto the chop point, and no owner for the perceive→plan→act cadence
that recovers when the path is blocked or the target moves. That missing half — **navigation +
actuation + the autonomous task loop** — is exactly what mineflayer-pathfinder, Baritone,
Voyager, and the trained-policy line (VPT/STEVE-1/DreamerV3) each solve in a different way. This
report maps those solutions and lands the architecture verdict the user asked for.

**TL;DR verdict (full argument in §4):** For a game that **already exposes structured world state
+ a raycast** — i.e. VOXIVERSE — the field consensus is unambiguous: **scripted pathfinding +
a small library of deterministic skills (goto / chop / harvest), driven by an LLM planner only for
goal selection, is both sufficient and superior.** A narrow trained policy (VPT/STEVE-1/DreamerV3)
buys nothing here that scripting doesn't already give you for free, and costs orders of magnitude
more (VPT: 70k video-hours + 720 V100-GPUs × 9 days; §4b) — its entire reason for existing is to
recover the structured state VOXIVERSE hands you directly. Build server-side composite verbs;
train nothing.

---

## 1. Navigation / pathfinding — what makes "go to that tree" one call

The universal shape: an **A\* search over a block-grid graph**, where nodes are stand-able cells,
edges are *movements* (walk / jump / fall / dig-through / place-to-cross), edge weight is a **cost**
(≈ time or a resource proxy), and the target is a **declarative goal object** the caller constructs
without knowing the route. The two canonical implementations are mineflayer-pathfinder (JS,
external bot) and Baritone (Java, in-client) — VOXIVERSE is architecturally the former (an external
process holding a mirror of an authoritative voxel world) but should steal Baritone's cost model.

### 1.1 mineflayer-pathfinder — the external-bot A\* navigator

A plugin that runs A\* over Mineflayer's world mirror and drives the bot to a **goal**. The whole
"go there" contract is one call: `bot.pathfinder.goto(goal)` returns a Promise that resolves when
the goal is reached (or `bot.pathfinder.setGoal(goal, dynamic)` for a re-planning follow).
([mineflayer-pathfinder README](https://github.com/PrismarineJS/mineflayer-pathfinder))

**Goal types** (the declarative "where", constructed by the caller):

| Goal | Meaning (verbatim) |
|---|---|
| `GoalBlock(x,y,z)` | "One specific block that the player should stand inside at foot level" |
| `GoalNear(x,y,z,range)` | "get within a certain radius of" a position |
| `GoalXZ(x,z)` | "long-range goals that don't have a specific Y level" |
| `GoalNearXZ(x,z,range)` | approximate X/Z, unknown Y |
| `GoalY(y)` | "Get to a Y level" |
| `GoalGetToBlock(x,y,z)` | "get directly adjacent to it. Useful for chests" — **do not stand inside** |
| `GoalFollow(entity,range)` | "Follows an entity" (dynamic) |
| `GoalInvert(goal)` | flee — "Inverts the goal" |
| `GoalCompositeAny([...])` / `GoalCompositeAll([...])` | any-of / all-of over sub-goals |
| `GoalPlaceBlock(pos,world,opts)` | stand where you can place a block at `pos` |
| `GoalLookAtBlock(pos,world,opts)` | "Path into a position where a blockface of block at pos is visible" |

`GoalGetToBlock` and `GoalLookAtBlock` are the two that matter for chopping: you want to be
*adjacent to and looking at* the trunk, not standing in it. ([README](https://github.com/PrismarineJS/mineflayer-pathfinder))

**Movements config** (the "how" / traversability + cost policy, a `Movements` object passed to
`bot.pathfinder.setMovements`): `canDig` (default `true` — allowed to tunnel through obstacles),
`allowParkour`, `allowSprinting`, `maxDropDown` (default `4`), `digCost` (default `1`), `placeCost`
(default `1`), `blocksToAvoid` (Set), `blocksCantBreak` (Set), `scafoldingBlocks` (items usable to
bridge). This object *is* the traversability model: flip `canDig=false` and the planner routes
around instead of through. ([README](https://github.com/PrismarineJS/mineflayer-pathfinder))

### 1.2 Baritone — the canonical Minecraft pathfinder (steal its cost model)

Baritone is the reference MC pathfinder (an in-client Java mod, "over 30× faster" than its
MineBot predecessor), and its design is the more sophisticated of the two. It runs **A\* "with some
modifications"** and its two ideas VOXIVERSE should copy are the **time-based cost model** and the
**compacted chunk cache**. ([Baritone repo](https://github.com/cabaletta/baritone),
[FEATURES.md](https://github.com/cabaletta/baritone/blob/master/FEATURES.md))

- **Cost = time (ticks), plus resource-proxy penalties.** Movement edges are costed by how long
  they take, then nudged by penalties that encode *preferences*: the **block-placement penalty is
  "set to 1 second by default"** (placing conserves limited blocks, so the planner avoids it unless
  it saves more than a second), there is a **block-break tiebreaker penalty** ("less likely to
  break blocks if it can avoid it"), and a **jump penalty** ("additional penalty for hitting the
  space bar … because it uses hunger"). So the cost model unifies *time* and *scarce-resource*
  concerns in one scalar. ([FEATURES.md](https://github.com/cabaletta/baritone/blob/master/FEATURES.md),
  [9minecraft cost-settings summary](https://www.9minecraft.net/baritone-ai-pathfinder-mod/))
- **Movement types it considers as edges:** walk, ascend/descend, diagonal, sprint-jump parkour
  ("over 1, 2, or 3 block gaps"), fall (up to 3 blocks, or up to 23 with a water bucket),
  ladders/vines, swim, and **break/place as part of the path** (it "considers breaking blocks as
  part of its path" and "accounts for your current tool set and hot bar").
  ([FEATURES.md](https://github.com/cabaletta/baritone/blob/master/FEATURES.md))
- **Chunk caching for long-range planning:** it "simplifies chunks to a compacted internal 2-bit
  representation (AIR, SOLID, WATER, AVOID)" with optional disk persistence — this is what lets it
  path across thousands of blocks without holding full chunk data. **[This is directly relevant to
  VOXIVERSE's faceted planet: a 2-bit traversability cache derived from `block_id_at` is exactly
  the right planning substrate at scale.]**
  ([FEATURES.md](https://github.com/cabaletta/baritone/blob/master/FEATURES.md))
- **Goal types** mirror pathfinder's: `GoalBlock`, `GoalXZ`, `GoalNear`, `GoalYLevel`,
  `GoalGetToBlock`, `GoalRunAway`, `GoalComposite`. Set programmatically, e.g.
  `getCustomGoalProcess().setGoalAndPath(new GoalXZ(10000, 20000))`, or by chat command:
  **`#goto <x> <z>`, `#mine <block_type>`, `#follow`, `#stop`**. ([Baritone repo](https://github.com/cabaletta/baritone),
  [Settings API](https://baritone.leijurv.com/baritone/api/Settings.html))
- **Partial-path robustness:** when A\* exits early without reaching the goal it uses **"incremental
  cost backoff"** — it keeps the best node under increasing coefficients and picks one that goes
  "at least 5 blocks from the start," then re-plans the next segment while "favoring backtracking"
  the current one. This is the anytime behavior that makes long paths feel continuous.
  ([FEATURES.md](https://github.com/cabaletta/baritone/blob/master/FEATURES.md))

`#mine diamond_ore` is the important composite: Baritone will **path to, break, and (with a
GetToBlock target) collect** a named block anywhere in the cached region — i.e. "mine that" is one
command, not a route the caller computes. ([FEATURES.md](https://github.com/cabaletta/baritone/blob/master/FEATURES.md))

### 1.3 MineRL / MineDojo navigation (the learned contrast)

The RL line (MineRL `Navigate`, MineDojo, Plan4MC's "Find" skill) treats navigation as a **learned
behavior** rather than an A\* search, because those environments deliberately withhold the block
grid and absolute pose (MC-AGENTS §1.4). MineRL `Navigate` gives only a `compassAngle` scalar +
pixels and trains a policy to walk toward the goal. Plan4MC learns a dedicated **"Finding" skill**
(explore until the target is in view) as one of three RL-trained skill types, then plans over an
LLM-generated skill graph. This is strictly a workaround for *not having* the grid — which
VOXIVERSE has. ([MineRL envs](https://minerl.readthedocs.io/en/latest/environments/index.html),
[Plan4MC](https://ar5iv.labs.arxiv.org/html/2303.16563))

**What makes "go to that tree" one call:** a declarative goal object (`GoalGetToBlock`/`GoalNear`)
+ an A\* planner over a block-grid traversability graph + a cost model that already knows how to
dig/place/fall through obstacles. The caller supplies *where*; the library owns *how*, *re-plans*
when blocked, and *drives the body* until the goal predicate is true. VOXIVERSE has the graph
(`block_id_at`); it needs the planner and the goal vocabulary.

---

## 2. Actuation / skills — turning "chop this tree" into primitives

Two philosophies, and the choice between them is the whole design question: **server-side composite
verbs** (one call = goto+aim+dig+collect, resolved inside the game) vs **client-side step
sequences** (the agent emits look/move/attack primitives itself).

### 2.1 Low-level primitives (the building blocks)

Mineflayer exposes semantic single-step verbs; the agent names *what*, the library resolves the
protocol details ([Mineflayer API](https://github.com/PrismarineJS/mineflayer/blob/master/docs/api.md)):

- **`bot.dig(block, [forceLook], [digFace])`** — mine a specific `Block` (optionally force the head
  to look at it and pick a face). `bot.stopDigging()`, `bot.canDigBlock(block)` gate it.
- **`bot.lookAt(point, [force])`** — orient the view toward a 3D point (computes the yaw/pitch);
  **`bot.look(yaw, pitch, [force])`** sets them directly. This is the *aiming* primitive.
- **`bot.blockAtCursor(maxDistance=256)`** — the crosshair raycast → the block in the line of sight.
  This is VOXIVERSE's `query_ray` exactly.
- **`bot.placeBlock(referenceBlock, faceVector)`**, **`bot.equip(item, destination)`**,
  **`bot.activateBlock(block, dir?, cursorPos?)`** — place / hold / use.

The **aiming pattern** is the load-bearing one for "chop the point I'm looking at":
`bot.lookAt(trunkTopCenter)` turns the head, then `bot.dig(trunkBlock)`; internally `lookAt`
computes `desired_yaw = atan2(Δx,Δz)`, `desired_pitch = atan2(Δy, hypot(Δx,Δz))` (FPS-AWARENESS
§4.5) and `dig` verifies the crosshair is on-target and in-reach before swinging. Without server-side
yaw/pitch there is no `lookAt` and no `blockAtCursor` — which is why FP_AGENT_POSE (task #134) was
the prerequisite that unblocks all of this.

### 2.2 Composite skill: `collectBlock` — goto + tool + dig + collect as ONE call

The **mineflayer-collectblock** plugin is the reference "harvest that" verb, and it is a pure
*composition of the primitives above*: `bot.collectBlock.collect(target, options)` where `target`
is a `Block`, an item-drop `Collectable`, or an array. It "wraps up into a single API function"
the workflow of "**pathfinding to a block, selecting the best tool to mine that block, actually
mining it, then moving to collect the item drops**" — i.e. it calls **mineflayer-pathfinder** to
walk over, **mineflayer-tool** to equip the best tool, `bot.dig` to break it, then paths onto the
dropped item. It even auto-deposits to a chest when the inventory fills and retrieves tools when
needed. ([mineflayer-collectblock](https://github.com/PrismarineJS/mineflayer-collectblock))

This is the exact template for VOXIVERSE's `chop_tree`: **one server-side verb that internally
sequences navigation + aiming + digging + collection**, returning a single completion ack. The
agent never emits look/move/attack.

### 2.3 Voyager — LEARNED skill library (skills as stored, composable *code*)

Voyager is the high end: **GPT-4 writes JavaScript against the Mineflayer API**, and every program
that verifies successful is **stored as a reusable skill, indexed by an embedding of its natural-
language description**. On a new task it retrieves the **top-5 relevant skills** by embedding
similarity and composes them — "complex skills can be synthesized by composing simpler programs,
which compounds Voyager's capabilities rapidly over time." The action is *a whole program*, not a
keypress. ([Voyager site](https://voyager.minedojo.org/), [Voyager paper (arXiv 2305.16291)](https://arxiv.org/abs/2305.16291))

Concretely, the generated skills are functions like `mineWoodLog(bot)`, `craftWoodenPlanks(bot)`,
`combatZombie(bot)`, `mineDiamond(bot)`, built on a fixed set of hand-written **control
primitives** — helper functions such as `mineBlock(bot, name, count)`, `craftItem`, `placeItem`,
`smeltItem`, `killMob` — which themselves call `bot.pathfinder.goto`, `bot.findBlocks`, `bot.dig`,
`bot.chat`, etc. So Voyager is a *two-layer* actuation stack: **hand-written deterministic
primitives at the bottom (never learned), LLM-authored compositions on top (learned & cached).**
([Voyager paper](https://arxiv.org/abs/2305.16291), [code](https://github.com/MineDojo/Voyager))
The key lesson for VOXIVERSE: even the most "autonomous" system keeps the *low-level actuation
scripted and deterministic* — the LLM only writes the glue.

### 2.4 GITM — goals → sub-goals → structured actions → keyboard/mouse

GITM (Ghost in the Minecraft) decomposes a goal into a tree of sub-goals, then into **structured
actions**, then finally into keyboard/mouse operations at the very bottom. The LLM never touches
raw input; it emits *structured actions* that a fixed controller executes. Same layering as
Voyager: LLM plans in a structured verb space, a deterministic controller actuates. ([GITM (arXiv 2305.17144)](https://arxiv.org/abs/2305.17144))

### 2.5 The trained low-level heads (VPT / STEVE-1) — for contrast

VPT and STEVE-1 collapse actuation into a **single trained policy** that outputs the native human
interface — ~20 keyboard buttons + binned mouse dx/dy at **20 Hz** — from pixels. There is no
"dig(block)" verb; "chop a tree" is thousands of individual key/mouse frames the network produces.
This is maximally general and maximally expensive, and it exists *because those agents have no
`bot.dig` and no block coordinates* (MC-AGENTS §2.1). ([VPT paper](https://arxiv.org/pdf/2206.11795),
[STEVE-1](https://arxiv.org/abs/2306.00937))

**The key question answered:** server-side composite verbs win decisively when the game can expose
them (VOXIVERSE can — it already resolves break/place through `WorldManager`). Client-side step
sequences and trained heads are what you're forced into when you *only have pixels + a 20 Hz
keyboard*. Composite verbs give one round-trip, one ack, deterministic success, and no training.

---

## 3. The autonomous loop — who owns perceive→plan→act, and how it recovers

### 3.1 The loop shape and its owner

Every autonomous MC agent runs a **hierarchical control loop** with a slow planner on top and a
fast controller/skill underneath — they differ only in *who owns each layer* and *what's learned*:

| System | High-level planner (slow) | Low-level actuation (fast) | Loop owner | Learned? |
|---|---|---|---|---|
| **Voyager** | GPT-4 automatic curriculum + code-gen | hand-written Mineflayer primitives | in-process JS agent | planner=LLM (frozen), skills=cached code |
| **GITM** | LLM goal→sub-goal decomposition | structured-action controller | in-process | nothing trained (LLM frozen) |
| **JARVIS-1** | multimodal-memory LLM planner | trained low-level controller (VPT-family) | in-process w/ memory | controller trained |
| **Optimus-1** | knowledge-graph planner + reflector | action controller | in-process w/ hybrid memory | nothing (weights frozen) |
| **Plan4MC** | LLM-generated **skill graph** planner | 3 RL-trained skills (Find/Manip/Craft) | scheduler | skills trained (RL) |
| **DreamerV3** | — (single policy) | latent world-model policy | trained agent | fully trained end-to-end |

The dominant, cheapest, most reliable pattern (Voyager, GITM, Optimus-1): **an LLM planner emitting
named verbs, sitting on a deterministic skill layer, with the loop owned in-process.** The LLM
decides *what next*; scripted skills own *how*; the loop reads structured state each cycle. This is
the async-realtime loop from FPS-AWARENESS §2.1 — the world keeps ticking, the agent reads fresh
state, emits a verb, waits for its ack, reads again.

### 3.2 Cadence — the planner is slow, the controller is fast

Critically, **the LLM planner does not run every tick.** It fires once per *sub-goal* (seconds
apart); the scripted skill runs the tight loop underneath at the game's tick rate (20 Hz reference,
MC-AGENTS §2.3). Voyager calls GPT-4 once to author/patch a skill, then the skill executes to
completion (many ticks) before the next LLM call. This is what makes LLM-in-the-loop affordable:
you pay one model call per *task*, not per frame. **[For VOXIVERSE this is the decisive economic
point: an Opus/Sonnet call per "chop this tree", with a scripted skill running the 20 Hz
navigate/aim/dig underneath — not a model call per keypress.]**

### 3.3 Error recovery — the part that separates a demo from an agent

This is where the closed loop earns its keep, and every serious system has an explicit recovery
mechanism:

- **Voyager — three feedback channels + self-verification.** The generated program runs against
  the live environment; Voyager feeds back (1) **environment feedback** (world state), (2)
  **execution errors** (JS exceptions / "you can't craft an acacia axe, there's no such item"),
  and (3) **self-verification** — GPT-4 is asked to critique whether the program achieved the task
  and to suggest a fix if not. The loop **re-prompts and re-generates** until verified, then caches
  the working skill. So recovery = re-plan on the actual failure signal. ([Voyager site](https://voyager.minedojo.org/),
  [paper](https://arxiv.org/abs/2305.16291))
- **Optimus-1 — Experience-Driven Reflector.** A separate module periodically checks progress and
  decides whether to *revise the plan*, using its Hybrid Multimodal Memory (a knowledge graph +
  an abstracted experience pool) — beating a GPT-4V baseline on long-horizon tasks **with no weight
  updates**, purely by better planning + reflection. ([Optimus-1 (arXiv 2408.03615)](https://arxiv.org/abs/2408.03615))
- **Pathfinder-level recovery is automatic.** mineflayer-pathfinder **re-plans dynamically** and
  can dig/place to open a blocked route; Baritone's incremental-cost-backoff continuously re-plans
  the next segment (§1.2). So "path blocked" and "I fell" are handled *below* the LLM — the planner
  only hears about failures the skill can't fix itself. **`GoalFollow`/dynamic goals** handle
  "target moved" natively (re-path each tick).
  ([mineflayer-pathfinder](https://github.com/PrismarineJS/mineflayer-pathfinder))

The recovery hierarchy that emerges: **(a)** the skill/pathfinder silently re-plans mechanical
failures (blocked, fell, target drifted); **(b)** the skill returns a typed failure
(`out_of_reach`, `no_path`, `wrong_tool`) when it genuinely can't; **(c)** the LLM planner
re-plans only on (b). VOXIVERSE should mirror this: put re-planning and reach/aim correction *inside*
the verb, and only surface a structured failure code to the agent when the verb gives up.

---

## 4. THE ARCHITECTURE DECISION — do we need a special Minecraft-playing model?

The user's core question. Three options; a clear verdict.

### (a) Scripted skills + LLM planner — Mineflayer/Baritone + Voyager

**What it is:** deterministic `goto`/`chop`/`harvest`/`place` verbs (A\* + composite skills), with an
LLM only for high-level goal selection and novel skill composition. Nothing is trained.

- **Cost:** effectively zero training; the only runtime cost is one LLM call per *task* (§3.2), and
  the skills run free. Voyager's entire "learning" is caching generated JS — no gradient steps.
- **Reliability:** deterministic. `bot.dig(block)` either succeeds or returns a typed error; A\*
  either finds a path or reports none. No hallucinated motor output, no distribution shift. This is
  the highest-reliability option by a wide margin.
- **When it's right:** whenever the game exposes structured state + interaction verbs (or can). This
  is the near-universal choice for external-controller agents (Voyager, GITM, Optimus-1 all sit
  here for actuation). **It is the right answer for VOXIVERSE.**
- **Limitation:** it can only do what the primitive set + composition can express. For a voxel
  sandbox with a small, well-defined interaction surface (break/place/move/aim/craft), that set is
  *complete* — there is no "chop a tree" behavior scripting can't express when you have the block
  grid and a raycast.

### (b) Narrow trained policy — VPT / STEVE-1 / DreamerV3

**What it is:** train a neural policy to output the low-level interface (keyboard+mouse, 20 Hz)
from pixels (+ optionally a goal embedding or a learned latent world model).

- **VPT** — behavioral cloning from **270,000 hours** of unlabeled internet Minecraft video,
  filtered to **~70,000 hours**; an Inverse Dynamics Model trained on **~2,000 hours** of
  contractor-labeled play labels that video with pseudo-actions; the **0.5-billion-parameter**
  foundation model was trained on **720 V100 GPUs for ~9 days**, and only *then*, with RL
  fine-tuning, could craft a diamond pickaxe (~**24,000 actions ≈ 20 minutes** of play).
  ([VPT paper](https://arxiv.org/pdf/2206.11795),
  [OpenAI VPT / 720×V100×9 days, 270k→70k→2k hours](https://ar5iv.labs.arxiv.org/html/2206.11795),
  [medium summary of the data pipeline](https://medium.com/mlearning-ai/the-video-pretraining-vpt-707bfa186b36))
- **STEVE-1** — makes VPT *instructable* from text far more cheaply (**~$60 of compute**), via a
  two-stage unCLIP recipe (finetune VPT to follow MineCLIP goal embeddings + a text→embedding
  prior), completing **12 of 13** early-game tasks. But it **still consumes only pixels + a goal
  embedding** and emits the low-level 20 Hz interface — no structured state, no `dig(block)`.
  ([STEVE-1 (arXiv 2306.00937)](https://arxiv.org/abs/2306.00937))
- **DreamerV3** — learns a **latent world model** from pixels and was the **first to obtain a
  diamond from scratch with no human data**, but that is a from-scratch RL training run, not a
  drop-in controller; the "world model" is learned latent state, not a queryable grid.
  ([DreamerV3 (arXiv 2301.04104)](https://arxiv.org/pdf/2301.04104))

**What it buys:** generality and human-fairness — a policy that works from *pixels alone*, with no
engine access, and can express fluid low-level behaviors no one scripted. **What it costs:** a
training pipeline (data collection, GPUs, RL tuning), a GPU in the inference loop at 20 Hz, and
non-determinism/distribution-shift failure modes.

**The decisive observation:** VPT and STEVE-1 are **pixels-only by design** — their entire
machinery (the IDM, the 70k-hour BC, the MineCLIP goal space) exists to *reconstruct the structured
state and control interface that VOXIVERSE already exposes directly.* If you already have
`query_box` (the block grid), `query_ray` (the exact crosshair cell + `in_range`), and pose, then a
policy whose job is to *infer blocks and aim from pixels* is solving a problem you don't have.
Structured access makes the trained low-level policy **unnecessary** for this game.

### (c) Hybrid — LLM planner + scripted skills + a small policy for the uncoverable parts

**What it is:** the (a) stack, plus a narrow learned policy for the *specific* sub-behaviors
scripting genuinely can't express well. In practice this is where JARVIS-1 and Plan4MC sit:
LLM/graph planner on top, **but a trained controller underneath for hard-to-script motor skills**
(fluid combat, fine-grained mob manipulation, terrain the analytic planner can't model). Plan4MC
trains exactly three RL skills (Find/Manipulate/Craft) and scripts the rest via an LLM skill graph.
([Plan4MC](https://ar5iv.labs.arxiv.org/html/2303.16563), [JARVIS-1 (arXiv 2311.05997)](https://arxiv.org/html/2311.05997))

**Where each is used:** scripting owns navigation, digging, placing, crafting, aiming — anything
with a clean analytic solution over the block grid. A learned policy is reserved for continuous,
reactive, adversarial control (real-time PvP/PvE dodging, projectile leading) where enumerating
the state→action map is infeasible. For VOXIVERSE **today** — a first-person voxel sandbox whose
interactions are break/place/move/aim/craft, with no combat requiring frame-perfect reflexes — the
"uncoverable" set is *empty*, so the hybrid degenerates to option (a). If VOXIVERSE later adds
real-time creature combat, that is the one place a small policy might earn its slot.

### Verdict

> **For a game that already exposes structured world state + a raycast, a special
> Minecraft-playing model is NOT warranted.** The field consensus — from Voyager and GITM
> (frozen LLM + scripted primitives) through Optimus-1 (no weight updates at all) — is that
> **scripted pathfinding + a deterministic skill library, planned by an LLM, is both sufficient
> and superior** here. The trained-policy line (VPT/STEVE-1/DreamerV3) exists to recover
> structured state and a control interface *from pixels* — precisely the thing VOXIVERSE already
> gives you. Building `goto`/`chop`/`harvest` as server-side composite verbs and letting an LLM
> pick goals is cheaper (no training, one model-call per task), more reliable (deterministic,
> typed failures), and lower-latency (one round-trip, one ack) than any narrow model. **Train
> nothing; script the verbs.** Reconsider only if real-time reflex combat is added — and even then,
> only for that one sub-behavior (option c).

---

## 5. Concrete "chop a tree" recipe — how each family implements it end-to-end

The same task, five ways, so VOXIVERSE can map onto the best one.

### 5.1 mineflayer + pathfinder + collectBlock (scripted verbs) — the target design
```
1. FIND    const tree = bot.findBlock({ matching: logIds, maxDistance: 64 })   // block-grid search
2. GOTO    await bot.pathfinder.goto(new GoalGetToBlock(tree.x, tree.y, tree.z))// A* to adjacent+reachable
3. AIM     await bot.lookAt(tree.position.offset(0.5, 0.5, 0.5))                // yaw/pitch onto chop point
4. CHOP    await bot.dig(tree)                                                  // verifies in-reach, swings
5. COLLECT await bot.collectBlock.collect(tree)                                 // OR one call = 2+3+4+path-to-drop
```
`collectBlock.collect(tree)` alone collapses steps 2–5. **One agent decision → one composite verb →
one ack.** ([pathfinder](https://github.com/PrismarineJS/mineflayer-pathfinder),
[collectblock](https://github.com/PrismarineJS/mineflayer-collectblock),
[mineflayer API](https://github.com/PrismarineJS/mineflayer/blob/master/docs/api.md))

### 5.2 Baritone (in-client): `#mine oak_log` — one command; A\* paths, breaks, collects across the cached region. ([FEATURES.md](https://github.com/cabaletta/baritone/blob/master/FEATURES.md))

### 5.3 Voyager (LLM writes the skill): GPT-4 emits `mineWoodLog(bot)` — a JS function that internally calls the `mineBlock(bot,'oak_log',n)` primitive (which itself does findBlocks → pathfinder.goto → dig). If it throws, self-verification re-prompts; on success the function is cached under the embedding of "mine wood log" for reuse. The *agent* never sees look/move/dig — only the named skill. ([Voyager](https://arxiv.org/abs/2305.16291))

### 5.4 GITM: goal "get wood" → sub-goal "approach tree" + "break log" → structured actions → keyboard/mouse, executed by the fixed controller. ([GITM](https://arxiv.org/abs/2305.17144))

### 5.5 VPT / STEVE-1 (trained policy): give STEVE-1 the text goal "chop a tree" → it emits ~hundreds of 20 Hz keyboard+mouse frames (walk toward the visually-detected tree, hold attack while the trunk is under the crosshair) purely from pixels. No coordinates, no explicit path, no success ack — behavior emerges from the network. Works from pixels alone; needs a GPU and a trained model, and can fail silently. ([STEVE-1](https://arxiv.org/abs/2306.00937), [VPT](https://arxiv.org/pdf/2206.11795))

**Mapping:** VOXIVERSE should implement 5.1 — it is the only recipe that is deterministic, needs no
training, and maps one-to-one onto assets VOXIVERSE already has (`query_box`=findBlock,
`query_ray`=blockAtCursor, pose=lookAt inputs, `WorldManager`=dig).

---

## 6. RECOMMENDATIONS FOR VOXIVERSE

VOXIVERSE already has the perception half (query_box, query_ray + in_range, FP_AGENT_POSE) and the
one true world query (`WorldManager.block_id_at`, CLAUDE.md rule 1). To close the autonomous loop,
add **navigation + actuation primitives owned by the game**, and let the external LLM own only goal
selection. Concretely, in priority order (this grounds task #140):

### 6.1 Navigation primitive — `goto(goal)` (A\* over `block_id_at`)
- Implement A\* over the block grid using **`block_id_at(cell)` as the traversability oracle** (so
  overlay + generated + trees stay consistent — never a parallel "what's solid," CLAUDE.md rule 1).
- **Goal vocabulary** (copy mineflayer-pathfinder): `GoalBlock`, `GoalNear(cell, r)`, `GoalXZ`,
  and crucially **`GoalGetToBlock(cell)`** (adjacent + reachable — the correct goal for chopping)
  and **`GoalFollow(entity, r)`** (dynamic, for moving targets). (§1.1)
- **Cost model** (copy Baritone): cost ≈ traversal time in ticks, plus a **placement penalty** and
  **break penalty** so the planner prefers routing around over digging through, and a **fall/jump**
  policy. Edges = walk / step-up / fall(≤N) / dig-through / place-to-bridge. (§1.2)
- **Faceted-planet note:** VOXIVERSE's surface is a faceted sphere with radial "up" (memory:
  seamless-scales, faceted-planet). A\* must run in **local facet/surface coordinates** and cost by
  geodesic (surface) distance, not world-Euclidean (FPS-AWARENESS §3.5) — and use a **2-bit
  traversability cache** (AIR/SOLID/WATER/AVOID, Baritone §1.2) derived from `block_id_at` for
  long-range paths so orbital-scale planning stays bounded (never-OOM, memory: never-oom-web).
- **Recovery inside the verb:** re-plan dynamically on blockage; return typed failure `no_path`
  only when genuinely stuck. (§3.3)

### 6.2 Actuation primitives — aim + dig, resolved server-side
- **`look_at(cell|point)`** / **`set_yaw_pitch(y,p)`** — turn the head onto the chop point
  (VOXIVERSE already has yaw/pitch via FP_AGENT_POSE; `look_at` computes them, FPS-AWARENESS §4.5).
- **`dig(cell)`** / **`place(cell, block_id)`** — route through `WorldManager` (the existing
  break/place path), gated by **`in_range`** from `query_ray` exactly as Mineflayer/Malmo gate on
  reach. Return `{status: done|failed, reason: out_of_reach|wrong_target}`. (§2.1)

### 6.3 The composite verb — `chop_tree(target)` (the collectBlock template)
- **One server-side verb** = `find log → goto(GoalGetToBlock) → look_at(chop point) → dig →
  (optionally) path to and collect the VoxelBody drop`, returning a single completion ack (§2.2).
  This is the "stupidly simple loop" as *one reliable operation*. Mirror `collectBlock`'s
  composition: navigation + tool + dig + collect behind one call.
- Same template generalizes to `harvest(resource)`, `mine(block_id)`, `place_at(cell, id)`.

### 6.4 Loop ownership & cadence
- **The game owns the fast loop** (the 20 Hz navigate/aim/dig inside the verb); **the external LLM
  owns only goal selection** — it emits `chop_tree(nearest)` and waits for the ack, ~one model call
  per task, not per tick (§3.2). This is the Voyager/GITM division and the reason it's affordable.
- Deliver verbs over the low-latency lane the companion reports specify (WebSocket push, acks —
  FPS-AWARENESS §5.1), so each verb is request→ack, not fire-and-forget.
- **Recovery hierarchy (§3.3):** pathfinder re-plans mechanical failures silently; the verb returns
  a typed failure only when it gives up; the LLM re-plans only on typed failures. Optionally add a
  Voyager-style **skill cache** later (store working compositions keyed by description) — natural,
  but not required for the first `goto`/`chop_tree`.

### 6.5 The narrow-model verdict for VOXIVERSE
**Do not build or train a special Minecraft-playing model.** VOXIVERSE exposes structured state +
a raycast, which is exactly the input that makes scripted pathfinding + deterministic skills the
sufficient-and-superior choice (§4). A trained policy (VPT/STEVE-1/DreamerV3) would cost a training
pipeline + a GPU in the loop to reconstruct the state you already have, while being *less* reliable
(non-deterministic, no success ack) and *higher* latency (per-frame policy vs one verb + ack). The
only future case for a small policy is real-time reflex combat (option c) — and only for that one
sub-behavior. For find→approach→aim→chop: **script the verbs, plan with the LLM, train nothing.**

---

## Sources

- **mineflayer-pathfinder** (goals, Movements, goto): [README](https://github.com/PrismarineJS/mineflayer-pathfinder)
- **mineflayer core API** (dig, lookAt, look, blockAtCursor, placeBlock, equip, activateBlock): [api.md](https://github.com/PrismarineJS/mineflayer/blob/master/docs/api.md)
- **mineflayer-collectblock** (collect = path+tool+dig+collect): [repo](https://github.com/PrismarineJS/mineflayer-collectblock)
- **Baritone** (A*, cost model, chunk cache, goals, `#goto`/`#mine`): [repo](https://github.com/cabaletta/baritone) · [FEATURES.md](https://github.com/cabaletta/baritone/blob/master/FEATURES.md) · [Settings API](https://baritone.leijurv.com/baritone/api/Settings.html) · [cost-settings summary](https://www.9minecraft.net/baritone-ai-pathfinder-mod/)
- **Voyager** (skill library, curriculum, iterative prompting/self-verification): [site](https://voyager.minedojo.org/) · [paper (arXiv 2305.16291)](https://arxiv.org/abs/2305.16291) · [code](https://github.com/MineDojo/Voyager)
- **GITM** (goal→sub-goal→structured action→keyboard/mouse): [paper (arXiv 2305.17144)](https://arxiv.org/abs/2305.17144)
- **JARVIS-1** (multimodal memory planner + trained controller): [paper (arXiv 2311.05997)](https://arxiv.org/html/2311.05997)
- **Optimus-1** (hybrid memory + experience-driven reflector, no weight updates): [paper (arXiv 2408.03615)](https://arxiv.org/abs/2408.03615)
- **Plan4MC** (LLM skill-graph planner + 3 RL skills Find/Manipulate/Craft): [paper (arXiv 2303.16563)](https://ar5iv.labs.arxiv.org/html/2303.16563)
- **VPT** (270k→70k hrs, IDM 2k hrs, 0.5B params, 720 V100 × 9 days, diamond pickaxe): [paper (arXiv 2206.11795)](https://arxiv.org/pdf/2206.11795) · [ar5iv](https://ar5iv.labs.arxiv.org/html/2206.11795) · [OpenAI blog](https://openai.com/index/vpt/) · [data-pipeline summary](https://medium.com/mlearning-ai/the-video-pretraining-vpt-707bfa186b36)
- **STEVE-1** (unCLIP text-to-behavior, $60 compute, pixels+goal embedding only): [paper (arXiv 2306.00937)](https://arxiv.org/abs/2306.00937)
- **DreamerV3** (latent world model, diamond from scratch): [paper (arXiv 2301.04104)](https://arxiv.org/pdf/2301.04104)
- **MineRL / Plan4MC navigation** (learned navigate, compass-only): [MineRL envs](https://minerl.readthedocs.io/en/latest/environments/index.html)
- Companion reports: `docs/RESEARCH-MC-AGENTS.md`, `docs/RESEARCH-FPS-AWARENESS.md`
