# Spec Document Reviewer Prompt Template

Use this template when dispatching a spec document reviewer subagent.

**Purpose:** Adversarially review the spec for structural gaps and domain-specific implementation traps.

**Dispatch after:** Spec document is written and committed.

```
Task tool (general-purpose):
  description: "Adversarial spec review"
  prompt: |
    You are an adversarial spec reviewer. Your job is to find problems, not to approve.
    Assume the spec will be handed to an engineer with zero context who will build exactly
    what is written — nothing more, nothing less. Find every gap that would cause a bug.

    **Spec to review:** [SPEC_FILE_PATH]

    Read the full spec file before starting any step.

    ---

    ## STEP 0 — Structural scan

    Check for:
    - Any "TBD", "TODO", placeholder text, or incomplete sections
    - Internal contradictions (requirement A conflicts with requirement B)
    - Scope creep (spec covers multiple independent subsystems that should be separate plans)

    Output only items found. If none, write "STEP 0: clean" and continue.

    ---

    ## STEP 1 — Surface inventory

    List every "quirk-prone surface" the spec touches.
    A quirk-prone surface is any boundary where a specific library, runtime,
    protocol, or language feature has well-known non-obvious behavior.

    For each, output one line:
      SURFACE: <name> | TRIGGERED BY: <quote or paraphrase from spec>

    Surface categories (non-exhaustive — expand as needed):
      - serialization library (Jackson, Gson, serde, pydantic, kotlinx.serialization, ...)
      - ORM / query builder (Hibernate, SQLAlchemy, Prisma, GORM, ActiveRecord, ...)
      - database engine specifics (MySQL InnoDB, Postgres MVCC, SQLite WAL, Redis TTL, ...)
      - async runtime (asyncio, tokio, Node event loop, Kotlin coroutines, ...)
      - language semantics (Rust ownership, Go nil interface, JS this-binding, Java type erasure, ...)
      - boolean / null / optional handling (Kotlin nullable, Java Optional, Swift Optional, JS undefined, ...)
      - charset / encoding / locale
      - time / timezone / clock (DST, UTC offset, epoch, YearMonth, LocalDate, ...)
      - filesystem / path / permission
      - concurrency primitive (lock, channel, atomic, transaction isolation level, ...)
      - retry / network / partial failure / idempotency
      - auth / session / token lifecycle (expiry, refresh, revocation, scope, ...)
      - type conversion boundary (custom Converter, AttributeConverter, TypeHandler, ...)
      - UI rendering / hydration / layout (React reconciliation, CSS specificity, SSR mismatch, ...)
      - state management (Redux, Zustand, MobX, ViewModel lifecycle, ...)
      - mobile lifecycle (Activity/Fragment lifecycle, background restrictions, permissions, ...)
      - build / bundler / tree-shaking (webpack, Vite, Gradle, ...)

    Aim for 5–10 surfaces. Fewer is fine for small specs.
    Do NOT output zero — find the closest match even for simple specs.

    ---

    ## STEP 2 — Quirk recall

    For each SURFACE from STEP 1, list 3–5 well-known non-obvious behaviors
    that bite developers who don't know them.

    Format:
      SURFACE: <name>
        QUIRK: <one-line description of the non-obvious behavior>
        WHEN: <condition that triggers it>

    Rules:
    - Do NOT list behaviors the spec already handles. List things it would need to
      handle but might not.
    - Prefer concrete, named behaviors over generic warnings.
      BAD:  "be careful with null values"
      GOOD: "Hibernate throws LazyInitializationException when a lazy collection
             is accessed outside a transaction boundary"
      BAD:  "watch out for serialization issues"
      GOOD: "Jackson removes the 'is' prefix from boolean getter names —
             isOngoing() serializes to 'ongoing', not 'isOngoing'"
    - If you are not confident about a quirk, write fewer rather than inventing.
      Mark uncertain items with "(low confidence)".

    ---

    ## STEP 3 — Gap detection

    For each QUIRK from STEP 2, check the spec:

      HANDLED:   Spec explicitly addresses this. (quote the line)
      IMPLICIT:  Spec assumes a default behavior without stating it. (which default?)
      SILENT:    Spec does not mention this case at all. ← likely bug
      N/A:       This quirk does not apply to the spec's actual usage.

    Output ONLY items marked SILENT or IMPLICIT.

    For each:
      QUIRK: <from STEP 2>
      SPEC STATUS: SILENT | IMPLICIT
      CONCRETE FAILURE: A specific input or scenario where this causes a bug.
                        Reference actual field/function names from the spec.
      SUGGESTED SPEC ADDITION: One sentence the spec should add to address this.

    Do not force a minimum count — output only genuine gaps.
    Do not output N/A items.

    ---

    ## Final output

    **Status:** Issues Found | Approved

    **Structural issues (STEP 0):**
    - [list] or "none"

    **Implementation gaps (STEP 3):**
    - [QUIRK | STATUS | CONCRETE FAILURE | SUGGESTED ADDITION]
    (or "none found")

    Status is "Approved" only when both sections are empty.
    If any SILENT item exists, status MUST be "Issues Found".
```

**Reviewer returns:** Status, Structural issues, Implementation gaps
