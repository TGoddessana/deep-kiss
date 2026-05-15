---
name: afterglow
description: "Use when the user invokes /afterglow to retrospectively scan the current project's past Claude Code sessions for repeated user corrections or workflow patterns. afterglow is an analyst: it surfaces patterns with verbatim evidence and offers to hand selected candidates to aftercare for capture. afterglow itself does NOT decide bucket, draft skills, or write files. Project-scoped. User-explicit invocation only; do NOT trigger automatically."
---

# afterglow — Retrospective Pattern Surfacer

`aftercare` and `afterglow` are two entry points to the same goal — capturing reusable learning from the project — and differ only in *discovery*:

- **aftercare**: in-session capture, using the rich current conversation context.
- **afterglow**: retrospective scan across past sessions, surfacing patterns that repeated across runs.

afterglow finds candidates and presents them with evidence. It then asks whether to hand the selected ones to `aftercare`, which owns the judgment (skill / memory-file / drop) and the drafting. afterglow itself never drafts and never writes files.

## When to use

- The user explicitly invokes `/afterglow`. Never auto-trigger.
- For in-session capture of a just-fixed mistake, use `aftercare` instead.

## Orchestration

### 1. Compute paths

1. Get the current working directory: `pwd`.
2. Encode it as a project path: replace every `/` with `-`. Example: `/Users/x/y` → `-Users-x-y`.
3. Resolve the Claude config base: `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`.
4. `SESSIONS_DIR = ${BASE}/projects/${ENCODED}`.
5. `CACHE_DIR = ${BASE}/afterglow/${ENCODED}`. Create it if absent: `mkdir -p`.

If `SESSIONS_DIR` does not exist, print "No prior sessions found for this project." and exit.

### 2. List recent substantive sessions

Call the bundled helper script in a single Bash invocation (path is relative to this skill's root):

```
bash scripts/list-substantive-sessions.sh "${SESSIONS_DIR}"
```

The script sorts by mtime descending, drops sessions with `user_message_count < 2` OR `size < 4096` bytes, and caps the output at the **most recent 50** by default. Override with `--limit N` (or `--limit 0` for unlimited) only when the user explicitly asks for a wider scan.

**Do NOT inline this as a shell loop** (`cd ~/.claude/projects/<encoded> && for f in *.jsonl ...` or any `for`/`while` over the sessions directory with `grep`/`wc` substitutions). Auto-mode permission classifier blocks those patterns. Always go through the helper.

If the output is empty, print "No substantive sessions found for this project." and exit.

### 3. Ensure compressed transcripts are cached

For each session path, with `session_id = <filename without .jsonl>`:

1. Target: `${CACHE_DIR}/<session_id>.txt`.
2. If the target exists AND its mtime is newer than the source `.jsonl`, mark as **cached** — skip compression.
3. Otherwise run `bash scripts/compress-session.sh <jsonl_path> ${CACHE_DIR}/<session_id>.txt`. The script writes `[User]: ...` / `[Assistant]: ...` / `[Tool: NAME]` lines (typical reduction 40–50×).

Print a one-line summary: `"Compressed N new (M cached)."`

### 4. Dispatch the analyst

Dispatch a single subagent (one `Agent` tool use):

- **Prompt**: body of `analyst-prompt.md`.
- **Input**: a list of `(session_id, transcript_path)` pairs covering the substantive set. The subagent will `Read` each `.txt` itself — the main context never reads transcript content.
- **Expected output**: YAML matching the analyst schema (`sessions_scanned`, `candidates`, `also_seen`).

Parse the YAML. On parse failure, re-dispatch once with a structure-correction note. If it still fails, print the raw output and ask the user how to proceed.

### 5. Present candidates

- `candidates: []` → "No repeated patterns found across N sessions." Print `also_seen` topics as a one-liner if any (for transparency). Exit.
- Otherwise, for each candidate, render:

  ```
  N. [×<count>] <topic>
     Evidence:
       • "<verbatim quote>"  (session <id[:8]>)
       • "<verbatim quote>"  (session <id[:8]>)
     Pattern: <detail>
  ```

- After the list, if `also_seen` is non-empty, append one line: `"Also seen once each: <topic>, <topic>, ..."` (truncate to ~5).

### 6. Offer hand-off to aftercare

Ask the user:

> "캡처할 패턴이 있나요? aftercare를 트리거하면 메모리/스킬로 만들 수 있습니다.
> 선택: (숫자 / all / no)"

Branches:

- **`no` or cancel** → "OK. /aftercare 직접 호출하셔도 됩니다." Exit cleanly. No files written.
- **숫자 / `all`** → Echo the selection back in plain text so it becomes part of the conversation context: `"선택된 패턴: 1, 3 — aftercare로 넘깁니다."` Then invoke `Skill(aftercare)` so its stage-1 judge picks up the presented candidates from the conversation. afterglow's job ends here; the rest is aftercare's flow.
- **`Skill(aftercare)` unavailable or fails** → Fall back to printing `"/aftercare 를 다음 메시지로 호출해주세요."` while keeping the candidate list on screen. Same destination either way.

## Errors / Edge Cases

| Situation | Handling |
|-----------|----------|
| `SESSIONS_DIR` missing | Step 1: "No prior sessions found for this project." Exit. |
| Substantive set empty | Step 2: "No substantive sessions found for this project." Exit. |
| Single compression failure | Log a one-line warning, continue with the remaining sessions. |
| Analyst YAML parse failure | Re-dispatch once with a correction note. If still bad: show raw output, ask user. |
| Zero candidates | Step 5: clean exit, with `also_seen` summary if any. |
| User rejects hand-off | Step 6: clean exit, no writes. |
| `Skill(aftercare)` chaining unsupported | Step 6: fall back to "type `/aftercare` next". |

## Constraints

- **User-explicit invocation only.** Never auto-trigger.
- **No drafting in afterglow.** It does not write skills, memory entries, or any files under `.claude/skills/`, `AGENTS.md`, `CLAUDE.md`, or `~/.claude/MEMORY.md`. That work belongs to `aftercare`.
- **No bucket decision in afterglow.** aftercare's 4-criteria judge owns skill / memory-file / drop.
- **Main context never reads transcripts.** Only metadata (mtime/size/grep counts via the helper script) and the analyst's structured YAML output enter the main context.
- Compressed `.txt` cache is append-only; do not delete on failure. Stale `.yaml` files from previous afterglow versions in the cache directory are harmless — leave them.
