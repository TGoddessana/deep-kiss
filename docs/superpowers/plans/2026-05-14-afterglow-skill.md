# Afterglow Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a project-scoped retrospective skill (`/afterglow`) that scans all past Claude Code sessions of the *current project*, identifies repeated user instructions and workflow patterns, and offers to materialize them as skills (`SKILL.md` bundles) or memory-file entries (`AGENTS.md` / `CLAUDE.md`).

**Architecture:** Map-reduce pipeline borrowed from Claude Code's built-in `/insights` command, but project-scoped and outputting *artifacts* (not just an HTML report). Three stages: (1) per-session harvest of signals by parallel subagents; (2) cross-session merge + bucket judgment by one subagent; (3) drafting via existing aftercare drafter prompts. Main context never reads transcripts — it only orchestrates and reviews structured candidate lists.

**Tech Stack:** Markdown-only skill (SKILL.md + prompt files). Subagent dispatch via the standard `Agent` tool. Bash for filesystem ops (path encoding, JSONL listing). YAML for inter-stage data exchange. Reuses `skills/aftercare/stage2-skill-drafter-prompt.md` and `skills/aftercare/stage2-memory-drafter-prompt.md` unchanged.

---

## Series Position

```
flirt (explore) → deep-kiss (confirm) → implement → aftercare (immediate post-fix) → afterglow (retrospective across sessions)
```

`aftercare` captures lessons from a *just-fixed mistake* in the current session. `afterglow` captures *repeated patterns* across a project's session history. They share Stage 2 drafters; their judgment stages differ.

## Design Decisions (Locked)

| Decision | Choice | Reason |
|---|---|---|
| Scope | Project-scoped (current `cwd`) | Per the user's framing — global is /insights's domain |
| Pipeline | Independent (no /insights cache reuse) | /insights is global; needs different scoping logic |
| Signal threshold | Appears in **2+ sessions** = candidate | Repetition is the signal (principle borrowed from /insights) |
| Substantive filter | `user_message_count >= 2 && duration >= 1 min` | Skip warmup/empty sessions to save subagent dispatches |
| Cache location | `$CLAUDE_CONFIG_DIR ?? ~/.claude / afterglow / <encoded-project-path> / <session_id>.yaml` | Follows Claude Code convention (top-level directory under config home, not nested under `data/`) |
| Project path encoding | `/` → `-` (matches `~/.claude/projects/` scheme) | Consistent with Claude Code's existing convention |
| Cache invalidation | Session JSONL mtime > cache mtime | Sessions are append-only; current session may grow |
| Concurrency | Dispatch one subagent per *uncached* session in parallel | Most projects have <50 sessions |
| No artificial cap | Unlike /insights (which caps at 200/50), afterglow processes all substantive sessions | Project scope keeps N small |
| Bucket mapping | `prescriptive_instruction` → usually `memory-file`; `workflow_pattern` → usually `skill`; merger may override | Captures the user's stated requirement (skill or memory) |
| Output location for skills | Both `.claude/skills/<name>/` and `.codex/skills/<name>/` (project) or `~/.claude/...` and `~/.codex/...` (user) | Inherited from aftercare's existing skill-drafter behavior |
| Output location for memory | `AGENTS.md` if exists, else `CLAUDE.md`, else create `AGENTS.md` | Inherited from aftercare's existing memory-drafter behavior |

## File Structure

All paths are relative to the deep-kiss repo root (`/Users/goddessana/Developments/deep-kiss/`).

| Path | Responsibility |
|---|---|
| `skills/afterglow/SKILL.md` | Orchestration: path computation, session listing, cache management, dispatch, user interaction, artifact writing |
| `skills/afterglow/stage1-harvester-prompt.md` | Per-session prompt: extract `prescriptive_instructions` and `workflow_patterns` as structured signals |
| `skills/afterglow/stage2-merger-prompt.md` | Cross-session prompt: aggregate signals by topic, apply 2+ threshold, assign bucket (skill / memory-file / drop) |
| (reused) `skills/aftercare/stage2-skill-drafter-prompt.md` | Drafts SKILL.md bundle for a selected candidate |
| (reused) `skills/aftercare/stage2-memory-drafter-prompt.md` | Drafts memory-file content for a selected candidate |

No scripts. No references directory. Everything fits in three new markdown files.

---

## Task 1: Stage 1 Harvester Prompt

**Files:**
- Create: `skills/afterglow/stage1-harvester-prompt.md`

This prompt is dispatched once per substantive session JSONL. It extracts repeatable signals from a single session transcript and outputs structured YAML.

- [ ] **Step 1: Write the prompt file**

Create `skills/afterglow/stage1-harvester-prompt.md` with this exact content:

````markdown
# Stage 1: Afterglow Harvester

You are dispatched by the `afterglow` skill to scan ONE Claude Code session transcript and extract reusable signals worth potentially capturing as skills or memory-file entries.

## Input

The session transcript (JSONL-style messages, possibly long). The dispatcher provides:
- `session_id`: the session's UUID (from filename)
- `transcript`: the raw conversation

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
```

Empty signals list is valid and common:

```yaml
session_id: <uuid>
substantive: true
signals: []
```

## Example

Input (excerpted):
> User: "stop adding try/except around everything, just let it raise"
> [later in same session]
> User: "again, no defensive try/except, this isn't user input"

Expected output:
```yaml
session_id: 7f3a-...
substantive: true
signals:
  - kind: prescriptive_instruction
    topic: "no defensive try/except around internal code"
    detail: "User wants exceptions to propagate from internal code paths; defensive try/except blocks are unwelcome. Reserve error handling for system boundaries (user input, external APIs)."
    evidence: "stop adding try/except around everything, just let it raise"
```

## Constraints

- YAML output only.
- Limit to ≤5 signals per session — prioritize the strongest.
- `topic` must be specific enough that two harvesters seeing the same rule produce similar topic strings (the merger groups by topic similarity).
- Do NOT decide bucket (skill vs. memory-file) — that's the merger's job.
- Do NOT draft any artifact content.
- If the transcript is mostly the harvester reading its own prompt (meta-session), set `substantive: false` and return empty signals.
````

- [ ] **Step 2: Verify file exists and is well-formed**

Run:
```bash
test -f /Users/goddessana/Developments/deep-kiss/skills/afterglow/stage1-harvester-prompt.md && wc -l /Users/goddessana/Developments/deep-kiss/skills/afterglow/stage1-harvester-prompt.md
```
Expected: file exists, ~60 lines.

- [ ] **Step 3: Commit**

```bash
git add skills/afterglow/stage1-harvester-prompt.md
git commit -m "feat(afterglow): add Stage 1 harvester prompt"
```

---

## Task 2: Stage 2 Merger Prompt

**Files:**
- Create: `skills/afterglow/stage2-merger-prompt.md`

This prompt is dispatched once per `/afterglow` invocation. It receives all Stage 1 outputs and produces a final candidate list with bucket decisions.

- [ ] **Step 1: Write the prompt file**

Create `skills/afterglow/stage2-merger-prompt.md` with this exact content:

````markdown
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
````

- [ ] **Step 2: Verify file exists**

Run:
```bash
test -f /Users/goddessana/Developments/deep-kiss/skills/afterglow/stage2-merger-prompt.md && wc -l /Users/goddessana/Developments/deep-kiss/skills/afterglow/stage2-merger-prompt.md
```
Expected: file exists, ~90 lines.

- [ ] **Step 3: Commit**

```bash
git add skills/afterglow/stage2-merger-prompt.md
git commit -m "feat(afterglow): add Stage 2 merger prompt"
```

---

## Task 3: SKILL.md Orchestration

**Files:**
- Create: `skills/afterglow/SKILL.md`

This is the orchestration document. The main agent reads it on `/afterglow` invocation and follows the steps.

- [ ] **Step 1: Write the SKILL.md**

Create `skills/afterglow/SKILL.md` with this exact content:

````markdown
---
name: afterglow
description: "Use when the user invokes /afterglow to retrospectively scan the current project's past Claude Code sessions for repeated user instructions or workflow patterns worth capturing as skills or memory-file entries. Project-scoped (not global). Dispatches one harvester subagent per substantive session in parallel, then a merger subagent to apply the 2-session repetition threshold, then reuses aftercare's drafters to produce SKILL.md bundles or AGENTS.md/CLAUDE.md additions. User-explicit invocation only; do NOT trigger automatically. Do NOT use for capturing a just-fixed mistake — that's aftercare's job."
---

# afterglow — Project-Retrospective Capture

Series flow: **flirt**(explore) → **deep-kiss**(confirm) → implement → **aftercare**(immediate post-fix) → **afterglow**(retrospective across sessions).

While `aftercare` captures lessons from a *just-fixed* mistake in the current session, `afterglow` scans the *project's session history* for *repeated* user instructions and workflow patterns. The main context never reads transcripts — judgment and drafting are fully delegated to subagents to respect the <200K context budget.

## When to use

- When the user explicitly invokes `/afterglow`.
- Never trigger automatically.
- Do NOT use for in-session mistake capture — use `aftercare` instead.

## Outputs (3 buckets, inherited from aftercare)

- `skill`: write a new skill file (SKILL.md + optional `scripts/`, `references/`)
- `memory-file`: a short addition to `AGENTS.md` or `CLAUDE.md` at the project root
- `drop`: not worth capturing — do nothing

## Orchestration Checklist

Execute in order. Each step is short; the main context handles only dispatch and user interaction.

### 1. Compute paths

1. Get the current working directory: `pwd`.
2. Encode as a project path: replace every `/` with `-`. Example: `/Users/x/y` → `-Users-x-y`.
3. Determine the Claude config base: `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`.
4. Sessions directory: `${BASE}/projects/${ENCODED}`.
5. Cache directory: `${BASE}/afterglow/${ENCODED}`. Create it if absent: `mkdir -p`.

If the sessions directory does not exist, print "No prior sessions found for this project." and exit.

### 2. List substantive sessions

1. List all `*.jsonl` files in the sessions directory.
2. For each file, compute a cheap substantive check via Bash:
   - User-message count: `grep -c '"type":"user"' <file>`
   - File size: `wc -c <file>`
3. Skip files with `user_message_count < 2` OR `size < 4096` bytes (≈ 1 minute of activity).
4. The remaining list is the **substantive session set** for this run.

If the substantive set is empty, print "No substantive sessions found for this project." and exit.

### 3. Cache check and dispatch

For each substantive session file:

1. Cache key: `<session_id>.yaml` where `session_id` is the filename without extension.
2. Cache path: `${CACHE_DIR}/<session_id>.yaml`.
3. If the cache file exists AND `mtime(cache) > mtime(session_jsonl)`, mark as **cached** (Stage 1 output already valid).
4. Otherwise, mark as **uncached**.

Dispatch a Stage 1 harvester subagent for each *uncached* session in parallel (single message with multiple `Agent` tool uses):

- Prompt: body of `skills/afterglow/stage1-harvester-prompt.md`.
- Input: the session JSONL contents plus `session_id`.
- Expected output: YAML matching the Stage 1 schema.

After all harvesters return, write each result to the cache path. Print: `"Harvested N new sessions (M cached)."`

### 4. Merger dispatch

1. Load all Stage 1 outputs (cached + freshly written) — concatenate as the `sessions` field of the merger input.
2. Dispatch a Stage 2 merger subagent with `skills/afterglow/stage2-merger-prompt.md` as the prompt.
3. Result: candidate list with `topic / bucket / count / sessions / signal_kind / rationale / consolidated_detail`.

### 5. Present candidates and user selection

- 0 candidates with bucket ≠ drop → "No repeated patterns found. (Scanned N sessions.)" Exit.
- 1 candidate (non-drop) → show it (topic, bucket, count, rationale), ask "Shall we proceed?"
- N candidates (non-drop) → present a numbered list, format:
  ```
  1. [memory-file ×3] Don't wrap internal code in defensive try/except
  2. [skill ×2] Run pytest verification after each edit
  ```
  Ask: "Which would you like to process? (all / number list / cancel)"

Drops are listed last in summary form: "Also dropped: <topic> (1 session each)." No further action.

### 6. Process each selected candidate

For each selected candidate, branch on `bucket`:

**memory-file**:

1. Check whether `AGENTS.md` and `CLAUDE.md` exist at the project root. If either exists, capture top-level section headings (lines starting with `## `) as `project_state`.
2. Dispatch a subagent with `skills/aftercare/stage2-memory-drafter-prompt.md` as the prompt. Input fields:
   - `topic`: from candidate
   - `rationale`: candidate's `rationale`
   - `context_excerpt`: candidate's `consolidated_detail`
   - `project_state`: as captured above
3. Expected output: YAML matching the memory-drafter schema (`target_file`, `operation`, `content`, optionally `section_heading`).
4. Show the user `target_file`, `operation`, and a preview of `content`. Ask for approval.
5. **Approved** → if `target_file` does not exist at project root, create it (one-line notice). Then append or insert into the specified section.
6. **Rejected with feedback** → re-dispatch (max 2 attempts total). On exceeding the limit, show the last raw output and ask the user to handle it manually.

**skill**:

1. Ask the user a scope question:
   > "Where would you like to install this skill?
   > (1) project — `./.claude/skills/<name>/` + `./.codex/skills/<name>/`
   > (2) user — `~/.claude/skills/<name>/` + `~/.codex/skills/<name>/`"
2. Dispatch a subagent with `skills/aftercare/stage2-skill-drafter-prompt.md` as the prompt. Input fields:
   - `topic`: from candidate
   - `rationale`: candidate's `rationale`
   - `context_excerpt`: candidate's `consolidated_detail`
3. Expected output: YAML matching the skill-drafter schema (`skill_name`, `files: [{path, content}]`, `notes`).
4. Show the user the file list, a preview of the first ~30 lines of each file, and `notes`. Ask for approval.
5. **Approved** → write files to BOTH the Claude Code path and the Codex path for the selected scope. If `.codex/` doesn't exist, mkdir it with a one-line notice. On filename conflict, ask the user: overwrite / rename / skip.
6. **Rejected with feedback** → re-dispatch (max 2 attempts total). On exceeding the limit, show the last raw output and ask the user to handle it manually.

**drop**: One-line notice: "Not recording — reason: <rationale>." Move on.

### 7. Closing summary

When a single `/afterglow` invocation is fully processed, print:
```
Result: skill ×A (paths: ...), memory ×B (file: ...), drop ×C. Scanned N sessions (M harvested fresh, K from cache).
```

## Errors / Edge Cases

| Situation | Handling |
|-----------|----------|
| Sessions directory missing | "No prior sessions found for this project." Exit. |
| Substantive set empty | "No substantive sessions found for this project." Exit. |
| Stage 1 (harvester) output parse failure on one session | Skip that session, log a one-line warning, continue. |
| Stage 2 (merger) output parse failure | Re-dispatch once with structure-correction note. If it still fails, show raw output and ask the user to decide. |
| Drafter parse failure or user rejection | Up to 2 total retries (attach feedback/error). Then raw output + manual handoff. |
| Rejection with no feedback | Ask "What should be changed?" once; if no response, skip. |
| Filename conflict (skill) | User chooses: overwrite / rename / skip. |
| `.codex/` directory absent | mkdir + one-line notice. |
| Cache directory creation fails | Print warning, proceed without caching (re-runs will reharvest). |

## Constraints

- Never trigger automatically — user-explicit invocation only.
- No direct judgment or drafting in the main context — delegate everything to subagents.
- Do NOT read raw session transcripts in the main context. Only metadata (mtime, size, message counts via grep) and structured subagent outputs.
- Do not touch `~/.claude/MEMORY.md` or the auto-memory system. Only `AGENTS.md` / `CLAUDE.md` at the project root are valid memory-file targets.
- Cache files are session-scoped and append-only; do not delete them on failure.

## Naming note (for series consistency)

`afterglow` continues the romance-themed naming of this plugin (`deep-kiss` → `flirt` → `aftercare` → `afterglow`). The metaphor: aftercare is the immediate post-coital tending; afterglow is the lingering warmth one notices later, when looking back.
````

- [ ] **Step 2: Verify file exists and is well-formed**

Run:
```bash
test -f /Users/goddessana/Developments/deep-kiss/skills/afterglow/SKILL.md && head -5 /Users/goddessana/Developments/deep-kiss/skills/afterglow/SKILL.md
```
Expected: file exists; first line `---`, second line `name: afterglow`.

- [ ] **Step 3: Commit**

```bash
git add skills/afterglow/SKILL.md
git commit -m "feat(afterglow): add SKILL.md orchestration"
```

---

## Task 4: Smoke Test Against deep-kiss Sessions

**Files:**
- Read-only: this project's own session JSONLs at `~/.claude/projects/-Users-goddessana-Developments-deep-kiss/`

No automated test exists for prompt-engineering skills. Verify end-to-end by invoking `/afterglow` in a real session and inspecting outputs.

- [ ] **Step 1: Inventory available sessions**

Run:
```bash
ls -la ~/.claude/projects/-Users-goddessana-Developments-deep-kiss/*.jsonl | wc -l
```
Expected: ≥1 session file. (If 0, the smoke test cannot run; skip to Step 5 and create at least one substantive session in this project, then return.)

- [ ] **Step 2: Trigger `/afterglow` in a fresh Claude Code session**

Open a fresh Claude Code session in `/Users/goddessana/Developments/deep-kiss` and type `/afterglow`. The main agent should:

1. Compute paths, list sessions, filter substantive.
2. Dispatch N harvester subagents (one per uncached session) in parallel.
3. Dispatch the merger.
4. Present candidates.

Observe and note: did the agent follow the orchestration without skipping steps? Did subagents return parseable YAML?

- [ ] **Step 3: Inspect cache directory**

After Step 2 completes (or fails), run:
```bash
ls -la "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/afterglow/-Users-goddessana-Developments-deep-kiss/" 2>/dev/null
```
Expected: one `.yaml` file per harvested session. Spot-check one file:
```bash
cat "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/afterglow/-Users-goddessana-Developments-deep-kiss/"<some-id>.yaml
```
Expected fields: `session_id`, `substantive`, `signals` (with the documented shape).

- [ ] **Step 4: Test the cache-hit path**

Trigger `/afterglow` a second time. The agent should print `"Harvested 0 new sessions (M cached)"` (no new harvester dispatches). Verify by watching dispatch output.

- [ ] **Step 5: Test a real candidate flow**

If at least one non-drop candidate surfaces, select it, approve the draft, and verify:
- For `memory-file`: the target file at the project root was modified (`git diff AGENTS.md` or `git diff CLAUDE.md`).
- For `skill`: both `.claude/skills/<name>/SKILL.md` and `.codex/skills/<name>/SKILL.md` exist (project scope) or `~/.claude/skills/<name>/` and `~/.codex/skills/<name>/` exist (user scope).

- [ ] **Step 6: Iterate on prompts if needed**

Common failure modes and fixes:
- *Harvester returns prose, not YAML* → tighten the "YAML only" constraint and re-test. Edit `stage1-harvester-prompt.md`.
- *Merger over-groups distinct topics* → strengthen "semantic topic similarity" guidance with a counter-example.
- *Bucket assignment feels off* → revisit the bucket override rules in `stage2-merger-prompt.md`.
- *Main agent skips cache check* → make the SKILL.md cache-check step more explicit.

After any prompt edit, commit:
```bash
git add skills/afterglow/
git commit -m "fix(afterglow): refine <prompt-name> based on smoke test"
```

- [ ] **Step 7: Final commit and verification**

Run:
```bash
git log --oneline | head -10
ls skills/afterglow/
```
Expected: 3+ commits for afterglow; directory contains `SKILL.md`, `stage1-harvester-prompt.md`, `stage2-merger-prompt.md`.

---

## Out of Scope (Explicitly Deferred)

The following were considered and intentionally deferred to keep v1 small:

- **Concurrency caps**: /insights uses `MAX_FACET_EXTRACTIONS = 50`. Afterglow has no cap. If a project has >50 substantive sessions, the dispatch may slow down; revisit if it becomes a problem.
- **Chunked transcript summarization**: /insights pre-summarizes >30K-char transcripts. Afterglow assumes each harvester subagent can handle a full session transcript directly. If sessions routinely exceed the subagent's context, add chunking similar to /insights's `formatTranscriptWithSummarization`.
- **Cross-project deduplication**: a `prescriptive_instruction` repeated across multiple *projects* (not just sessions within one project) is /insights's territory. Afterglow stays project-scoped.
- **Branched session deduplication**: /insights's `deduplicateSessionBranches` collapses multiple JSONL files for the same `session_id`. Afterglow treats each filename as a separate session for v1. If branch noise pollutes counts, revisit.
- **Skipping the in-flight session**: the JSONL currently being written may grow mid-run. The mtime cache invalidation handles this loosely (next run re-harvests it). A stricter approach (skip files modified within the last 5 minutes) is deferred.
