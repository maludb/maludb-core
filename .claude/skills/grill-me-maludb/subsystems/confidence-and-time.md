# Subsystem: MAUT confidence + bitemporal time

Two cross-cutting concepts that color many connection points. Open when grilling
reveals "how sure are we" or "as of when". Confirm signatures against
`maludb_core--0.73.0.sql`.

## MAUT confidence scoring
Facts carry a multi-criteria confidence score (Multi-Attribute Utility Theory):
supporting facts, corroborating sources, temporal proximity, consistency,
stakeholder consensus, metadata quality, logical derivation. Match: "how
confident are we", "trust score", "weight evidence", "only show high-confidence".
- `set_maut_score(p_object_type, p_object_id, p_category, p_score, ...)` — record a subscore.
- `apply_default_weights(...)` — normalize/weight categories.
- `record_reinforcement(...)` — update confidence from usage outcomes (was it useful? right?).
- `maut_aggregate_confidence(p_object_type, p_object_id)` → final confidence number.
- Where it shows up at a connection point: `execute_retrieval`'s envelope has a
  `confidence_floor` — "only return things we're at least this sure about." If the
  user wants confidence-filtered recall, that's the lever.

## Bitemporal time
Every fact tracks TWO timelines:
- **valid time** — when the fact was true in the real world.
- **transaction time** — when the system knew it.
This is what lets MaluDB answer both "what was true on date X" and "what did we
believe on date X" — different questions. Match: "as of", "point in time", "what
did we know then vs what was actually true".
- Point reads: `fact_as_of(p_at)`, `memory_as_of(p_at)`, `episode_as_of(p_at)`.
- In retrieval: the envelope has `valid_as_of` and `transaction_as_of` — set
  either to time-travel a query.
- In replay: `replay_episode(..., mode)` exposes the modes (current_valid,
  historical, as_of_transaction_time, full_bitemporal) — see retrieval.md.
- Corrections (`correct_fact`) close the valid window of the old fact and open a
  new one — this is what makes the bitemporal history navigable.

## When to surface these
Confidence and bitemporal are usually NOT separate connection points the user
wires by hand — they're properties of facts and parameters on retrieval. Mention
them when the user asks "can I see how sure we were" or "can I see what we
believed back then" — then point at the confidence_floor / as_of levers rather
than a standalone call.