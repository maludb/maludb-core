# INTEGRATION-MAP.md Format

`INTEGRATION-MAP.md` lives at the root of the **user's** project (the system MaluDB
is being wired into). Create it lazily — only when the first connection point is
confirmed. It is the artifact this skill produces: where MaluDB plugs in, why, and
the paste-ready SQL.

## Structure

```md
# MaluDB Integration Map — {project name}

{One sentence: what this system is and what role MaluDB plays in it.}

## Connection points

### 1. {App-moment} → {MaluDB connection point}

**Where:** {brownfield: `path/to/file.py:42`, the `execute_trade()` function ·
greenfield: "the intended trade-execution step"}

**Why:** {one sentence — what makes this a MaluDB spot. History? Provenance?
Changed-our-mind? Name which.}

**Connection point:** {claim | fact | correction | retraction | retrieval | …}

**Call:**
```sql
SELECT register_claim(
    p_subject           => '...',
    p_statement_text    => '...',
    p_source_package_id => :src
);
```

{If brownfield: a one-line note on how it slots into the existing function —
"add after the broker.buy() call".}

---

### 2. {next confirmed point …}
```

## Rules

- **One entry per confirmed connection point.** Write sparingly — only spots the
  grilling actually confirmed, not every candidate.
- **Each entry is whole.** Where + why + exact SQL together, so the user wires it
  from one place without flipping between files.
- **Confirm every signature.** The SQL in an entry must match a subsystem doc or
  the canonical SQL (`maludb_core--0.73.0.sql`). Never paste an unverified call.
- **Name the connection point in MaluDB's vocabulary** — claim, fact, correction,
  retrieval — not vague words like "save" or "store".
- **Record rejected fits briefly.** A short "## Considered and skipped" section may
  list moments where MaluDB was the wrong tool, with the one-line reason. This is
  the sales-engineer honesty made visible.

## Rejected-fits section (optional)

```md
## Considered and skipped

- **Current account balance** — pure current-state lookup, no history value. Use a
  normal table, not MaluDB.
- **Session tokens** — ephemeral, overwritten constantly. Not a MaluDB fit.
```