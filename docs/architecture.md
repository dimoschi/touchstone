# Architecture

Touchstone is a Claude Code plugin, not an application. Nothing here runs as a service.
What ships is installed into *other* repositories and executed there, which drives most
of the design below.

Two consequences to internalise before changing anything:

- **Scripts resolve their own location, never the cwd.** Every script derives
  `SKILL_DIR`/`LIB_DIR` from `${BASH_SOURCE[0]}`, because at runtime they live in a
  version-keyed plugin cache rather than in this checkout. Hooks use
  `${CLAUDE_PLUGIN_ROOT}`.
- **The target repo is not this repo.** A gate measures whatever repo the agent is
  working in. Anything that reads `git rev-parse` is asking about the target, so a hook
  must resolve which repo a command acts on before it can decide anything. All three
  gates also take that repo as an optional leading `<absolute-repo-path>` argument
  (matching `crap-commit.sh`'s existing one), so a caller can name it explicitly rather
  than relying on the process cwd, and print the repo root and branch they resolved as
  the first line of output on every code path.

## The gates (`skills/crap-controlled-changes/`)

Three entry points, each a language-agnostic dispatcher over `lib/`:

| Script | Measures | When |
|---|---|---|
| `crap-check.sh` | `complexity² × (1 − coverage)³ + complexity` per changed function | every commit |
| `deadcode-check.sh` | static reachability (**Go only**; exits 0 on other languages) | every commit |
| `mutation-check.sh` | surviving mutants on changed lines | before a PR |

`crap-check.sh` and `mutation-check.sh` detect the languages of staged files, delegate
to `lib/<gate>-<lang>.sh`, and normalise every module's output to one row format. The
real logic lives in the `lib/*.py` parsers, so bash stays orchestration. Prefer
extending a parser over growing a shell script.

`crap-commit.sh` is the only sanctioned way for an agent to commit: it runs both
commit-time gates, then `git commit`. It takes the repo as an explicit absolute path
rather than inferring it, because every parse failure in the old inference was a silent
bypass, and forwards that same path to the two gates it runs so they never fall back to
resolving it from the cwd either.

### Exit codes are a shared vocabulary

All three gates use the same codes. Do not invent new ones.

| Code | Meaning |
|---|---|
| 0 | green |
| 1 | red, findings to act on |
| 2 | setup problem (missing tool, not a repo, unsupported language) |
| 3 | stash restore failed (CRAP language modules only) |
| 4 | could not measure |
| 5 | unscored source on the branch (`crap-check.sh`), or unrecorded paths (`--verify`) |

`2` and `4` are not passes. A gate that cannot measure says so rather than reporting
green, because a gate that waves through what it cannot measure claims a guarantee it
never checked.

### Ledgers

`crap-check-scored.json`, `mutation-ledger.json`, `mutation-accepted.json` and
`deadcode-accepted.json` sit under `git rev-parse --git-common-dir`. The *common* dir,
not `--git-dir`: a per-ticket worktree would otherwise carry the record away when it is
removed.

They are content-addressed by blob SHA, so a record survives amend and rebase but
invalidates the moment the file's content changes.

Only their own tools write them. Never hand-edit a ledger and never regenerate one to
clear a failure: a gate that can be satisfied by editing its own record measures
nothing. `--accept` and `--mark-scored` are user-approved overrides, not agent moves.

### Thresholds and classification live in one place

`lib/thresholds.py` holds the four settings, their defaults, and the rule that
turns a complexity/coverage pair into a status. `lib/classify_rows.py` joins the
baseline and current measurements and prints the report rows. Both are shared by
all three language modules.

They used to be an awk program inside each of `crap-check-go.sh`,
`crap-check-php.sh` and `crap-check-python.sh`, plus a fourth copy in
`test/run-php.sh` which meant that suite verified its own replica rather than
the module. Per-repo settings are only possible with one implementation.

A repo sets any of the four in its `.crap-gated`, which already carries the
exemption patterns. The marker rather than the environment, because an
environment variable is settable by the agent under measurement. The coverage
requirement is not a setting: it is derived from the hard cap, so the two cannot
drift apart.

### Module resolution lives in one place

`lib/go_modules.py` answers "which module owns this file" for all three Go gates. It was
copy-pasted into each of them before, which let the gates disagree about what to measure
while all reporting green.

## The hooks (`hooks/`)

Python gates that read the tool call on stdin and refuse it. Shared git logic
(base-branch detection, `git -C` and `cd` chain resolution, marker lookup) lives in
`base_branch.py`, so two hooks cannot disagree about what a command targets.
`hook_invocation.py` normalises the payload itself, since each host names things
differently: `tool_input_path()` reads both `file_path` and `path`, and
`HookInvocation.host` is one of `claude`, `codex`, `copilot`.

### Eight policy gates, two manifests

The gates are the same on every host. What differs is how a host invokes them and how it
learns the verdict.

`hooks/hooks.json` is the Claude manifest. It invokes each gate directly, and **the exit
code is the verdict**. Every gate but one is `PreToolUse`, a refusal before the tool call
runs; `comment-policy-gate.py` is `PostToolUse`, since it inspects what a completed
Edit/Write/MultiEdit added rather than deciding whether to allow it.

`hooks/copilot-hooks.json` is the Copilot manifest. Every entry goes through one
dispatcher, `copilot-hook-runner.py <key>`, which looks the key up in a fixed allowlist,
runs the real gate as a child process with the same stdin, and translates the result
into Copilot's JSON contract (`permissionDecision: allow | deny` for `PreToolUse`,
`additionalContext` for `PostToolUse`). The dispatcher **always exits 0** and speaks its
verdict in JSON, so do not read its exit code as a result. Child stderr becomes the
denial (or context) text, bounded to 12 lines and 1200 characters.

Adding a gate therefore means touching both manifests and the runner's `HOOKS` map.

Four gates are opt-in via a marker. Three resolve it at the target repo root,
shared by every worktree even before a commit; `comment-policy-gate.py` reads
its own from the worktree being edited instead, since the marker carries
policy content a branch can change. That resolution (`worktree_root` plus a
plain `.exists()`) is a filesystem check, not a git one: the marker does not
need to be tracked or committed at all, an untracked file created directly in
that worktree gates it just the same. What it does need is to already be on
disk in *that* worktree; committing it on `main` does not by itself reach a
linked worktree that was created earlier, since the worktree's checkout is
fixed at the point it was cut and does not pick up a later commit to the
branch it started from on its own:

| Hook | Marker | Enforcement |
|---|---|---|
| `crap-commit-gate.py` | `.crap-gated` | refuses a raw `git commit`, naming `crap-commit.sh` instead |
| `contributing-gate.py` | `.crap-gated` | refuses the first edit until the repo's contribution guide has been read this session |
| `mutation-pr-gate.py` | `.mutation-gated` | refuses `gh pr create`, a merge onto a base branch, or a push at one, while the ledger is unverified |
| `comment-policy-gate.py` | `.comment-gated` | `PostToolUse`, so it cannot refuse; it flags (exit 2, non-blocking) a newly added comment matching one of the marker's own regex rules after the edit has already landed. The plugin ships no default rule |

Four fire everywhere, because each acts on its own evidence rather than on a marker:

| Hook | Evidence |
|---|---|
| `base-branch-commit-gate.py` | a commit on `main`/`master`/etc. Exempts a repo with no remote |
| `gate-pipe-gate.py` | a gate piped anywhere |
| `generated-file-gate.py` | an `@generated` or `DO NOT EDIT` header, which is the file's own consent |
| `worktree-edit-gate.py` | an `Edit`/`Write`/`MultiEdit` landing in the main checkout while a ticket worktree is active for the acting agent |

`gate-pipe-gate.py` applies while working in this repo too. `$?` after a pipeline is the
*last* command's status, so `mutation-check.sh | tail` reports tail's exit 0 however the
gate ended, turning a red gate into a reported pass. Redirect instead:

```bash
<gate> > /tmp/gate.log 2>&1; echo "EXIT=$?"
```

then read the file.

### An agent's own transcript is evidence a marker cannot be

`worktree-edit-gate.py` refuses an `Edit`/`Write`/`MultiEdit` that lands under the repo's
main checkout while a ticket worktree is active for the *acting* agent, so a subagent that
loses track of `git -C <worktree>` and reaches for a bare relative path cannot silently
edit the tree another session is using. "Active" is not a marker: a marker here would have
to be written by the dispatched agent itself, which is exactly the state under
measurement, not evidence of it. Instead the hook reads the payload's own `agent_id` and
that subagent's own transcript (`hook_invocation.subagent_transcript`, shared with
`contributing-gate.py`), and requires its first `type == "user"` entry to open with the
`[touchstone: <label>]` header and `Repo worktree: <path>` line every `treeAgent` dispatch
(`workflows/parts/20-setup-worktree.js.part`) stamps on once a worktree exists. A payload
with no `agent_id` (the invoking session) or a subagent whose transcript is missing or
never carries that header is waved through rather than refused: there is no opt-in marker
to fail closed behind, and failing closed on absent evidence would block every subagent's
first edit in every repo until its transcript happened to exist on disk. Only the
ticket worktree itself and the shared git directory (scratch path, gate ledgers) are
exempt; another worktree under `.claude/worktrees/` is refused too, since a session
running in a worktree of its own is where a stray relative path lands.

Known gap: a Bash command that writes a file (a redirect, `sed -i`, a script, a test
fixture writing fixtures of its own) is not covered. `base_branch.shell_tokens`'s own
docstring already gives the reason a command's write target cannot be recovered from its
text alone; the `treeAgent` prompt forcing `git -C <worktree>` for every git command, and
`base-branch-commit-gate.py`'s refusal of a commit on main, are what this hook leans on
for that path instead of modelling it itself.

### Guide-read evidence is host-specific

`contributing-gate.py` needs to know the contribution guide was actually read this
session. On Claude it inspects the session transcript. Copilot exposes no equivalent, so
the Copilot manifest carries a `PostToolUse` hook on `Read` that routes to
`copilot_session_evidence.py`, which records the read per session under
`TOUCHSTONE_HOOK_STATE_DIR` (falling back to `XDG_STATE_HOME`, then `HOME`).

Only that hook writes those records. An acknowledgement file the agent writes itself
does not satisfy the gate, which is the whole point: the evidence has to come from
something the agent does not control.

The module's own docstring states the boundary, and it is worth repeating rather than
discovering later. Local CLI hooks run as the invoking user, so same-UID shell code can
alter this state. These records are operational evidence, not a security boundary. A
threat model that needs one wants a policy-level or root-owned deployment instead.

## The workflow (`workflows/deliver-pipeline.js`)

A Workflow tool **script**, not a standalone program. It has no imports and executes
with runtime-provided globals (`agent`, `parallel`, `phase`, `budget`, `log`) plus
top-level `await` and `return`. CI parses it with `vm.compileFunction` wrapped in an
async IIFE for exactly that reason. It cannot be run with `node`.

The host needs it as one file, so it is generated: `scripts/build-pipeline.sh`
concatenates `workflows/parts/*.js.part`, in sorted-name order, into the committed
`workflows/deliver-pipeline.js`. Edit a part and rebuild; `--check` refuses a stale
build.

Structure, top to bottom: `meta` (phase titles must match the `phase()` calls exactly),
argument validation that throws early, `CEILINGS` per stage, then the phases in order.

### Setup: one dispatch for three unrelated facts

Before the worktree is cut, a single `agent()` call labelled `setup` (not a
`treeAgent`, since there is nothing to point it at yet) answers the ticket fetch, the
`plugin:version` probe, and the two gate markers together, against the `SETUP` schema.
Each sub-object (`ticket`, `version`, `markers`) keeps its own found/false fallback, so
a model that could not resolve one of the three still returns valid JSON for the other
two. Every git command it runs resolves the repo root itself
(`dirname $(git rev-parse --path-format=absolute --git-common-dir)`), since no worktree
path exists to be handed one; its only write is the one `git fetch origin <base>` the
version check needs. Checks discovery is not part of this call: it needs the worktree
path, which does not exist until the very next phase, so it rides on the `branch`/
`branch:existing` call instead (see Check discovery, below).

The run record (`.claude/touchstone-runs/<ticket>.json`) used to be written by a
dedicated `run-record` dispatch on every exit path. The script has no filesystem
access, so all it can do is name where the file belongs (`record_file`, sanitizing the
ticket arg to a safe basename) and hand back the full payload; the invoking session
(`commands/deliver.md`) writes it, the same session that already appends `run_id`,
`models` and `recorded_on` afterwards.

Two invariants the script exists to hold:

- **Every run needs a ticket**, and the marker (`gh-216` vs `jira-PROJ-4821`) is decided
  in the script by regex, never by an agent. The branch name is the run's only ticket
  link, so a guessed one is unrecoverable after the fact.
- **Ceilings are tripwires, not aborts.** A running agent cannot be stopped from the
  script, so `over()` is read only after an agent returns. That makes a ceiling a real
  bound only where it gates a further iteration (fix rounds, mutation attempts,
  re-review latches). `plan` and `implement` are deliberately uncapped. Do not describe
  these as hard per-call token limits.

`workflows/test-fix-loop-join.sh` drives the real script with stubbed globals, which is
how the loop logic is tested without spending tokens.

### Triage's involved verdict has to be earned

`involved` triples effort and ceilings against `routine` (see `EFFORT`/`CEILING_SCALE`),
so the script does not take the word alone: it stands only when `TRIAGE`'s response also
carries `involved_reason`, `expected_files`, and `expected_call_sites`, all non-empty. A
recognised `involved` verdict missing any of the three demotes to `routine` and logs why;
a ticket naming one file and one behaviour is routine unless triage can say otherwise.
This never touches the separate unrecognised-value fallback (an invalid `complexity`
string still defaults straight to `involved`), which is not a judgement about difficulty
at all, so there is nothing to demote it against.

### The run budget

`dispatch()` is the one function that ever calls the runtime's own `agent()`; a static
check in `test-static.sh` asserts nothing else does. Every `treeAgent` call and every
direct `agent()`-style call (`setup`, `branch`, `branch:existing`, `collapseDuplicates`'s
`review:dedup`) goes through it. Before Triage has sized the work, `runBudget` is `null`
and `dispatch()` never refuses; right after Triage, it is set to `100_000 + 1_500 *
estimated_loc` output tokens, clamped `300_000..1_000_000`, or a flat `300_000`/`600_000`
default by scope when triage gave no estimate, and `args.runBudget` overrides either.
From there, `dispatch()` refuses any call once `budget.spent()` has reached it.

Everything after that point runs inside one `try`/`catch`, so a refusal anywhere in the
run unwinds to a single halt rather than needing its own latch at every call site. Two
places have to re-check the flag explicitly rather than let it propagate on its own:
`parallel()` (used to run review lenses concurrently) catches each thunk's own throw and
hands back `null`, which would otherwise read as a lens that legitimately found nothing,
and `markStale`'s own `try`/`catch` would otherwise log the refusal as a merely failed
staleness probe. Both re-throw when `runBudgetSpent` is set. A stage still open when the
throw unwinds past its own `close()` -- the one actually running at the halt -- has its
spend folded into `stage_spend` by the catch, rather than silently dropped from it.

### What can hold a run: `classify()` and reproducers

A lens can raise up to `MAX_FINDINGS_PER_LENS` findings, and every one carries a
`category` from a closed enum. Only `BLOCKING_CATEGORIES` (`wrong-result`, `crash`,
`gate-bypass`, `unmet-criterion`) can stop the run, and only when the finding also
carries a complete `reproducer`: one command, run from the worktree root, that exits 0
when the code is correct. `classify(f, ctx)` is the pure function that turns a lens's
fields into a candidate (blocking, pending execution) or a note (reaching the PR body,
never the run), in this order: a content-identical or referenced re-report of something
already tracked drops; a reference to a *settled* finding becomes a `residual` note
instead; a non-blocking category, a missing reproducer, an `unmet-criterion` quote that
is not a verbatim substring of the ticket text, or (from the first re-review on) a line
span outside what the preceding fix or mutation range actually touched, each becomes a
note with its own `reason`. What survives is a candidate, and `executeAtHead()` is what
runs it: one haiku dispatch per batch, against the worktree's current HEAD, reporting
each row's raw, combined stdout and stderr verbatim alongside its exit code.

`outcomeOf(row)` is what turns that row into a disposition, and it is the only place
that does: no row is `not-executed`; exit 0 is `passed`, marker or not; 126 or 127 is
`could-not-run`; any other nonzero is `reproduced` only when the row's raw output (read
before `truncateOutput` ever runs on it) carries `REPRODUCED_MARKER` on a line of its
own, and `errored` otherwise. A command that fails for its own reasons -- a missing
environment variable, a wrong path, a syntax error -- exits nonzero same as a real
demonstration, and used to read the same way; a reproducer now has to prove it observed
the defect, not merely that it did not exit 0. `disposeCandidates()` opens a candidate
only on `reproduced`; `passed`, `could-not-run` and `errored` become a note with its own
reason (`did-not-reproduce`, `reproducer-could-not-run`, `reproducer-errored`) and its
`reproducer_run` (the outcome, the exit code, and the truncated output) attached so the
note keeps what actually happened.

`not-executed` is neither: a missing row is even less evidence than an errored one, so
it must not open a candidate on nothing, and it is no verdict at all, so it must not
become a note either -- the same rule #116 applies to a discovered check the runner
never measured. `executeAndDispose()` retries whatever comes back `not-executed` exactly
once, at the same head, as its own `executeAtHead()` call restricted to just those
candidates and labelled with the original label plus `:retry` -- run alone in the
worktree like every such call, so a dirty result there halts the same way. Whatever is
still `not-executed` after that halts the run (at Review for the initial review and the
post-mutation review, at Fix for a fix round's fresh candidates), naming each finding by
id and title and saying the halt is about measurement, not the code (gh-113).

`unmet-criterion` needs a reproducer too. The verbatim quote proves the criterion
exists; only an executed command shows the change misses it, and the alternative, a
model reading the code and declaring the criterion met, is the judgement blocking must
not rest on.

An open finding carries its latest `reproducer_run` into every fix brief, replaced each
round rather than accumulated. Exit 0 settles it regardless of the marker; nonzero with
the marker keeps it open as `reproduced`; nonzero without it keeps it open as `errored`,
and the brief says the reproducer itself failed to run, with its exit code and output, so
the fixer is not sent chasing a defect nobody demonstrated.

A settled finding is re-run at every head the code moves to after it settled: in every
later fix round (`reproduce:settled:<round>`) and at the mutation gate's head
(`reproduce:settled:mutation`), budget or not. `regressedOf()` splits what comes back into
`regressed` (still fails, `reproduced`/`could-not-run`/`not-executed`) and `errored`
(reproducer itself failed) and reopens both, logged separately: a fix nobody could
re-measure is not the same claim as one whose reproducer ran clean and still shows the
defect. Reopened findings get the next round if one is left; at the mutation head, where
no round follows, the run halts at Review with a note that counts undone and errored
fixes separately. Nothing here waits for a lens to report the regression, so a `residual`
note is only ever a note: whether a new finding is a *variant* of a fixed one is decided
by the lens setting `duplicate_of`, which is a judgement no exit code can make, and the
cost of that judgement being wrong is a line in the PR body rather than another round.

### Check discovery

Folded into the `branch`/`branch:existing` call's own last step (`checks_source` on
the `BRANCH`/`EXISTING_BRANCH` schema), rather than a separate `checks:discover`
dispatch: that call already has the worktree path open by the time it can answer,
since it derives that path itself in an earlier step. It reads only
`<worktree>/AGENTS.md` (or `CLAUDE.md`) and transcribes
every `##` heading and the fenced block that follows it verbatim, including its own
opening and closing marker lines; it chooses, filters and interprets nothing.
`checksFrom()` then selects the section whose heading is exactly `## Checks` (only
trailing whitespace ignored -- `## Commands`, `### Checks` and `## checks` all name
something else), drops the fence's marker lines, splits what remains into commands,
strips comments, and assigns each an id (`check:1`, `check:2`, ...) in declared order.
Every downstream consumer -- the runner, the baseline drop, the red list, the fix
brief -- keys on that id, never on the command text or a name a model invented.

A discovered check runs repeatedly on a blocking run: once as the environmental
baseline before Implement, then again after Implement, after the pre-review check fix,
and after every fix round. `## Checks` must therefore list only read-only, deterministic
commands, never one that mutates the repo or depends on state a later run cannot
repeat.

The runner is handed each check's exact Bash invocation
(`` o=$(mktemp); bash -c 'cd <worktree> && <command>' >"$o" 2>&1; echo "TOUCHSTONE_CHECK_EXIT <id> $?"; tail -c 8192 "$o"; rm -f "$o" ``)
and must report `command` back as it ran it. The full invocation, its inner
`bash -c '...'`, and the bare declared command are all accepted, because runners
have reported each of the three in the same run; a row reporting anything else
(an added `timeout`, a changed flag) is
not measured, and an unmeasured row is never read as a pass or as evidence of
the repo's own environment. The `cd` target is quoted only when it needs to be:
a worktree path made only of letters, digits and `/ . _ - + : @ % = ,` is
spliced in bare, so the ordinary invocation has no nested quoting for the
runner to copy. A path (or a declared check's own command) carrying any other
character is still single-quoted the old way. This matters because the match
is exact and the runner has to reproduce it byte for byte: on the pipeline
0.21.0 run that #116 is about, the runner miscopied the nested `'\''` escaping
on every row, and no check was measured for the rest of that run.

A row's exit code is read only from its own `TOUCHSTONE_CHECK_EXIT <id> <code>`
line in `output`, never from the `exit_code` field a model fills in: that field
stays in the schema so a model has somewhere to answer, but `classifyResults`
never reads it, which is what let a still-running or merely summarised check
read as a pass at `exit_code: 0` before #120. The echo sits outside the
`bash -c` string and after `;`, not `&&`, so it runs and reports the real exit
code even when the check itself calls `exit N` or its own command chain ends
nonzero. The check's output goes to a temp file, so the exit line is printed
first and followed only by the last 8192 bytes of the log. The Bash tool shows a
large output as a short preview of its start (this repo's own fix-loop suite
prints about 56KB), so an exit line printed last was out of the runner's sight,
and relaying a whole long log verbatim is what runners had already failed at.
The runner also reports that line on its own in `exit_line`, since runners have dropped it from `output` while relaying the rest; the script reads `exit_line` followed by `output` as one text. Only its first non-empty line is read, and it must be a well-formed
line naming the check's own id. A later line that looks like one is the check's
own output. No exit line at all, one that is not first, one naming a different
id, or a malformed one all come back as their own reason (`no exit line`, `exit
line not first`, `exit line names <other id>`, `malformed exit line`) and the
row is unmeasured, the same as a command mismatch, never red and never a pass. The runner is told to run each
invocation alone in the foreground, one at a time and in order, never in the
background or in parallel, and never to write the exit line itself; a call
that does not return inside its own timeout is reported with whatever it
printed and no exit line, which is also unmeasured rather than assumed to
still be running.

An unmeasured check is kept apart from red rather than merged into it, and gets one
retry: after any check run that follows a commit, `runChecks()` runs the checks that
came back unmeasured a second time, at the same head, before anything else happens.
A row still unmeasured after that halts the run (`unmeasuredChecksHalt`, at Implement
for the two pre-review sites and at Fix for the fix loop) rather than reaching a
fixer -- a fixer cannot change what a runner echoes back, and #116 is three fix
rounds spent finding that out the slow way. The halt names each check, its expected
invocation, and the specific reason each of the two attempts could not be measured.
On a non-blocking (`existingBranch`) run nothing here ever halts; an unmeasured check
is only reported under `checks.unmeasured`, the same as a red one is reported under
`checks.red` without blocking.

### Measuring the diff: `size`, lens count, and the ratio halt

The `draft-pr` call also runs a probe command (`diffstatCommandFor`): a `git diff
--numstat` pass over `impl.commit_range` (after the pre-review checks fix, if one
landed, folds into that range), then an `awk` pass over `git diff --unified=0` counting,
per file, added lines whose trimmed text opens a comment: `//` or `/*` anywhere, a bare
`*` only when it opens a block-comment continuation or close (`* foo`, `*/`, not a Go/C
pointer write like `*p = v`), and `#` unless it is `#!` (a shebang) or `#[` (a PHP 8
attribute, e.g. `#[ORM\Column]`). Three markers (`TOUCHSTONE_DIFFSTAT <range>`, `TOUCHSTONE_COMMENT_LINES`,
`TOUCHSTONE_DIFFSTAT_END`) bound the response so `parseDiffstat` -- a pure function --
can tell a well-formed one from a truncated or off-range one: the begin line has to name
the exact range asked about, or the whole response counts as unmeasured, the same as a
numstat row or a comment-count row that does not match its own regex. Unmeasured gets
one retry, via a dedicated `size`-labelled call re-running the identical command; still
unmeasured after that halts at Review as a measurement problem, never reaching a lens.

`sizeOf` classifies each file by path (`test`, `doc`, or `code`; see the function for the
exact patterns) and aggregates: `code` is a code file's added lines minus its own comment
lines, `comment` is those subtracted lines, `test`/`doc` are their files' added lines
as-is, and `codeChurn` is code-file added-plus-removed, which both of the following key
on. `lensKeysFor(size)` replaces the old implementer-reported `big`/`trivial` split
(`files_changed`/`insertions`, which went stale the moment a pre-review fix landed after
them without updating either): no lenses when the diff is a single file under
`INLINE_LOC` churn, one (`correctness`) under `ONE_LENS_LOC`, three (plus
`requirements`) over `BIG_LOC` or past `BIG_FILES` code files, two (`correctness`,
`advocate`) otherwise. `args.reviewers` and `args.devilsAdvocate` still slice and filter
the result afterward, same as before.

Before any lens runs, when `code >= RATIO_MIN_CODE` and `(test + doc + comment) / code`
exceeds `MAX_SUPPORT_RATIO` (10, chosen against this repo's own merged history: the last
20 commits ran 1.0-14.4:1, and every one still at or above the code floor ran 1.2-7.6:1),
the run halts at Review: support code (tests, docs, and a code file's own comments) far
outweighing the actual change is not something a lens should spend a token reviewing.
Below the code floor the ratio never applies, which is what lets an ordinary TDD change
(support code well over 1:1 against the code it backs) through unaffected.
`args.supportRatio` raises the limit for a run that knows its own
ratio is intentional.

### Pipeline version transparency

A host can persist a snapshot of this script and keep executing it after `main`
moves on, so the running code and the checkout it operates on can silently disagree.
The script has no `fs` and no imports, so it cannot read `.claude-plugin/plugin.json`
at runtime to find out -- any such read would report whatever the *current* file
holds, which is exactly wrong when the point is to name what this *running*
snapshot is. `PLUGIN_NAME` and `PIPELINE_VERSION`, near the top of the script, are
literals for that reason: they travel with the executed bytes, and
`scripts/check-version-bump.sh` checks them against the manifest at HEAD
(`scripts/test-version-bump.sh` covers that half).

One third of the merged `setup` call (below), placed before the worktree is even cut
and before Triage, resolves the repository's actual base branch itself and reads its
manifest exactly once, neither the branch's own working tree nor `wt.base` (neither
exists yet at this point in the run): a resumed branch already carries this run's own
earlier version-bump commit as often as not (`check-version-bump.sh` forces one onto
every `workflows/` change), and reading the working tree back would report that bump as
drift against itself, while `wt.base` becomes the branch under review whenever this run
is stacked (`args.base`), whose own unmerged version bump would revive the same
self-accusation through the base instead. The probe also fetches that base fresh before
reading it, since neither reuse path in Worktree ever runs `git fetch` and a stale
remote-tracking ref would let a stale base pass as `mismatch: false`. A failed fetch (no
network, no auth, a remote needing a hardware key) does not by itself count as a missing
manifest: `origin/<base>` can already hold it from an earlier fetch or the initial
clone, so the probe reads it anyway rather than reporting the fetch failure as if the
manifest were absent. The result is a `pipeline_version` object carried on every exit
path, a halt at any phase included:

- `executed` -- `PIPELINE_VERSION`, always present, even on a halt at Worktree
  before the probe has run.
- `base_branch` -- the version the probe read off the repository's base branch, or
  `null` if it found no manifest naming this plugin there.
- `base_refreshed` -- `false` when the probe could not fetch the base before
  reading it, so `base_branch` came from a remote-tracking ref that may predate
  the base branch's real state. A `mismatch: false` alongside it is an agreement
  with a possibly stale ref, not with the base branch, and is logged as such.
- `mismatch` -- `true` when the base branch names this plugin at a different
  version, `false` when it names this plugin at the same version, `null` when the
  probe found no comparable manifest at all (not found, or a different plugin's
  name). `null` is the ordinary case: it is what every repo this pipeline delivers
  into other than touchstone's own reports, since their manifest is never named
  `touchstone`; that case is still logged, distinct in wording from an actual
  mismatch, so it never reads as silence. A probe that returns no response at all
  also leaves `null`, but is logged separately again, since that means the
  comparison did not run rather than that there was nothing to compare.

A mismatch is informational, never a halt: `log()` names both versions and the run
continues to completion. `mismatch: true` says only that the two differ, not which
one is ahead; a reader has to compare the two strings to say which. Refusing to
proceed would make the messenger the failure; the gate above is where drift is
actually enforced. Refreshing the host's snapshot so it executes the newer code is
host behaviour, out of scope for this script.
