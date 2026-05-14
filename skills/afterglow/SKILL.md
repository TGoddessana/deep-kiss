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
