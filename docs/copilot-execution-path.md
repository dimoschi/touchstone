# Copilot execution path (issue #53)

Findings from exercising GitHub Copilot CLI directly (v1.0.83, macOS) against a
throwaway local repo, plus documentation review, to answer the questions #45
already answered for Codex: which Copilot surface(s) can run Touchstone's
delivery policy, what the runtime actually guarantees, and what the smallest
adapter interface looks like. Everything under "Verified" below was run, not
inferred; everything under "Not yet verified" is an explicit gap, not a claim.

## Two Copilot surfaces, not one

- **Copilot CLI** — runs locally, in the developer's own shell. Interactive by
  default; `-p/--prompt` gives non-interactive scripting. All hook events fire.
  Folder trust and permission prompts apply.
- **Copilot cloud agent** — runs inside an ephemeral, non-interactive Linux
  sandbox GitHub provisions per job. Only `.github/hooks/*.json` is read (no
  user/policy hooks); only `bash`/`command` hook entries are honored
  (`powershell` ignored); outbound network is firewalled to GitHub/Copilot
  hosts by default; the filesystem is discarded when the job ends, so hook
  output must go over an `http` hook entry to survive, not to a file.

**Recommendation: target Copilot CLI first.** It is the closer analogue of
Claude Code's plugin runtime (local machine, full hook coverage, resumable
sessions) and of Codex's prototype target in #45. Copilot cloud agent is a
distinct, narrower target — worth a follow-up once the CLI adapter is solid,
not a blocker for it. This mirrors #45's own conclusion for Codex: evaluate
the existing host first, don't require a second billed surface to get basic
support working.

## There is no Workflow-tool equivalent — the driver has to be external

`workflows/deliver-pipeline.js` runs *inside* Claude's runtime, which supplies
`agent`, `parallel`, `phase`, and `budget` as host primitives. Copilot CLI has
no equivalent in-process scripting API. What it does have is a well-formed
**non-interactive subprocess contract**: `copilot -p "<prompt>" --output-format
json` runs one turn (or several, to completion) and emits one JSON object per
line on stdout, ending in a `{"type":"result",...}` line carrying `exitCode`
and `usage`.

The implication: a Copilot adapter is an **external deterministic script**
(bash or node, same language as this repo's other tooling) that invokes
`copilot -p` once per phase and decides what runs next by parsing that
process's exit code and JSON output — never by asking a running Copilot
session to self-orchestrate the next phase. This is exactly what the issue
warns against skipping ("do not substitute a prompt checklist for the
delivery controller"): the controller is the external script, full stop.
This is also the shape #49 is already extracting for Codex, so the Copilot
adapter should consume that same policy/contract layer as a third caller,
not re-derive phase transitions independently (tracked as its own issue, #57).

## Verified

All of the below were exercised against a real local repo with
`copilot -p ... --allow-all-tools --output-format json`, reading the actual
JSONL event stream and hook stdin/stdout.

- **Persistent run identity across phases.** `--session-id <uuid>` set on one
  invocation and reused on a later, separate `copilot -p` process resumes the
  same conversation (a value told to the model in call 1 was recalled
  correctly in call 2). This is the primitive a driver script uses to run each
  phase as its own OS process while keeping one continuous run identity, the
  direct analogue of the run/session identity #50 asks Codex's adapter to
  persist.
- **Structured phase output to validate at the boundary.** `--output-format
  json` gives one JSON object per line; the final line is always
  `{"type":"result","exitCode":...,"usage":{...}}`. A driver script parses this
  line for pass/fail and reads `assistant.message` events for the model's
  actual text — the same "trust structure, not prose" boundary #49 requires
  generically.
- **Budget/usage accounting, not enforcement.** `--usage-output-file <path>`
  writes a structured per-model token/cost breakdown after the process exits.
  `--max-ai-credits` is a **soft** cap, checked only after a model response
  returns — "[a] response can therefore exceed or exhaust the limit before the
  CLI can observe that it has done so" (own docs). This is the same
  after-the-fact accounting #45 found in Claude's and expects in Codex's
  runtime: usage reporting is real, a hard per-call ceiling is not.
- **Concurrent read-only-shaped invocations against one repo.** Two
  `copilot -p` background processes reading the same directory completed
  concurrently (~8-9s each, running in parallel, not serialized), which is
  what the Review phase's simultaneous reviewer lenses need.
- **Hard gate enforcement via hooks, with the same guarantee Claude's
  PreToolUse hooks give today.** A `.github/hooks/*.json` `preToolUse` command
  hook receives one JSON object on stdin —
  `{"sessionId","timestamp","cwd","toolName","toolArgs"}` — and its stdout is
  parsed for a decision object. Returning
  `{"permissionDecision":"deny","permissionDecisionReason":"..."}` reliably
  blocked the tool call: the resulting `tool.execution_complete` event reports
  `"success":false,"error":{"code":"denied","message":"Denied by preToolUse
  hook: ..."}`, and the agent cannot bypass it — it can only report the
  refusal back to the user, exactly like today's exit-2 refusal under Claude.
  This is the mechanism #56 needs to port `crap-commit-gate.py`,
  `mutation-pr-gate.py`, `base-branch-commit-gate.py`, and `gate-pipe-gate.py`
  to.
- **`--add-dir <dir>` grants scoped trust for a single session.** Per
  `copilot --help`, it "load[s] its `.github/skills` and `.github/agents` as
  trusted configuration" for that directory, without touching the user's
  global `trustedFolders`. This is the mechanism a driver script (or CI) should
  use to grant a worktree exactly the trust it needs, rather than mutating
  `~/.copilot/config.json`.

## A silent-failure mode that must be handled explicitly (blocks #56)

**Repo-level `.github/hooks/*.json` is not loaded — with no error, warning, or
event of any kind — unless the directory is inside the user's `trustedFolders`
list in `~/.copilot/config.json`.** Verified directly: an identical hook file,
byte-for-byte, fired every time from a directory under a trusted parent and
never fired even once from `/tmp` (untrusted). Nothing in the `--output-format
json` event stream mentions the hook, the skipped trust check, or the file at
all — a gated repo whose hooks silently never load looks, from the JSON
stream, identical to a repo with no `.github/hooks/` at all.

This is precisely the class of bug #48 already flags for Codex's edit gates
("no silent success caused by missing input fields") — here the missing input
is trust, not a field, but the failure shape is the same: a real gate that
looks green because it never ran. Any Copilot packaging or CI verification
(#54, #59) must assert the hook actually fired (e.g. via a marker file the
hook itself writes) rather than trusting a clean exit code as evidence a gate
was enforced. `--add-dir` (above) is the fix for a driver script that controls
its own invocation; it does not help an end user running `copilot` directly in
an untrusted clone, who needs to be told to trust the folder first.

## Not yet verified — explicit gaps, not solved here

- **Enforcing "read-only" on a reviewer is unresolved.** Both
  `--deny-tool write` (the documented `write(path?)` permission kind) and
  `--excluded-tools create,edit` were tried against the CLI's own built-in
  `create` tool in this build; neither blocked it — the file was created
  either way. Either the permission-kind classifier doesn't cover the CLI's
  native file tools the way it covers shell redirection, or the tool
  identifiers tested don't match what the permission system expects. This
  needs a follow-up spike (or a GitHub-side clarification) before #58 can
  claim reviewers are actually read-only; until then, the fallback is a
  `preToolUse` hook that explicitly denies `toolName in {"create","edit"}` for
  a reviewer's session, which is already proven to work per the Verified
  section above.
- **Copilot cloud agent was not exercised.** Everything above is Copilot CLI
  only. The cloud agent's sandboxed, non-interactive, partial-hook-event
  environment is a real third target, not assumed equivalent to the CLI, and
  is scoped as follow-up work rather than claimed here.
- **Cancellation/interruption mid-phase** was only exercised via an OS-level
  `timeout` wrapper around each `copilot -p` call, which worked cleanly. Truly
  interrupting a running call (e.g. SIGINT mid-tool-execution) and resuming via
  `--session-id`/`--resume` afterward was not tested end-to-end.
- **Custom-agent (`*.agent.md`) role restriction** (e.g. confirming a planner
  agent genuinely lacks write access, per #58's requirement) was not exercised
  in this pass — `--agent <agent>` exists and is documented, but its
  tool-restriction behavior wasn't independently verified here.

## Minimal adapter interface (answers #53's core question)

The smallest contract a Copilot adapter needs, beyond what #49 extracts
generically for both hosts:

1. **One `copilot -p` process per phase**, driven by an external script, never
   a self-orchestrating single session. `--session-id <run-id>` shared across
   phase calls gives continuity; `--output-format json` gives a parseable
   result line per call.
2. **A phase prompt that ends in one parseable JSON block**, validated by the
   driver before being trusted — the same "validate structured phase results
   at the adapter boundary" rule #49 states, satisfied the same way for
   Copilot as it will be for Codex.
3. **Hooks as the enforcement layer**, ported via a thin shim that maps
   Copilot's `{toolName, toolArgs, cwd}` stdin shape onto the shape
   `hooks/*.py` already expect (`tool_name`, `tool_input`), and maps the
   existing exit-2 refusal onto `{"permissionDecision":"deny"}` on stdout. The
   gate logic itself (CRAP, dead-code, mutation, base-branch, gate-pipe) does
   not change; only the thin translation layer at the hook's entrypoint does.
   Full mapping work is #56.
4. **`--add-dir` for trust, not global config**, so a driver script (or CI) can
   run a worktree's hooks/skills/agents without mutating the user's
   `~/.copilot/config.json`.
5. **Usage accounting via `--usage-output-file`**, read and recorded the same
   way agent-eval records phase metrics today — optional, additive, never a
   hard gate on its own.

## Supported surface and minimum tested version

**Copilot CLI 1.0.83** (macOS) is the only surface exercised here and the one
recommended as the initial target. Copilot cloud agent is explicitly
out of scope for this pass (see Not yet verified). Any claim of "Copilot
support" prior to a follow-up cloud-agent investigation should say "Copilot
CLI support," not "Copilot support" unqualified — the same discipline #52
already applies to distinguishing Claude Code's guarantees from Codex's.
