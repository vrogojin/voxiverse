# MULTIPLAYER-ARCHITECTURE — VOXIVERSE as a Trustless, Serverless, Peer-to-Peer Shared Universe

Status: **RESEARCH + LOCKED LAYERED DESIGN — DOCUMENTATION ONLY, NOTHING IS IMPLEMENTED.**
This document is the authoritative architecture for turning VOXIVERSE — today a
single-player, browser-served voxel sim (Godot 4.4.1 + godot_voxel, threaded WASM,
deterministic analytic worldgen) with a locked toy-solar-system roadmap
(`docs/COSMOS-ARCHITECTURE.md`) — into a **shared universe for thousands of players in
which all simulation runs on the players' own hosts**, global consistency is enforced by
**cryptographic proofs and endorsement consensus checkpointed into Unicity tokens**, and
real-time co-located play is kept coherent by an **elected peer coordinator** whose worst
misbehaviour costs a few minutes of rollback.

**Implementation is explicitly gated on the readiness of the Unicity Sphere SDK and the
UXF token container format** (§7 prerequisites per phase). No phase in §7 starts before
its named Unicity prerequisites exist. This document consolidates a state-of-the-art
survey (§3, with sources), a six-layer architecture (§4), a precise two-level consensus
model (§4.7), a threat model (§6), and a phased roadmap (§7). Each layer names the
follow-up dedicated design pass it needs (§8); those passes refine, they do not
relitigate, the shape locked here.

Read together with: `docs/COSMOS-ARCHITECTURE.md` + `docs/COSMOS-PLANET-TOPOLOGY.md` (the
shared universe this multiplayer layer runs on — deterministic worldgen, universal time T,
on-rails ephemeris, LOD bands), `docs/DESIGN.md` (current milestone),
`docs/RUNTIME-MATERIAL-STREAMING.md` (the peer-transmissible zone-bundle format whose
"transport, signing, and trust model" out-of-scope note this document fills —
`docs/RUNTIME-MATERIAL-STREAMING.md:82`), `docs/VOXEL-DATA-STRUCTURE.md` (the edit-overlay
data model that becomes the replicated state), and `.claude/CLAUDE.md` (the Unicity
five-layer stack this design persists into).

Code citations are against the current working tree (`main` @ b168eea, docs @ bee9e81).
Unicity facts are cited against the workspace reference docs
(`.claude/docs/*.md`, `.claude/reference/*.md`). External claims carry URLs (§3, §9).

---

## 0. Executive summary

**The vision** (§1, locked): every player's machine runs the immersive simulation
locally; there is **no game server anywhere**. Any two players who observe the same
place and time observe **the same facts** — one story about one universe. Nearby world
is fully simulated; far-away world is simulated at low LOD from deterministic shared
functions; genuinely global events (the Moon explodes) reach every observer. When
players meet, one of their hosts is elected **local coordinator** so real-time play is
coherent; because players cannot be assumed honest, **every consistency claim is backed
by cryptography**: signed simulation traces, deterministic re-execution audits by
anonymously-sampled peers, endorsement quorums, and **checkpoints persisted as Unicity
token state transitions** whose latest version is pointed to by the Unicity Aggregator
and whose payloads live in IPFS as UXF containers. Insufficient endorsement ⇒ rollback
to the last checkpoint.

**The honest verdict, stated up front: the vision is achievable on the web engine — with
four load-bearing qualifications.**

1. **"Serverless" is achievable as "no authoritative game server", not as "zero
   infrastructure".** The design leans on infrastructure that already exists and is
   already decentralized — Nostr relays (discovery + signaling + async messaging), the
   Unicity network (L1 PoW / L2 BFT / L3 Aggregator), IPFS — plus one *thin* class of
   helper the browser platform makes unavoidable: **STUN/TURN for WebRTC NAT traversal**
   (browsers cannot listen for connections; a measurable fraction of peer pairs cannot
   connect directly — §3.1) and **IPFS pinning/archival** for zones nobody currently
   inhabits. Both roles are designed as *untrusted accelerators* ("fog peers", §4.3.5):
   they hold and move bytes, they never hold authority, and any volunteer (including a
   player's own always-on home machine running the headless export) can provide them.
   Truly zero-infra — browser-only, no relays at all — is **infeasible**: hole
   punching fails for a real minority of pairs (budgeted ~25–30% needing relayed
   bytes, §4.3.1), symmetric/carrier-grade NAT defeats STUN *by construction*, and a
   brand-new peer has no first address to dial —
   even libp2p ships a hardcoded bootstrap list (§3.1). The design's answer is to map
   the whole unavoidable tier onto infrastructure Unicity already runs
   permissionlessly — Nostr relays (signaling/discovery/liveness), IPFS (payloads),
   the Aggregator (checkpoints) — leaving only commodity TURN/fog relays as new. One
   more honesty note: **no shipped browser MMO runs a true P2P mesh at scale** (the
   ".io" games are server-relayed); this design *synthesizes* from adjacent proven
   pieces (WebRTC limits, cheat-proof-playout literature, rollup dispute patterns,
   Croquet-style replicated determinism) rather than following a production
   precedent (§3.1).
2. **The consistency linchpin is determinism — and the honest engineering position is
   that bit-exact whole-engine determinism is NOT a safe assumption, so the design
   never bets correctness on it.** The state of the art is unanimous: every shipped
   deterministic-networked game (Factorio, StarCraft II, GGPO titles) either uses
   fixed-point or hand-owns every float operation in the sim; browser/WASM adds its
   own hazards (threads — and this export IS threaded; relaxed-SIMD is nondeterministic
   *by design*; NaN payloads), and no validated determinism layer exists for
   GDScript + Emscripten (§3.2). The design therefore splits the problem three ways:
   (a) **a narrowly-scoped deterministic consensus subset** — the `step` function of
   §4.1 touches only integer cells, quantized (fixed-point) kinematics, integer
   inventory/damage, sorted iteration and seeded RNG, and is hand-audited like Box2D
   audits its math (§3.2); the engine helps enormously — worldgen is already a pure
   seeded function (`terrain_config.gd:25-30`), world state is one integer-keyed edit
   overlay behind one query (`world_manager.gd:134-139`), and player physics is
   analytic column math, not a physics engine (`world_manager.gd:740,779`);
   (b) **state-hashing + checkpoint-reconciliation as the PRIMARY live mechanism** —
   zone state roots are compared every second and any diverging peer resyncs from the
   co-signed root rather than the protocol assuming lockstep held (§4.1.2 D6);
   determinism makes resync *rare* and audits *decisive*, it is never the sole
   guarantee; (c) **exclusion of the undeterminizable** — Godot rigid-body debris
   trajectories are cosmetic (settled outcomes are sequenced events, §4.1.4), derived
   per-voxel fields are recomputed rather than replicated, rendering is entirely
   outside the hash.
3. **Trustlessness is achieved optimistically, not with zk.** Proving a real-time voxel
   simulation in zero knowledge is orders of magnitude beyond today's provers (§3.4);
   the pragmatic core is the **optimistic-rollup pattern**: execute locally, publish
   signed commitments (hash-chained simulation traces + Merkle state roots), let
   randomly-sampled anonymous peers **re-execute and endorse**, keep an open **challenge
   window** in which any single honest peer can submit a fraud proof, and only then
   persist the checkpoint into a Unicity token. Real-time play inside the window is
   protected differently: the elected coordinator is a **sequencer, not a simulator**
   (§4.4) — it orders signed inputs, every peer simulates identically, so the
   coordinator's entire cheating surface is ordering bias, censorship, and equivocation,
   all of which are detectable from its own signed chain. Worst case: minutes of
   rollback — exactly the bound the vision accepts.
4. **The Unicity mapping is natural but requires SDK/UXF features that do not exist
   yet.** Zone checkpoints are `update(newData)` state transitions on location tokens;
   the Aggregator's SMT inclusion proof (plus its single-successor "unicity" property)
   is precisely the "latest legitimate state" pointer; item duplication is *structurally
   impossible* because items are tokens (§4.6). But the design needs, and is blocked on:
   the UXF container format; a browser (JavaScriptBridge) integration path for the
   TypeScript sphere-sdk; an **endorsement predicate** (k-of-n co-signature on a state
   transition — today's predicates are single-key masked/unmasked); batched/cheap
   game-cadence commitments; and the Sphere profile-token pattern generalized to
   game-entity tokens. §7 gates every phase on the exact missing pieces.

**The single biggest risks** (each gets a mitigation and a phase gate in §7):

| # | Risk | Why it is the risk | Mitigation locked here |
|---|---|---|---|
| MR1 | **Determinism erosion** — one divergent float, iteration order, or version skew desyncs a zone | Audits require bit-identical replay of the consensus subset; Godot was not designed as a deterministic lockstep engine, and WASM threads/relaxed-SIMD are nondeterministic (§3.2) | The three-way split of §0.2: hand-audited fixed-point/integer consensus subset; state-hash + resync as the primary live mechanism (divergence is *repaired*, not fatal — §4.1.2 D6); the undeterminizable excluded from state; build-hash epochs; Phase M0 ships record/replay + cross-browser replay CI before any netcode exists, and must verify Emscripten `-ffp-contract` and godot_voxel SIMD flags (§8.2) |
| MR2 | **Endorsement economics & sybil/collusion** — why do strangers audit, and what stops bought committees? | The historical consensus is only as strong as its auditor sampling and incentives | VRF-style sortition from ledger randomness over *cost-bearing identities*, small committees + open challenge window (one-honest-verifier fallback), endorser reputation and stake recorded on identity tokens (§4.5.4); economics flagged as the §8.1 Fable pass and a hard Unicity dependency |
| MR3 | **Data availability** — a fraud proof is worthless if the coordinator withholds the input log | The classic rollup failure mode, §3.5 | Checkpoint validity *requires* availability attestations: k endorsers sign only after holding the full segment log; logs are content-addressed (IPFS CID inside the checkpoint token); zone peers replicate the live log by construction (they consume it to simulate) (§4.5.3) |
| MR4 | **Browser P2P at the edges** — NAT failure, tab lifecycle, one WASM heap, upload bandwidth of a residential coordinator | The web platform is the most hostile P2P host there is | Zone size caps (~16–24 real-time peers, §4.3.4), coordinator input batching, QoS-weighted election that *prefers* well-connected hosts (§4.4.2), fog relays as fallback, EVE-style tick dilation under load (§3.1) |
| MR5 | **Scope** — this is a research programme wearing a game's clothes | — | Six independently-demoable phases (§7), the first two needing zero Unicity infrastructure; **nothing is implemented until Sphere SDK + UXF are ready** |

If any part of the vision is *not* achievable as stated, it is: (a) **zero-infrastructure
purity** (needs thin fog helpers — bounded and untrusted, but real); (b) **cryptographic
prevention of input-level cheating** (aimbots, perfect reflexes — no protocol can
distinguish a skilled hand from a script; the design prevents *state* forgery: minting,
teleport, stat/inventory tampering, history rewriting); (c) **real-time trustlessness
stronger than bounded-rollback** (inside the few-minute window a colluding zone can lie
to itself; it cannot make the lie *stick*, and it cannot export it — §4.7); and
(d) **hidden information** (a masked player position is incompatible with peers
re-executing your movement; VOXIVERSE has little fog-of-war by design, and what privacy
the token layer offers is inherited from masked predicates — §8.6).

---

## 1. The locked vision, restated precisely

These are requirements, not aspirations. Every layer in §4 exists to satisfy one of
them. They restate — verbatim in intent — the locked multiplayer vision for VOXIVERSE.

- **MP-V1 — Local simulation, serverless.** All game simulation runs on the users'
  hosts, delivering the immersive experience locally, with minimal reliance on public
  infrastructure. There is no authoritative game server; the only permitted standing
  infrastructure is (i) networks that already exist and are already decentralized
  (Nostr relays, IPFS, the Unicity network) and (ii) thin, untrusted, volunteer-run
  fog/relay/bootstrap helpers (§4.3.5).
- **MP-V2 — One story.** Any users observing and/or visiting the same locations and the
  same events must experience **exactly the same facts and outcomes** — a single
  consistent story about the sandbox universe, regardless of where/when/what they are
  doing or when they meet. Facts, once endorsed and checkpointed, are permanent and
  universal.
- **MP-V3 — LOD simulation with global events.** Each host simulates the relevant local
  observable world at varying detail — immediate surroundings fully simulated, the Moon
  in the sky merely keeps orbiting on its deterministic rail — **but** a genuine cosmic
  event (the Moon explodes) must be seen by everyone observing the Moon, in the same
  form and the same order relative to other global events.
- **MP-V4 — Real-time co-location.** When 2+ players gather in one location they need
  real-time (not just historical) simulation consistency. Based on QoS checks and
  parameters, one player's host is elected **local coordinator** to keep all co-located
  players' simulations coherent without killing the real-time experience.
- **MP-V5 — Trustless.** No honest-simulation assumption. Hosts run local game parts, so
  a player could cheat: mint top items from nowhere, teleport, fake health/stats. The
  design requires **cryptographic simulation traces and proofs**: entering a location ⇒
  obtain a proof that its current state is legitimate (from a cloud/fog peer or the
  current occupants); meeting another player ⇒ mutually prove correct honest state
  (health, inventory, legitimately-present — not teleported).
- **MP-V6 — Endorsement consensus (historical).** Unrelated players anonymously and
  randomly cross-check each other's location/object/character simulations. When an
  object collects enough endorsements about its current state, that state is persisted
  as the next **checkpoint in a Unicity token** (all objects AND locations are
  tokenized). Insufficient endorsements ⇒ **rollback to the latest persisted
  checkpoint**.
- **MP-V7 — Two-level consensus.** (1) HISTORICAL — cryptographic proofs/endorsements
  tokenized in Unicity tokens; (2) REAL-TIME — a trusted appointed local coordinator
  among co-located players. If the coordinator misbehaves, the WORST case is that the
  co-located players' experience rolls back to the latest checkpoints — acceptable with
  checkpointing every few minutes.
- **MP-V8 — Global latest-state reference.** The Unicity **Aggregator** points to the
  latest version of the Unicity token storing an object's state/simulation — exactly as
  done for user profiles in the UXF Sphere SDK pattern. Tokens are stored and exchanged
  via **IPFS**, containerized in the **UXF** format.

Two derived requirements this document adds (they follow from the above and are locked
with them):

- **MP-D1 — Determinism is law.** MP-V2 + MP-V5 are only satisfiable if the simulation
  is a deterministic function of (seed, checkpoint state, ordered inputs, T). Every
  future engine feature must either be deterministic under §4.1's rules or be explicitly
  classified *cosmetic* (never part of consensus state). This extends the engine's
  existing determinism discipline (`terrain_config.gd:25`, COSMOS §1.3) from worldgen
  and ephemeris to the whole gameplay loop.
- **MP-D2 — Exit checkpoints.** A zone's coordinator must produce a checkpoint when the
  last player leaves a zone (in addition to the periodic cadence), so that an
  *uninhabited zone is always exactly its last checkpoint* — no un-endorsed tail exists
  for places nobody is simulating (§4.5.5). This is what makes "the world keeps its
  state while everyone is offline" true with zero standing simulation infrastructure.

---

## 2. Ground truth: what exists today, and what it already gives us

### 2.1 The engine (verified against source at the stated lines)

The three architectural rules of `CLAUDE.md` (one cell query; gameplay reads the sim
layer, not geometry; two render paths, one behaviour) plus the COSMOS layers are exactly
the seams a replicated deterministic simulation needs. Most of the multiplayer substrate
is *already built*, under other names:

| Subsystem | Today | What it gives multiplayer |
|---|---|---|
| Worldgen | Pure deterministic function of `const SEED := 20260702` (`terrain_config.gd:30`); every decision is seeded FastNoiseLite (`terrain_config.gd:25-27`); `height_at`/`column_profile`/`generated_cell`/`resolve_cell` (`terrain_config.gd:315,359,383,390`) | **Zero-bandwidth world sync.** Every peer derives the identical pristine world from the seed; only *deviations* ever cross the wire. This is the same property COSMOS §4.2 uses for the ephemeris — a shared pure function of shared constants |
| World state | Sparse edit overlay `_edits: Dictionary` (Vector3i → packed cell value, 0 = dug-to-air; `world_manager.gd:38`), composed by THE one cell query `cell_value_at` (`world_manager.gd:134-139`); single write choke point `_write_cell` (`world_manager.gd:378`) | **The replicated state IS the edit log.** One dictionary, one write path — the interposition point for "apply only coordinator-ordered, signed edits" is a single function. State = (seed, edits, object records, T): small, hashable, Merkle-izable |
| Mutations | `break_terrain` (`world_manager.gd:315`), `place_block` (`world_manager.gd:337`), structural carve via `StructuralSolver.solve` (`structural_solver.gd:41`) invoked from `_structural_update` (`world_manager.gd:663`) | The complete input alphabet of the world sim is a handful of intents (break/place/…) — small, signable events. Structural collapse is a *deterministic pure solver* over the cell query, so all peers derive identical carve sets from identical edits |
| Player physics | Analytic, collider-less: scalar gravity (`player.gd:21`), `floor_under`/`blocked` column scans (`world_manager.gd:740,779`), DDA raycast; no trimesh, no physics-engine dependence | **Deterministic movement for free.** Pure-GDScript column math is bit-reproducible under §4.1; movement validation ("could this player legally move here?") is the same cheap function every auditor already has |
| Loose debris | `VoxelBody` rigid bodies, dormant-by-default, wake-on-disturbance (`wake_bodies_near`, `world_manager.gd:275`) | The **one non-deterministic subsystem** (Godot physics). Dormancy bounds it: consensus covers settled poses only; trajectories are cosmetic (§4.1.4) |
| Persistence | Edits-only tiers; `ZoneChunk` 32³ self-describing byte format with canonical name-keyed palettes (`zone_chunk.gd:1-38`, `region_origin_of` `world_manager.gd:496`, `save_edits`/`load_edits` `world_manager.gd:513,538`) | **The checkpoint payload format exists.** A ZoneChunk is already "the world's deviations from the pure generated function" in compact bytes — precisely what a checkpoint must contain |
| P2P payloads | `ZoneBundle` — "self-contained, **peer-transmissible** payload" with content-hashed material documents (GMIDs), explicitly excluding "the p2p transport, signing, and trust model" (`zone_bundle.gd:1-30`, `docs/RUNTIME-MATERIAL-STREAMING.md:19,82`) | The wire format for zone transfer is designed and its trust model is *deliberately an open slot* — this document fills it. Content-hashed GMIDs map 1:1 onto IPFS CIDs |
| Time & cosmos | Universal time T (f64 seconds since epoch), all celestial state closed-form in T (COSMOS §1.3, §4.2); dormant objects on Kepler rails; "save = T + edit stores + object records" (COSMOS §4.6) | **Free LOD consistency for the undisturbed universe** (MP-V3): every peer that agrees on T agrees on the whole sky. Multiplayer must only synchronize T and the *disturbances* |
| Verification culture | Headless invariant harness `godot/src/tools/verify_feature.gd` (CLAUDE.md "Running / testing") | The natural home for determinism CI: record/replay equality, cross-run state-hash pinning (§7 M0) |
| Web runtime | One WASM binary, threaded (COOP/COEP mandatory), godot_voxel worker pool pinned tiny on web (`project.godot:63-65`); GDScript `float` is f64 | Same-binary determinism (§3.2); but also the constraint set: no listen sockets, tab lifecycle, one heap — §4.3's transport must live inside WebRTC/WebTransport |

### 2.2 The Unicity substrate (cited against the workspace docs)

The five-layer stack (`.claude/CLAUDE.md` "Unicity Architecture Overview",
`.claude/docs/architecture.md`):

```
L5 wallet/agent (sphere, sphere-sdk consumers)      <- the game becomes an L5 client
L4 state transitions (sphere-sdk, state-transition-sdk: predicates, TXF/UXF)
L3 aggregation (aggregator-go: Sparse Merkle Tree, inclusion proofs, 1M+ commits/sec)
L2 BFT consensus (bft-core: 1-second rounds, 2/3+ quorum)
L1 PoW (alpha: RandomX, UTXO, ~2-minute anchoring)
```

What each layer contributes to this design, with the exact facts relied upon:

- **Tokens are immutable state chains.** "Token state is immutable — transitions create
  new state" and every transition appends an inclusion proof to a monotonically growing
  proof chain (`.claude/reference/state-transition-sdk.md`, `.claude/reference/txf-format.md`).
  A game object/location token is therefore an *auditable history* by construction —
  MP-V2's "one story" is literally the token's proof chain.
- **TXF vs UXF, stated once.** The workspace reference docs specify **TXF** (Token
  eXchange Format — `.claude/reference/txf-format.md`); the locked vision names
  **UXF** as the container format in which tokens are stored/exchanged via IPFS and
  which the Sphere SDK uses for user profiles (MP-V8). This document treats UXF as
  the containerized successor/superset of TXF with the same core shape
  (`tokenId / ownerPredicate / data / proofChain / stateHash`); its exact
  specification is itself one of the gating Unicity deliverables (§7 M4) — every
  UXF-shaped structure in §4.6 binds to whatever the final spec says, and nothing
  here depends on more than the TXF-documented core plus IPFS containerization.
- **The `update(newData)` operation** exists in the TXF transition alphabet
  (`.claude/reference/txf-format.md` "Operations") — a checkpoint is an `update` carrying
  the new state root + evidence CIDs, not a new token type (§4.6.2).
- **The Aggregator is the latest-state pointer.** `certification_request` /
  `get_inclusion_proof` (`.claude/reference/aggregator-go.md`); proofs are
  "self-contained — verifiable without access to the full tree" and support
  **non-membership** (`.claude/docs/design-decisions.md` "Sparse Merkle Trees") — which is
  what makes "this is the *latest* state, no successor exists" provable: the single-
  successor discipline over commitment keys is the network's namesake unicity property.
  Throughput "1M+ commits/sec" (`.claude/reference/aggregator-go.md`) dwarfs game
  checkpoint cadence by ~4 orders of magnitude (§4.6.5).
- **Finality ladder.** L2 BFT finality ~1 s; L1 PoW anchoring ~2 min
  (`.claude/docs/architecture.md` "Dual-Layer Payment Model") — conveniently matching the
  game's own consistency ladder: real-time (ms) → endorsed checkpoint (minutes) →
  PoW-anchored history (§4.7).
- **Identity.** secp256k1 everywhere, BIP-39/BIP-32 derivation, the same keys usable for
  Nostr transport (`.claude/reference/crypto-primitives.md`); the workspace already runs
  this pattern for *agents* — a keypair in `.claude/agent/identity.json` with an npub,
  DM channels, and NIP-29 group membership (`.claude/CLAUDE.md` "Agent Communication").
  The player identity of §4.2 is this exact pattern applied to humans.
- **Transport & storage.** Nostr NIP-04/17 encrypted DMs, NIP-29 groups, nametags for
  human-readable discovery; IPFS for immutable content, IPNS for mutable pointers,
  "token state published to IPNS… large payloads stored on IPFS, referenced by CID in
  TXF data field" (`.claude/reference/transport-protocols.md`). The game reuses all of it
  unchanged (§4.3, §4.6.4).
- **Predicates.** Masked/unmasked single-key ownership predicates
  (`.claude/reference/state-transition-sdk.md`). **Gap:** endorsement checkpoints need a
  k-of-n co-signature condition on transitions — a new predicate/validation type, named
  as a hard dependency in §7 (M4) and §8.1.
- **The Sphere profile pattern.** sphere-sdk's provider architecture (Transport/Oracle/
  Storage injectables, `.claude/docs/sphere-sdk-guide.md`) and the profile-token pattern —
  a user's mutable profile as a token whose latest version the Aggregator references —
  is the exact shape reused for every game entity (MP-V8, §4.6.1).

### 2.3 What is genuinely new

Everything in §4 that is neither in the engine nor in Unicity today: the deterministic
tick/input formalization (§4.1), session keys + presence chains (§4.2), the WebRTC/Nostr
transport fabric and zone AOI (§4.3), coordinator election/lease/failover (§4.4), the
trace/state-root/audit/endorsement protocol (§4.5), the game-entity token schema and
checkpoint transitions (§4.6), and the rollback machinery (§4.7). None of it requires
engine-core (C++) changes; all of it lives in GDScript + the page's JavaScript
(sphere-sdk via `JavaScriptBridge`) + Unicity-side SDK features.

---

## 3. Research: how the state of the art solves each hard problem

Six problem areas. Each item: what it is → the concrete lesson this design adopts
(with the §4 section that consumes it). Items whose primary sources could not be
fully verified this session are flagged inline; the peer-research caveats are
preserved.

### 3.1 P2P / serverless MMO netcode & authority

**The blunt headline first: no shipped browser MMO uses a true P2P mesh at scale.**
The ".io" games (Agar.io et al.) are server-authoritative WebSocket relays. This
design *synthesizes* from adjacent, individually-proven pieces — RTS lockstep,
fighting-game rollback, console host-migration P2P, video-conf WebRTC limits, rollup
dispute games — rather than following one production precedent. Stated once, owned
everywhere (§0).

- **Deterministic lockstep — Age of Empires' "1500 archers on a 28.8k modem"**
  ([Bettner & Terrano, GDC 2001](https://www.gamedeveloper.com/programming/1500-archers-on-a-28-8-network-programming-in-age-of-empires-and-beyond)):
  send inputs, not state; every client simulates identically; bandwidth is flat in
  entity count. Lesson: input-sync is the only thing that scales to a *voxel world's*
  state size (→ §4.1.1) — but full lockstep stalls on the slowest peer and cannot
  span thousands of players; authority must be partitioned (→ §4.3.3 zones).
- **GGPO rollback netcode** ([ggpo.net](https://www.ggpo.net/),
  [github.com/pond3r/ggpo](https://github.com/pond3r/ggpo)): predict remote inputs,
  roll back and re-simulate on mispredict — great feel at 2–8 players, cost grows
  with rollback depth × sim cost; explicitly lists cross-platform floats as a top
  desync source. Lesson: rollback is a *local feel* tool inside a zone tick horizon,
  not a consistency architecture (→ §4.4.5).
- **Gaffer On Games — [Deterministic Lockstep](https://gafferongames.com/post/deterministic_lockstep/)
  / [Floating Point Determinism](https://gafferongames.com/post/floating_point_determinism/)**:
  the canonical statements of both the pattern and its float peril (→ §3.2, §4.1.2).
- **Factorio** ([Multiplayer — official wiki](https://wiki.factorio.com/Multiplayer)):
  the strongest shipped proof of large-N deterministic lockstep (500+ mixed-OS
  players) — achieved only by owning every nondeterminism source (including
  replacing libc trig) and backed by continuous **state-hash desync detection**.
  Lesson: hash-compare is non-negotiable plumbing even when you believe you are
  deterministic (→ §4.1.2 D6).
- **StarCraft II / Clash Royale / the RTS tradition**: fixed-point for all networked
  simulation, floats for rendering only (corroborated via the §3.2 determinism
  sources). Lesson adopted wholesale for the consensus subset (→ §4.1.1).
- **Croquet / Multisynq** ([croquet.io](https://croquet.io/) — "synchronized
  computation" via bit-identical replicated VMs; tiny stateless **reflectors** only
  order and timestamp messages): the closest architectural ancestor of this design's
  coordinator. Lesson: when computation is replicated and deterministic, the only
  central role left is *ordering* — and even Croquet could not remove that last
  always-on reflector; we make it an elected, fenced, accountable *peer* instead
  (→ §4.4.1).
- **Photon Quantum / Fusion** ([Quantum](https://doc.photonengine.com/quantum/current/getting-started/quantum-intro):
  a commercial *deterministic, fixed-point* prediction/rollback engine — market proof
  that determinism-as-product requires owning the whole math stack;
  [Fusion](https://doc.photonengine.com/fusion/current/getting-started/fusion-introduction)'s
  shared/host modes): "distributed authority" in commercial engines
  ([Nakama](https://heroiclabs.com/nakama/), [Colyseus](https://colyseus.io/),
  [Mirror](https://mirror-networking.com/), [FishNet](https://fish-networking.gitbook.io/docs/))
  means *per-object authority assignment among trusted clients + a relay* — none of
  them address Byzantine peers. Lesson: the ecosystem solves topology, not trust;
  trust is exactly the part this design must add (→ §4.5).
- **Host migration in production P2P — GTA Online, Destiny**: GTA sessions migrate
  the session-host role on departure (long-standing player-visible behaviour);
  Destiny's networking talk describes its physics-host/mission-host hybrid P2P with
  host migration ([Bungie, GDC 2015 "Shared World Shooter"](https://www.gdcvault.com/play/1022247/Shared-World-Shooter-Destiny-s)).
  Lesson: elected-peer authority with live migration is shipped, mass-market reality —
  what's new here is making the migration *cryptographically accountable* (→ §4.4.4).
- **SpatialOS / Worlds Adrift** ([Improbable docs archive](https://documentation.improbable.io/spatialos-overview/docs);
  [Bossa's shutdown announcement, 2019](https://worldsadrift.com/blog/worlds-adrift-closure-faq/)):
  cloud-meshed authority (many small authoritative workers over one world) worked
  technically, but cost scaled with simulation, and the game died commercially.
  Lesson: always-on per-region cloud simulation is exactly the cost structure a
  player-hosted design avoids — the *simulation* bill must sit on players' machines
  (→ MP-V1), leaving only thin relay/storage infra (→ §4.3.5).
- **Dual Universe** ([NovaQuark's single-shard architecture talks](https://www.dualuniverse.game/news/dev-blogs)):
  a single-shard voxel MMO via server-side spatial partitioning + heavy determinism.
  Lesson: single-shard *voxel* worlds are feasible when the world is
  deviations-over-a-function (→ §2.1's edit overlay is the same insight).
- **EVE Online time dilation** ([CCP dev blog: Introducing Time Dilation](https://www.eveonline.com/news/view/introducing-time-dilation-tidi)):
  under overload, slow *simulated time* uniformly instead of dropping players or
  consistency. Lesson: tick dilation is the honest overload valve for mass
  gatherings (→ §4.3.4, §4.4.5).
- **WebRTC DataChannel** ([RFC 8831](https://www.rfc-editor.org/rfc/rfc8831);
  [MDN](https://developer.mozilla.org/en-US/docs/Web/API/RTCDataChannel)):
  SCTP-over-DTLS with configurable reliability/ordering — the only browser p2p
  transport; unreliable-unordered mode is what makes per-tick claims droppable
  (→ §4.3.1). **Mesh ceilings**: full mesh reliable ~4, degraded by ~10–12; a tab
  sustains only low dozens of live RTCPeerConnections in practice
  ([Antmedia on topologies/scale](https://antmedia.io/webrtc-servers-and-multiparty-webrtc-topologies/),
  [TensorWorks stream-limit measurements](https://tensorworks.com.au/blog/webrtc-stream-limits-investigation/);
  empirical, not spec) — sparse membership is structural (→ §4.3.4).
- **NAT traversal economics**: STUN succeeds for most residential cone-NAT pairs;
  symmetric/CGNAT defeats it by construction; industry figures put TURN need at
  ~15–20% consumer / 60–85% enterprise
  ([webrtcHacks on TURN usage](https://webrtchacks.com/limit-webrtc-bandwidth/),
  Kranky Geek industry talks — figure well-repeated, no single peer-reviewed
  source); production IPFS measured **≈70% hole-punch success** (~30% stay relayed)
  over 4.4M attempts ([libp2p DCUtR + measurement campaign](https://docs.libp2p.io/concepts/nat/dcutr/),
  arXiv hole-punching study — IPFS population, flagged inference). Lesson: budget
  ~25–30% of pairs on relays; adopt the **relay-then-upgrade (DCUtR)** pattern
  (→ §4.3.1).
- **libp2p in the browser** ([WebRTC transport docs](https://docs.libp2p.io/concepts/transports/webrtc/),
  [Circuit Relay v2](https://docs.libp2p.io/concepts/nat/circuit-relay/),
  [gossipsub v1.1 spec](https://github.com/libp2p/specs/blob/master/pubsub/gossipsub/gossipsub-v1.1.md)):
  browser↔browser *requires* a relay for signaling; Circuit Relay v2 is deliberately
  resource-constrained (control-plane, cost O(#connections) not O(bytes)) — the
  permissionless-relay shape; browsers are second-class DHT citizens (rendezvous/
  pubsub discovery instead — → §4.3.2's Nostr choice). **HyParView**
  ([Leitão et al., DSN 2007](https://asc.di.fct.unl.pt/~jleitao/pdf/dsn07-leitao.pdf)):
  small active view + large passive view; broadcast survives 80% simultaneous node
  loss at small fanout (→ §4.3.4).
- **Nostr-signaled WebRTC — demonstrated** ([nostr_webrtc, Codeberg](https://codeberg.org/cipres/nostr_webrtc)):
  SDP offers/answers as Nostr events through ordinary relays. Lesson: the signaling
  plane VOXIVERSE needs already exists on infrastructure Unicity already runs
  (→ §4.3.1); use NIP-44-class encryption for payloads.
- **SnoW: serverless n-party WebRTC** ([arXiv 2206.12762](https://arxiv.org/abs/2206.12762)
  — abstract verified, full text not rendered this session): peers themselves take
  the SFU/MCU forwarding roles. Lesson: coordinator-as-serverless-SFU has published
  prior art, with no capacity numbers to lean on (→ §4.3.4).
- **WebTransport is client-server only** ([W3C P2P-WebTransport note](https://w3c.github.io/p2p-webtransport/)):
  it cannot carry the mesh; useful solely for client↔fog hops (→ §4.3.1).
- **WebTorrent** ([webtorrent.io](https://webtorrent.io/)): the largest shipped
  browser swarm — proof browsers can hold real DataChannel swarms for *bulk
  content*; its tracker dependency mirrors our rendezvous dependency (→ §0
  qualification 1).

### 3.2 Deterministic distributed simulation (the linchpin — assessed honestly)

- **The WebAssembly nondeterminism list** ([WebAssembly design docs: Nondeterminism](https://github.com/WebAssembly/design/blob/main/Nondeterminism.md);
  [spec numerics](https://webassembly.github.io/spec/core/exec/numerics.html)): core
  float ops (+ − × ÷ sqrt, rounding) are fully specified IEEE-754 — *but* NaN bit
  patterns are unspecified, **relaxed-SIMD is nondeterministic by design**, and
  shared-memory/threads interleavings are inherently nondeterministic. VOXIVERSE's
  export is threaded (COOP/COEP, CLAUDE.md "Why COOP/COEP"). Lesson: same-binary
  WASM kills cross-*compiler* divergence but is not a determinism guarantee for a
  threaded, unaudited engine (→ §4.1.2 D1/D2; §8.2's `-ffp-contract`/SIMD checks).
- **Transcendentals are the real landmine, not arithmetic**
  ([Rapier determinism docs](https://rapier.rs/docs/user_guides/rust/determinism/):
  `sin/cos` differ across platforms/engines by design;
  [Box2D v3 determinism post, 2024](https://box2d.org/posts/2024/08/determinism/):
  ships its own `atan2f`/`sinf`/`cosf` because libm differs per platform, notes
  `sqrtf` is safe, disables FP contraction). JS engines differ in `Math.sin` by
  documented last-bit variance (V8 polynomial vs SpiderMonkey libm). Lesson: **no
  built-in transcendental inside consensus code, ever**; owned LUT/CORDIC trig if
  needed — the same kernel COSMOS R4 plans (→ §4.1.1, COSMOS §7.4).
- **Fixed-point as industry answer**: Photon Quantum (§3.1) and the Godot ecosystem's
  own deterministic-rollback work
  ([SG Physics 2D — deterministic fixed-point physics for Godot](https://www.snopekgames.com/tutorial/2021/getting-started-sg-physics-2d-and-deterministic-physics-godot))
  both go fixed-point; the one Godot determinism framework found (Klotho) is
  **C#/.NET-only, never validated on WASM/GDScript** — there is no drop-in layer for
  this stack. Lesson: hand-scope the deterministic subset; don't buy one (→ §0.2,
  §4.1.1).
- **Deterministic RNG** ([PCG](https://www.pcg-random.org/),
  [xoshiro](https://prng.di.unimi.it/)): trivially solved — named, seeded streams per
  system; never engine `randi()` (→ §4.1.2 D4).
- **Input-sync vs state-sync & desync detection**: Factorio's state-hash discipline
  (§3.1) and rollback engines' checksum frames converge on the same practice: hash
  authoritative state at fixed cadence, treat divergence as a first-class event.
  Lesson, upgraded by the trust context: **hash-and-resync is the primary
  correctness mechanism; determinism is the efficiency mechanism** (→ §4.1.2 D6) —
  and finding the first divergent tick in a signed log is *the same algorithm* as an
  optimistic-rollup dispute (→ §4.5.3, §3.4 Dave).
- **Godot-specific hazards** ([Godot large-world docs confirm GDScript `float` is
  64-bit](https://docs.godotengine.org/en/stable/tutorials/physics/large_world_coordinates.html);
  Godot physics is not deterministic across runs/platforms — long-standing upstream
  position): Dictionary iteration is insertion-ordered (history-dependent across
  peers), `_collapse`/flood-fill tie order is iteration-dependent, per-voxel float
  fields accumulate. Lessons: canonical sort-before-hash (→ D3), canonical solver
  frontier order (→ §8.2), rigid-body physics excluded from consensus (→ §4.1.4),
  derived fields recomputed not replicated (→ §4.1.1).
- **Honest verdict for MP-D1**: the engine's pure-function worldgen
  (`terrain_config.gd:25-30`) and analytic physics make the deterministic *subset*
  unusually large and cheap for a 3D game — but worldgen determinism ≠ sim
  determinism, and the sim loop's own debris physics, flood fills and float fields
  are exactly the classic offenders. Hence the three-way split of §0.2, which no
  research finding contradicts and four independent traditions (RTS, fighting games,
  Factorio, rollups) jointly prescribe.

### 3.3 Consensus, coordinator election, accountability

- **Raft** ([raft.github.io](https://raft.github.io/); Ongaro & Ousterhout, USENIX
  ATC'14): understandable leader election + replicated log — but elections are
  randomized-timeout, latency-blind. Lesson: borrow Raft's *terms* (→ epochs) and
  log discipline, replace its election trigger with QoS ranking (→ §4.4.2).
- **Latency-aware leader election** (Santos & Hutle — leader optimal w.r.t.
  transmission delays; abstract-verified only, flagged): the academic form of
  "coordinator = lowest-RTT peer" (→ §4.4.2).
- **PBFT view change** ([Castro & Liskov, OSDI'99](https://pmg.csail.mit.edu/papers/osdi99.pdf)):
  a new view must be quorum-certified and preserve the old view's decisions. Lesson:
  coordinator failover = certified handoff from the last co-signed receipt, not ad
  hoc re-election (→ §4.4.4). **Tendermint** ([docs](https://docs.tendermint.com/))
  and **HotStuff** ([arXiv 1803.05069](https://arxiv.org/abs/1803.05069)) show
  round-robin/timeout proposer rotation and linear view change — relevant if a
  *global* committee (cosmic events, §8.7) ever needs real BFT.
- **SWIM + Lifeguard** ([SWIM overview](https://www.brianstorti.com/swim/);
  [HashiCorp Lifeguard](https://www.hashicorp.com/blog/making-gossip-more-robust-with-lifeguard),
  [arXiv 1707.00788](https://arxiv.org/abs/1707.00788)): O(1)-per-period gossip
  membership; Lifeguard cuts false-positive failures >50× by self-awareness. Lesson:
  mandatory in a browser mesh where GC pauses and backgrounded tabs mimic death
  (→ §4.4.2).
- **Plumtree / Epidemic Broadcast Trees** ([Leitão et al., SRDS 2007](https://asc.di.fct.unl.pt/~jleitao/pdf/srds07-leitao.pdf)):
  eager spanning tree + lazy gossip repair. Lesson: the shape for receipt/event
  fan-out beyond a zone (→ §4.3.4, Ring-1 streams).
- **CRDTs** ([crdt.tech](https://crdt.tech/); [Yjs](https://yjs.dev/),
  [Automerge](https://automerge.org/) in production): coordination-free convergence —
  fits per-cell LWW edit merging; **wrong for competitive state** (non-commutative:
  who-got-there-first, contested inventory) — thin prior art on CRDT game state
  (one 2025 arXiv analysis; reasoned-from-commutativity, flagged). Lesson: the
  §4.4.7 split, with the CRDT half gated and flagged.
- **Lamport / vector clocks / HLC** (Lamport 1978; Fidge/Mattern;
  [Kulkarni et al., HLC](https://cse.buffalo.edu/tech-reports/2014-04.pdf) — used by
  CockroachDB/MongoDB): HLC gives O(1) monotonic causality-respecting timestamps
  under NTP drift. Lesson: HLC for cross-coordinator event timestamps; no vector
  clocks needed once the sequencer gives per-zone total order (→ §4.4.6).
- **Leases + fencing tokens** ([Kleppmann: How to do distributed locking](https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html)):
  a paused-and-resumed leader must be *rejected by the resource* via a monotonic
  token. Lesson: THE safety primitive bounding a stale/rogue coordinator — every
  message carries the epoch, every peer fences (→ §4.4.3).
- **PeerReview — accountability in distributed systems**
  ([Haeberlen, Kouznetsov, Druschel, SOSP'07](https://www.cis.upenn.edu/~ahae/papers/peerreview-sosp07.pdf)):
  signed tamper-evident logs + witness audit ⇒ every observed Byzantine fault is
  eventually detected and *irrefutably attributed*; correct nodes can prove
  innocence. Lesson: the theoretical backbone of the whole MP4 layer — the
  coordinator needs accountability, not real-time BFT (→ §4.4.1, §4.5.1, MP-V7).
- **Forward-secure tamper-evident logs** (Schneier–Kelsey, ACM TISSEC 1999;
  [Crosby & Wallach, USENIX Security'09](https://www.usenix.org/legacy/event/sec09/tech/full_papers/crosby.pdf)):
  hash chains + key evolution make *past* log entries unforgeable even after host
  compromise; anchor log heads externally. Lesson: seal coordinator logs
  forward-securely; the external anchor is the checkpoint token (→ §4.4.1, §4.6.2).

### 3.4 Trustless anti-cheat / verifiable simulation

**Feasibility verdict (load-bearing):** zk-proving the running voxel sim is
**infeasible today by 2–4 orders of magnitude** — a physics/collision tick costs
~10⁸–10¹⁰ cycles/frame, while RISC Zero proves ~10⁶ RISC-V cycles/sec
([RISC Zero](https://risczero.com/) — proof ~256 B, verification cheap) and SP1's
Hypercube needs ~160 RTX 4090s to prove an Ethereum block in ~10 s
([Succinct blog](https://blog.succinct.xyz/)). Proof *verification* is cheap
everywhere — it is per-tick *generation* that cannot fit a frame. Optimistic
re-execution is therefore the core; zk is reserved for narrow, discrete statements
(→ §4.5.7). No published proving benchmark exists for a sustained voxel-game sim —
the verdict is a cycle-count extrapolation, flagged as such.

- **Dark Forest** ([blog.zkga.me](https://blog.zkga.me/announcing-darkforest)): the
  canonical zk game — players submit hash commitments + zkSNARKs that *single moves*
  follow rules, never raw state. Lessons: (a) zk works for small well-defined
  transitions; (b) commitments-on-ledger + raw-state-off-ledger is the persistence
  shape (→ §4.6.1, §4.5.7).
- **MUD / Lattice** ([mud.dev](https://mud.dev/)) and **Dojo/Cairo**
  ([dojoengine.org](https://dojoengine.org/); "provable game engine", zero published
  perf numbers — flagged): the fully-on-chain end of the spectrum — gas-bound,
  turn-based-shaped. Lesson: the opposite pole confirming the checkpoint-only
  middle path (→ §4.6.3).
- **Cartesi + Dave/PRT** ([docs.cartesi.io](https://docs.cartesi.io/);
  [Dave](https://github.com/cartesi/dave); [PRT paper, arXiv 2212.12439](https://arxiv.org/abs/2212.12439)):
  full game logic in a deterministic RISC-V VM; disputes = interactive bisection to
  one instruction; **"one honest validator"** defeats arbitrarily many sybils at
  O(log) cost. Lessons: deterministic-re-execution-plus-dispute is a shipped stack;
  our challenge-window security model is exactly theirs (→ §4.5.3); their VM-level
  determinism is what our D-rules approximate at engine level.
- **Arbitrum BoLD / Optimism fault proofs**
  ([BoLD docs](https://docs.arbitrum.io/how-arbitrum-works/bold/gentle-introduction),
  [OP fault proofs](https://docs.optimism.io/stack/protocol/fault-proofs/explainer)):
  permissionless dispute games; the ~7-day windows are sized by *L1 censorship
  resistance*, not proving time. Lesson: our windows can be minutes because DA is
  enforced up-front (attestations, §4.5.3.2) and value-at-risk is bounded by the
  provisional-gains rule — the window covers detection latency only (→ §4.5.3,
  §4.5.5).
- **Baughman & Levine — cheat-proof playout** ([IEEE ToN version](https://forensics.cs.umass.edu/pubs/baughman.ToN.pdf);
  INFOCOM'01): commit-reveal lockstep kills look-ahead cheating; **Asynchronous
  Synchronization** drops into lockstep *only when interaction auras overlap*.
  Lesson: the escalation-on-contact pattern (→ §4.4.7) with real pedigree.
  **NEO** (GauthierDickey & Zappala, NOSSDAV'04 — corroborated, PDF unrendered):
  lower-latency majority-ordered variant for real-time p2p (→ §8.4).
- **Server-side rewind / lag compensation**
  ([Valve: Latency Compensating Methods](https://developer.valvesoftware.com/wiki/Latency_Compensating_Methods_in_Client/Server_In-game_Protocol_Design_and_Optimization)):
  rewind to the shooter's claimed timestamp, validate, **clamp the claim window**.
  Lesson: the mundane, essential real-time guard — shipped here as a deterministic
  protocol rule (→ §4.4.5).
- **TEEs — ruled out** (SGX deprecated on client CPUs since 2021; attestation-key
  extractions [SGAxe](https://sgaxe.com/); and decisively: **browser WASM has no
  TEE/attestation access whatsoever**). Lesson: there is no hardware-trust shortcut
  for a browser game; the protocol must carry all trust (→ §0.3).
- **Randomness & sortition**: [Algorand VRF cryptographic sortition](https://developer.algorand.org/docs/get-details/algorand_consensus/)
  (private self-selection, publicly verifiable);
  [drand / League of Entropy](https://drand.love/) (threshold-BLS public beacon);
  Ethereum [RANDAO](https://eth2book.info/capella/part2/building_blocks/randomness/)
  (proposer-biasable — the caveat we inherit for L2-derived seeds). Lesson: §4.5.4's
  self-selecting anonymous auditors, with beacon-bias analysis assigned to §8.1.
- **Reputation & sybil bounds**: [EigenTrust](https://nlp.stanford.edu/pubs/eigentrust.pdf)
  (transitive trust anchored in pre-trusted seeds);
  [SybilGuard](https://www.comp.nus.edu.sg/~yuhf/sybilguard-sigcomm06.pdf)/SybilLimit
  (social-graph random walks — require a real trust graph a keypair population lacks).
  Lesson: reputation *weights*, never *replaces*, identity cost (→ §4.5.4, T11).
- **Committee attestation of off-system facts**
  ([Chainlink DECO](https://blog.chain.link/deco/)): the "N sortitioned parties
  attest to X" pattern generalizes to "N peers attest they replayed segment S"
  (→ §4.5.3).

### 3.5 Blockchain/DLT game-state persistence

- **State channels do not generalize to open worlds**: FunFair's Fate Channels
  (2-party player-vs-house), [Perun virtual channels](https://perun.network/)
  (point-to-point via hubs), [ForceMove](https://docs.statechannels.org/)
  (strictly turn-based). Lesson: channels fit duels/trades between two fixed
  parties; a many-party open world needs the rollup shape instead — which is what
  the zone is (→ §4.6.3).
- **Optimistic rollups & DA economics**: data availability ≈ **95% of rollup
  operating cost**; [Celestia](https://celestia.org/)'s DAS exists precisely because
  posting bulk data to consensus is the bottleneck. Lesson: post 32-byte roots to
  Unicity, keep bulk on IPFS with availability *attested*, never assumed (→ §4.6.1,
  §4.5.3.2).
- **MagicBlock Ephemeral Rollups** ([arXiv 2311.02650](https://arxiv.org/abs/2311.02650)):
  a temporary, per-region, high-frequency runtime (10–50 ms blocks) into which
  accounts are delegated, settling atomically back to the base chain — motivated by
  exactly our math (1,000 players × 10 Hz position updates ≫ any L1). Lesson: the
  **closest shipped precedent for "zone sequencer + periodic checkpoint to base"**;
  our coordinator is an ephemeral rollup whose sequencer is an elected player
  (→ §4.4.1, §4.6.3).
- **Shared-sequencer trust caveat** (rollup literature consensus): a sequencer is a
  liveness+fairness dependency; it needs permissionless rotation or an escape
  hatch. Lesson: stated verbatim in §4.7 — the coordinator is a *documented trust
  assumption* with rotation (election), fencing, and fraud-proof exits; never
  advertised as trustless-by-default.
- **Session keys** ([Starknet/Argent "Ready" session keys](https://www.ready.co/blog/session-keys)):
  sign once, play many; realistic shape = scoped policy + on-chain revocation, not
  perfect trustlessness. Lesson: §4.2's session certificates, with the same honest
  framing (T17).
- **IPNS latency — measured** ([ProbeLab IPNS measurement, 2025](https://probelab.io/tools/ipns/)):
  p50 resolution **7–11 s**, tails 37–60 s. Lesson: IPNS never appears on a hot
  path; the Aggregator is the live pointer, IPFS fetch-by-known-CID the payload
  path (→ §4.3.1's tier table, §4.6.2).
- **OrbitDB** ([github.com/orbitdb](https://github.com/orbitdb/orbitdb)): p2p
  log-CRDT DB over IPFS pubsub — no sybil resistance, no dispute machinery. Lesson:
  a fine *sync substrate* shape, never an adjudicator — validity always lives in
  MP4 (→ §4.5).
- **What shipped web3 games actually persist**: Gods Unchained keeps only durable
  tradeable assets on the ledger (Immutable X zk-rollup batches), progression
  off-chain; Axie/Ronin migrated *toward* modular rollup + external DA. Lesson: the
  industry converged on "checkpoint durable ownership, not ticks" — our
  boundary-tokenization rule (→ §4.6.3).
- **Throughput sanity**: thousands of objects checkpointing every few minutes
  Merkleized per zone ⇒ tens of commits/sec (§4.6.5) against the Aggregator's
  documented 1M+/s (`.claude/reference/aggregator-go.md`) — the SMT *is* the
  Merkle-batching primitive the rollup world reinvents (→ §4.6.5).

### 3.6 LOD-consistency and global events

- **Aura–nimbus** (Benford & Fahlén, ECSCW'93 — the spatial model of interaction)
  and the **interest-management survey literature** (ACM Computing Surveys 46(4),
  2013; DIVE/MASSIVE): awareness = focus ∩ nimbus; zone/aura/visibility filtering
  kills O(n²). Lesson: rings around a static zone partition (→ §4.3.3), auras as
  the contested-interaction trigger (→ §4.4.7).
- **DIS dead reckoning** ([IEEE 1278](https://standards.ieee.org/ieee/1278.1/4949/)):
  standardized extrapolation models + threshold-triggered updates — military sims
  solved multi-fidelity entity exchange decades ago. Lesson: remote-entity
  interpolation specified as DR thresholds, not ad hoc smoothing (→ §4.4.5).
- **HLA time management** (IEEE 1516; Fujimoto's federate time services):
  conservative and optimistic federates in one federation — *in principle*; in
  practice mostly conservative-only ever shipped. Lesson, honestly: multi-fidelity
  *time* coordination is hard even with a mature standard — cite as difficulty
  evidence, not as a solution (→ why zones own their tick and only checkpoints
  cross timescales, §4.7).
- **PDES: CMB vs Time Warp** (Chandy–Misra–Bryant null-message conservatism;
  [Jefferson, "Virtual Time", TOPLAS 1985](https://dl.acm.org/doi/10.1145/3916.3988) —
  optimistic rollback with antimessages; Fujimoto's surveys): our
  predict-locally/rollback-on-authority is Time Warp with a bounded rollback
  horizon; decades of literature exist for every knob (→ §4.4.5).
- **Causal vs total order**: causal broadcast is cheap and sufficient for real-time
  perception; total order requires consensus and is reserved for the ledger rung.
  Lesson: the design never pays for total order below the checkpoint (→ §4.4.6,
  §4.7).
- **The ephemeris pattern** (deterministic lockstep's degenerate, zero-input case):
  anything that is a pure function of (shared constants, shared T) is consistent
  across *all* LOD tiers with **zero traffic** — the engine's worldgen and COSMOS's
  on-rails sky already are this (§2.1). Lesson: MP-V3's "the Moon keeps orbiting"
  costs nothing; only *disturbances* need consensus (→ §4.6.6).
- **Star Citizen server meshing** (CIG CitizenCon 2023 materials; community
  summaries — primaries paywalled/403, figures illustrative): a **replication
  layer** decoupling state replication from simulation; entity authority migrates
  between servers; CIG ships *static* meshing before *dynamic* because boundary
  handoff is the hard part. Lessons: our replication/simulation split mirrors it
  (receipts/gossip ≈ replication layer, coordinator ≈ DGS), and the roadmap ships
  static zones first (→ §4.4.6, Phase M2 before §8.4).
- **Ledger-anchored global world events: no credible shipped precedent found.**
  Flagged plainly: §4.6.6 is first-principles design (built exclusively from
  conservative parts — ordinary token transitions + the ordinary endorsement
  pipeline), not borrowed practice. Same flag for token-incentivized relay
  operation (§4.3.5) — unshipped anywhere.

---

## 4. The layered architecture

Six layers, crisp interfaces, each buildable on the current web engine and the Unicity
stack, honestly bounded by browser limits. Layers only call downward. The existing
engine appears mostly *inside* MP0 — the multiplayer fabric wraps the current game, it
does not rewrite it (the COSMOS discipline, `docs/COSMOS-ARCHITECTURE.md` §4).

```
            ┌────────────────────────────────────────────────────────────┐
   MP5      │ UNICITY PERSISTENCE                                        │
            │ entity tokens (UXF) · checkpoint = state transition ·      │
            │ aggregator SMT = latest-state pointer · IPFS payloads ·    │
            │ global/cosmic event tokens                                 │
            ├────────────────────────────────────────────────────────────┤
   MP4      │ PROOF & AUDIT                                              │
            │ signed simulation traces · Merkle state roots · segment    │
            │ logs · sortition auditors · endorsements · fraud proofs ·  │
            │ entry proofs · meet proofs · rollback                      │
            ├────────────────────────────────────────────────────────────┤
   MP3      │ REAL-TIME COORDINATION                                     │
            │ zone coordinator = SEQUENCER · QoS-weighted election ·     │
            │ lease + fencing epochs · view change / host migration ·    │
            │ prediction + tick dilation                                 │
            ├────────────────────────────────────────────────────────────┤
   MP2      │ P2P TRANSPORT & INTEREST MANAGEMENT                        │
            │ WebRTC data channels · Nostr signaling/discovery · zone    │
            │ AOI partition · gossip fabric · fog peers (untrusted)      │
            ├────────────────────────────────────────────────────────────┤
   MP1      │ IDENTITY & KEYS                                            │
            │ player identity token (secp256k1/BIP-32) · session keys ·  │
            │ presence chain (enter/exit attestations)                   │
            ├────────────────────────────────────────────────────────────┤
   MP0      │ DETERMINISTIC SIMULATION SUBSTRATE                         │
            │ the existing engine + tick/input formalization · canonical │
            │ state serialization · state hashing · replay · RNG policy  │
            └────────────────────────────────────────────────────────────┘
```

The **consistency ladder** — each rung trades latency for trust; the design's central
move is refusing to make one mechanism serve all rungs:

| Rung | Latency | Mechanism (layer) | Guarantee |
|---|---|---|---|
| Local prediction | 0 ms | client-side prediction (MP3) | none — cosmetic, reconciled next tick |
| Sequenced tick | ~50–150 ms | coordinator-ordered signed inputs (MP3) | all co-located peers compute identical state; coordinator misbehaviour detectable |
| Co-signed receipt | ~1 s | peers co-sign the zone state root (MP4) | quorum of occupants attests the root; equivocation now provable |
| Endorsed checkpoint | ~3–5 min | sortition auditors re-execute + endorse (MP4) | unrelated third parties attest; rollback boundary |
| Tokenized checkpoint | + ~1 s | Unicity `update` transition + SMT inclusion proof (MP5) | globally unique latest state; "one story" fact |
| PoW-anchored | + ~2 min | L2 root anchored to L1 (`alpha`) | history rewriting needs PoW majority |

### 4.1 MP0 — Deterministic simulation substrate (the linchpin)

Everything above this layer assumes: **given the same checkpoint base, the same ordered
input log, and the same T, every peer and every auditor computes bit-identical zone
state.** This section defines exactly what "state", "input", and "computes" mean, and
the rules that keep the property true.

#### 4.1.1 The authoritative state and the tick

The authoritative state of a **zone** (the AOI unit, §4.3.3) is:

```
ZoneState {
  base:      checkpoint reference (token id + state root it committed)
  edits:     the edit overlay restricted to the zone      # world_manager.gd:38
  meta:      cell metadata + material documents           # ZoneChunk layers
  objects:   settled VoxelBody records (cells, pose_q)    # pose quantized, §4.1.4
  players:   per-player records { pos_q, vel_q, health, … }  # quantized claims
  tick:      integer tick index since base  (T = base.T + tick / TICK_RATE)
  rng:       per-zone deterministic RNG cursor (§4.1.2)
}
```

State evolves only by the pure transition function

```
ZoneState' = step(ZoneState, OrderedInputs[tick])
```

executed at a fixed tick rate (design target 20 Hz; the rate is a per-zone constant
recorded in the trace so auditors replay at the same cadence). `step` is the existing
engine: `break_terrain`/`place_block` (`world_manager.gd:315,337`) → the deterministic
`StructuralSolver.solve` carve (`structural_solver.gd:41`), inventory mutations, damage
application, and validation of movement claims (below). Rendering, meshing, particles,
audio and prediction live strictly outside `step`.

**The input alphabet — semantic intents, not raw controls (locked).** Two classes:

1. **World mutations** are *replayed*: `Break(cell)`, `Place(cell, item)`,
   `Use(cell/object)`, `Attack(target, params)`, `Craft(recipe)`, `Drop/Pickup(item)`…
   — each a small signed event whose full effect is recomputed deterministically by
   every peer and every auditor. The engine's single write choke point
   (`_write_cell`, `world_manager.gd:378`) is where "apply only sequenced, signed
   mutations" is enforced.
2. **Movement is *claimed and validated*, not replayed.** Each tick a player submits a
   quantized kinematic claim `{pos_q, vel_q, stance}` (positions on a 1/256-block
   grid). `step` validates the claim against the analytic movement rules the engine
   already exposes as pure functions — per-tick displacement ≤ v_max(mode)·dt, no
   passage through cells where `blocked()` holds (`world_manager.gd:779`), support/fall
   rules via `floor_under` (`world_manager.gd:740`), jump/fly capabilities from the
   character token — and **rejects invalid claims deterministically** (the player is
   held at the last valid state; repeated violations are protocol violations, §6).
   Rationale: replaying raw look/WASD inputs would drag the whole FPS controller
   (mouse deltas, frame timing) into the determinism boundary for no security gain —
   teleport/speed/clip cheats are exactly what the validity predicate checks, and
   auditors verify claims in O(1) per tick instead of re-simulating a controller.
   This is the standard trust split in shipped games: server-validated movement rather
   than server-simulated movement, here with "server" replaced by "every peer" (§3.1).

**What is deliberately NOT in ZoneState:** meshes, far-field LOD, per-voxel *derived*
fields (temperature/light are recomputed from the same deterministic models on demand —
CLAUDE.md rule 2; continuously-integrated float fields would otherwise be a textbook
cross-peer drift source, §3.2), in-flight debris trajectories (§4.1.4), and anything
cosmetic. State stays small: a zone's serialized deviation-from-generator is
ZoneChunk-compact (`zone_chunk.gd:1-8` — "only present (edited) cells occupy the
chunk").

**The consensus subset is deliberately arithmetic-boring.** Everything `step` computes
is integers (cells, item counts, damage), quantized fixed-point (the 1/256-block
kinematic grid — claims arrive already quantized, validation compares quantized
values), table lookups (BlockCatalog masses, recipe tables), and sorted-order graph
walks (the structural solver, whose flood traversal gets a canonical frontier order —
a flagged change, §8.2, since tie order is otherwise iteration-dependent, §3.2). No
engine transcendental, no accumulated float, no frame-delta ever enters `step`; if a
future mechanic genuinely needs trig inside consensus, it uses an owned LUT/CORDIC
implementation (the Box2D/Factorio fix, §3.2, and the same kernel COSMOS R4 already
plans — `docs/COSMOS-ARCHITECTURE.md` §7.4). This is the "narrow hand-audited
deterministic subset" the literature prescribes instead of trusting a whole engine
(§3.2).

#### 4.1.2 The determinism rules (the law of MP0)

- **D1 — One binary, one epoch — and no blind trust even then.** All peers of a zone
  run the same WASM build; the build hash is exchanged at handshake and recorded in
  every checkpoint. Same-binary WASM removes the classic cross-*compiler* divergence
  (compiled-in libm, baked FP contraction), and core WASM float ops are
  spec-deterministic — but the spec's own nondeterminism list (NaN payloads,
  **relaxed-SIMD**, **threads/shared memory**) plus an unaudited engine mean the
  binary is *necessary, not sufficient* (§3.2); D6 carries the correctness burden.
  Implementation-phase checks recorded now: Emscripten's `-ffp-contract` default and
  any relaxed-SIMD use in godot_voxel must be pinned in `docker/engine/versions.env`
  discipline (§8.2). Version upgrades begin a new **determinism epoch**: a zone
  checkpoints on the old build, then resumes on the new one; audits never replay
  across an epoch boundary with the wrong build (fog peers archive old builds; the
  build hash in the trace says which to use). Native desktop builds may *play* but
  are never the canonical replay target; if a native build is ever to audit, it must
  ship the COSMOS R4 own-math kernel (`docs/COSMOS-ARCHITECTURE.md` §7.4) — same open
  question, same fix.
- **D2 — The sim tick runs on the main thread only.** godot_voxel's worker threads
  (`project.godot:63-65`) touch meshing exclusively; nothing in `step` reads from or
  races with them. This is true today by architecture (gameplay reads the cell query,
  not the mesher — CLAUDE.md rule 2) and becomes a tested invariant.
- **D3 — Canonical order everywhere it matters.** Hashing/serializing `_edits` and all
  state dictionaries iterates keys in sorted canonical order (Godot Dictionaries
  preserve insertion order, which differs per peer history — never rely on it). Inputs
  within a tick are ordered by the coordinator's sequence (§4.4.1) with a deterministic
  tie-break (sender pubkey, then event hash). ZoneChunk palette construction must be
  made canonical (first-seen order is history-dependent — flagged change, §8.2).
- **D4 — Seeded randomness only.** Any in-sim randomness draws from a per-zone stream
  `rng = PCG(zone_seed = H(SEED, zone_id), tick)`; never `randi()`, never wall-clock,
  never OS entropy. Worldgen already obeys a stronger version of this rule
  (`terrain_config.gd:25-27`); TreeGen's noise-seed discipline
  (`terrain_config.gd:114`) is the template.
- **D5 — T is consensus data, not a clock.** The universal time T of COSMOS §1.3
  advances as `base.T + tick/TICK_RATE` inside a zone; wall clocks only *schedule*
  ticks, they never enter state. Cross-zone/global T is anchored by checkpoint records
  and, ultimately, aggregator block height (§4.6.6). Peers NTP-sync loosely for
  scheduling; drift shows up as latency, never as divergence.
- **D6 — Hash-and-resync is the PRIMARY consistency mechanism; determinism is the
  optimization that makes it rare.** Every peer computes the zone state root each
  co-sign round (§4.5.1) and compares against the receipt quorum's. On mismatch the
  minority peer does not stall the zone and the protocol does not assume lockstep
  held: the peer **resyncs** — refetches the divergent regions (per-region hashes,
  §4.1.3) from the quorum root and rejoins, exactly a late-join in miniature. A peer
  convinced its *own* root is right doesn't argue in real time — it files a dispute
  through MP4 (the first-divergent-tick search over the shared log is the Dave/BoLD
  bisection problem in its adversarial form, §3.5 — desync debugging and fraud
  proving are the same algorithm). Every resync is logged and counted: resync *rate*
  is the health metric of the deterministic subset (target ≈ 0; Factorio's
  state-hash discipline, §3.2, applied p2p), and a rising rate is a determinism bug,
  not an accepted cost.

#### 4.1.3 Canonical serialization and the state root

The **zone state root** is the Merkle root over:

```
root = MerkleRoot(
  [H(ZoneChunk.to_bytes(region_r))  for r in sorted touched 32³ regions],   # world
  H(canonical_bytes(objects)),                                              # settled debris
  H(canonical_bytes(players)),                                              # kinematic + vitals
  H(tick, rng_cursor, base_ref, build_hash)                                 # framing
)
```

`ZoneChunk.to_bytes()` already emits a compact, self-describing, name-keyed layout
(`zone_chunk.gd:29-35`); making it *canonical* (D3) is the only format change required.
Per-region hashing means an auditor or a late-joining peer can verify/fetch the world
piecemeal, and the checkpoint token commits to the same root the live protocol
co-signs — one root from HUD to ledger, no translation layer (the CLAUDE.md "one cell
query" philosophy applied to trust).

#### 4.1.4 The physics carve-out (locked)

Godot's rigid-body solver is not cross-run deterministic and is not made so here.
`VoxelBody` debris (`godot/src/physics/voxel_body.gd`) is handled by a strict split:

- **Deterministic:** the *carve* that creates a body (StructuralSolver over the cell
  query — pure), its cell inventory and mass (BlockCatalog data), and its *settled*
  pose — because settling is an event in the sequenced log.
- **Cosmetic:** the tumbling trajectory between detach and settle. Peers each run
  their local physics for visuals; nobody's trajectory is authoritative.
- **Sequenced settle events:** when a body sleeps on the coordinator's host, the
  coordinator emits `Settle(body_id, pose_q)` into the input log; every peer snaps its
  local body to `pose_q` (a small visual correction of the same class as the COSMOS
  chart re-anchor settle, `docs/COSMOS-ARCHITECTURE.md` §4.3.4) and the pose becomes
  state. Validity predicates bound coordinator abuse: the settled pose must be
  supported, within a plausibility radius of the detach site given elapsed ticks, not
  intersecting solid cells, and mass/cell-conserving (cells(body) ≡ cells carved).
  A coordinator that emits an invalid settle produces a fraud-provable trace like any
  other invalid transition.
- **Player↔body pushes** (mass-dependent shoving, CLAUDE.md "Physics is analytic")
  during ACTIVE phases are, likewise, cosmetic until the settle event fixes the
  outcome.

The engine's **dormant-by-default law** (memory: voxiverse-physics-scale; wake paths
`world_manager.gd:275`) is what makes this split cheap: at any instant, almost
everything is LANDED/settled, i.e. already inside the deterministic state. The COSMOS
RAILS state (Kepler elements, closed-form in T — COSMOS §4.4) is *better* than
deterministic — it is analytic — so orbital objects need no sequencing at all beyond
their state-change events. An optional future upgrade — a fixed-point deterministic
mini-solver for consensus-relevant debris — is scoped as §8.3, not assumed.

**Interface (sketch):**

```
Sim.step(state, ordered_inputs) -> state            # THE pure transition
Sim.state_root(state) -> Hash                        # canonical Merkle root (§4.1.3)
Sim.serialize(state) / Sim.load(bytes)               # ZoneChunk-based, canonical
Sim.validate_move(state, player, claim) -> bool      # the movement predicate
Sim.replay(base_state, input_log) -> state           # = fold(step) — the auditor entry
```

**Reuses:** the whole gameplay engine, ZoneChunk/ZoneBundle, the verify harness.
**Needs new:** tick/input formalization, canonical hashing, RNG policy, record/replay.
**Web feasibility:** `step` is what the engine already does per frame; hashing a few
hundred KB of canonical state per second is trivial WASM work.
**Unicity dependency:** none — this layer is buildable today (Phase M0).

### 4.2 MP1 — Identity, session keys, presence

- **Player identity = the agent-identity pattern, applied to players.** A secp256k1
  keypair from a BIP-39 mnemonic with BIP-32 derivation — exactly the stack Unicity
  uses everywhere (`.claude/reference/crypto-primitives.md`) and the workspace already
  operates for AI agents (keypair + npub + owner DM channel,
  `.claude/CLAUDE.md` "Agent Communication"). The public identity is carried by an
  **identity token** (MP5) whose data records: creation cost proof (§4.5.4), display
  nametag (Nostr nametag resolution, `.claude/reference/transport-protocols.md`),
  reputation/accountability history, and the current **character token** reference.
  The same key doubles as the Nostr key — identity and transport share one root, by
  Unicity design (`.claude/docs/design-decisions.md` "secp256k1 over ed25519").
- **Session keys.** The hot game loop signs dozens of events per second; it must never
  touch the master key. At login the master key signs a **session certificate**
  authorizing a derived child key (own BIP-32 path) for a bounded scope: validity
  window, game build hash, optionally a zone allowlist. Peers verify `sig_session ∘
  cert ∘ master` once at handshake, then only cheap per-event session-key checks.
  This is the "session keys" pattern of web3 gaming (§3.5) realized with the BIP-32
  machinery sphere-sdk already has. Compromise of a session key is bounded by the
  cert's window and revocable by an identity-token transition.
- **The presence chain — the anti-teleport primitive.** A player's location history is
  a hash chain of **presence records**: `Enter(zone, T, prev_hash)` and
  `Exit(zone, T, prev_hash)` attestations, each co-signed by the zone's coordinator
  *and* a quorum of occupants present at that tick (so a lone colluding coordinator
  cannot fabricate presence). Validity rules checked by any verifier: chain integrity;
  zones of consecutive records adjacent, or reachable given ΔT and the maximum speed of
  the traversal mode (walking, ship, orbital transfer — the COSMOS velocity table,
  `docs/COSMOS-ARCHITECTURE.md` §1.2, gives the caps); enter of zone Z+1 only after
  exit of Z. "Legitimately present, not teleported" (MP-V5) = "shows an unbroken,
  co-signed presence chain from their last checkpoint to here" (§4.5.6). Empty-zone
  travel (wilderness with no witnesses) produces *self-signed* segments — valid but
  marked unwitnessed; they still bind the player (signed claims are fraud-provable
  retroactively if they conflict with anyone's observation) and the movement caps
  still apply between witnessed endpoints.

**Reuses:** Unicity identity stack, Nostr keys/nametags. **Needs new:** session cert
format, presence record format. **Unicity dependency:** identity tokens + nametags
(exists per reference docs); session-cert conventions (new, SDK-level — §7 M4).

### 4.3 MP2 — P2P transport & interest management

#### 4.3.1 The transport stack (browser-bounded)

The whole fabric obeys a **three-tier latency budget** — each tier used only for what
its latency class permits, never below it:

| Tier | Latency class | Used for | Never used for |
|---|---|---|---|
| Nostr relays | seconds | signaling, discovery, coordinator liveness (~1–2 s beacons), checkpoint-pointer announcements | gameplay |
| WebRTC DataChannel | sub-100 ms | everything real-time (ticks, claims, receipts) | first contact (needs signaling) |
| Aggregator + IPFS | ~1 s / minutes | checkpoint truth + payload storage | anything live (IPNS resolution is 7–11 s p50 — §3.5) |

The web export cannot open listen sockets; every live link is **WebRTC
DataChannel** (the only browser primitive giving unreliable/unordered *and*
reliable/ordered p2p transport — §3.1):

| Channel | Mode | Carries |
|---|---|---|
| `ctl` | reliable, ordered | handshake, session certs, election, receipts, checkpoints |
| `seq` | reliable, ordered | coordinator's OrderedBatch stream (the input log) |
| `claims` | unreliable, unordered | per-tick movement claims, cosmetic state (droppable) |
| `bulk` | reliable, ordered | ZoneBundle transfer, segment logs, catch-up |

- **Signaling rides Nostr** — SDP offers/answers as encrypted Nostr events (NIP-44
  payload encryption; NIP-17 wrapping for metadata privacy —
  `.claude/reference/transport-protocols.md`) between player npubs. This is
  *demonstrated* prior art, not speculation (a shipped nostr-WebRTC signaling project
  exists — §3.1): no bespoke signaling server, relays are message carriers with zero
  authority, players multi-home across relays, and the identity performing signaling
  *is* the game identity, killing a whole class of MITM setup attacks (the offer is
  signed by the key you will play against). libp2p Circuit Relay v2 is the
  equivalent permissionless *control-plane* relay shape if a libp2p fabric is ever
  preferred (§3.1).
- **The two relay tiers are economically distinct — never conflate them (§3.1):**
  * **Control plane** (signaling, discovery, liveness): cost O(#introductions), tiny
    bursty traffic, permissionless and volunteer-run — Nostr relays cover it, and
    they are infrastructure the Unicity ecosystem *already operates* for agent
    comms (`.claude/CLAUDE.md` "Agent Communication"). Genuinely near-zero new infra.
  * **Data plane** (relay fallback): cost ∝ relayed bytes. The load-bearing pattern
    is **connect-through-relay, then upgrade** (libp2p's DCUtR shape, §3.1): first
    contact goes through a lightweight relay hop — an application-level forward via a
    mutually-reachable *zone peer* (a browser can copy between two DataChannels —
    fine for `seq`/`ctl` bitrates) or a fog relay (§4.3.5) — then the pair attempts a
    hole-punched direct connection and drops the relay on success. The pinned
    numbers: general WebRTC surveys put TURN need at ~15–20% of consumer connections
    (60–85% corporate); production IPFS measured hole-punch success at ≈70% over
    millions of attempts, i.e. ~30% remain on relay (§3.1 — an inference from an
    IPFS, not gaming, NAT population; flagged as the conservative bound).
    **Capacity is budgeted at ~25–30% of pairs carrying real bytes over a relay** —
    this fraction is why "truly zero-infra" is an overclaim, and a crowd-sourceable
    relay pool (coturn-style TURN and/or circuit-relay peers, §4.3.5) is part of the
    locked design: someone always pays for those bytes.
- **WebTransport** is client↔server only per the W3C spec — it cannot replace WebRTC
  for the mesh (§3.1); it is the natural protocol for client↔fog hops (log archives,
  pinning, relaying) — noted for the fog design pass (§8.5).

#### 4.3.2 Discovery & rendezvous

- **Zone rendezvous:** each zone maps to a **NIP-29 group** (key derived from
  `H(body, zone_id)`) — NIP-29 is already Unicity's "multi-party coordination"
  channel (`.claude/reference/transport-protocols.md`), and relay endpoints are
  already provisioned network-wide (`wss://relay.unicity.network` +
  redundant-multi-relay SDK config — `.claude/reference/network-config.md`). In the
  group: the acting coordinator posts ~1–2 s liveness beacons and signed
  checkpoint-pointer announcements; arriving players publish a signed short-TTL
  presence beacon, collect occupants + coordinator + latest pointer, then form WebRTC
  links via signaling DMs. Cold zones (nobody there): the group is silent, and the
  player boots the zone solo from its checkpoint token (§4.5.2) — becoming its
  coordinator.
- **Global directory = the ledger itself.** The authoritative "where is the latest
  state of X" query is never a relay lookup — it is the Aggregator (MP-V8): token id →
  latest commitment + inclusion proof (`.claude/reference/aggregator-go.md`). Nostr is
  the *fast path* and liveness layer; Unicity is the *truth* layer. An eclipsed player
  can be denied freshness, never fed a forged history (§6).

#### 4.3.3 Interest management: the zone partition

- **The zone is the unit of everything:** real-time membership (MP3), the trace and
  its audits (MP4), the location token (MP5), and AOI. Locked: a zone is a fixed
  lattice-aligned column region of **256×256 m** (8×8 ZoneChunk regions,
  `region_origin_of` `world_manager.gd:496`), full vertical slab — matching the render
  radius/fog edge (`docs/DESIGN.md` §1) so "the zone you're in" ≈ "the world you can
  see". Under COSMOS, zone keys gain the `(body, face)` dimensions exactly as region
  keys do (COSMOS §4.6); a zone is face-local so the topology remap machinery
  (`docs/COSMOS-PLANET-TOPOLOGY.md` §4) is reused, not duplicated.
- **Interest rings** (the aura/nimbus model hardened by decades of DVE research and
  by the LOD ladder COSMOS §5 already locks):
  * **Ring 0 — the zone:** full membership: sequenced ticks, live claims, receipts.
  * **Ring 1 — the 8 neighbours:** subscribe to their coordinators' receipt stream
    (state roots + entering/leaving players + audible/visible events), no per-tick
    claims. Border interactions escalate to cross-zone sequencing (§4.4.6).
  * **Ring 2+ — everything else:** checkpoint tokens and global event stream only
    (§4.6.6). The Moon keeps orbiting because the ephemeris is a shared pure function;
    you learn it exploded because that is a token event, not because anyone streamed
    you the Moon.
- **Scale shape:** thousands of players ⇒ hundreds–thousands of mostly-independent
  zones, each with 1–24 live peers; there is no global tick, no global membership, no
  O(players²) anything. The global layers (gossip of events, ledger checkpoints) are
  O(events), and events are human-generated — low rate by nature.

#### 4.3.4 Topology and capacity inside a zone

The browser ceilings are *measured* facts, not tunables: WebRTC full mesh is reliable
at ~4 peers and degrades hard by ~10–12 (O(n) upload per peer, O(n²) total —
residential uplink is the wall), and a tab sustains only **low dozens of live
RTCPeerConnections** in practice regardless of channel type (§3.1). Consequence:
**sparse membership is structurally required, not an optimization** — each client
keeps a small *active view* (the connections it actually holds: zone peers + a few
Ring-1/fabric links) and a larger *passive view* (known-but-unconnected peers used to
repair the active view on churn) — the HyParView construction, which keeps broadcast
reliable through even massive simultaneous failure at small fanout (§3.3). AOI (§4.3.3)
is what decides *which* peers deserve an active slot. Locked topology ladder:

- ≤ ~6–8 peers: full mesh (per-pair DataChannels, trickle ICE).
- ~8–24 peers: star over the coordinator for `seq` — the elected coordinator plays a
  **serverless SFU** role (published prior art: SnoW builds mesh/SFU/MCU equivalents
  entirely from peers, a capable peer forwarding for weaker ones — §3.1, no capacity
  numbers though): one input batch in, one OrderedBatch fan-out per
  tick per peer (batching keeps a 20 Hz × ~20-peer stream inside ~0.5–1 Mbps of
  uplink); mesh retained for `claims` between mutually-reachable pairs; peers with
  spare uplink volunteer as fan-out sub-relays (relay-tree, §3.1 gossip patterns).
  The 24-peer star ceiling is an *estimate to be measured* — it is a Phase M2 exit
  gate, not a promise.
- Beyond the measured ceiling: **the zone does not grow — it subdivides** (quadrant sub-zones with the
  same machinery, merged back when population falls) and/or the tick dilates
  (EVE-style time dilation as graceful degradation, §3.1: the tick rate drops, T
  advances slower *inside the sequenced log*, consistency is never sacrificed for
  rate). Mass events are a designed-for degradation, not a supported steady state —
  this is the honest browser bound.

#### 4.3.5 Fog peers — the thin, untrusted helper tier

Volunteer always-on nodes (a player's home machine running the headless Linux export,
`docker/engine/bin/` toolchain, or any JS node) providing, in strict order of value:

1. **TURN/relay** for unreachable pairs (§4.3.1) — bytes only, E2E-encrypted.
2. **Availability**: pinning IPFS payloads (checkpoints, segment logs, ZoneBundles,
   old build binaries) and serving them fast — the "cloud/fog peer" a player asks for
   an entry proof (MP-V5) *serves* the proof; it never certifies anything: every byte
   it hands over is content-addressed (CID) or signature-covered, so a lying fog peer
   can only fail to answer, never deceive.
3. **Witnessing** (optional, reputation-bearing): standing auditors that accept
   sortition duty at higher availability than browsers (§4.5.4), and archival
   witnesses for DA attestations (§4.5.3).

Fog peers hold **no authority**: not coordinators (they hold no player stake in the
experience — though the §8.5 pass may revisit letting them coordinate *empty-ish*
zones), no endorsement privileges beyond their sortition weight, no protocol role that
isn't verifiable by content hash or signature. The design goal: the universe stays
*correct* with zero fog peers (Unicity + IPFS + relays suffice for truth), and stays
*pleasant* with a handful.

**The smallest always-on footprint, in one table** — four roles, all permissionless
and replaceable, none of them a "VOXIVERSE Inc. game server":

| Role | Filled by | Permissionless? | Already provisioned? |
|---|---|---|---|
| Signaling + discovery + coordinator liveness | Nostr relays, NIP-29 zone groups | yes — any operator; players multi-home | **yes** — `wss://relay.unicity.network` + multi-relay SDK config (`.claude/reference/network-config.md`) |
| NAT relay fallback (~25–30% of pairs, §4.3.1) | peer/fog relays with direct-upgrade (DCUtR shape); coturn-style TURN pool | yes — any reachable peer, incl. player machines | new — the one real recurring cost |
| Checkpoint truth / latest-state pointer | Unicity Aggregator SMT + inclusion proofs | inherited from L2 BFT — the Unicity trust root | **yes** — `https://aggregator.unicity.network`, 1M+/s (`.claude/reference/network-config.md`, `aggregator-go.md`) |
| Checkpoint payload storage | IPFS, volunteer/fog-pinned | yes — content-addressed | **yes** — `https://ipfs.unicity.network` gateway (`.claude/reference/network-config.md`) |

Three of the four are the Unicity network's existing, already-decentralized services;
the relay-bytes fraction is the single honest residue of "not zero infrastructure".
Volunteer (Tor-relay/IPFS-pinning-spirit) operation is sufficient to start;
**token-incentivized relay running has no shipped precedent anywhere** — if VOXIVERSE
ever pays relays in tokens, that is pioneering work and is flagged as such (§8.1,
§3.1).

**Reuses:** Nostr transport + identity, ZoneBundle as the bulk payload, the deploy
toolchain for the headless fog build. **Needs new:** everything WebRTC (a GDScript/
JS-bridge WebRTC wrapper — Godot's WebRTC classes work on web export), rendezvous
conventions, zone partition constants. **Unicity dependency:** relays/nametags only
(exists); no SDK gaps at this layer.

### 4.4 MP3 — Real-time coordination (the soft-authority layer)

The real-time coordinator is a **soft-authority optimization over a hard historical
ledger** — never a source of truth, only a source of *order*. This section makes that
split mechanical.

#### 4.4.1 The coordinator is a sequencer, not a simulator (locked)

The coordinator's duties are exactly four; note that *none of them is "compute the
game state"*:

1. **Order**: collect signed input events from zone peers, emit one `OrderedBatch` per
   tick: `{zone, epoch, tick, prev_hash, H(events…), sig_coord}` — a hash chain. Every
   peer (coordinator included) then applies `Sim.step` locally and identically (MP0).
2. **Arbitrate the carve-out**: emit `Settle` events for debris (§4.1.4) and
   tie-breaks the determinism rules delegate to sequencing (e.g., two `Pickup`s of one
   item in one tick — first in the batch wins, and the batch order is signed).
3. **Aggregate receipts**: each co-sign round (~1 s), collect peers' state-root
   signatures into a **receipt** `{tick, root, {sig_peer…}}` and append it to the log.
4. **Checkpoint**: at cadence or on last-exit (MP-D2), assemble the checkpoint
   candidate (§4.5.5) and submit it through MP4/MP5.

This is the Croquet/Multisynq reflector insight (§3.1) fused with the rollup-sequencer
pattern (§3.5): when computation is replicated and deterministic, the *only* central
function left is ordering — and ordering is cheap to provide, cheap to verify, and
cheap to take away. The cheating surface of a sequencer is exactly: **censorship**
(dropping a player's events — visible to the victim, complainable, and grounds for
re-election), **ordering bias** (legal but auditable — order within a tick is visible
in the signed batch), and **equivocation** (two different signed batches for one
(epoch, tick) — a self-signed, transferable fraud proof; §4.5.3). A sequencer *cannot*
forge inputs (events are player-signed), cannot mint state (it doesn't produce state,
`step` does), and cannot rewrite history (the hash chain + receipts pin it).

Because every message the coordinator emits is signed and hash-chained, the zone log
is a **tamper-evident log** in the PeerReview sense (§3.3): any Byzantine act that any
correct peer observes yields an irrefutable, attributable proof of misbehaviour — the
formal foundation for "trusted appointed coordinator with bounded, provable damage"
(MP-V7). The log additionally adopts forward-secure sealing (Schneier–Kelsey key
evolution over the session key, §3.3) so a host compromised *mid-session* cannot
silently rewrite the entries it emitted before compromise; checkpointing log heads
into Unicity tokens (§4.6.2) gives the log its external unforgeable anchors.

#### 4.4.2 QoS-weighted election

Vanilla Raft elects *any* live peer via randomized timeouts — safety-correct,
latency-blind (§3.3). A game zone wants the *best-connected* peer, so election is
**measurement-ranked**:

- Every zone peer continuously maintains a signed **QoS record**: RTT vector to the
  other peers (median/p95), uplink estimate, tick-processing headroom, session
  uptime, and the reliability score carried on its identity token (checkpoint-signed
  history of past coordinator terms — §4.6.1).
- The **score** is a deterministic function of the co-signed measurement set (locked
  shape: minimize worst-case RTT to current peers — the latency-aware leader
  criterion of §3.3 — tie-broken by uplink, then reliability, then pubkey). Everyone
  computes the same ranking from the same signed records; "election" is adoption, not
  a vote campaign.
- **Membership** for the ranking uses SWIM-style gossip with Lifeguard's
  self-awareness corrections (§3.3) — mandatory in a browser mesh, where GC pauses
  and backgrounded tabs would otherwise cause exactly the false-positive evictions
  Lifeguard was built to fix.
- Hysteresis: re-ranking runs continuously, but re-election triggers only on lease
  expiry, score degradation past a threshold, or peer-set change — a stable, slightly
  suboptimal coordinator beats an optimal churn.

#### 4.4.3 Lease + fencing epoch (the load-bearing safety primitive)

Coordinator authority is a **lease**: granted for ~30 s, renewed by heartbeat, and
stamped with a monotonically increasing **epoch number** that every message carries.
Every peer enforces the fencing rule — *reject any coordinator message whose epoch is
lower than the highest epoch seen* (Kleppmann's fencing tokens, §3.3 — the single
most load-bearing primitive here). This is what makes the classic split-brain
harmless: a coordinator whose tab froze for 40 s wakes, still believes it leads, emits
batches — and every peer discards them, because epoch e < e+1 already adopted. The
"resource" that fences is the peer set itself (and ultimately the checkpoint: a
checkpoint candidate carries its epoch, and MP5 will not accept a checkpoint built on
a superseded epoch's chain).

#### 4.4.4 View change / host migration

On lease expiry, Lifeguard-confirmed failure, or a proven fault (§4.4.1):

1. Peers gossip a `ViewChange(epoch+1, last co-signed receipt)` referencing the
   highest receipt they hold — the PBFT view-change shape (§3.3): the new view must
   agree on, and preserve, everything the old view finalized.
2. The next-ranked candidate (by the §4.4.2 score, recomputed without the failed
   peer) assumes epoch+1 **from the last co-signed receipt**, re-requests any events
   peers submitted after it, and resumes sequencing. Peers ack; fencing retires the
   old epoch.
3. Cost in the common case: one to two seconds of input stall (comparable to
   production host migration in GTA Online / Destiny's host-migrating P2P — §3.1),
   **no rollback**, because receipts are ~1 s apart and the log survives on every
   peer. Rollback (to the last receipt, worst case the last checkpoint) happens only
   when the failure *is* an equivocation — i.e. there are two chains and the honest
   suffix cannot be identified — which is precisely MP-V7's accepted worst case.

#### 4.4.5 The feel: prediction, reconciliation, dilation — and the rewind clamp

- Each client predicts locally (own movement immediately; remote entities via
  DIS-style dead reckoning with divergence thresholds — §3.4) and reconciles against
  the sequenced tick when it arrives — the Time-Warp optimistic-PDES pattern
  (speculate, roll back on straggler; §3.4) that rollback netcode reduced to practice
  (GGPO, §3.1), applied *within* the zone tick horizon (tens of ms), never across it.
- **Lag compensation is a deterministic protocol rule, not a server favour.** A
  time-sensitive interaction event (an `Attack`) cites the tick it was aimed at:
  `Attack(target, tick_fired, params)`. `step` resolves the hit against the
  *sequenced state at `tick_fired`* — which every peer has, because history is shared
  — subject to the **clamp** `tick_now − tick_fired ≤ REWIND_MAX` (~10 ticks ≈
  500 ms). This is classic server-side rewind (§3.1) upgraded by determinism: the
  "rewound snapshot" is consensus state, so the validation is replayable by auditors
  like everything else, and the clamp kills the claim-a-favourable-past cheat by
  rule rather than by trust. Cheap, real-time, and independent of the crypto layers
  above it — the mundane guard ships first (Phase M1).
- Sequenced tick rate 20 Hz nominal; under overload or population spikes the
  coordinator **dilates the tick** (EVE time-dilation, §3.1): T advances slower in
  the log, consistency is preserved exactly, responsiveness degrades gracefully and
  honestly.
- Formally, the whole real-time layer is optimistic PDES with bounded rollback depth
  (one tick horizon locally; one receipt on view change; one checkpoint on proven
  fraud) — a mature literature exists for every knob (§3.4).

#### 4.4.6 Static zones first; cross-zone interactions

Zone boundaries are **static lattice facts** (§4.3.3) — deliberately so: the state of
the art's hardest open problem is *dynamic* authority handoff across mobile
boundaries (Star Citizen ships static server meshing before dynamic for exactly this
reason — §3.4). Locked consequences:

- A player near a border is a member of one zone (their position's), observed by the
  neighbour (Ring 1). An interaction that spans the border (shooting across it,
  a collapse whose flood crosses it) is sequenced by the **owner of the affected
  cell/object**, with the deterministic tie-break "lower zone key sequences first"
  when one event touches both (the touched-cell set of a mutation is computable
  before application — `StructuralSolver._region` bounds it, `structural_solver.gd:145`).
- Player handoff = `Exit(Z)` attestation + `Enter(Z')` (presence chain, §4.2) +
  transfer of the player record via a signed **handoff receipt** both coordinators
  countersign — the entity-authority-migration pattern, in its easy (static-boundary)
  form.
- Cross-coordinator timestamps (which neighbour event happened "before" which local
  tick, for Ring-1 rendering and border sequencing) use **hybrid logical clocks**
  (§3.3) — O(1), monotonic, NTP-drift-tolerant; total order is *not* sought here
  (causal suffices in real time; total order exists only at the ledger rung — §4.7).
- Dynamic sub-zone splitting under crowding (§4.3.4) is therefore the design's
  riskiest moving part and gets its own pass (§8.4) — the roadmap ships static-only
  first (Phase M2), mirroring the industry's sequencing.

#### 4.4.7 The uncontested fast path (flagged design, not consensus practice)

Most of a sandbox's life is *not* contested: one builder alone in a zone, or two
players building 100 m apart. For zones whose live peer set is provably
non-interacting (disjoint interaction auras for N consecutive ticks), the protocol
may relax to **causal broadcast of edits with per-cell last-writer-wins** semantics —
per-cell block place/remove is commutative/idempotent enough for CRDT-style merge —
escalating back to full sequencing the moment auras overlap or any contested-class
event (combat, pickup, trade) occurs. The escalation-on-aura-overlap shape has a real
pedigree: Baughman–Levine's **Asynchronous Synchronization** (§3.4) runs hosts fully
async and drops into (commit-reveal) lockstep *only* when players can interact —
"cheap most of the time, cryptographically fair exactly when it matters"; NEO (§3.4)
is the lower-latency ordering alternative for the contested moments. CAVEAT, honestly
flagged: the *CRDT half* ("per-cell LWW merge for the commutative subset") has thin
prior art and is reasoned from commutativity, not literature consensus (§3.3);
competitive state (health, contested inventory, who-got-there-first) is **never**
CRDT-merged. The fast path is an optimization gate (Phase M5+), not a foundation; the
foundation is the sequencer.

**Interface (sketch):**

```
Coord.submit(event_signed)                    # player -> coordinator
Coord.batch_stream() -> OrderedBatch          # coordinator -> all (seq channel)
Coord.receipt_round(root) -> Receipt          # co-signing
Coord.epoch() -> int                          # fencing check, every message
signal view_change(new_epoch, base_receipt)
signal proven_fault(evidence)                 # equivocation / invalid settle / censorship
```

**Reuses:** nothing directly — this layer is new, but thin: it moves signatures and
hashes, not game state. **Needs new:** all of it (GDScript protocol code).
**Unicity dependency:** none at runtime (identity tokens for reliability scores are
read-only inputs); buildable in Phase M1–M2 with static reputation.

### 4.5 MP4 — Proof & audit (the trustless layer)

What exactly is proven, to whom, when — and what it costs. The layer implements a
five-rung anti-cheat stack (the synthesis the state of the art converges on, §3.4),
each rung catching what the faster rung above it cannot:

| Rung | Mechanism | Timescale | Catches |
|---|---|---|---|
| 1 | deterministic validation + rewind clamp under fenced coordinator authority (§4.1.1, §4.4.5) | per tick | impossible inputs, kinematic cheats, favourable-past claims |
| 2 | commit-reveal escalation on aura overlap for contested interactions (§4.4.7, §8.4) | per interaction | look-ahead cheating in duels/trades |
| 3 | PeerReview-style signed, forward-secure, hash-chained logs (§4.4.1, §4.5.1) | continuous | equivocation, history tampering — attributable proof |
| 4 | optimistic re-execution + fraud proofs over the log (§4.5.3) — short in-zone dispute, longer checkpoint window | seconds → cadence | any state fiction, colluding zones |
| 5 | zk proofs, narrowly (§4.5.7) | checkpoint time (future) | hidden-info claims without disclosure |

#### 4.5.1 The simulation trace (the evidence format)

A zone **segment** = everything between two checkpoints:

```
Segment {
  base:      checkpoint token ref + state root R₀
  batches:   [OrderedBatch t=1..N]      # coordinator-signed hash chain (§4.4.1)
  events:    the full signed input events (player-signed payloads)
  receipts:  [Receipt every ~1s]        # peer co-signatures over state roots
  claims:    quantized movement claims  # part of events, listed for emphasis
  end_root:  R_N = Sim.state_root(replay(R₀-state, batches))
}
```

Properties: **append-only and tamper-evident** (hash chain + signatures — the
PeerReview construction, §3.3); **self-authenticating** (every byte attributable to a
key); **replayable** (MP0's `Sim.replay` maps it to exactly one end state);
**content-addressed** (serialized canonically, stored as IPFS DAG, its CID cited in
the checkpoint token — §4.6.2). Size envelope: 20 Hz × ~300 s × (a few dozen bytes of
batch header + event payloads); tens of KB to a few MB per segment depending on
activity — IPFS-appropriate, browser-holdable.

#### 4.5.2 Entry proof — "this location's state is legit" (MP-V5)

A player entering zone Z verifies, in order, spending only signature checks and one
aggregator round-trip:

1. **The base**: Z's location-token latest state — from a fog peer, a current
   occupant, or IPFS — with its **Aggregator inclusion proof** verified against a
   finalized SMT root (`.claude/reference/proof-system.md` "Proof Verification"), plus
   the endorsement co-signatures the checkpoint carries (§4.6.2). This proves: *this
   is the globally unique latest endorsed state of this place* (single-successor
   unicity + non-membership of any later transition).
2. **The live tail**: the current segment's batch chain from R₀ to now + the latest
   receipt. This proves: *the peers currently here agree on the current state, and
   it descends from the endorsed base by a signed, replayable path*.
3. **Optionally** (paranoid mode / high-stakes zones): spot re-execution of the tail
   or a random slice of it — the verifier has `Sim.replay` and the log; trust is a
   dial, not a leap.

The ZoneBundle the newcomer streams to materialize the world
(`zone_bundle.gd:1-30`) is verified against the per-region hashes inside the state
root (§4.1.3) — bytes from *anyone* are safe, because the root, not the sender, is
the authority. Cold zones degenerate to step 1 only: the checkpoint *is* the state
(MP-D2).

#### 4.5.3 Audits, endorsements, fraud proofs (optimistic verification)

The core loop — optimistic-rollup logic (§3.5) with sortition instead of staked
sequencer-watchers:

1. **Publish**: at checkpoint time the coordinator publishes the Segment to IPFS and
   broadcasts `{zone, epoch, R₀→R_N, segment CID}`.
2. **Availability attestation (MR3)**: the checkpoint candidate is valid only with
   k signatures of the form "I hold the full segment bytes for this CID" from
   endorsers/occupants. A coordinator that withholds data simply cannot checkpoint —
   the un-endorsed segment expires and rolls back. (This is the state-of-the-art
   lesson from rollups: fraud proofs are only as good as data availability, §3.5;
   here DA is enforced *before* acceptance, not assumed.)
3. **Audit**: sortition (§4.5.4) selects auditors, who fetch base + segment (via
   IPFS/fog — *not* from the auditee, preserving auditor anonymity until they
   publish), run `Sim.replay`, and compare `R_N`.
4. **Endorse**: match ⇒ signed endorsement `{zone, epoch, R_N, CID, sig}`. k-of-n
   endorsements ⇒ the checkpoint transition proceeds to MP5.
5. **Challenge window**: from publication until the *next* checkpoint is endorsed,
   **anyone** — auditor or not — may submit a **fraud proof**. Because the full log
   is available and replay is deterministic, a fraud proof is non-interactive and
   humiliatingly simple: `(segment CID, claimed R_N, correct R_N)` — any verifier
   replays and sees who lied. (Interactive bisection à la Arbitrum, §3.5, is the
   fallback only if segments ever get too big to replay outright; at zone scale they
   don't.) Special fast-path fraud proofs need no replay at all: **equivocation**
   (two signed batches, same (epoch, tick)) and **invalid settle** (§4.1.4 predicate
   violation) are checkable from two messages.
6. **Consequences**: proven fraud ⇒ the segment is void (rollback, §4.5.5), the
   culprit's identity token records the strike (slashing reputation/stake — §4.6.1),
   and the fraud proof itself is archived as evidence in the ledger record.

The security model is thereby the optimistic one: **safe if at least one honest
party audits within the window** — with sortition making "at least one honest
auditor" statistically overwhelming (below) and the open window making even a fully
bought committee unable to *safely* cheat (any latecomer can still void the segment
before it becomes a base for the next endorsed one; after that it is final — §4.7).

#### 4.5.4 Sortition, sybil resistance, collusion resistance

- **Eligibility**: auditor duty attaches to **identity tokens** (§4.2) that carry
  verifiable cost: an L1 coin spend at creation, account age × activity attested by
  prior endorsed checkpoints, and optionally an explicit stake balance. Sybils are
  therefore not free, and a sybil army's audit weight is bounded by its spend — the
  standard identity-cost answer (§3.5); pure social-graph defenses (SybilGuard-class)
  are noted and not relied on (§3.5).
- **Selection**: for checkpoint (zone Z, epoch e, height h), an identity is selected
  iff `H(sig_identity(seed)) < τ` where `seed = H(Z, e, root_h)` and `root_h` is the
  finalized L2/aggregator block reference at h — Algorand-style VRF sortition (§3.5):
  self-selecting (nobody can enumerate the committee in advance), non-gameable
  without forging the beacon, weight-adjustable via τ. The signature *is* the proof
  of selection, published only with the endorsement — auditors are anonymous until
  they speak (MP-V6's "anonymously, randomly cross-check"). Beacon caveat: an L2
  proposer has bounded bias on `root_h`; if analysis (§8.1) finds it material, the
  seed moves to an external verifiable beacon (drand-class, §3.5).
- **Committee math** (illustrative, to be locked in §8.1): with adversarial audit
  weight α = 0.2, committee n = 12, threshold k = 8: P(≥k adversarial) ≈ 10⁻⁵ per
  checkpoint; and even that residue is not safety-critical because of the open
  challenge window (one honest verifier suffices) — committees buy *liveness and
  latency*, the window buys *safety*.
- **Load**: an auditor replays ~5 min of one zone — seconds of CPU on the same WASM
  build (replay has no rendering, no vsync). Duty frequency per player scales as
  (zones × n) / population — a few audits per hour at plausible ratios; fog peers
  (§4.3.5) absorb duty for underpowered clients. **Incentives** — why accept duty at
  all — are a Unicity-economics dependency (fees/rewards on checkpoint transitions)
  and the top open question, §8.1.

#### 4.5.5 Checkpoints and rollback semantics

- **Cadence**: every 3–5 min per active zone (the MP-V7 bound), plus **exit
  checkpoints** (MP-D2), plus *event checkpoints* on demand (a player may pay to
  checkpoint early — e.g., after a major find — buying earlier finality for their
  gains).
- **Rollback triggers**: (a) endorsement quorum not reached by deadline (auditors
  unreachable, DA failure); (b) successful fraud proof; (c) unresolvable coordinator
  equivocation (§4.4.4). Effect: the zone token stays at the last endorsed
  checkpoint; peers reload from it (`Sim.load` of the checkpoint's ZoneChunks) and
  the segment's events are void. Player wall-clock loss: ≤ one cadence. This is the
  MP-V7 acceptance made mechanical.
- **The provisional-gains rule** (what makes rollback *safe*, not just possible):
  any state acquired inside a segment is **provisional** — usable in-zone
  immediately, but not exportable (not tradable through MP5, not carriable through a
  zone exit that outruns its covering checkpoint) until the covering checkpoint is
  endorsed. Exit therefore forces MP-D2's exit checkpoint: you *leave with* endorsed
  state or you leave without the tail. No provisional fact can contaminate the
  endorsed universe — rollback never cascades across zones.
- **Trades bypass the window entirely**: transferring an item to another player is a
  **native Unicity token transfer** (predicate swap, ~1 s L2 finality —
  `.claude/reference/state-transition-sdk.md`, `.claude/docs/architecture.md`), not a
  zone-sim event. World simulation is optimistic; asset motion is ledger-native.
  This split is the design's quiet keystone: the highest-value cheat targets (item
  ownership) never depend on zone consensus at all.

#### 4.5.6 The meet proof — "prove your character is honest" (MP-V5)

When players meet (enter mutual interaction range), each presents, and the other
verifies in <1 s of signature work:

1. **Character base**: character-token latest checkpoint + inclusion proof (health,
   stats, skills as of the last endorsement — same machinery as a zone, the player
   being a mobile "location" of themselves, §4.6.1).
2. **Presence chain** since that checkpoint (§4.2): co-signed Enter/Exit records,
   adjacency + speed-cap validated — *not teleported*.
3. **Inventory**: items are tokens; each shown item = token id + inclusion proof of
   its latest state naming this character's predicate as owner. Nothing to
   re-execute: **minting from nowhere is impossible** because item genesis requires
   the item-class predicate (crafting/mining events inside endorsed checkpoints —
   §4.6.3), and **duplication is impossible** because the aggregator enforces single
   succession per token state (the unicity property, §2.2).
4. **Live vitals**: current health/effects = character state root in the current
   zone's receipt chain — co-signed by the zone, fraud-provable like everything
   else.

Verification degrades gracefully by stakes: a passerby checks 1+3's signatures; a
duel or high-value trade checks all four plus spot-replays the tail.

**Interface (sketch):**

```
Proof.entry(zone) -> {ckpt_token, incl_proof, endorsements, tail} ; verify_entry(...)
Proof.meet(peer) -> {char_ckpt, presence_chain, inventory_proofs, vitals} ; verify_meet(...)
Audit.duty(seed) -> Option<AuditTask>          # sortition self-check
Audit.replay(task) -> Endorsement | FraudProof
Fraud.submit(evidence) -> LedgerRecord         # anyone, anytime in window
```

**Reuses:** MP0 replay, MP1 keys/presence, ZoneBundle. **Needs new:** trace/segment
formats, sortition, endorsement/fraud protocol. **Unicity dependency:** inclusion
proofs + non-membership (exists — `.claude/reference/aggregator-go.md`); identity-cost
and incentive mechanics (missing — §7 M5, §8.1).

### 4.6 MP5 — Unicity persistence (the hard-consensus layer)

How a game object/location becomes a UXF token, how a checkpoint is a state
transition, and how the Aggregator anchors "latest state" — the MP-V6/MP-V8
requirements made concrete against the SDK that exists and the gaps that don't.

#### 4.6.1 The token schema: everything is an entity token

Four entity classes, one shape — the Sphere **profile-token pattern** (a mutable
document as a token whose latest version the Aggregator references, §2.2) generalized:

```
GameEntityToken (UXF container; fields per TxfStorageDataBase, txf-format.md) {
  tokenId:        H(universe_id, entity_class, entity_key)
                  # LocationToken:  entity_key = (body, face, zone_uv)   — §4.3.3
                  # CharacterToken: entity_key = character guid
                  # ItemToken:      entity_key = item guid
                  # IdentityToken:  entity_key = player master pubkey
  ownerPredicate: # Location: the ENDORSEMENT predicate (k-of-n, see gap below)
                  # Character/Item: the player's (masked or unmasked) predicate
                  # Identity: unmasked player predicate
  data: {
    state_root:   32-byte Merkle root (§4.1.3)          # THE commitment
    T:            universal time of the checkpoint       # COSMOS §1.3
    epoch:        coordinator epoch (fencing, §4.4.3)
    build_hash:   determinism epoch (§4.1.2 D1)
    evidence: {   segment_cid, state_cid (ZoneBundle), endorsements[] }   # IPFS CIDs
    class_data:   # Item: item class + genesis event ref; Character: vitals digest;
                  # Location: zone extent + parent body; Identity: cost proof, nametag,
                  # reliability record, strikes (§4.5.3.6)
  }
  proofChain:     [inclusion proofs]                     # the auditable history
}
```

- **The universe is content-addressed all the way down**: `state_root` commits the
  canonical state; `segment_cid`/`state_cid` name the bytes on IPFS; the token
  commits the roots; the Aggregator commits the token transitions; L2 finalizes; L1
  anchors. Only 32-byte roots and small metadata ever touch consensus — the DA
  lesson from rollup economics (bulk data is ~all of the cost; §3.5) applied by
  construction, and the Dark Forest persistence shape (commitments on-ledger, raw
  state off-ledger; §3.5).
- **"One story" is the proof chain.** TXF proof chains are append-only and
  monotonically growing (`.claude/reference/txf-format.md`); the history of a place
  *is* its LocationToken's chain of endorsed roots. Two players comparing memories
  of an event are comparing inclusion proofs against the same SMT roots — MP-V2
  discharged by data structure rather than by protocol goodwill.

#### 4.6.2 Checkpoint = `update` state transition (and the predicate gap)

A checkpoint is not a new mechanism — it is TXF's existing `update(newData)`
transition (`.claude/reference/txf-format.md` "Operations") on the entity token,
whose commitment goes to the Aggregator via `certification_request` and whose
inclusion proof returns via `get_inclusion_proof`
(`.claude/reference/aggregator-go.md`), appended to the proof chain. What TXF does
**not** have today is the authorization rule this design needs:

> **SDK GAP (hard dependency, gates Phase M4):** an **endorsement predicate** — a
> location/character checkpoint transition is valid iff it carries k-of-n signatures
> from identities provably sortition-selected for (zone, epoch, seed) (§4.5.4), plus
> the coordinator's signature and the DA attestations. Today's predicates are
> single-key masked/unmasked (`.claude/reference/state-transition-sdk.md`). Whether
> this lands as a native predicate type, a multi-sig predicate composition, or an
> application-level validation convention over an unmasked "zone authority" key set
> is a Unicity-side design decision this document consumes, not makes (§8.1).

The **latest-state pointer** (MP-V8) is then exactly the Sphere profile lookup:
resolve entity token → latest commitment in the Aggregator → inclusion proof (+
non-membership of any successor) → `evidence.state_cid` → IPFS fetch → verify bytes
against `state_root`. Note the division of labour, with measured justification:
**IPNS is not in the hot path anywhere** — production IPNS resolution is seconds at
p50 (§3.5), unusable per-interaction; the Aggregator (a ~1 s-finality indexed
lookup) is the mutable pointer, Nostr events are the push-fast-path, IPNS at most
labels slow-changing snapshot directories.

#### 4.6.3 The zone-rollup model: objects live inside zone checkpoints

Tokenizing "all objects AND locations" (MP-V6) does *not* mean one ledger transition
per block broken — that would be absurd (and unnecessary: the state root already
commits every cell). Locked model, directly the ephemeral-rollup/zone-sequencer
pattern (MagicBlock's per-region runtime settling to a base chain is the closest
shipped precedent — §3.5):

- **The zone is the rollup.** All in-zone object state (edits, settled debris,
  dropped items, machine states) is committed *inside* the LocationToken's
  `state_root`. In-zone object identity is a stable guid in the state tree — a
  Merkle *path*, not a ledger row.
- **An object graduates to its own ItemToken at the boundary**: picked up into an
  inventory (→ mint/update ItemToken owned by the character's predicate, citing the
  Merkle proof of the object's presence in the endorsed zone root it came from — the
  rollup *withdrawal* pattern, §3.5), traded (native transfer, §4.5.5), or carried
  across zones. Symmetrically, dropping an item *deposits* it back into zone state
  (ItemToken parked/burned into the zone root).
- **Item genesis** (the mint-from-nowhere killer): an ItemToken can only be created
  citing a **provenance event** inside an endorsed checkpoint — the mining/crafting
  event at (zone, tick), whose validity auditors already re-executed. The genesis
  predicate refuses anything else. Minting a diamond therefore requires corrupting
  an endorsed checkpoint *and* surviving its challenge window — the full weight of
  §4.5, not a client-side check.
- **CharacterTokens are mobile zones of themselves**: same checkpoint machinery,
  the endorsers being the zones they pass through (receipts co-sign the player
  records inside the zone root; the character checkpoint cites them).

#### 4.6.4 Storage & transport reuse

| Need | Mechanism | Status |
|---|---|---|
| Checkpoint payloads (ZoneBundle state, segment logs, endorsement sets) | IPFS, CID-referenced from token `data` — "large payloads on IPFS, referenced by CID in the TXF data field" is already the documented pattern (`.claude/reference/transport-protocols.md`) | exists |
| Latest-state pointer | Aggregator SMT + inclusion/non-membership proofs (MP-V8) | exists (SDK query API) |
| Fast-path notification (checkpoint minted, global event) | Nostr: NIP-29 zone/universe groups; NIP-17 DMs for targeted proofs | exists |
| Pinning / archival | fog peers (§4.3.5) + occupants pin their own zones; incentive design §8.1 | new (policy, not tech) |
| The game ↔ sphere-sdk bridge | sphere-sdk is TypeScript; the web export calls it in-page via Godot's `JavaScriptBridge` (the game is already a browser app — the wallet lives beside it, not inside WASM) | **new — gates M4** |

#### 4.6.5 Throughput & cadence honesty

Back-of-envelope at target scale (5,000 players, ~2,000 concurrently active zones,
4-min cadence): zone checkpoints ≈ 8/s; character checkpoints (5 min) ≈ 17/s; item
boundary events, trades, presence anchors — generously ≈ 50/s total. Against the
Aggregator's documented **1M+ commits/sec ingestion** (`.claude/reference/aggregator-go.md`)
this is noise: **ledger throughput is a non-problem by ~4 orders of magnitude** (the
Merkle-batched-roots pattern is precisely what the SMT is for — §3.5). The *actual*
bottlenecks, in order: (1) endorsement latency — sortition + fetch + replay + k
signatures within the cadence window (§4.5.4's load math; the binding constraint on
cadence, not the ledger); (2) IPFS publish/pin latency for segment payloads
(seconds; overlapped with the endorsement round); (3) the browser's signature
throughput at meet-proof bursts (hundreds of secp256k1 verifies/s in WASM — fine,
but budgeted, §8.2). Fees/economics per transition: unknown — Unicity dependency
(§8.1).

#### 4.6.6 Global events & LOD consistency (MP-V3)

The undisturbed universe needs no messages at all: worldgen and the ephemeris are
pure functions of (SEED, T) (§2.1; the deterministic-lockstep "ephemeris pattern" —
zero traffic for anything that is a function of shared constants and shared time,
§3.4). Disturbances are events; the design makes *global* ones ledger-facts:

- **A cosmic event is a state transition on the affected body's own token** (the
  Moon has a LocationToken tree up to its body root). "The Moon explodes" =
  an endorsed transition on the Moon body token: `{event_class, T_event,
  parameters, evidence}`. Total order for the (rare) global events comes free from
  the ledger — aggregator block height orders them (`.claude/reference/aggregator-go.md`
  "Block height is monotonically increasing"); no gossip ordering protocol is
  needed at planetary scope because the rate is ~zero and the latency budget is
  minutes.
- **Propagation** is push + lazy pull: a Nostr universe-group broadcast (fast path,
  seconds), and — the backstop that guarantees MP-V3 — every client's LOD layer
  *subscribes its render inputs to token state*: the B3 celestial band (COSMOS
  §4.5) renders the Moon from `(ephemeris(T), moon_token.latest_events)`. A client
  that missed every broadcast still shows the explosion the next time it verifies
  the Moon token (and any co-located peer's entry proof forces freshness). Every
  observer sees the same event at the same T because the *event record* carries
  T_event and the ephemeris is shared — observers render one fact, at their own
  LOD.
- **Who simulates a cosmic event** (who is its "zone coordinator") and how its
  endorsement committee is drawn for a body nobody stands on — flagged as the §8.7
  design pass. Honestly noted: **no shipped game anchors global world events in a
  ledger; this element is novel territory** (§3.4 — the survey found no credible
  precedent), which is exactly why it leans on the most conservative machinery in
  the design (ordinary token transitions + the ordinary endorsement pipeline).

**Reuses:** the whole Unicity stack as documented; ZoneBundle bytes as checkpoint
payloads. **Needs new:** entity-token schema conventions, JavaScriptBridge SDK glue.
**Unicity dependencies (the gate list):** UXF container spec; endorsement predicate;
JS-bridge-friendly sphere-sdk build; genesis/provenance predicate for items;
fee/incentive model; (nice-to-have) batch `certification_request`.

### 4.7 The two-level consensus, made precise

The full lifecycle of a zone's state, as a state machine — this diagram *is* the
MP-V7 requirement:

```mermaid
stateDiagram-v2
    [*] --> LocalSim
    LocalSim: LOCAL SIM (per peer) — predict + render; MP0 step on sequenced ticks
    LocalSim --> Sequenced: inputs signed to coordinator; OrderedBatch(epoch, tick) applied
    Sequenced: SEQUENCED (real-time consensus) — all co-located peers identical state
    Sequenced --> CoSigned: ~1 s receipt round; peers co-sign state root
    CoSigned: CO-SIGNED RECEIPT — equivocation now provable
    CoSigned --> Sequenced: next ticks
    CoSigned --> Published: cadence / last-exit / on-demand; segment to IPFS (CID)
    Published: PUBLISHED SEGMENT — DA attestations required
    Published --> Audited: sortition auditors replay Sim.replay(base, log)
    Audited --> Endorsed: k-of-n roots match
    Endorsed: ENDORSED — challenge window still open
    Endorsed --> Checkpointed: update() on LocationToken; certification_request; inclusion proof
    Checkpointed: CHECKPOINTED (Unicity) — globally unique latest state (MP-V8)
    Checkpointed --> Anchored: L2 root to L1 PoW (~2 min)
    Anchored: ANCHORED — rewrite needs PoW majority
    Anchored --> LocalSim: new base for next segment

    Sequenced --> ViewChange: lease expiry / failure / fault proof
    ViewChange: VIEW CHANGE (epoch+1) — resume from last co-signed receipt
    ViewChange --> Sequenced: 1-2 s stall, no rollback
    ViewChange --> Rollback: equivocation with no honest suffix
    Published --> Rollback: DA failure / quorum missed by deadline
    Endorsed --> Rollback: fraud proof in window
    Rollback: ROLLBACK — reload last endorsed checkpoint; provisional gains void (max one cadence lost)
    Rollback --> LocalSim
```

The two consensus levels in one sentence each:

- **REAL-TIME (MP3):** *a leased, fenced, QoS-elected sequencer orders signed inputs
  over a deterministic replicated simulation* — agreement is instant and cheap
  because it is agreement about *order only*; its honesty is not assumed but
  **accounted for** (tamper-evident log + receipts), with damage bounded by the
  checkpoint cadence. The coordinator is explicitly a *trust assumption with
  permissionless rotation and a fraud-proof escape hatch* — never presented as
  trustless-by-default (the shared-sequencer lesson, §3.5).
- **HISTORICAL (MP4+MP5):** *sortition-audited, endorsement-gated, fraud-provable
  checkpoints as immutable token transitions with a global uniqueness proof* — slow,
  final, and the only thing other players' universes ever build on.

Real-time consensus can be wrong for minutes; historical consensus cannot be wrong
without a successful attack on sortition *and* an empty challenge window *and* (for
rewriting, after anchoring) L1 PoW. The provisional-gains rule (§4.5.5) is the seal
between the levels: nothing crosses from the fast world to the permanent one except
through an endorsed checkpoint.

---

## 5. What is trusted vs proven, at each distance and timescale

The honest ladder (compare COSMOS §5's faked-vs-simulated ladder — same discipline,
applied to trust):

| Scope | Consistency mechanism | What a cheater could fake | For how long | Caught by |
|---|---|---|---|---|
| Own screen (prediction) | none — cosmetic | anything, locally | until next tick | sequenced reconcile |
| Zone, live (Ring 0) | sequenced ticks over deterministic sim | nothing unilaterally; coordinator can censor/order-bias | ≤ receipt (~1 s) for equivocation; ≤ cadence for the rest | receipts, fault proofs, view change |
| Zone, recent past | co-signed receipts + published segment | a *colluding whole zone* can co-sign fiction | ≤ challenge window (~one cadence) | sortition audit + anyone's fraud proof |
| Zone, endorsed history | checkpoint token + inclusion proof | nothing, absent a corrupted committee AND silent window | — | (residual risk quantified §4.5.4) |
| Anchored history | L1 PoW anchor | nothing below a 51% attack on `alpha` | — | `.claude/reference/security-model.md` |
| Neighbour zones (Ring 1) | receipt stream + HLC-timestamped events | stale by one receipt | ~1 s | next receipt |
| Far world (Ring 2+) | checkpoint tokens on observation | nothing (you verify on entry) | — | entry proof |
| The sky (LOD) | ephemeris(T) + body-token event log | nothing (pure function + ledger facts) | — | inclusion proofs |
| Other players met | meet proof (§4.5.6) | un-checkpointed very-recent tail | ≤ cadence | their next checkpoint or your challenge |
| Items/inventory | native tokens, single-successor | **nothing — mint/dup structurally impossible** | — | aggregator unicity property |

---

## 6. Threat model

"Trustless" is a claim about this table. Vectors ordered roughly by gravity; every
mitigation names its layer.

| # | Attack | Vector | Mitigation (layer) | Residual risk |
|---|---|---|---|---|
| T1 | **Item minting** | client fabricates a rare item | items are tokens; genesis requires a provenance event inside an *endorsed* checkpoint (§4.6.3); client-side state is never authority | corrupt an endorsement committee AND survive the challenge window (§4.5.4 math) |
| T2 | **Item duplication** | replay/spend a token state twice | Aggregator single-successor (unicity) property — second transition from the same state is rejected/provably conflicting (§2.2, MP5) | none identified at design level |
| T3 | **Teleportation** | jump across the map between observations | presence chain: co-signed Enter/Exit, adjacency + speed caps from the COSMOS velocity table (§4.2); movement claims validated per tick in-zone (§4.1.1) | unwitnessed wilderness segments are self-signed — position inside them is soft, but endpoints + caps still bind (and retroactive fraud proofs apply) |
| T4 | **Speed/fly/clip hacks** | impossible kinematics in-zone | per-tick validity predicate over `blocked`/`floor_under` (§4.1.1) — every peer and auditor checks; invalid ⇒ deterministic rejection | none in sequenced zones; solo zones caught at audit |
| T5 | **Stat/health forgery** | inflate vitals | vitals are deterministic state (§4.1.1) in co-signed roots + character checkpoints; meet proof verifies (§4.5.6) | fiction inside an un-endorsed tail; expires with the window |
| T6 | **History rewriting** | re-tell the past | proof chains append-only; roots in SMT; L1 anchoring (§4.6.1, §2.2) | 51% on L1 / 2/3 on L2 — inherited Unicity assumptions (`.claude/reference/security-model.md`) |
| T7 | **Coordinator censorship** | drop a victim's inputs | victim sees own events missing from signed batches ⇒ complaint + re-election (§4.4.1); persistent censorship = QoS/reliability strike | brief unfairness (seconds–minutes); bounded, attributable |
| T8 | **Coordinator ordering bias** | favourable intra-tick ordering | order is visible in signed batches; statistical bias is auditable; commit-reveal ordering for high-stakes contested events is the §8.4 escalation (Baughman-Levine, §3.4) | mild, detectable; an economics-grade fix is deferred |
| T9 | **Coordinator equivocation** | different batches to different peers | two signatures = transferable fraud proof (§4.4.1); fencing epochs prevent stale-leader split-brain (§4.4.3) | ≤ one receipt of divergence, then view change/rollback |
| T10 | **Whole-zone collusion** | everyone present co-signs fiction (the "empty forest" attack) | sortition auditors are *outsiders* (§4.5.4); provisional-gains rule quarantines the fiction until endorsement (§4.5.5) | colluders can lie *to each other* for one window — self-harm only; MP-V7 explicitly accepts this |
| T11 | **Endorsement sybil** | flood the auditor pool | identity cost (L1 spend/age/stake) weights sortition (§4.5.4); keypairs alone are worthless (SybilLimit caveat honoured, §3.5) | audit weight ∝ money — quantified, not eliminated; §8.1 |
| T12 | **Bought committee** | bribe the k endorsers | committee unpredictable (VRF-style, revealed only at endorsement); open challenge window means one honest replayer voids the segment (Dave/PRT "one honest validator" model, §3.5); endorser strikes are on-ledger (§4.5.3) | finality after an *unchallenged* corrupt window; probability §4.5.4 |
| T13 | **Data withholding** | checkpoint without releasing the log | DA attestations are a validity condition (§4.5.3.2); no data ⇒ no checkpoint ⇒ rollback, harming the withholder | griefing-by-rollback (see T16) |
| T14 | **Replay attacks** | re-send old signed events | events carry (zone, epoch, tick); batches hash-chain; tokens single-successor (T2) | none identified |
| T15 | **Eclipse attacks** | isolate a victim's view of the network | multi-relay Nostr + aggregator as truth: an eclipsed client can be *starved* (no freshness) but not *fed forgeries* — every fact it accepts carries inclusion proofs against finalized roots (§4.3.2); trusted-root freshness is the light-client dependency §8.6 | denial of freshness/service; not a consistency break |
| T16 | **Rollback griefing** | deliberately fail endorsement (DoS auditors, withhold DA) to void others' progress | exit checkpoints minimize exposure (MP-D2); on-demand checkpoints let players buy finality (§4.5.5); attacker cost > victim cost in most shapes (attacker also loses their window) | the nastiest residual — a dedicated griefing analysis is §8.1 |
| T17 | **Identity theft / session abuse** | steal a session key | session certs are scoped + expiring + revocable on the identity token; realistic model is on-chain revocation + policy co-signing, not perfect trustlessness (§4.2, §3.5) | in-window abuse of a stolen *session*, master key safe |
| T18 | **Time forgery** | lie about T | T is consensus data (D5): checkpoint T monotone per token, cross-checked against aggregator block height; zone T advances only via sequenced ticks | skew within one cadence; bounded by anchoring |
| T19 | **Version-skew / determinism attacks** | exploit build differences to force desyncs or contested audits | build hash in handshake + trace + token (D1); auditors replay on the recorded build; mismatched peers can't join | zero-day nondeterminism in the engine itself → MR1 discipline + M0 CI |
| T20 | **Input-level cheating** (aimbot, macro, ESP on *visible* state) | perfect play within legal inputs | **out of scope — not cryptographically preventable in an open client.** The protocol guarantees *state* integrity, not *human* inputs. Community/social layers (reputation, servers-of-friends zone policies) are the honest answer | permanent; stated openly (§0 qualification b) |
| T21 | **Privacy leakage** | presence chains + audit logs reveal player movement | masked predicates hide token ownership (`.claude/reference/state-transition-sdk.md`); presence records can commit to zones via salted hashes revealed only pairwise (§8.6) | audit logs necessarily reveal in-zone actions to auditors; fundamental tension, §8.6 |

## 7. Phased roadmap — single-player to trustless shared universe

**NOTHING IN THIS ROADMAP IS IMPLEMENTED NOW.** Phases M0–M3 have no Unicity
dependency and *could* start early; M4+ is **hard-gated on Sphere SDK + UXF
readiness**, and the programme is sequenced so that by the time the gate opens, the
protocol beneath it is already proven. Each phase is independently demoable on the
live web deploy (the DESIGN §7 gate outranks feature depth — `docs/DESIGN.md:74`),
lands on its own branch tree, and extends `godot/src/tools/verify_feature.gd` with
its invariants. Effort is in focused agent-weeks (aw), calibrated as in COSMOS §6;
these are Opus-implementation phases with named Fable design passes (§8) at the
risky joints.

### Phase M0 — The deterministic substrate (~2–3 aw) — no Unicity deps
Formalize tick/inputs (§4.1.1), canonical serialization + state roots (§4.1.3, incl.
the ZoneChunk canonical-palette change), the RNG policy (D4), record/replay
(`Sim.replay`), and desync detection. Wire a determinism CI: record a fuzzed session,
replay it headless and in a second browser, pin the state-root sequence in
`verify_feature.gd`.
**Demo:** a recorded solo session replays bit-identically on a different machine;
the HUD shows the live state root.
**Key risk (MR1):** discovering engine nondeterminism (threaded reads, iteration
order). **Exit gate:** N-hour fuzz replay equality across two browser families +
headless.

### Phase M1 — Two players, one zone (~3–4 aw) — public Nostr relays only
WebRTC DataChannels with Nostr NIP-17 signaling (§4.3.1); fixed coordinator (first
arrival); sequenced ticks + movement claims + rewind clamp (§4.4.5); join via
ZoneBundle streaming verified against state roots; ~1 s receipt co-signing.
**Demo (the flagship early demo):** two browsers on the live site dig, build, and
chop trees in one world; both see identical collapses; state roots match on screen.
**Key risk:** browser realities — tab throttling, DataChannel buffer bloat, NAT
failures (fallback path: peer-relay hop).

### Phase M2 — Election, migration, many players, many zones (~3–5 aw)
QoS records + deterministic ranking (§4.4.2); leases + fencing epochs (§4.4.3);
view change (§4.4.4); SWIM+Lifeguard membership; the static zone partition + Ring-1
neighbour streams + cross-zone handoff receipts (§4.4.6); star topology with the
coordinator as serverless SFU (§4.3.4).
**Demo:** 8–16 players across 3+ zones; the coordinator's tab is killed mid-fight
and play resumes in ~2 s without rollback; players cross zone borders seamlessly.
**Exit gate:** measured star ceiling + view-change stall on residential uplinks.

### Phase M3 — Accountability without a ledger (~2–3 aw)
Signed hash-chained traces + forward-secure sealing (§4.4.1, §4.5.1); segment
publication (any HTTP/fog store pre-IPFS); equivocation + invalid-settle fast fraud
proofs; full replay audits runnable manually; strikes recorded locally.
**Demo:** a deliberately-cheating modified client (teleport, item spawn, forged
batch) is deterministically rejected in-zone AND yields a transferable, third-party-
verifiable fraud proof.
**Key risk:** none structural — this phase is the protocol's proving ground while
Unicity matures.

### Phase M4 — Unicity integration (~4–6 aw) — **THE GATED PHASE**
Entity-token schema (§4.6.1); checkpoints as `update` transitions with inclusion
proofs (§4.6.2); the Aggregator latest-state pointer + non-membership freshness;
IPFS payload storage/pinning; identity tokens + session certificates (§4.2);
sphere-sdk in-page via `JavaScriptBridge`.
**Unicity prerequisites (hard):** UXF container spec final; a browser-bundled
sphere-sdk with the provider set the game needs (Nostr transport, IPFS storage,
aggregator proofs — `.claude/reference/sphere-sdk.md`); the **endorsement predicate**
or an interim k-of-n validation convention (§4.6.2); a fee model tolerable at game
cadence.
**Demo:** wipe the browser, rejoin: the world you built comes back from the ledger +
IPFS alone, every zone verified by inclusion proof; occupant-co-signed checkpoints
(interim trust: occupants, not yet sortition).
**Key risk:** SDK integration surface (WASM↔JS marshalling, key custody UX).

### Phase M5 — Endorsement consensus, entry/meet proofs (~4–6 aw)
Sortition + anonymous audits + endorsement quorum + challenge window + rollback
machinery + provisional-gains rule (§4.5.3–4.5.5); presence chains (§4.2); entry and
meet proofs (§4.5.2, §4.5.6); item genesis/withdrawal predicates (§4.6.3); the
uncontested fast path (§4.4.7) if measurements demand it.
**Unicity prerequisites:** identity-cost mechanics (creation spend/stake), the
incentive/fee flow for auditors (§8.1's output), non-membership proof API surfaced
in the SDK.
**Demo (the trustless flagship):** a colluding 3-player zone co-signs a minted
diamond; an outside sortition auditor replays, files the fraud proof, the segment
rolls back on camera — and a legitimately-mined diamond transfers between players in
~1 s as a native token.
**Key risk (MR2):** endorsement economics — this phase does not start before the
§8.1 Fable pass lands.

### Phase M6 — Global events, LOD fabric, fog tier, scale (~4+ aw, open-ended)
Cosmic-event tokens + LOD render subscription (§4.6.6); the gossip fabric for
universe-scale events; the fog-peer image (headless export + TURN + pinning +
standing-auditor duty — reusing the `docker/` toolchain); dynamic zone subdivision +
tick dilation under crowding (§4.3.4, §8.4); zone keys gaining COSMOS body/face
dimensions as the planets ship (COSMOS §4.6).
**Unicity prerequisites:** none new beyond M5 (volume only).
**Demo:** a scheduled comet-impact event: hundreds of players across dozens of zones
and LOD rings all witness the same impact at the same T; the crater is an endorsed
fact forever.
**Key risk:** emergent load shapes (mass gatherings) — mitigated by dilation +
subdivision, measured honestly.

Dependency shape: M0 → M1 → M2 → M3 → **[Sphere-SDK/UXF gate]** → M4 → M5 → M6,
with M3 overlappable into M2, and the §8 design passes running ahead of their
consuming phases. The COSMOS roadmap (COSMOS §6) proceeds independently; the two
merge at M6 (multi-body zones) — and COSMOS Phase 6 already names "multiplayer
groundwork (shared T + edit logs)" as its endpoint, which is exactly M0's substrate.

---

## 8. Open questions — where the deeper, dedicated design passes go

This document fixes the shape; each item below is a scoped follow-up (Fable-class
where marked) that must not change the layer interfaces without amending this doc.

1. **[MP4/MP5, Fable] The endorsement-economics pass.** Auditor incentives (who pays,
   in what, per what), identity-creation cost calibration, stake/slash amounts,
   committee size/threshold vs adversarial-weight curves, beacon-bias analysis (L2
   proposer influence on the sortition seed vs external drand), rollback-griefing
   economics (T16), and pinning incentives. *Blocks Phase M5.* This is also where
   the Unicity fee model becomes a design input — coordinate with the Unicity team.
2. **[MP0] The canonicalization pass.** Exact canonical serialization of every state
   component (ZoneChunk palette ordering — today first-seen, history-dependent;
   object/player record layout; Merkle tree arity and domain separation), hash
   function choices (SHA-256 to match Unicity — `.claude/reference/crypto-primitives.md`),
   and the state-root performance budget. *Blocks Phase M0's exit gate.*
3. **[MP0] Deterministic debris.** Evaluate a fixed-point deterministic mini-solver
   for consensus-relevant loose bodies vs the locked settle-event model (§4.1.4) —
   the settle model is sound but surrenders mid-flight interactions (catching a
   falling block) to cosmetics; decide whether gameplay ever needs better.
4. **[MP3, Fable] The contested-interaction pass.** Commit-reveal escalation details
   on aura overlap (§4.4.7): reveal deadlines vs tick budget, NEO-style pipelined
   ordering, fairness under asymmetric RTT to the coordinator, and the dynamic
   sub-zone split/merge protocol (§4.3.4) — the design's hardest moving part
   (the industry's too, §3.4).
5. **[MP2] The fog-peer pass.** The headless fog build (reuse `docker/engine`
   toolchain), TURN provisioning/rotation, WebTransport for client↔fog hops,
   pinning quotas, standing-auditor duty cycles, and whether fog peers may
   coordinate *empty* zones (currently: no authority at all).
6. **[MP1/MP4] The privacy pass.** Masked-predicate usage across entity classes;
   presence-chain zone commitments (salted hashes, selective disclosure);
   audit-disclosure minimization (auditors necessarily see in-zone actions); the
   light-client problem — how a browser learns fresh finalized SMT roots without
   trusting one endpoint (multi-source root fetching; T15's residual).
7. **[MP5, Fable] The cosmic-event authority pass.** Who simulates and who endorses
   a body-scale event with no occupants (§4.6.6) — candidate: sortition committee
   over the body token itself with fog-peer execution; flagged novel territory with
   no industry precedent (§3.4).
8. **[MP0 × COSMOS] The shared-time conflict.** COSMOS Phase 4's **time-warp**
   (advance T faster when all-railed, COSMOS §1.3/§6) is **incompatible with a
   shared universe** — one player's warp would fork T, violating MP-V2. Options for
   the joint pass: warp only in solo/private universes; warp as *prediction
   rendering* (T never moves faster, the map view extrapolates); or scheduled
   universe-wide warp epochs as ledger events. Also here: the COSMOS R4 determinism
   pass (own minimax trig) becomes mandatory for any native-build *auditor* (§4.1.2
   D1) — the two documents' determinism work merges into one kernel.
9. **[Product] Versioning & governance.** Determinism-epoch migration UX (D1),
   old-build archival responsibility (fog tier), protocol-parameter governance
   (cadence, committee sizes, speed caps — who changes them, recorded where; the
   natural answer is a universe-genesis token whose data is the parameter set,
   updated by explicit governed transitions), and the universe-genesis ceremony
   (SEED, `terrain_config.gd:30`, becomes a public constant of the genesis token).

---

## 9. Annotated sources

Inline URLs live in §3 next to their lessons; this index groups the load-bearing
ones. Peer-research verification status is preserved: items marked ⚑ were
corroborated from multiple secondary sources but their primary PDF/page did not
render during this research session.

**P2P netcode & authority**
- Bettner & Terrano — [1500 Archers on a 28.8 (AoE lockstep)](https://www.gamedeveloper.com/programming/1500-archers-on-a-28-8-network-programming-in-age-of-empires-and-beyond)
- [GGPO](https://www.ggpo.net/) / [source](https://github.com/pond3r/ggpo); Gaffer On Games — [Deterministic Lockstep](https://gafferongames.com/post/deterministic_lockstep/), [Floating Point Determinism](https://gafferongames.com/post/floating_point_determinism/)
- [Factorio Multiplayer (wiki)](https://wiki.factorio.com/Multiplayer) — shipped large-N lockstep + state hashing
- [Croquet/Multisynq](https://croquet.io/) — replicated deterministic VMs + ordering-only reflectors
- Bungie — [Shared World Shooter (GDC 2015, Destiny P2P + host migration)](https://www.gdcvault.com/play/1022247/Shared-World-Shooter-Destiny-s)
- [Worlds Adrift closure FAQ](https://worldsadrift.com/blog/worlds-adrift-closure-faq/) / [SpatialOS docs](https://documentation.improbable.io/spatialos-overview/docs); [Dual Universe dev blogs](https://www.dualuniverse.game/news/dev-blogs); [EVE time dilation](https://www.eveonline.com/news/view/introducing-time-dilation-tidi)
- Commercial authority models: [Photon Quantum](https://doc.photonengine.com/quantum/current/getting-started/quantum-intro), [Fusion](https://doc.photonengine.com/fusion/current/getting-started/fusion-introduction), [Nakama](https://heroiclabs.com/nakama/), [Colyseus](https://colyseus.io/), [Mirror](https://mirror-networking.com/), [FishNet](https://fish-networking.gitbook.io/docs/)

**Browser transport**
- [RFC 8831 (DataChannels)](https://www.rfc-editor.org/rfc/rfc8831); mesh/tab ceilings: [Antmedia topologies](https://antmedia.io/webrtc-servers-and-multiparty-webrtc-topologies/), [TensorWorks limits](https://tensorworks.com.au/blog/webrtc-stream-limits-investigation/) (empirical)
- libp2p: [browser WebRTC](https://docs.libp2p.io/concepts/transports/webrtc/), [Circuit Relay v2](https://docs.libp2p.io/concepts/nat/circuit-relay/), [DCUtR + hole-punch measurement (~70%)](https://docs.libp2p.io/concepts/nat/dcutr/), [gossipsub v1.1](https://github.com/libp2p/specs/blob/master/pubsub/gossipsub/gossipsub-v1.1.md)
- [HyParView (DSN'07)](https://asc.di.fct.unl.pt/~jleitao/pdf/dsn07-leitao.pdf), [Plumtree (SRDS'07)](https://asc.di.fct.unl.pt/~jleitao/pdf/srds07-leitao.pdf)
- [nostr_webrtc (SDP over Nostr — demonstrated)](https://codeberg.org/cipres/nostr_webrtc); [SnoW, arXiv 2206.12762](https://arxiv.org/abs/2206.12762) ⚑; [W3C P2P-WebTransport (client-server only)](https://w3c.github.io/p2p-webtransport/); [WebTorrent](https://webtorrent.io/)
- TURN need figures: [webrtcHacks](https://webrtchacks.com/limit-webrtc-bandwidth/) + Kranky Geek industry talks (well-repeated, no single primary) ⚑

**Determinism**
- [WebAssembly Nondeterminism (design doc)](https://github.com/WebAssembly/design/blob/main/Nondeterminism.md), [spec numerics](https://webassembly.github.io/spec/core/exec/numerics.html)
- [Box2D v3 determinism (2024)](https://box2d.org/posts/2024/08/determinism/) — owned trig, `-ffp-contract=off`; [Rapier determinism](https://rapier.rs/docs/user_guides/rust/determinism/)
- [SG Physics 2D (deterministic fixed-point for Godot)](https://www.snopekgames.com/tutorial/2021/getting-started-sg-physics-2d-and-deterministic-physics-godot); [PCG](https://www.pcg-random.org/); [xoshiro](https://prng.di.unimi.it/); [Godot large-world coords (GDScript float = f64)](https://docs.godotengine.org/en/stable/tutorials/physics/large_world_coordinates.html)

**Consensus & accountability**
- [Raft](https://raft.github.io/); Santos & Hutle latency-aware election (abstract) ⚑; [PBFT (OSDI'99)](https://pmg.csail.mit.edu/papers/osdi99.pdf); [Tendermint](https://docs.tendermint.com/); [HotStuff](https://arxiv.org/abs/1803.05069)
- [SWIM](https://www.brianstorti.com/swim/); [Lifeguard](https://arxiv.org/abs/1707.00788); [HLC](https://cse.buffalo.edu/tech-reports/2014-04.pdf); [Kleppmann — fencing tokens](https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html)
- [PeerReview (SOSP'07)](https://www.cis.upenn.edu/~ahae/papers/peerreview-sosp07.pdf); [Crosby–Wallach tamper-evident logs](https://www.usenix.org/legacy/event/sec09/tech/full_papers/crosby.pdf); Schneier–Kelsey (TISSEC'99) ⚑
- [crdt.tech](https://crdt.tech/), [Yjs](https://yjs.dev/), [Automerge](https://automerge.org/) (+ 2025 arXiv CRDT-game analysis ⚑)

**Verifiable simulation & anti-cheat**
- [Dark Forest](https://blog.zkga.me/announcing-darkforest); [MUD](https://mud.dev/); [Dojo](https://dojoengine.org/) (no perf numbers published)
- [RISC Zero](https://risczero.com/); [Succinct SP1](https://blog.succinct.xyz/) — the zk cycle-count wall
- [Cartesi](https://docs.cartesi.io/); [Dave](https://github.com/cartesi/dave); [PRT (arXiv 2212.12439)](https://arxiv.org/abs/2212.12439) — "one honest validator"
- [Arbitrum BoLD](https://docs.arbitrum.io/how-arbitrum-works/bold/gentle-introduction); [Optimism fault proofs](https://docs.optimism.io/stack/protocol/fault-proofs/explainer)
- [Baughman–Levine cheat-proof playout (ToN)](https://forensics.cs.umass.edu/pubs/baughman.ToN.pdf) ⚑; NEO (NOSSDAV'04) ⚑; [Valve lag compensation](https://developer.valvesoftware.com/wiki/Latency_Compensating_Methods_in_Client/Server_In-game_Protocol_Design_and_Optimization)
- [SGAxe](https://sgaxe.com/) (TEE verdict); [Algorand sortition](https://developer.algorand.org/docs/get-details/algorand_consensus/); [drand](https://drand.love/); [RANDAO biasability](https://eth2book.info/capella/part2/building_blocks/randomness/); [EigenTrust](https://nlp.stanford.edu/pubs/eigentrust.pdf); [SybilGuard](https://www.comp.nus.edu.sg/~yuhf/sybilguard-sigcomm06.pdf); [DECO](https://blog.chain.link/deco/)

**DLT persistence**
- [Perun](https://perun.network/); [ForceMove/statechannels](https://docs.statechannels.org/) — why channels don't generalize
- [Celestia](https://celestia.org/) + DA-cost consensus (~95% of rollup cost); [MagicBlock Ephemeral Rollups (arXiv 2311.02650)](https://arxiv.org/abs/2311.02650) — the zone-sequencer precedent
- [Ready/Argent session keys](https://www.ready.co/blog/session-keys); [ProbeLab IPNS latency (7–11 s p50)](https://probelab.io/tools/ipns/); [OrbitDB](https://github.com/orbitdb/orbitdb)

**LOD & distributed simulation theory**
- Benford & Fahlén aura–nimbus (ECSCW'93); ACM CSUR 46(4) interest-management survey
- [IEEE 1278 DIS](https://standards.ieee.org/ieee/1278.1/4949/); IEEE 1516 HLA time management (caveat: optimistic interop never fully shipped)
- [Jefferson — Virtual Time / Time Warp (TOPLAS'85)](https://dl.acm.org/doi/10.1145/3916.3988); Chandy–Misra–Bryant; Fujimoto PDES surveys
- Star Citizen server meshing / replication layer (CitizenCon 2023; community secondaries — figures illustrative) ⚑

**In-repo ground truth** — `.claude/CLAUDE.md` (Unicity stack, agent identity),
`.claude/docs/architecture.md`, `.claude/docs/design-decisions.md`,
`.claude/docs/sphere-sdk-guide.md`, `.claude/reference/{sphere-sdk, state-transition-sdk,
txf-format, aggregator-go, proof-system, transport-protocols, network-config,
crypto-primitives, security-model, bft-core}.md`; `docs/COSMOS-ARCHITECTURE.md`,
`docs/COSMOS-PLANET-TOPOLOGY.md`, `docs/DESIGN.md`, `docs/RUNTIME-MATERIAL-STREAMING.md`,
`docs/VOXEL-DATA-STRUCTURE.md`; and the cited source lines throughout §2/§4 (verified
2026-07-07 against the working tree at `main`, docs @ bee9e81).




