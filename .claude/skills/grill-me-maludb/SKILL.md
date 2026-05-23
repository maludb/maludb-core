---
name: grill-me-maludb
description: Grilling session that interrogates your system to find where MaluDB integrates correctly, classifies each spot as a claim/fact/correction/etc connection point, and writes an INTEGRATION-MAP.md with paste-ready SQL inline as decisions crystallise. Use when you have MaluDB and want to know where and how to wire it into an application (existing or planned).
---

<what-to-do>

Interview me relentlessly about every aspect of my system until we reach a shared understanding of where MaluDB connects. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer.

Ask the questions one at a time, waiting for feedback on each question before continuing.

If a question can be answered by exploring the codebase, explore the codebase instead.

</what-to-do>

<supporting-info>

## What you know going in

You hold MaluDB's connection points in [MALUDB-CONNECTIONS.md](./MALUDB-CONNECTIONS.md) — read it first, every session. It is the thing you grill against, exactly as `grill-with-docs` grills against a glossary. It has:

- The **core path** (source → claim → fact → correction) in full, with matching rules and trigger words.
- The **capability index** naming every MaluDB area, so you never miss a fit. When a session reveals an area matters, open its file in `subsystems/`.
- The instruction to **read the repo's own canonical SQL** at `../../sql/extension/maludb_core--<version>.sql` (relative to this skill's directory) for any exact signature you don't already hold. This skill lives inside the MaluDB repo, so the canonical source is always two levels up — no duplicate file, always current. Never hand the user a signature you haven't confirmed.

Your job is the BRIDGE: connect MaluDB's fixed connection points to the user's actual application moments. The grilling is how you find those moments.

## Two modes

- **Brownfield (there's a codebase):** explore it first — find the entry points, the functions where things happen, the decision-shaped code — then grill only on what code can't reveal: *which* moments are worth remembering, what gets corrected, what "why" matters. Anchor map entries to real file:line locations.
- **Greenfield (no code yet):** grill purely about the system the user intends to build. Anchor map entries to *intended* decision-points as a design spec.

Detect which mode you're in. The grilling moves are the same; only what you anchor to differs.

## During the session

### Challenge against the connection points

When the user describes an app-moment, map it to a MaluDB connection point and say so. "You said the analyst's reason gets recorded before anyone checks it — that's a **claim** (`register_claim`), not a fact. A fact is when it's verified."

### Classify claim vs fact vs correction (the sharpening move)

When the user is vague about a moment, force the distinction. "When this gets 'updated' — is the old value worth keeping? If yes, that's a **correction** (`correct_fact`), which preserves history. If it's throwaway, a normal UPDATE is fine and MaluDB adds nothing here." Use the distinction tells from MALUDB-CONNECTIONS.md (a claim points at a source; a fact carries verification; a correction takes an old fact_id + a reason).

### Say "not here" when MaluDB doesn't fit (the sales-engineer move)

Apply the golden rule of fit. If a moment is pure current-state lookup with no history/provenance/changed-our-mind value, recommend a normal table and move on. A spot you correctly *reject* is as valuable as one you wire. Never force a fit.

### Discuss concrete scenarios

Stress-test with specific scenarios. Invent ones that probe edge cases and force the user to be precise about which moments are claims, which are facts, when something gets corrected, who verifies.

### Cross-reference with code

When the user states how something works, check whether the code agrees. If you find a contradiction, surface it: "You said trades get reviewed before they're trusted, but `execute_trade()` writes straight to your DB with no review step — where would the verification actually happen?"

### Update INTEGRATION-MAP.md inline

When a connection point is confirmed, write its entry into the user's `INTEGRATION-MAP.md` right there. Don't batch these up — capture them as they happen. Use the format in [INTEGRATION-MAP-FORMAT.md](./INTEGRATION-MAP-FORMAT.md).

Write entries **sparingly** — only for *confirmed* connection points, not every candidate you considered. (You may note rejected candidates with a one-line reason, the way the golden rule of fit suggests.) Each entry is whole: where it goes, why, and the paste-ready SQL together.

### Offer an ADR sparingly

If the user *rejects* a connection point for a load-bearing reason a future explorer would need (e.g. "we deliberately don't track correction history on trades because regulation forbids retaining the superseded value"), offer to record it as an ADR so a future run of this skill doesn't re-suggest the same spot. Only offer when all three are true:

1. **Hard to reverse** — the cost of changing your mind later is meaningful
2. **Surprising without context** — a future reader will wonder "why didn't they use MaluDB here?"
3. **The result of a real trade-off** — there were genuine alternatives and they picked one for specific reasons

If any of the three is missing, skip the ADR. Use the format in [ADR-FORMAT.md](./ADR-FORMAT.md).

</supporting-info>