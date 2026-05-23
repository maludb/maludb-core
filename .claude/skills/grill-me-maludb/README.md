# grill-me-maludb

A Claude Code skill that interviews you about your application and tells you
**where and how to integrate MaluDB** — classifying each spot as a claim, fact,
correction, retrieval, etc., and writing a paste-ready `INTEGRATION-MAP.md` into
your project as the conversation goes.

It's a MaluDB integration *sales engineer*, not a salesman: it will also tell you
where MaluDB does **not** fit and a normal table is the right choice.

## Use

The skill ships with this repo. If you have Claude Code installed and you're
working inside (or with) a checkout of MaluDB, invoke it:

```
/grill-me-maludb
```

No install step. The skill auto-loads from `.claude/skills/grill-me-maludb/`.

## How it stays current

The skill reads exact SQL signatures live from this repo's
`sql/extension/maludb_core--<version>.sql`, so it never invents a call and stays
in sync with whatever MaluDB version this checkout is on. No bundled duplicate.

## What's inside

- `SKILL.md` — the grilling instructions (built on the grill-with-docs pattern).
- `MALUDB-CONNECTIONS.md` — the always-loaded knowledge: the core integration path
  plus an index naming every MaluDB capability area.
- `subsystems/` — detailed notes per capability area, opened on demand.
- `INTEGRATION-MAP-FORMAT.md`, `ADR-FORMAT.md` — formats for the artifacts the
  skill writes into the user's project during a session.

## Provenance

The grilling engine is copied verbatim from
[`grill-with-docs`](https://github.com/mattpocock/skills) by Matt Pocock — only
the targets are swapped (from glossary terms to MaluDB connection points). Credit
for the conversational pattern belongs there.