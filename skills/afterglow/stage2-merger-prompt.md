# Stage 2: Afterglow Merger

You are dispatched by the `afterglow` skill to merge per-session signals into a single candidate list, applying the **repetition threshold** and assigning each candidate to a bucket.

## Input

A list of Stage 1 outputs, one per session:

```yaml
sessions:
  - session_id: <uuid>
    substantive: true | false
    signals: [...]
  - ...
```

## Task

1. **Group** signals across sessions by *semantic topic similarity*. Two signals about "no defensive try/except" and "let exceptions propagate" belong in the same group.
2. **Count** distinct sessions in each group (`count = unique session_ids`).
3. **Threshold:**
   - `count >= 2` → keep as candidate
   - `count == 1` → `drop` (unless the single signal is extraordinarily specific and actionable; default to drop)
4. **Assign bucket:**
   - `prescriptive_instruction` kind → usually `memory-file` (the rule belongs in `AGENTS.md` / `CLAUDE.md`)
   - `workflow_pattern` kind → usually `skill` (a reusable procedure)
   - **Override when:**
     - A prescriptive instruction implies a multi-step verification → `skill`
     - A workflow pattern is just a one-line convention with no procedure → `memory-file`
5. **Consolidate** the per-session `detail` and `evidence` fields into a single coherent description.

## Output Schema

YAML only. No prose outside the schema.

```yaml
candidates:
  - topic: <one-line summary>
    bucket: skill | memory-file | drop
    count: <int, number of sessions where this surfaced>
    sessions: [<session_id>, <session_id>, ...]
    signal_kind: prescriptive_instruction | workflow_pattern
    rationale: <one line — why this bucket, citing count and kind>
    consolidated_detail: <2-4 sentences merging the per-session details into one description>
```

Empty list is valid:

```yaml
candidates: []
```

## Example

Input:
```yaml
sessions:
  - session_id: aaa
    substantive: true
    signals:
      - kind: prescriptive_instruction
        topic: "no defensive try/except around internal code"
        detail: "User wants exceptions to propagate from internal code."
        evidence: "stop adding try/except around everything"
  - session_id: bbb
    substantive: true
    signals:
      - kind: prescriptive_instruction
        topic: "let exceptions propagate, no defensive catch"
        detail: "User rejected a try/except wrapper, wants the exception to bubble."
        evidence: "again, no try/except, just let it raise"
  - session_id: ccc
    substantive: true
    signals:
      - kind: workflow_pattern
        topic: "run pytest -x after each edit"
        detail: "User invokes pytest with -x flag after every edit cycle."
        evidence: "ok now `pytest -x`"
```

Expected output:
```yaml
candidates:
  - topic: "Don't wrap internal code in defensive try/except"
    bucket: memory-file
    count: 2
    sessions: [aaa, bbb]
    signal_kind: prescriptive_instruction
    rationale: "Appears in 2 sessions; one-line rule without procedure — fits memory-file."
    consolidated_detail: "Internal code should let exceptions propagate. Reserve try/except for system boundaries (user input, external APIs). User has rejected defensive wrappers in multiple sessions."
  - topic: "Run pytest -x after each edit"
    bucket: drop
    count: 1
    sessions: [ccc]
    signal_kind: workflow_pattern
    rationale: "Single session occurrence — below 2-session threshold."
    consolidated_detail: "User invoked pytest -x after edits in one session. Not enough repetition to capture."
```

## Constraints

- YAML output only.
- Maximum 10 candidates total (including drops). If more groups exist, keep the top 10 by count descending; tie-break by signal strength.
- Sort output by bucket (`skill` first, then `memory-file`, then `drop`) and within each by `count` descending.
- `topic` must be a clean, canonical phrasing — not just one of the source topics.
- Do NOT draft skill or memory content. That's the next stage's job (handled by aftercare's drafter prompts).
