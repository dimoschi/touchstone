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
  must resolve which repo a command acts on before it can decide anything.

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
bypass.

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

### Seven policy gates, two manifests

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

Three fire everywhere, because each acts on its own evidence rather than on a marker:

| Hook | Evidence |
|---|---|
| `base-branch-commit-gate.py` | a commit on `main`/`master`/etc. Exempts a repo with no remote |
| `gate-pipe-gate.py` | a gate piped anywhere |
| `generated-file-gate.py` | an `@generated` or `DO NOT EDIT` header, which is the file's own consent |

`gate-pipe-gate.py` applies while working in this repo too. `$?` after a pipeline is the
*last* command's status, so `mutation-check.sh | tail` reports tail's exit 0 however the
gate ended, turning a red gate into a reported pass. Redirect instead:

```bash
<gate> > /tmp/gate.log 2>&1; echo "EXIT=$?"
```

then read the file.

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

Structure, top to bottom: `meta` (phase titles must match the `phase()` calls exactly),
argument validation that throws early, `CEILINGS` per stage, then the phases in order.

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
