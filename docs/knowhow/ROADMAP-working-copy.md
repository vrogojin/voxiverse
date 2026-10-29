# Roadmap

This roadmap is the human-readable mirror of this project's GitHub Project board.
The two MUST stay in sync — run `/roadmap-sync` after landing work (the
`roadmap-sync-check` hook nudges you when a commit changed code without touching
this file). Each item below maps to one card on the board; the emoji encodes its
board status.

**Status legend (four-state model):**

| Emoji | Status | Meaning |
|-------|--------|---------|
| ✅ | Completed | Shipped / merged / done. |
| 🚧 | In progress | Actively being worked on right now. |
| ⏸️ | Stalled / paused | Started but on hold (blocked, deprioritized, awaiting input). |
| 🔵 | Planned | Agreed, not yet started. |

> Keep one item per line: `- <emoji> **<title>** — <short description>`.
> Add an optional `(#<issue>)` or `(PR #<n>)` reference when one exists.

## ✅ Completed

- ✅ **Far-village render jerk** — version-gated far-structure step + impostor-card tier + render diet; the ~2 Hz village spike is gone. (PR #84)
- ✅ **Freeze-on-break near villages** — debounced far-edit re-bake with a provably O(1) edit frame; 3547 ms → 42–92 ms, no freeze. (PR #84)
- ✅ **Far-village edit reflection** — block edits re-bake into the far LOD model after you depart (~16 blk) + idle, NEVER-DROP preserved. (PR #84)
- ✅ **LOD-ladder dropout** — hold the far card/mesh tier until the fine-map skin is baked; structures show 0 drawable gap crossing an LOD step. (PR #84)
- ✅ **Chopped-tree body renders black** — feed planet_centre to the BlockMaterials debris twins in the unified-shade path; detached canopy renders lit. (PR #84)
- ✅ **Spawn at early morning** — `SPAWN_LOCAL_HOURS = 7.0` instead of midnight. (PR #84)
- ✅ **Surface-entry (space) freeze** — far-tree flip-calm + incremental orbit-relief GPU commit (persistent surface + coalesced region uploads); 1.1 s freeze → ~40 ms one-time hitch. (PR #84)

## 🚧 In progress

<!-- What is actively being built right now. -->

## ⏸️ Stalled / paused

<!-- Started but on hold — note why (blocked on X, awaiting Y). -->

## 🔵 Planned

<!-- Next agreed work — add items as they're scoped. -->
