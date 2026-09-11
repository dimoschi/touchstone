# Copilot driver prototype (issue #53)

A small, actually-runnable spike proving the primitives a future Copilot
adapter (#57, #58) needs, against the real Copilot CLI -- not a mock. This is
investigation code for #53's acceptance criteria, not the shipped adapter.

Run it:

```sh
bash prototypes/copilot-driver/driver.sh
```

It makes real `copilot -p` calls (small, cheap prompts), so it costs a little
and takes roughly a couple of minutes. It:

1. Invokes a worker phase and validates its structured `--output-format json`
   result.
2. Proves a raw `git commit` is denied by a `preToolUse` hook before a local
   check has passed.
3. Proves `check-and-commit.sh` halts on a failing local check, then commits
   once the check passes.
4. Runs two reviewer-shaped calls concurrently and confirms they aren't
   serialized.
5. Attempts an interruption + resume via `--session-id`, and reports the
   real (negative) result: session state is not crash-durable across a killed
   process (see `docs/copilot-execution-path.md`).

Prints `PASS`/`FAIL` per step and exits non-zero if any fail -- including
step 5, which is an expected, tracked finding, not a bug in this script.
`RUN-LOG.md` is a captured real run.

## Files

- `driver.sh` -- the orchestrator described above.
- `hooks/preToolUse-commit-gate.sh` -- ports `hooks/crap-commit-gate.py`'s
  "refuse a raw `git commit`, redirect to a wrapper" policy to Copilot's real
  `preToolUse` hook JSON contract (camelCase `toolName`/`toolArgs`/`cwd` on
  stdin, `{"permissionDecision":...}` on stdout).
- `check-and-commit.sh` -- mirrors `hooks/crap-commit.sh`'s pattern: runs a
  local check, writes a marker file only on success, then commits.
- `RUN-LOG.md` -- captured output from a real run.

It is installed into an isolated `COPILOT_HOME` scratch directory by
`driver.sh`, so it never touches the real developer's `~/.copilot/config.json`
or `trustedFolders`.
