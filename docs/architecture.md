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
| `mutation-pr-gate.py` | `.mutation-gated` | refuses a non-draft `gh pr create`, `gh pr ready` (but not `gh pr ready --undo`, which converts back to a draft), a merge onto a base branch, or a push at one, while the ledger is unverified |
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

### Setup: prepared by the invoking session

`/touchstone:deliver` runs `skills/crap-controlled-changes/prepare-delivery.sh` before it
launches the workflow (logic in `lib/prepare_delivery.py`) and passes the JSON it prints
as `args.prepared`. The script does with fixed commands what the `branch`/
`branch:existing` agents and two thirds of `setup` used to relay: `git worktree prune`;
in fresh mode, fetch the base and refuse (exit 3) a branch name that exists locally or on
origin (`git ls-remote origin refs/heads/<name>`), or an occupied path, then cut
`<repo>/.claude/worktrees/<marker>-<slug>`; in existing mode, find the ticket's worktree
(used where it is), then a branch with no worktree, by marker, and failing both, adopt
the checkout's own unmarked feature branch unrenamed (`worktree_action: adopted`; the
mutation ledger keys on branch names). It refuses a branch whose latest PR merged (from
`gh pr list --head <branch> --state all`, the open one else the highest-numbered, the
draft-PR step's rule; a gh that cannot answer is noted in `detail` and treated as not
merged), a dirty tree, more than one match, a checkout on another ticket's branch, or
nothing to use. Every git and gh call runs with stdin closed and
`GIT_TERMINAL_PROMPT=0`, so a credential prompt fails instead of hanging the session;
existing mode's fetch failing is not fatal. It then reads the gate markers at the repo root,
its own `plugin.json`, the base branch's manifest, `AGENTS.md`/`CLAUDE.md`'s `##`
sections with their first fence (the `checks_source` shape below), and, given
`--prior-head`, the ancestry line the resume check reads. Ticket text is not fetched
there, since a Jira ticket needs the session's MCP tools.

Every field of `args.prepared` is validated (`workflows/parts/15-prepared.js.part`)
before anything is dispatched, and the first that fails halts at Worktree naming it. A
fresh worktree must sit directly under `<repo_root>/.claude/worktrees/` and carry the
ticket marker, as must its branch. An existing one may be any absolute path, with the
marker on its branch or its directory name; an adopted one must carry no ticket marker
at all. The ticket and marker must be this run's, the base a ref name or 40-hex SHA (and
equal `args.base` when one is given), the mode and action must match `existingBranch`,
and the plugin must be this run's own name and `PIPELINE_VERSION`. A valid one skips
the branch dispatch, and `setup` asks for the ticket alone (`SETUP_TICKET`).

Without `args.prepared` the agent path below still runs. Both branch schemas require
`halt_reason`, with a value for every failure their prompt describes, and `created` is
never read: one agent read it as "newly created" and halted a run whose lookup had
succeeded. A reply proceeds only on `halt_reason: none` with facts that agree: not
dirty, a non-empty branch, an absolute path, and in fresh mode a branch carrying the
marker. The facts matter because the schema forces branch and path, so a failing agent
fills in the names it meant to use. A reply that contradicts itself (`none` with facts
that fail, or `dirty` on a clean tree) is asked once more under a `:retry` label, then
halts naming the contradiction. The fresh prompt also runs `git ls-remote --heads origin <name>` and
halts (`halt_reason: remote-exists`) on a name already on origin, whose pull request the
run would otherwise adopt.

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
`models` and `recorded_on` afterwards. That session also adds `outcome` and
`pr_number`, read from `gh pr view` rather than asked of an agent, and
`scripts/run-report.py` (logic in `scripts/lib/run_report.py`) summarises every record
per pipeline version, refreshing any outcome still `open`. The record is the single
source: no phase reports on itself any more.

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

### A failed dispatch

Any throw that reaches the run's top-level `catch` other than a budget refusal, such as an
agent that exhausted its structured-output retries, ends as a halt at the current phase.
Its note names the error, and the payload carries the same state as a budget halt, so the
invoking session always has a record to write.

### The run budget

`dispatch()` is the one function that ever calls the runtime's own `agent()`; a static
check in `test-static.sh` asserts nothing else does. Every `treeAgent` call and every
direct `agent()`-style call (`setup`, `branch`, `branch:existing`, `collapseDuplicates`'s
`review:dedup`) goes through it. Before Triage has sized the work, `runBudget` is `null`
and `dispatch()` never refuses; right after Triage, it is set to `100_000 + 1_500 *
estimated_loc` output tokens, clamped `300_000..1_000_000`, or a flat `300_000`/`600_000`
default by scope when triage gave no estimate, and `args.runBudget` overrides either.
A resumed `--existing` run raises the budget to the same formula applied to its first
review range's measured changed lines, and logs it, when that figure is above the budget
set after Triage, whether that budget came from triage's estimate or from the flat default.
The range is the whole branch, not the part after the record's head, when a merge came
after that head. The branch step checks that once; the implementer may merge the base
too, so a `resume:range-check` probe asks the same question at the head Implement left,
and a probe that is missing or not the marker line is read as a merge.
`args.runBudget` is never raised. A halt note after a raise says what the budget was raised
to fit and what it was raised from, including why that figure was set. From there, `dispatch()` refuses any call once `budget.spent()` has reached it.

Everything after that point runs inside one `try`/`catch`, so a refusal anywhere in the
run unwinds to a single halt rather than needing its own latch at every call site. Two
places have to re-check the flag explicitly rather than let it propagate on its own:
`parallel()` (used to run review lenses concurrently) catches each thunk's own throw and
hands back `null`, which would otherwise be reported as a dead lens (below) rather than
as the budget halt it is, and `markStale`'s own `try`/`catch` would otherwise log the refusal as a merely failed
staleness probe. Both re-throw when `runBudgetSpent` is set. A stage still open when the
throw unwinds past its own `close()` -- the one actually running at the halt -- has its
spend folded into `stage_spend` by the catch, rather than silently dropped from it.

A lens that returns `null` for any other reason (stalled, errored, or failed its schema
after retries) did not review anything, so it is never read as zero findings. The round's
findings are dropped and the run halts at that phase (Review, Fix for a fix-round review,
Review for the post-mutation review) with a note naming each dead lens and saying the
review did not run. `reviewed_through` does not move past the range, so a resume reviews
it again. A lens that returns an empty findings list is still a clean review.

The catch also reports whatever work and review state the run had reached: plan, checks,
implementation and gates, open findings, notes, fix rounds and their output, and the
mutation result, the same fields any other halt at that phase carries. It cannot read the
`try`'s own `let` bindings, so `budgetHaltState`, declared just above the `try`, is a
closure each phase widens with `widenBudgetHaltState()` once the state it adds exists. A
field the run never reached is absent from the halt rather than guessed.

### Work beyond the ticket: plan additions

The planner returns work it believes the ticket needs but does not ask for under
`additions`, each with an `item` and the `consequence` that makes it necessary, apart
from `plan` itself. The implementer and every review lens (tail and post-mutation
reviews included) are shown the list marked as beyond the ticket, the lenses are asked
to set `scope` (`ticket` or `addition`) on each finding, and the PR body gets a "Beyond
the ticket" section. `reviewOf` stamps `scope` itself: `ticket` for every finding when
there are no additions, otherwise the lens's value, or `unattributed` when it gave none
or an invalid one. Every halt and the final result carry `plan_additions` and, once
review has started, `scope_split`: counts by scope of the blocking findings, settled
and open. An empty list is the normal case, and then no prompt grows by a word.

Additions are not forbidden; some are genuinely required. The point is attribution: on
two runs that grew past their ticket, every finding left at the halt sat in the added
work, and nothing in the record could show it.

### The plan is a file, not a prompt section

The implementer never gets the plan as prompt text. `brief()` clamps to `briefChars`
(4000), so a 24,600-char plan used to reach the implementer as its first 4,000 chars.

- **Length gate.** The planner is told to stay within `PLAN_MAX_CHARS` (6000;
  `args.planMaxChars` overrides). A longer plan is sent back once as
  `planner:tighten`, with the previous plan in full. Still over, or no answer, halts at
  Plan: the ticket probably needs splitting. A plan passed as `args.plan` is held to the
  same limit but never tightened: over it, the run halts at Plan before any agent is
  dispatched (no setup, branch or triage), so nothing has been created. The inline stub
  plan is not gated.
- **Plan file.** On every plan path, a `plan:write` agent runs one shell command the
  script built: a quoted heredoc that writes the plan to `<worktree>/.touchstone/plan.md`,
  then a `printf` that appends a blank line and `END OF PLAN <id>`. No model reproduces
  the plan: asked to copy it with the Write tool, models dropped the end line, indented a
  line and turned lines into list items, and each halted a run on a correct plan. It adds `.touchstone/`
  to `info/exclude` under `git rev-parse --git-common-dir` (never a tracked
  `.gitignore`), and reports a content digest, `tail -n 1` and the `git check-ignore`
  exit. The digest is FNV-1a over the file's UTF-8 bytes with every run of spaces, tabs
  and newlines collapsed to one space, printed by a `python3` command the script built;
  the script computes the same over the plan, so a changed or dropped word fails. The script halts at Implement unless the digests match, the last line is the
  end line, and the file is ignored. The id is an FNV-1a
  hash of ticket and plan, computed by the script, so it is deterministic. A failed
  verification is retried once as `plan:write:retry` with the identical prompt; a second
  failure halts at Implement.
- **Proof of reading.** The implementer is told to read the whole file and return the id
  as `plan_id`, or to refuse to start (empty `plan_id`) if it cannot. A missing, empty or
  wrong id halts at Implement before the draft PR, review or any fix.
- **Leak probe.** Nothing under `.touchstone/` may be committed. After Implement and its
  checks fix, after every fix round that moved the head, and after a mutation attempt
  that moved it, a `plan:leak:<phase>` agent runs a script-built `git log --name-only`
  over `<implementer base>..<new head>`. Using the range from the implementer's base
  catches a commit that adds the file and a later one that deletes it. Missing or
  unparseable output is retried once as `plan:leak:<phase>:retry`. A path found on
  either attempt halts that phase at once, before a push; output unparseable twice halts
  as unverified.

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
runs it: one haiku dispatch per batch, against the worktree's current HEAD, given lines
the script builds and run the same way as the check runner's below (`reproLinesFor` in
`50-classify-fix.js.part`, one foreground Bash call per line, `runnerPrompt` shared with
`checks:run`). No model copies a command, an exit code, an output or a porcelain:

- A before line empties the run's `rows` file, writes `git status --porcelain` to
  `before.log` (stderr to `before.err`) and prints `TOUCHSTONE_REPRO_BEFORE <run>
  clean|dirty`.
- One line per reproducer decodes its command from base64 (`printf %s <b64> | base64
  --decode`, refusing an empty result) and runs it as `(cd <worktree> && bash -c "$c")`
  with all its output in `<id>.log`. The command travels encoded because a reproducer
  can span several lines (a `python3 -c` script, a heredoc), and a newline spliced into
  the fence would split one line into fragments the runner executes on their own,
  outside the worktree and the log. The script encodes the UTF-8 bytes itself
  (`base64Of`), since the Workflow runtime has no `Buffer`. The line then decides in the shell whether that log holds a line that is exactly
  `REPRODUCED_MARKER` once surrounding whitespace (a CR included) is trimmed, and prints
  `TOUCHSTONE_REPRO <id> <exit> <0|1> <log path>`, appending the same row to `rows`. A
  marker inside a longer line, such as
  a `set -x` echo, does not count, and a long output can never push the marker out of
  view, since the grep reads the whole log.
- When the call is given a range, one line writes `git diff --unified=0 --no-color
  <range>` to `diff.log`, keeps only the lines starting with `+++ ` or `@@ `, and prints
  them between `TOUCHSTONE_HUNKS_BEGIN <run>` and `TOUCHSTONE_HUNKS_END <run> <count>`,
  the count computed by the shell. When `git diff` itself exits nonzero (a bad range),
  the line prints `TOUCHSTONE_HUNKS_FAILED <run> <exit>` instead: the hunks are unknown
  (`hunks: null`, classify()'s could-not-measure path) and the reproducer rows still count.
- An end line writes the porcelain after into `status.log` and prints
  `TOUCHSTONE_REPRO_END <run> clean|dirty <crc> <bytes> <status log path>`, where
  `<crc> <bytes>` is `cksum < rows`. It carries the path because the mutation-hunk fetch
  runs no reproducer, so no row would name the directory.

All of these sit in `touchstone-repro/<run>/` under the worktree's git dir, where `<run>`
is the plan id, the label and a per-run counter. `parseReproRun` (pure, in
`10-schemas.js.part`) accepts the reply only in that order: the before line first, one
row per runnable id in order with an integer exit, a 0 or 1 marker flag and a log in this
run's one directory, the hunks block or the failed line when a range was asked for (a
block's count equal to the lines between the markers, each a `+++ ` or `@@ ` line), and
the end line last, whose cksum must equal the one the script computes over the rows it
accepted (see the rows checksum under check discovery). Anything
else makes the whole call unmeasured, read exactly as a call that returned nothing: no
rows, hunks unknown rather than empty, nothing seen dirty. The reason is logged as
`<label>: unmeasured (<reason>)`.

`outcomeOf(row)` is what turns that row into a disposition, and it is the only place
that does: no row is `not-executed`; exit 0 is `passed`, marker or not; 126 or 127 is
`could-not-run`; any other nonzero is `reproduced` only when the shell's marker flag is
1, and `errored` otherwise. A command that fails for its own reasons -- a missing
environment variable, a wrong path, a syntax error -- exits nonzero same as a real
demonstration, and used to read the same way; a reproducer now has to prove it observed
the defect, not merely that it did not exit 0. `disposeCandidates()` opens a candidate
only on `reproduced`; `passed`, `could-not-run` and `errored` become a note with its own
reason (`did-not-reproduce`, `reproducer-could-not-run`, `reproducer-errored`) and its
`reproducer_run` (the outcome, the exit code, and the log path) attached so the
note keeps what actually happened.

`not-executed` is neither: a missing row is even less evidence than an errored one, so
it must not open a candidate on nothing, and it is no verdict at all, so it must not
become a note either -- the same rule #116 applies to a discovered check the runner
never measured. `executeAndDispose()` retries whatever comes back `not-executed` exactly
once, at the same head, as its own `executeAtHead()` call restricted to just those
candidates and labelled with the original label plus `:retry` -- run alone in the
worktree like every such call, so a dirty result there halts the same way. Since one
missing or extra row makes the whole call unmeasured, the retry normally covers every
candidate of the first call. A dirty result halts with a note naming the `status.log`
that holds the porcelain, not a copy of it. Whatever is
still `not-executed` after that halts the run (at Review for the initial review and the
post-mutation review, at Fix for a fix round's fresh candidates), naming each finding by
id and title and saying the halt is about measurement, not the code (gh-113).

`unmet-criterion` needs a reproducer too. The verbatim quote proves the criterion
exists; only an executed command shows the change misses it, and the alternative, a
model reading the code and declaring the criterion met, is the judgement blocking must
not rest on.

An open finding carries its latest `reproducer_run` into every fix brief, replaced each
round rather than accumulated. A round whose row the executor dropped is no run, so the
finding (open, or a settled one reopened by its recheck) keeps the last run that
happened: `not-executed` in a record therefore only ever names a candidate no row came
back for, which is what a resumed `--existing` run measures again before anything else.
Exit 0 settles it regardless of the marker; nonzero with
the marker keeps it open as `reproduced`; nonzero without it keeps it open as `errored`,
and the brief says the reproducer itself failed to run, with its exit code and the path
of its log (outside the worktree, read from the end), never the output itself, so the
fixer is not sent chasing a defect nobody demonstrated.

A settled finding is re-run at every head the code moves to after it settled: in every
later fix round (`reproduce:settled:<round>`) and at the mutation gate's head
(`reproduce:settled:mutation`), budget or not. `regressedOf()` splits what comes back into
`regressed` (still fails, `reproduced`/`could-not-run`/`not-executed`) and `errored`
(reproducer itself failed) and reopens both, logged separately: a fix nobody could
re-measure is not the same claim as one whose reproducer ran clean and still shows the
defect. Reopened findings get the next round if one is left; at the mutation head, where
no round follows, the run halts at Review with a note that counts undone and errored
fixes separately. A missing row inside a measured call still counts as regressed, but an
unmeasured call has no rows at all, so `executeSettled()` retries it once
(`<label>:retry`) before `regressedOf()` sees it: without that, one copy slip would
reopen every settled finding and, at the mutation head, blame the gate's commits for
undoing them. Still unmeasured after the retry, the run halts (`unmeasuredSettledHalt`,
at Fix or at Review) with a note saying the re-check could not be measured and that this
is a measurement failure, not a regression. Nothing is reopened; each settled finding is
carried in `unresolved_findings` with its last measured run and `awaiting_recheck: true`.
A resumed run puts such a finding back among the settled ones, so the next settled
re-check measures it again; it never reaches a fixer. Nothing here waits for a lens to report the regression, so a `residual`
note is only ever a note: whether a new finding is a *variant* of a fixed one is decided
by the lens setting `duplicate_of`, which is a judgement no exit code can make, and the
cost of that judgement being wrong is a line in the PR body rather than another round.

### Gate verdicts: mutation and unreviewed commits

Two decisions before the PR used to rest on a model's account and are now read from a
line the script builds and the shell prints, the same way as the check and reproducer
runners (`60-mutation-pr.js.part`, parsers in `10-schemas.js.part`).

**Mutation.** After every `mutation:N` attempt, including one whose agent returned
nothing, a `mutation-verify:N` agent (haiku, low effort, `runnerPrompt`) runs one line:

```
d="$(git -C <worktree> rev-parse --path-format=absolute --git-path touchstone-gates/<run> 2>/dev/null)" && mkdir -p "$d" && h="$(git -C <worktree> rev-parse HEAD 2>/dev/null)" && { mutation-check.sh <worktree> --verify >|"$d/mutation-verify.log" 2>&1; e=$?; t="$(sed -n '$s/^mutation-check: EXIT=\([0-9][0-9]*\) .*$/\1/p' "$d/mutation-verify.log")"; printf 'TOUCHSTONE_MUTATION_VERIFY %s %s %s %s %s\n' <run> "$e" "${t:--}" "$h" "$d/mutation-verify.log"; }
```

`<run>` is the plan id plus `mutation-verify-<n>`. The line names `mutation-check.sh`
without its directory, so the agent is told to find it in the crap-controlled-changes
skill's directory and replace that one word with its absolute path, the same way the
signals probe resolves `change-signals.sh`. That substitution is the one step a model
still does here, and the trailer is what checks it: the real `mutation-check.sh` ends
every run past its own setup with `mutation-check: EXIT=<n> <verdict>`, and the line
prints that `<n>` from the log's last line, or `-` when there is none.
`parseMutationVerify` accepts exactly one line naming this run, an integer exit, a
trailer that equals the exit (or `-` with an exit other than 0 and 5), a 40-hex head and
an absolute log path ending in `/touchstone-gates/<run>/mutation-verify.log`. A
substituted `true` prints exit 0 with no trailer and is read as unmeasured.

The script keeps the agent's `detail`, `needs_user_run` and `unsupported_language` for
the halt note and ignores its `green` and `head_sha`, so the post-mutation review range,
the plan-leak probe and the settled re-check all start from git's head. The exit decides
the rest:

| `--verify` exit | Meaning | Run |
|---|---|---|
| 0 | the ledger records a green run for this head | green, `head_sha` from the shell |
| 5 | missing or stale ledger: mutants survived, or no run was recorded | red; the next attempt runs as before, and the halt note says the gate has not recorded a green run for this head, with the exit and log |
| anything else (127 not found, 2 setup) | the gate could not run | `verify_setup`: no further attempt, and a halt note naming the exit and log, distinct from survivors and from unmeasured |

A reply that does not parse is retried once as `mutation-verify:N:retry`. Still
unparseable, the result is not green (`verdict_unmeasured`, with both reasons, and without
the agent's `head_sha`, which nothing measured), no further
mutation attempt runs (another run cannot fix a relay that did not print its line), and the
Mutation halt says the gate's verdict could not be measured, which is a different claim
from surviving mutants. A repo without `.mutation-gated` skips the gate as before and runs
no verdict line.

`hooks/gate-pipe-gate.py` reads the verdict line too, since it names a gate: `>|`, the
redirect that overrides `noclobber`, is not a pipe there, so the line passes, and
`workflows/tests/test-gate-verdicts.sh` feeds every built runner line to the hook.

**Unreviewed commits.** When the run has a reviewer lens, a `pr-unreviewed` agent runs one
line before `pr` is dispatched:

```
h="$(git -C <worktree> rev-parse HEAD 2>/dev/null)" && n="$(git -C <worktree> rev-list --count <reviewed>.."$h" 2>/dev/null)" && printf 'TOUCHSTONE_UNREVIEWED %s %s %s\n' <reviewed> "$n" "$h"
```

`parseUnreviewed` accepts exactly one line starting at the reviewed head the script asked
about, an integer count and a 40-hex head. A count above 0 halts at PR without dispatching
`pr`, naming the count and the range `<reviewed>..<head>`. Unparseable twice
(`pr-unreviewed:retry`) halts at PR as unmeasured. The `pr` prompt no longer runs or judges
this count.

### Draft PR: adopting by line, never by name

The Draft PR phase used to hand one agent two jobs: find or open the branch's PR, and relay the
diffstat. Nothing checked that an adopted PR shared history with the branch, so a fresh run once
attached itself to an unrelated PR whose branch had the same name, and a resumed run pushed
ungated commits to a PR that was already ready, then halted saying it was a draft. Now every
decision there is read from a line the script builds and the shell prints
(`40-implement-draft-review.js.part`, parsers in `10-schemas.js.part`).

**Which PR.** A `pr:state` agent runs one line:

```
p="$(cd <worktree> && gh pr list --head <branch> --state all --json number,state,isDraft,headRefOid --limit 20 --jq 'sort_by(-.number) | (map(select(.state == "OPEN")) + .)[0] // empty | "\(.number) \(.state) \(.isDraft) \(.headRefOid)"' 2>/dev/null)"; g=$?; read -r n s r h <<<"$p"; if [ -n "$h" ] && git -C <worktree> merge-base --is-ancestor "$h" HEAD 2>/dev/null; then a=1; else a=0; fi; printf 'TOUCHSTONE_PR %s %s %s %s %s %s %s\n' <branch> "$g" "${n:-none}" "${s:-none}" "${r:-none}" "${h:-none}" "$a"
```

`gh` has no `-C`, so it runs in a subshell inside the worktree. `gh pr list` exits 0 and prints
nothing when the branch has no PR, so the line prints `0 none none none none 0`; a `gh` that
fails (bad credentials, no network) prints its own exit instead, and `parsePrState` reads any
nonzero exit as unmeasured, never as "no PR". Of several PRs for the branch the open one is
taken, else the highest-numbered, with its real state. The ancestry is git's: a PR head this
clone does not have is not an ancestor either. `parsePrState` accepts exactly one line naming
this branch with gh exit 0, then either all `none` with ancestor `0`, or an integer number, a
state of `OPEN`, `CLOSED` or `MERGED`, `true` or `false`, a 40-hex head and `0` or `1`. The script
checks the state first, then the ancestry:

| Line | Run |
|---|---|
| no PR | the `draft-pr` agent pushes and opens a draft (its prompt only creates; it never adopts) |
| a merged PR | halt at Draft PR: the PR is merged; pick another branch name |
| a closed PR | halt at Draft PR: the PR is closed; pick another branch name or reopen it |
| an open PR whose head is not an ancestor of the branch head | halt at Draft PR naming the PR, its head and the branch, as an unrelated PR under the same name; nothing is adopted or pushed |
| an open PR that is an ancestor | adopted, with the number from the line, then pushed by a `pr:push` line |

Unparseable twice, or `gh` failing twice (`pr:state:retry`), the run opens and adopts nothing and
goes on without a PR: not knowing is no reason to open one next to a PR the run must not touch.
If it then gets as far as the PR phase, it halts there before `pr` is dispatched, with both
reasons, rather than opening a PR beside one it never read.

**A ready PR.** An adopted PR that is ready for review is converted back to a draft before the
push, by a `pr:undo` line that runs `gh pr ready <n> --undo` (log under
`<git dir>/touchstone-pr/<run>/pr-undo.log`), re-reads `isDraft` and prints
`TOUCHSTONE_PR_UNDO <n> <exit> <true|false|none> <log>`. The re-read decides, not the exit:
`true` is a draft, `false` is still ready, and `none` (the re-read failed) or a line unparseable
twice leaves the state unknown. `mutation-pr-gate.py` lets `gh pr ready --undo` through, since it
withdraws a review request rather than making one. Every `gh pr ready` in the command is judged
on its own: a command starts at the beginning or after `;`, `&`, `|`, `(`, a newline or a backtick,
and ends at `;`, `&`, `|`, `)`, a newline, a backtick or `#`. Only that command's own words count,
and the last `--undo`/`--undo=<v>` wins, as in pflag, so `gh pr ready 5 # --undo`,
`gh pr ready 5 --undo --undo=false`, and `gh pr ready 5 --undo` followed by a plain
`gh pr ready 5` on the next line are all still gated.

**The push.** `pr:push` runs `git -C <worktree> push -u origin <branch>` and prints
`TOUCHSTONE_PUSH <branch> <exit> <log>`, retried once (`pr:push:retry`) when it does not parse. A
failed push is logged and is not fatal; the PR phase pushes again.

**What a halt says.** `draftPr` records what the run read: `draft`, `stateUnknown`, why it is not
a draft (`readyWhy`), and whether this run's push succeeded (`pushed`). `prNote()` builds its
sentence from those fields: "The PR was left as a draft", "No PR was opened ...", "PR #<n> read as
ready for review, ...", or "PR #<n> was ready for review when this run adopted it, and its state is
unknown after converting it to a draft was tried, ...". It says "with commits the gates have not
passed" only when the push succeeded, "holding no commit from this run" when it failed, and that
whether the push reached it is unknown when its result could not be read. While the
PR is not a draft, `halted()` appends that sentence to every halt note that does not already carry
it, so a halt at any phase after the push says so.

### Check discovery

With `args.prepared`, `checks_source` comes from `prepare-delivery.sh`, which applies
the same transcription rule in code. Otherwise it is folded into the
`branch`/`branch:existing` call's own last step (`checks_source` on
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

A batch of checks is run by lines the script builds, never by a model copying a
command or relaying output (`checkLineFor` and `endLineFor` in `30-triage-plan-checks.js.part`). The
`checks:run:N` agent is given one fenced line per check, plus an end line, and runs each
as its own foreground Bash call. A check's line is self-contained:

```
d="$(git -C <worktree> rev-parse --path-format=absolute --git-path touchstone-checks/<run> 2>/dev/null)" && mkdir -p "$d" && { bash -c 'cd <worktree> && <command>' >|"$d/<id>.log" 2>&1; e=$?; r="$(printf 'TOUCHSTONE_CHECK %s %s %s' <id> "$e" "$d/<id>.log")"; printf '%s\n' "$r" >>"$d/rows"; printf '%s\n' "$r"; }
```

The check's whole output, stdout and stderr, goes to
`touchstone-checks/<run>/<id>.log` under the worktree's own git dir, so a log is never
part of the tree, cannot dirty it, and is removed with the worktree. `<run>` is the plan
id and the attempt number (`<planId>-<n>`): the retry of a batch writes new logs and
leaves the first attempt's as they were. A later run with the same plan in the same
worktree reuses those directories and overwrites them; every redirect is `>|`, so a
shell with `noclobber` set still writes the log instead of failing the check. The exit
code is read from `$?` after `;` rather than `&&`, so it is printed even when the check
failed or called `exit N` itself. The only thing the shell prints per check is `TOUCHSTONE_CHECK <id>
<exit> <log path>`, which is also why a long suite (this repo's own prints minutes of
output) no longer has to fit the Bash tool's inline preview. The end line runs `git
status --porcelain` once, after the last check, into `status.log` in the same
directory and prints `TOUCHSTONE_CHECKS_END <run> clean|dirty <crc> <bytes>`. Only stdout decides
dirty: git's stderr goes to `status.err` beside it (and a `rev-parse` warning is
dropped), because a warning on a healthy tree, such as an unreadable excludes file,
would otherwise read as a dirty tree or as an unexpected line. Every line is a
separate call because one call per batch would sit close to the 600000 ms Bash cap: this
repo's checks took 526 s in sequence on one machine, so a slower machine or a growing
suite crosses it. The agent still joins one short line per call, but the parser holds
every id, exit and log path to what the script expects, so a misjoined batch reads as
unmeasured, never as a pass.

Every row line also writes the exact row it printed to `rows` in the run directory (the
first line of a batch with `>|`, so a re-run in the same directory starts over; the rest
with `>>`), and the end line prints `cksum < rows`: the POSIX CRC and the byte count.
`parseCheckRun` and `parseReproRun` recompute that cksum (`cksum` in `10-schemas.js.part`,
the 32-bit POSIX CRC with the length appended, over the UTF-8 bytes) over the rows they accepted,
joined with newlines as the shell wrote them, and a mismatch makes the call unmeasured
(`rows checksum does not match what the runner wrote`). A row copied with a slip that
still parses was never written to `rows`, so it cannot pass. The sum guards against slips,
not against a model set on forging: with a Bash tool it could compute a matching sum. No line
contains `exit`: the agent's shell persists, and one would end it. The `cd` target is
quoted only when it needs to be: a worktree path made only of letters, digits and `/ . _
- + : @ % = ,` is spliced in bare, and a path or declared command carrying any other
character is single-quoted, with a quote inside it written `'\''`.

The agent returns `output` and nothing else: the lines it saw printed, verbatim and in
order. `parseCheckRun` (a pure function in `10-schemas.js.part`, in the style of
`parseDiffstat`) accepts that only if every discovered id appears exactly once and in
order, each exit is an integer, each log path is absolute and ends in
`/touchstone-checks/<run>/<id>.log` for this run and id, all rows share one directory,
the end line names this run
and is both last and unique, and its cksum matches the rows. Anything else makes the whole batch unmeasured, not just
the row at fault, with the first reason found (`no output`, `no end line`, `end line is
not last`, `end line repeated`, `malformed end line`, `end line names run X, not Y`,
`unexpected line ...`, `malformed check line`, `<id> reported twice`, `unexpected id
<id>`, `<id> reported where <id> was expected`, `exit of <id> is not an integer`, `log
path of <id> is not under this run`, `no line for <id>`, `log path of <id> is not in the
run directory`, `rows checksum does not match what the runner wrote`). A reply that is wrong
anywhere is not trusted anywhere, and an unmeasured batch is never read as a pass or as
evidence about the repo's own environment. `classifyResults` then reads exit 0 as green
and any other exit as red, 2 and 4 included, as AGENTS.md says they are not passes.

A red check reaches a fixer (`checks:fix`, `fix:N`) as `Check <id> (<command>) exited
<n>. Full output: <log path>`, never as its output. The prompt says the log sits under
the worktree's git directory, outside the worktree, which makes it the one path a fixer
may Read that does not start with the worktree path, and to read it from the end, where
a check prints its verdict.

An unmeasured batch gets one retry, whole: `runChecks()` runs the batch a second time at
the same head, under a new run, before anything else happens. A batch still unmeasured
after that halts the run (`unmeasuredChecksHalt`, at Implement for the two pre-review
sites and at Fix for the fix loop) rather than reaching a fixer -- a fixer cannot change
what a runner printed, and #116 is three fix rounds spent finding that out the slow way.
The halt names each check and the reason each of the two attempts could not be
measured. The baseline before Implement is the same retry, and an unmeasured baseline
halts at Implement before anything is implemented, saying the baseline could not be
established: with nothing known about the base commit, every check red afterwards
would read as the run's own doing and reach a fixer (#143). A baseline whose end line
says `dirty` halts there too, naming the `status.log` path rather than copying what it
holds. On a non-blocking (`existingBranch`) run nothing here ever halts; an unmeasured
check is only reported under `checks.unmeasured`, the same as a red one is reported under
`checks.red` without blocking.

Advisory checks (`## Advisory checks`) use the same runner, once and with no retry. A red
one becomes a note carrying `exit <n>` and its `log`; the PR prompt tells the agent to
read that log and quote what the check reported, and never to put the path in the PR.

### Measuring the diff: `size`, lens count, and the ratio halt

At the start of Review a `diffstat` agent (haiku, low effort, `runnerPrompt`) runs one
script-built line (`diffstatLineFor`): a `git diff
--numstat` pass over `impl.commit_range` (after the pre-review checks fix, if one
landed, folds into that range), then an `awk` pass over `git diff --unified=0` counting,
per file, added lines whose trimmed text opens a comment: `//` or `/*` anywhere, a bare
`*` only when it opens a block-comment continuation or close (`* foo`, `*/`, not a Go/C
pointer write like `*p = v`), and `#` unless it is `#!` (a shebang) or `#[` (a PHP 8
attribute, e.g. `#[ORM\Column]`). Both passes write to `<git dir>/touchstone-diffstat/<run>/diffstat.log`,
and only then does the line print it between `TOUCHSTONE_DIFFSTAT <range>` and
`TOUCHSTONE_DIFFSTAT_END <lines> <numstat exit>`, with `TOUCHSTONE_COMMENT_LINES` separating the
two passes inside the log. The line count is `grep -c ''` of the log, so the shell, not the relay,
says how many rows there are. `parseDiffstat` -- a pure function -- accepts the output only when
the begin line names the exact range asked about, the end line is last, its count equals the
lines between them, numstat exited 0 (a failed `git diff` would otherwise read as an empty diff
and skip review), and every numstat and comment-count row matches its own regex. Unmeasured gets
one retry (`diffstat:retry`), the same line under a new run; still unmeasured after that halts
at Review as a measurement problem, never reaching a lens.

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

### Change-risk signals

Every run records fourteen deterministic facts about its change, so that later work
can ask which of them predicted trouble. They are recorded and nothing more: the lens
count, the ratio halt, the round limit and every ceiling are decided without them, and
`workflows/tests/test-change-signals.sh` pins that by running the same scenarios with
every signal raised, every one clear and the probe failing.

`skills/crap-controlled-changes/change-signals.sh <absolute-repo-path> <base>..<head>`
prints exactly `TOUCHSTONE_SIGNALS <range>`, one compact JSON line
`{"range", "values": {<name>: {"value", "evidence", "reason"?}}}`, and
`TOUCHSTONE_SIGNALS_END`; nothing else reaches stdout or stderr on success. Exit 0 once
printed, 2 for bad arguments or a range that does not resolve. The wrapper only
resolves the repo and hands three settings that live in shell to
`lib/change_signals.py`: `UNSUPPORTED_SPEC`, the marker's exemptions from
`crap_exempt_pathspecs`, and the pinned deadcode version. `lib/signal_base.py` holds
what the signals share (the signal shape, the tool runner, the range's diff) and
`lib/signal_tools.py` the four that run a tool.

A value is `true`, `false`, a finite number or `"unmeasured"`, and an unmeasured one
always carries a `reason`. `evidence` is the command, its exit code and its output cut
to 400 characters. Every name is always present: a signal that throws is recorded as
unmeasured with the exception, never dropped.

| Signal | Meaning |
|---|---|
| `la`, `ld` | added and removed lines (`git diff --numstat`, binary files left out) |
| `lt` | lines at the base of every touched text file; a new file counts 0 |
| `la_lt` | `la / lt` to 3 places; unmeasured when `lt` is 0 |
| `files`, `directories` | changed paths, binaries included, and the distinct directories holding them |
| `dependency_surface` | a changed `go.mod`, `go.sum`, `composer.json`, `composer.lock`, `pyproject.toml`, `uv.lock` or `requirements*.txt` |
| `api_broken` | Go: `apidiff -m` of the module at the base against HEAD. Python: `griffe check` per top-level package. PHP: `roave-backward-compatibility-check --from=<base>` |
| `security_pattern` | a finding of `gosec`, `bandit` or `opengrep` (rules in `lib/opengrep-php.yml`) on a line the range added. Every changed Python and PHP file is scanned, test files included, with `bandit`'s B101 (`assert_used`) skipped because every test asserts; Go test files are scanned too (`gosec -tests`). A changed Go file that `go list ./...` does not build on this host (a build constraint, a directory it skips), or that sits in a directory whose path holds `vendor` (`gosec`'s default `-exclude-dir`, which is a substring match, so `vendorclient/` goes too), makes it unmeasured, since `gosec` drops such a file without saying so. `go list` runs with `-tags=` because `gosec` ignores the tags a `GOFLAGS` sets and `go list` would not. Each scanner is told to ignore suppression comments (`gosec -nosec`, `bandit --ignore-nosec`, `opengrep --disable-nosem`), because the change under measurement writes them |
| `semantic_noop` | `difft --check-only --exit-code` over the base and head blob of each changed file: true only when no file changed syntactically |
| `crap_max`, `coverage_min` | the worst CRAP and lowest coverage among the functions the branch added or made worse, from the rows below |
| `reachable` | Go: a function the range changed that `deadcode` does not list as unreachable from some main package. A changed Python, PHP or unsupported-language source file makes it unmeasured unless a Go function proves it true |
| `defect_files` | range files an earlier run's record names in an unresolved finding whose reproducer was `reproduced`. A finding's `file` counts as its repo-relative path: an absolute path under the checkout or one of its worktrees, and a trailing `:line` or `:start-end`, are stripped first |

Rules that apply to the tool-run signals. A signal is false only when every tool that
applies ran to the end over every changed file of its language. A tool that is missing,
errors or runs past 90 seconds, a changed file in a language no tool here covers, and no
Go, PHP or Python file at all each make it unmeasured. The languages no tool covers are
`UNSUPPORTED_SPEC` plus shell (`*.sh`, `*.bash`, `*.zsh`, `*.ksh`, which the CRAP gate
leaves out on purpose), and a path the repo's marker exempts is still one of them: the
exemption is about the CRAP gate, and no tool here read the file. A changed Go, PHP or
Python file the marker exempts is not handed to any tool either, so it makes `api_broken`
and `security_pattern` unmeasured as well, with one carve-out for `api_broken`: its tools
read a whole module (`apidiff`), top-level package (`griffe`) or project (`roave`), so an
exempt file inside one they ran over for a gated file was read, and an exempt test file
(`_test.go` for Go, any test file for Python and PHP) is one no `api_broken` tool counts
whether it is exempt or not. A non-zero exit counts as a finding only when
the output holds that tool's own finding record, because the same exit code also means
the tool broke. A proof stands over what could not be checked: one
language showing a break is true even if another's tool was missing. Tools that read the
working tree are unmeasured unless it is the range's head: `HEAD` is that commit and no
tracked file has an edit that is not in it, since the tools report lines of the files as
they are on disk and those are matched against the lines the range added. The
security tools scan HEAD and keep the findings on added lines instead of running a
baseline, which asks the same question in one run. `semantic_noop` reads blobs, not the
working tree, and reports a changed, added, deleted or binary file as not a no-op.

`crap-check.sh` keeps the rows of each green run in `crap-check-rows.json` under
`git rev-parse --git-common-dir`, so a ticket's worktree that is removed and made again on
the same branch keeps the branch's earlier rows. It is kept per branch by
`lib/crap_rows.py`: the latest row of every function, and the stronger tag when a later
commit touches a function again (each run tags against the commit before it, so a function
the branch added reads `unchanged` on its second commit). Writing it never changes the
gate's exit.

The file outlives a branch, and a redone ticket cuts its branch again under the same name,
so a row counts only while the commit that carried it is in history. The gate scores the
index before that commit exists, so each row names the `HEAD` the run was against and the
tree it scored; the commit is the one after that `HEAD` with that tree. A write drops the
rows that no longer qualify before it merges, and `change-signals.sh` reads only the ones
that do, so a gate run whose commit never landed and an abandoned attempt both count for
nothing. A row also keeps the rows it was merged over, newest first, as a chain of `prior`s,
and counts as the first of them whose commit is in history, so a second run at the same
`HEAD` that never lands, or a reset back to an earlier commit, cannot cost a landed commit
its tag. Parallel worktrees share the file, so a write takes its own lock file,
`crap-check-rows.json.lock`, which is not the scored ledger's.

In the pipeline, a `signals` agent (haiku, low effort) runs the script right after the
implementer returns its range, before anything can halt on that work, and relays its
output. A pre-review checks fix that moves the head runs it again over the folded range,
so the record ends up over the same `impl.commit_range` the diffstat measures; a second
probe that fails leaves the first record in place, and its `range` says which it is.
`parseSignals` accepts only an exact record: the begin line naming that range, one JSON
line with every name and a well-formed value, the end line. Anything else is `null`, as
is an agent that fails or throws: a probe failure is logged and never halts, and is not
retried. A spent run budget skips the probe instead of letting its refusal end the run
as a budget halt, which would stand in for the halt the run was making for its own
reason (an unsupported language, an implementer over its ceiling). Whether the
implementer overran is read before the probe, so its spend is not charged to that stage.
`signals` sits beside `size` in the result and in every halt, `null` on every halt
before the implementer has returned a range, and on a run whose budget was spent by then.

Limits worth knowing. The CRAP record keeps a row for a function that was later removed.
A commit rewritten into a different tree (amend, rebase) no longer vouches for its rows, so
`crap_max` and `coverage_min` then read over the rows that remain.
`reachable` reads functions by gofmt's layout (`func` in column zero to `}` in column
zero) and treats a root that never built a replaced module's package as not listing it.
Python `api_broken` needs `__init__.py` packages; a file in none is unmeasured.
`defect_files` reads only records of earlier runs, since a run's own record is written
when it ends. `scripts/run-report.py` prints, under each version, every signal's runs
grouped by value (numbers split at the median of the measured ones) with each group's
median fix rounds, halts and blocking findings.

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

With `args.prepared`, the manifest comes from `prepare-delivery.sh`'s `base_manifest`,
read the same way (fetch the default base, then read `origin/<base>`'s manifest even when
the fetch failed). Otherwise one third of the merged `setup` call (below), placed before the worktree is even cut
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
