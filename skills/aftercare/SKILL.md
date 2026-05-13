---
name: aftercare
description: "Use when the user invokes /aftercare to capture lessons from a just-fixed mistake or to retrospectively review a session for skill/memory candidates. Dispatches two stages of subagents — Stage 1 judges candidates against 4 criteria (recurrence/generalizability/proceduralization/trigger-clarity), Stage 2 drafts the artifact (skill bundle or memory-file entry). User-explicit invocation only; do NOT trigger automatically. Do NOT use for in-progress debugging — only after a mistake is fixed."
---

# aftercare — Post-Fix Mistake-to-Skill Capture

Series flow: **flirt**(explore) → **deep-kiss**(confirm) → implement → **aftercare**(restorative care).

After fixing a mistake, or at a session retrospective moment, the user invokes `/aftercare`. The main context acts only as a thin orchestrator — judgment and drafting are delegated to subagents to keep the main context clean.

## When to use

- When the user explicitly invokes `/aftercare`
- Never trigger automatically

## Outputs (3 buckets)

- `skill`: write a new skill file (SKILL.md + `scripts/`, `references/` if needed)
- `memory-file`: a short addition to `AGENTS.md` or `CLAUDE.md` at the project root
- `drop`: not worth capturing — do nothing

## Orchestration Checklist

Execute in order. Each step is short; the main context handles only dispatch and user interaction.

### 1. Stage 1 dispatch (candidate extraction + judgment)

1. Prepare the recent conversation context as the dispatch payload. Heuristic: "from the point where the last user intent started, up to the present." When in doubt about how much to include, err on the side of *more* — include the whole thing rather than trimming.
2. Dispatch a subagent with the body of `skills/aftercare/stage1-judge-prompt.md` as the prompt and the above context as input.
3. Result schema:
   ```yaml
   candidates:
     - topic: <one line>
       bucket: skill | memory-file | drop
       rationale: <one line>
   ```

### 2. Present candidates + user selection

- 0 candidates → "No capture candidates found in the recent context." Exit.
- 1 candidate → Show bucket and rationale, then ask "Shall we proceed?" once.
- N candidates → Present a numbered list. "Which would you like to process? (all / number list / cancel)"

### 3. Process each selected candidate (branch)

**drop**: One-line notice: "Not recording — reason: <rationale>." Move to next candidate.

**memory-file**:
1. Check whether `AGENTS.md` and `CLAUDE.md` exist at the project root → note as `project_state`.
2. Dispatch a subagent with `skills/aftercare/stage2-memory-drafter-prompt.md` as the prompt. Input: candidate + project_state.
3. Result schema:
   ```yaml
   artifact_type: memory-file
   target_file: AGENTS.md
   operation: append
   section_heading: "## ..."  # omit unless operation=insert-section
   content: |
     ...
   notes: ...
   ```
4. Show the user `target_file`, `operation`, and a content preview, then ask for approval.
5. Approved → if `target_file` doesn't exist at the project root, create an empty file (one-line notice), then append or insert into the specified section. Rejected with feedback → re-dispatch (2 attempts total). If the limit is exceeded, show the last raw output and ask the user to handle it manually.

**skill**:
1. Ask the user a scope question:
   > "Where would you like to install this skill?
   > (1) project — `./.claude/skills/<name>/` + `./.codex/skills/<name>/`
   > (2) user — `~/.claude/skills/<name>/` + `~/.codex/skills/<name>/`"
2. Dispatch a subagent with `skills/aftercare/stage2-skill-drafter-prompt.md` as the prompt. Input: candidate + rejection feedback if this is a re-dispatch.
3. Result schema:
   ```yaml
   artifact_type: skill
   skill_name: <kebab-case>
   files:
     - path: SKILL.md
       content: |
         ...
     - path: scripts/...
       content: |
         ...
   notes: ...
   ```
4. Show the user the file list, a preview of the first ~30 lines of each file, and `notes`, then ask for approval.
5. Approved → write files to both the *Claude Code path* and the *Codex path* for the selected scope. If `.codex/` doesn't exist, mkdir it and give a one-line notice. On filename conflict, ask the user: overwrite / rename / skip.
6. Rejected with feedback → re-dispatch (2 attempts total). If the limit is exceeded, show the last raw output and ask the user to handle it manually.

### 4. Closing summary

When a single `/aftercare` invocation is fully processed, print a one-line summary: "Result: skill ×A (path: ...), memory ×B (file: ...), drop ×C."

## Errors / Edge Cases

| Situation | Handling |
|-----------|----------|
| Stage 1 output parse failure | Re-dispatch once (with structure-correction instruction). If it still fails, show raw output and ask the user to decide. |
| Stage 2 output parse failure or user rejection | Up to 2 total retries (attach feedback/error to input). If exceeded: raw output + ask user to handle manually. |
| Rejection with no feedback | Ask "What should be changed?" once; if no response, skip that candidate. |
| Filename conflict (skill) | User chooses: overwrite / rename / skip. |
| `.codex/` directory absent | mkdir + one-line notice. |

## Constraints

- Never trigger automatically — user-explicit invocation only.
- No direct judgment or drafting in the main context — delegate everything to subagents.
- Do not touch `~/.claude/MEMORY.md` or the auto-memory system.
- Only `AGENTS.md` or `CLAUDE.md` at the project root are valid memory-file targets.
