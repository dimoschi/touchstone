---
name: crap-controlled-changes
description: MUST be invoked BEFORE writing or editing any Go, PHP, or Python file in a repo that has opted into gating with a .crap-gated file at its root. This skill mandates TDD via superpowers:test-driven-development as its first step, targets CRAP (Change Risk Anti-Patterns) ≤6 soft / ≤8 hard on changed functions/methods, and runs a pre-commit per-function check via crap-check.sh. If you are about to write Go, PHP, or Python code in a repo with a .crap-gated marker and have not yet invoked this skill, STOP and invoke it now.
---

# CRAP-Controlled Changes

<EXTREMELY-IMPORTANT>
**STOP. Before reading anything else in this skill, before writing or editing any Go, PHP, or Python file, before responding to the user about implementation:**

1. Invoke `superpowers:test-driven-development` NOW.
2. Follow it strictly: write a failing test, see it fail, then implement.

This is non-negotiable. The CRAP gate at the bottom of this skill assumes ≥80% coverage on every changed function. Coverage that low only happens if you wrote tests first. If you skip this step, the pre-commit check will fail the coverage gate and you will have to redo the work.

You may not rationalize an exception. "Just exploring", "small change", "obvious code", "I'll add tests after" — none of these are valid. Every code-writing turn in this session must begin with a failing test.
</EXTREMELY-IMPORTANT>

The goal of this skill is to keep AI-generated changes small, well-tested, and easy to reason about by holding changed functions to a CRAP score of ≤6 (soft target) or ≤8 (hard ceiling). CRAP is defined as `comp(m)^2 * (1 - cov(m)/100)^3 + comp(m)`, where `comp` is cyclomatic complexity and `cov` is per-function test coverage as a percentage.

## Workflow

1. **TDD first** (see the EXTREMELY-IMPORTANT block above). Do not proceed past this point until `superpowers:test-driven-development` has been invoked for this change.
2. **While writing**, apply the Signal A heuristics below to shape each function as you go.
3. **Iterate with the repo's own test command**, not with the gate. The gate is not a test runner: it runs the whole suite *twice* per invocation, a baseline and your change, because that is how it attributes coverage to the diff. Use `go test ./...`, `pytest`, `phpunit`, whatever the repo uses, while you work.
4. **To commit, run `crap-commit.sh`.** It runs the gates itself, so running `crap-check.sh` first is a second full double-suite run that buys nothing: when the gate is red the wrapper prints that same output, `== NEXT_ACTION ==` included, and refuses to commit. Run `crap-check.sh` alone only to see the score without attempting a commit. It auto-detects the languages of your staged files; for language-specific setup and gotchas see `go.md` (Go), `php.md` (PHP), or `python.md` (Python) in this skill directory.
5. **Do exactly what the `== NEXT_ACTION ==` block says** (see Signal B below).

**Never background a gate and poll it with `sleep`.** Run it in the foreground with an explicit Bash `timeout` of up to `600000` ms. A `sleep` longer than the 120s default is cut short without saying so, so the wait becomes a guess that silently fails and gets repeated; one blocking call costs the gate's real duration and nothing more. `600000` ms is the tool's maximum, i.e. **10 minutes**, which is enough for the CRAP and dead-code gates but not always for a first mutation run. What to do then is in Signal C. Note what this rule forbids: polling, not `run_in_background`, which does not poll and has its own limits described there.

**Never pipe a gate, not even into `tail`.** `$?` after a pipeline is the last command's status, so `mutation-check.sh | tail -45` reports tail's exit 0 however the gate ended, turning a red gate into a reported pass; `tail` and `head` also cut off the findings the gate exists to print. Redirect and read the file: `<gate> > /tmp/gate.log 2>&1; echo "EXIT=$?"`, then Read `/tmp/gate.log`. A PreToolUse hook (`hooks/gate-pipe-gate.py`) refuses the piped form. `mutation-check.sh` also restates its own verdict as its final line (`mutation-check: EXIT=1 KILL_SURVIVORS; every mutant row is in <abs path>`) and keeps every row in that log, so read that line rather than trusting `$?`, and open the log rather than scrolling. `crap-check.sh` and `deadcode-check.sh` do not do this yet: for those the exit code is still the only verdict.

**`go` is often not on your PATH, and the failure looks like nothing else.** mise resolves toolchains per directory while the agent's shell initialises once, somewhere else, so in any repo whose Go comes from mise (`go = "1.26.6"` in `mise.toml`) every Go gate dies immediately with `go not on PATH`. That is a setup failure, exit 2, and it is neither a pass nor a timeout: a one-second gate run is this, not a fast repo. Prefix the command, `mise exec -- <gate>`, and the same for `go test` while you iterate.

## Signal A: Heuristics While Writing

You estimate CRAP per function in your head, with no tooling. The point is to shape the first draft.

**Complexity heuristic:** about 1 + count of `if`, `else if`, `for`, `case`, `&&`, `||`, and any early `return` past the first.

**Coverage heuristic:** if you are following strict TDD, assume 100% on new code. For functions you only modify, look at existing test coverage.

**Memorised CRAP table** (no math needed at write time):

| Complexity | Coverage 100% | Coverage 80% | Coverage 50% |
|------------|---------------|--------------|--------------|
| 3          | 3             | 3.0          | 3.4          |
| 5          | 5             | 5.2          | 8.1          |
| 7          | 7             | 7.4          | 13.1         |
| 10         | 10            | 10.8         | 22.5         |

**Practical rule:** at coverage ≥80%, complexity ≤7 keeps CRAP under the hard threshold. If a function has more than ~6 branches, stop and split it.

**In-flight anti-pattern triggers** (any of these means stop and refactor before continuing):

- Nested conditionals more than 2 deep
- Function longer than ~40 lines
- A `switch`/`case` with more than 5 arms doing non-trivial work
- A function mixing I/O, business logic, and error mapping in one body

When triggered, your next action is to extract a helper, not to keep typing.

**Assertion obligations (the mutation-gate half of Signal A).** Coverage asks whether a line ran; the mutation gate asks whether an assertion would notice if that line were wrong. Four constructs create an obligation the moment you type them, and they account for nearly every survivor this gate finds:

| You write | You owe |
|---|---|
| an error return (`fmt.Errorf("x: %w", err)`, `raise`, `throw`) | a test that enters the branch and asserts the message and the wrapped cause, not just that an error occurred |
| a comparison or boundary (`<`, `<=`, `==`) | a case on each side of it, including the boundary value |
| a returned value | an assertion on the value, since every return gets replaced by its zero value |
| a branch you cannot construct an input for | nothing: it is dead code, so delete it now with a comment saying why, rather than after a survivor points at it |

The first row is the one that surprises people: one untested error branch produces three or four survivors by itself, because the guard, the wrap, and the return are separate mutators. That reads as a crop of failures when it is a single missing test. The per-language catalogs (`go.md` Signal C) list exactly which mutators run, so you can predict this rather than discover it.

## Signal B: Pre-Commit Check (the Decision Policy, executed by the tool)

After you believe the change is complete, but before producing a commit:

1. Stage the change: `git add <paths>`.
2. Run `crap-commit.sh` (it dispatches per language; see `go.md`, `php.md`, or `python.md` for setup notes). It gates first and commits only if green, so this step and the commit are one call, not two.
3. Read the `== NEXT_ACTION ==` block at the end of the output and do exactly what it says. Do not re-derive the policy yourself; the tool tracks refactor attempts per function across runs (state in `.git/crap-check-state.json`, keyed by branch), so re-running is always safe and an unchanged re-run never burns an attempt.

The directives, and your move for each:

- **`COMMIT_OK`** (exit 0): gate is green, commit. Copy any "note for commit body" lines into the commit body verbatim.
- **`WRITE_TESTS`**: new/worsened functions are under 80% coverage. Do not refactor, do not edit source. A high CRAP score here is a symptom of missing tests, not of bad structure. Invoke `superpowers:test-driven-development`, write the tests, see them pass, re-run. Surface to the user only if the function is genuinely untestable as written (then extracting *to make it testable* is the right call, a structural conversation rather than a CRAP refactor).
- **`REFACTOR`**: over threshold with attempts remaining (1 for SOFT, 2 for HARD). Make one focused pass per listed function (extract a helper, flatten a conditional), then re-run. For `package main` functions (thin-main rule, complexity ≤5) the fix is never testing `func main()`: extract logic into a testable sibling package (e.g. `internal/app`) and leave main as wiring.
- **`SURFACE_TO_USER`**: attempts exhausted. Stop editing. Ask the user, quoting the message the tool prints. Only on explicit user approval run `crap-check.sh --accept '<function-id>'`, then re-run. Never run `--accept` on your own judgment.

Two rules the tool applies that you get for free: legacy functions you touched but did not worsen (tag `unchanged`) pass with a "remains at CRAP=x" commit note (no worse than found), and a user acceptance is revoked automatically if the function later worsens beyond the accepted score.

**Commit with `crap-commit.sh`, never with `git commit` directly:**

```
""/skills/crap-controlled-changes/crap-commit.sh <absolute-repo-path> -m "message"
```

It runs the gates in that repo (CRAP, then dead-code) and, only if both are green, commits the staged diff SSH-signed.

**The dead-code gate** (`deadcode-check.sh`, Go only) blocks functions your diff adds that nothing can reach from any main package. It exists because CRAP and mutation testing both *reward* covered, asserted code, so a speculative helper plus a test for it passes them — the test is what makes it look alive. `deadcode` runs without `-test` on purpose, so a helper whose only caller is its own test is reported. Only symbols the diff adds are checked, so existing dead code never blocks new work. Unreachable is not always deletable (a method may exist to satisfy an interface nothing calls yet), so there is a recorded escape hatch, on explicit user approval only: `deadcode-check.sh --accept '<file>|<symbol>'`, with `--revoke` to drop one once it is reachable again. In a multi-module repo each changed module is analysed from every module that replaces it as well as from itself, and a symbol is dead only when every root that actually built its package reports it unreachable: a shared library's callers live in the consumer module, so analysing the library alone flags its whole exported API. A module no main package can reach is skipped loudly rather than passed silently, and symbols whose package no root built are reported as not analysed. Stage your files first; `-a` (and `-am`, and any short cluster containing `a`) is refused, because it stages at commit time and the gate scores the index. Extra `git commit` flags pass through, so `--amend` and `--no-edit` work.

The repo is an explicit absolute argument on purpose. A PreToolUse hook (`hooks/crap-commit-gate.py`) refuses raw `git commit` in scope and points here. It used to instead *infer* which repo a commit would land in by parsing `cd`, `git -C` and `--git-dir` out of the command, and every form it failed to parse was a silent bypass of both this gate and the signing rule. Naming the repo removes the question rather than answering it better, and signing now has one implementation instead of a regex that approximated it.

### Cognitive complexity (advisory)

If `crap-check.sh` prints a "Cognitive complexity" section after the CRAP table, functions over the threshold (default 15) are flagged but not blocking. CRAP catches "big + untested"; cognitive complexity catches "tangled to read", typically the deep nesting AIs tend to produce. Treat each flagged function as a structural review prompt: can the branching be flattened (guard clauses, early return, extracted predicate), or is it essential to what the function does? Acting is a judgment call, not a gate.

Do not refactor a function purely because cognitive complexity is high if CRAP is OK and the structure reads cleanly. Two metrics gaming each other is worse than one metric well-followed.

## Signal C: Pre-PR Mutation Check

Coverage proves the tests *execute* the code; mutation testing proves they *assert* on it. After the CRAP gate is green and the branch work is committed, before opening a PR, run:

```
""/skills/crap-controlled-changes/mutation-check.sh
```

It mutates only the lines changed vs the diff base (origin/HEAD, then main/master; override with `MUTATION_BASE`) using pinned deterministic tools per language (Go: quality-gates/mutago, PHP: infection, Python: mutmut + pattern wrapper) and prints normalized rows plus a NEXT_ACTION:

- **`MUTATION_OK`** (exit 0): every mutant of your changed lines was killed. Done.
- **`KILL_SURVIVORS`** (exit 1): each `SURVIVED` row shows a concrete code change your tests cannot detect, with the mutation diff and (Go) a kill hint. Write a test that fails on the mutated code and passes on the original. Never weaken or restructure the production code just to dodge a mutant; if a mutant is genuinely equivalent (undetectable by any test), surface it to the user instead of looping.

**Ask `--verify` first; it costs milliseconds.** `mutation-check.sh --verify [branch]` reads the ledger and answers whether the branch is already recorded green, without measuring anything. Only when `--verify` reports the ledger missing or stale do you owe a real run. Skipping this step is how a branch that has been green for hours gets re-measured from scratch.

**Then measure, rather than assuming the run is long or short.** The duration belongs to the repo's test suite, not to this gate, and it varies by orders of magnitude: minutes for a package whose tests are pure, tens of minutes where they are not. Predict from the cause rather than from a number. Every mutant is one test run of its package, compiled through an overlay so build artefacts never cache-hit, so a suite that reaches a database reaches it once per mutant. Expect tens of minutes where mutants hit a database or another live service, seconds to low minutes where they do not, and confirm before reporting.

**Run it in the foreground with `timeout: 600000`.** Above that ceiling neither escape is free. `run_in_background` is not subject to the ceiling and does not poll, but it is only *proven* to about 12 minutes. Beyond that it is known to fail: long backgrounded runs get killed by SIGTERM to the process group, surfacing as `exit: 143`. Sleep is not the cause, since sleep sends no signal, which is why `caffeinate` does not help; nor is memory pressure, since jetsam sends SIGKILL 137 and leaves `memorystatus` entries in the system log. So for a repo already known to cost tens of minutes, hand the user the exact command to run in their own terminal, where it has no such ceiling. Do not rediscover this threshold by losing a run to it. After one green run is recorded, every later run narrows to the files you dirtied.

**A follow-up run measures only what you dirtied**, and prints what it skipped (`incremental scope, 1 of 7 changed source file(s)`). The ledger is keyed per path and lives in the repository's common git dir, so it is shared across worktrees and survives `git worktree remove`: a file whose blob is unchanged since the last green run already has a record and re-measuring it produces the same claim, whichever worktree measured it.

**A merge inherits the branch's records**, because merging preserves blobs. A record is borrowed across branches only when the commit that measured it is reachable from the ref being verified and the tool versions still match, and each one is named on stdout (`borrowed: ...`) rather than assumed. So the post-merge run on `master` normally measures nothing, while an abandoned branch's record, a rebase that rewrote the content, or a bumped mutago all fall back to measuring. PHP and Python passes record no fingerprint (no cheap version handshake), so their records stay branch-local. The same borrow applies to the CRAP ledger, where it also covers a branch stacked on an unmerged one; there the record is anchored after the commit exists (`crap-commit.sh` calls `crap-check.sh --anchor-committed`), because the gate scores the index and a parent-commit anchor would let any sibling branch inherit the claim. An adoption (`--mark-scored`) is never borrowed, so a per-branch override stays one.

A changed *or deleted* test pulls its own package's changed sources back in; PHP and Python have no reliable test-to-source mapping, so any test change there re-measures the whole set. This makes the gate cheap enough to run after each commit rather than once at the end, which is where survivors are cheapest to fix: the pre-PR run then usually has nothing left to do. `mutation-check.sh --full` measures every changed source, which is what you want when something outside the ledger's key can change a verdict (a fixture, a compose file, a toolchain pin). Narrowing is disabled on a dirty tree, and one thing it deliberately does not chase is a changed source in *another* package that a kill depended on; use `--full` if you have just moved shared test helpers around.

Not a commit gate: a mutation run costs one test-suite run per mutant, so it runs pre-PR, not per commit. It is enforced mechanically at that boundary: a PreToolUse hook (`hooks/mutation-pr-gate.py`) runs this check on `gh pr create` / `gh pr ready` in scope and blocks while the gate is red. The Go module requires a clean working tree, because a measurement is only recordable for the committed content the ledger keys on (mutago itself leaves the tree alone: v2.8.1 writes mutants to a temp dir and substitutes them via `go test -overlay`). Python repos should set `[tool.mutmut] source_paths` in pyproject.toml and gitignore `mutants/`. PHP repos need an `infection.json` declaring `source.directories`, for the same reason: which directories are source is a project decision, and the gate refuses (exit 2) rather than guessing. The gate copies that config with a `logs.json` logger injected, because infection 0.34 exposes the per-mutant report only as a config key and has no `--logger-json` flag. Concurrency is handled in the skill, not in your prompt. The Go gate measures its
HEAD baseline in a throwaway `git worktree`, so parallel runs share nothing. PHP
and Python cannot do that (they run their suites in-tree and need gitignored
`vendor/` and `.venv/`), so they still stash, and the stash stack belongs to the
repository rather than the worktree: two overlapping runs would pop each other's
staged changes. Those two therefore take a repo-global lock
(`$(git rev-parse --git-common-dir)/crap-check-stash.lock`, see `lib/repo-lock.sh`)
and wait rather than interleave. A run killed mid-stash leaves the lock behind
with its pid in it; the next run clears it once that pid is gone. `CRAP_LOCK_WAIT`
caps the wait (default 900s). Do not add your own locking around gate runs.

Env knobs: `MUTATION_GO_TEST_FLAGS`, `MUTATION_PHP_INFECTION`, `MUTATION_PHP_CONFIG`, `MUTATION_PHP_THREADS`, `MUTATION_PY_RUN`. The Go run is CPU-bounded to `cores/4` parallel mutants at `GOMAXPROCS=2` each, since mutago's own default is one worker per core and each worker runs a full `go test`; raise with `MUTATION_GO_WORKERS` / `MUTATION_GO_MAXPROCS` on a machine that can take it.

## Out of Scope

- CI enforcement: not in v1.
- Languages other than Go, PHP, and Python: JS/TS and others may be added as additional procedure files alongside `go.md`, `php.md`, and `python.md`.
- Python entrypoint special-casing (a `package main` analogue): not in v1. All Python functions get the normal CRAP + coverage gate.
- Repo-level dashboards or trend tracking.
- Per-repo or per-directory threshold overrides.
