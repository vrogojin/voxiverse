---
name: voxiverse-never-oom-web
description: Hard user constraint — the web build must never risk OOM; memory safety outranks visual quality; memory-costly upgrades ship flag-gated OFF behind a measured A/B go-gate
metadata: 
  node_type: memory
  type: project
---

Hard constraint issued by the user (July 2026, during COSMOS M4 design): the VOXIVERSE web
build must **never risk an out-of-memory**, even if that makes a visual feature briefer,
coarser, or less complete. Locked as §0 of docs/COSMOS-M4-HANDOFF.md (rev 3, ship-both).

**Why:** the wasm heap is bounded and an OOM crash is strictly worse than any cosmetic
degradation; the live-playable web demo is the project's top gate (DESIGN §7).

**How to apply:** (1) the shipped DEFAULT must add zero extra near-voxel memory — exactly one
near volume at all times; (2) a memory-costly quality upgrade may still be built, but
flag-gated OFF by default (one-line const flip, no other code-path difference) and enabled in
production only after a measured live A/B gate (heap flatness across a flip storm on the
low-end target, invariant telemetry, clean retirement reasons) — the M4 pattern; (3) every
transient/bridge structure needs a code-enforced count/triangle ceiling or single-instance
invariant AND a hard lifetime cap; (4) order degrade ladders memory-safety first, visual
completeness second. Related: [[voxiverse-project]], [[voxiverse-physics-scale]].
