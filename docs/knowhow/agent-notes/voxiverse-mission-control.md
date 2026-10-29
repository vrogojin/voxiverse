---
name: voxiverse-mission-control
description: "Mission-control remote-control channel (Houston→rover) — built P1-P3, security-audited, go-live GATED on"
metadata: 
  node_type: memory
  type: project
---

Phase-2 of the remote-play bridge: a Claude agent uplinks a timed command sequence to the live browser game (the "rover") and reads back correlated telemetry — a half-duplex Houston→Mars-rover control loop. Design: docs/COSMOS-REMOTE-CONTROL-DESIGN.md. Branch fix/voxiverse-crossing-hitches.

**PURPOSE (the killer use, per user 2026-07-15):** make it MY unattended dev/test harness — I edit code → build+export+deploy (host-side) → send `reload` (browser fetches new build + re-arms via unattended) → drive the rover to test-cross a ridge → read the crossing telemetry → iterate. So the generation-fix (the real crossing-hitch lever, see [[voxiverse-crossing-phys-spike]]) can be developed hands-off without the user re-walking each cycle.

**Built + committed (all inert behind `CONTROL_ENABLED := false`, byte-identical off):** P1 relay bidirectional core (default-deny forward gate, outbox ingress, consent state machine); P2 game receiver + capability-enumerating consent modal + `reload` op + persistent unattended mode (localStorage); P3 locomotion+mutation executor (player.gd intent seam, closed-loop move-until-displacement, break/place/select_slot through the human WorldManager pipeline). Gates: FLAT 6035/0, RC smoke.

**Resolved decisions:** D1 grant until-revoked · D2 re-consent after any override · D3 preempt · D4 full-res shots · D5 FULL agency (move+break/place/inventory). Unattended: accepted as designed (until-revoked, auto-resume 5s idle).

**Security:** Fable adversarial audit = CONDITIONAL GO, no CRITICAL. Load-bearing wall HOLDS: command ingress is host-filesystem-only + game-side human-consent second factor → no attacker (even with the observe token) can drive/mutate a NON-consenting human's game. Fixed F1 (relay-minted per-socket grant nonce + no-supersede + forged-result dropping), F2 (client control_revoke handler), F3 (CSPRNG ids + same-origin model), F5 (X-Real-IP rate key, pruned maps, fly-off-on-override). Committed d232d72.

**#113 DONE — GO-LIVE-READY (2026-07-15, commit 4080a74).** The token-race residual is CLOSED: control now requires a SECOND host secret (REMOTE_BRIDGE_CONTROL_TOKEN / gitignored .control-token, distinct from the observe .token). Grant carries grant_proof = HMAC-SHA256(control_secret, "vxv-ctl-grant.v1\n"+F1-nonce); relay validates timing-safe (nonceOk→CONTROL_AVAILABLE→proofOk→no-supersede). Secret never on the wire. Fail-CLOSED when unset/==observe (no offers, observe untouched → deploys safe vs live Phase-1). Smoke B(j) proves a token-only socket can't grant. Attended = key typed once, stored NOWHERE; unattended (D6 accepted) = {uid,ck} in localStorage, restart-safe, Esc-cleared. Godot HMAC has an RFC-2104 fallback (validated vs Node) for web. smoke 105/0, verify_feature 6035/0. CONTROL_ENABLED still false.

**GO-LIVE PROCEDURE (operator/me, on user's go):** (1) provision `.control-token` = `openssl rand -hex 24` (MUST differ from .token) on the host + set it on the voxiverse-relay container (env REMOTE_BRIDGE_CONTROL_TOKEN or bind-mount) + restart relay; (2) sed CONTROL_ENABLED := true (+ the FP flags) at export, export-web, revert source, deploy; (3) user opens game, enters the control key in the consent modal, grants + opts into unattended once; (4) I self-drive the generation-fix loop. Related: [[voxiverse-remote-bridge]], [[voxiverse-remote-telemetry-launch]], [[voxiverse-crossing-phys-spike]].
