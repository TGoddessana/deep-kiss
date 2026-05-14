# Stage 1: Afterglow Harvester

You are dispatched by the `afterglow` skill to scan ONE Claude Code session transcript and extract reusable signals worth potentially capturing as skills or memory-file entries.

## Input

The dispatcher provides:
- `session_id`: the session's UUID (from filename)
- `transcript_path`: absolute path to a pre-compressed transcript file

Read the transcript with the Read tool. The file format is one event per line:

- `[User]: <text>` — user message (truncated to 500 chars)
- `[Assistant]: <text>` — assistant text reply (truncated to 300 chars)
- `[Tool: <NAME>]` — assistant tool call (arguments and results dropped)

JSONL structure, thinking blocks, and tool results have already been stripped — only signal-bearing content remains. Truncation means a long user instruction may end mid-sentence; that's fine, the leading portion is what matters for topic detection.

## What to Look For

Two signal kinds only:

1. **`prescriptive_instruction`** — the user explicitly *told* the model how to behave in this project.
   - Cues: "don't ...", "always ...", "from now on ...", "in this project we ...", "use X not Y", "stop doing Z".
   - Source: user messages only. NOT model self-corrections, NOT inferred conventions.

2. **`workflow_pattern`** — the user repeated a multi-step procedure (within this session, or referenced doing it before).
   - Cues: same sequence of tool calls/prompts ≥ 2 times, or user describing "the usual flow".
   - Must be proceduralizable as numbered steps.

## What to Ignore

- One-off fixes with no class-level lesson
- Code-content corrections that are project-specific facts already in the codebase
- Pure praise/complaint with no actionable rule
- Model's autonomous decisions that the user didn't endorse or repeat
- Warmup/exploration without a stated rule

## Output Schema

YAML only. No prose, no markdown headings outside the schema, no commentary.

```yaml
session_id: <uuid from input>
substantive: true | false   # false = warmup/empty; if false, signals must be []
signals:
  - kind: prescriptive_instruction | workflow_pattern
    topic: <one-line summary, ≤80 chars>
    detail: <2-3 sentences: what the rule/pattern is, in declarative form>
    evidence: <a short user quote or paraphrase, ≤150 chars>
    decisive_excerpts:                  # 1–3 ranges into THIS session's compressed transcript
      - line_range: [<start>, <end>]    # 1-indexed, inclusive; each range ≤50 lines
```

### How to pick `decisive_excerpts`

Skill quality depends on these. Pick the moments a future drafter must SEE to write a usable artifact — not the moments that prove the rule exists. Prefer:

- The user's actual instruction (the verbatim turn where they stated the rule)
- The wrong behavior being corrected (so the drafter knows the anti-pattern)
- The applied procedure (for workflow_pattern: the actual tool sequence or fix steps)

Avoid ranges that are mostly boilerplate, `[Tool: Read]` chains with no surrounding text, or repetitions of the same point. Tight ranges over wide ones. If one decisive turn says everything, ONE range is enough — don't pad to three.

Empty signals list is valid and common:

```yaml
session_id: <uuid>
substantive: true
signals: []
```

## Example

Suppose the compressed transcript file looks like (with line numbers):
```
 ...
 42  [User]: stop adding try/except around everything, just let it raise
 43  [Assistant]: Understood, removing the wrapper.
 44  [Tool: Edit]
 ...
 91  [User]: again, no defensive try/except, this isn't user input
 92  [Assistant]: Got it. Reverting and letting the exception propagate.
 93  [Tool: Edit]
```

Expected output:
```yaml
session_id: 7f3a-...
substantive: true
signals:
  - kind: prescriptive_instruction
    topic: "no defensive try/except around internal code"
    detail: "User wants exceptions to propagate from internal code paths; defensive try/except blocks are unwelcome. Reserve error handling for system boundaries (user input, external APIs)."
    evidence: "stop adding try/except around everything, just let it raise"
    decisive_excerpts:
      - line_range: [42, 44]
      - line_range: [91, 93]
```

## Constraints

- YAML output only.
- Limit to ≤5 signals per session — prioritize the strongest.
- `topic` must be specific enough that two harvesters seeing the same rule produce similar topic strings (the merger groups by topic similarity).
- Do NOT decide bucket (skill vs. memory-file) — that's the merger's job.
- Do NOT draft any artifact content.
- If the transcript is mostly the harvester reading its own prompt (meta-session), set `substantive: false` and return empty signals.
