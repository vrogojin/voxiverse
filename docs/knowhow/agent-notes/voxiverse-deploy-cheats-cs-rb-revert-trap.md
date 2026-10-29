---
name: voxiverse-deploy-cheats-cs-rb-revert-trap
description: "deploy_cheats.sh git-checkout-reverts cube_sphere.gd + remote_bridge.gd every run — any UNCOMMITTED flag/const there is wiped, breaking refs in other files"
metadata: 
  node_type: memory
  type: project
  modified: 2026-09-04T14:13:16.240Z
---

**deploy_cheats.sh reverts cube_sphere.gd (CS) + remote_bridge.gd (RB) to HEAD on EVERY run**
(`git checkout -- "$CS" "$RB"` at lines 15 AND 46 — once before export to clear the sed, once
after to restore). It seds the CLITE flags ON into CS, exports, then reverts. **Consequence:
any UNCOMMITTED flag/const definition in CS or RB is WIPED by the pre-export checkout** — but
references to it in OTHER files (facet_far_*, world_manager, verify_*) survive → the export hits
`Parse Error: Cannot find member "FP_X" in base "CubeSphere"` → **broken web build served**
(fresh loads blank/crash; the currently-loaded page keeps working, hiding it).

**This bit hard on 2026-09-04:** lod-skin-impl added FP_SKIN_READY_GATE/HANDOFF_PREWARM +
5 consts to CS uncommitted; a deploy wiped them; the deployed build had parse errors in 5 core
runtime scripts. Caught by grepping `scratchpad/export_cheats.log` for "Parse Error"/"SCRIPT ERROR"
AFTER the deploy (deploy_cheats exits 0 despite the parse errors — Godot export does not fail on
GDScript parse errors). Recovery: re-add the wiped defs to CS, **COMMIT them** (so HEAD carries
them and the checkout restores WITH them), re-run FLAT gate (6042/0), re-deploy.

**RULE: any flag/const/telemetry-surface in cube_sphere.gd or remote_bridge.gd MUST BE COMMITTED
before a deploy** — uncommitted edits there do NOT survive. (Edits in every OTHER file are exported
from the working tree as-is; only CS+RB are reverted.) When multiple background agents share the
worktree, cube_sphere.gd is the #1 contention/loss point — commit flag additions immediately.

**Verify a deploy is not silently broken:** `grep -iE "Parse Error|SCRIPT ERROR|Cannot find member"
scratchpad/export_cheats.log` after every deploy. See [[voxiverse-deploy-cheats-pipeline]].

**RELATED TRAP — NEVER run concurrent flag-ON gate runs in one worktree (2026-09-04, cost hours).**
Flag-ON gates work by `sed`-ing FP_* flags true in cube_sphere.gd, running the verify, then restoring
(git checkout OR a cp backup). Two of these overlapping — or one overlapping a deploy_cheats, or a
falsification test that injects+reverts a line, or another session/agent editing CS — RACE on cube_sphere.gd:
one job's restore writes a stale/flag-flipped/duplicate-const copy over another's, leaving CS corrupted
(stray `FACETED := true` etc., or a duplicate `const` = parse error). A corrupted CS then gets COMMITTED if
you don't gate the commit on a clean check. **RULES:** (1) SERIALIZE all gate runs — one godot verify at a
time in a worktree; (2) prefer `git checkout` restore over cp-backup (backup can capture an already-corrupt
state); (3) `pgrep -f verify_structures` SELF-MATCHES a wait-loop whose cmdline contains that string — match
the godot BINARY (`pgrep -f godot.linuxbsd.editor`) instead; (4) before ANY commit of cube_sphere.gd, assert
`git diff <base> -- cube_sphere.gd | grep -cE '^\+const (FP_|FACETED).* := true'` == 0 AND no duplicate const,
and ABORT the commit if not (don't just echo it). Recovery from a committed-corrupt CS: `git checkout <good-sha>
-- cube_sphere.gd`, re-apply the intended const edits by hand, verify single defs + no stray flags, amend.
