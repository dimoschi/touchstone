# Prototype run log (issue #53)

Captured real output from `bash prototypes/copilot-driver/driver.sh`,
run against the actual Copilot CLI (v1.0.83), macOS, no mocks. Exit code
1 is expected: step 5 is a genuine, now-documented CLI limitation, not a
bug in this prototype -- see `docs/copilot-execution-path.md`.

```
== scratch run root: /var/folders/s0/7sb813cj6jj6f6pdf5fcnh300000gn/T/tmp.FGp2im7qtl ==
== isolated COPILOT_HOME: /var/folders/s0/7sb813cj6jj6f6pdf5fcnh300000gn/T/tmp.FGp2im7qtl/copilot-home (real ~/.copilot untouched) ==

### 1. Worker phase: invoke, then validate its structured result
PASS: worker phase produced calc.py + test_calc.py and reported exitCode 0

### 2. Hard gate: a raw commit is refused before the local check runs
PASS: raw git commit was denied by the preToolUse hook before any local check ran

### 3. Local check halts on failure, then unblocks the commit on success
== running local check (python3 -m unittest) ==
PASS: check-and-commit.sh halted (nonzero exit) on a failing local check, nothing committed
== running local check (python3 -m unittest) ==
test_add_negative_numbers (test_calc.TestAdd.test_add_negative_numbers) ... ok
test_add_positive_numbers (test_calc.TestAdd.test_add_positive_numbers) ... ok
test_add_zero (test_calc.TestAdd.test_add_zero) ... ok

----------------------------------------------------------------------
Ran 3 tests in 0.000s

OK
== check passed ==
== committed ==
PASS: check-and-commit.sh committed once the local check passed (HEAD advanced)

### 4. Two read-only-shaped reviewers run concurrently
PASS: both concurrent reviewer processes exited 0 (wall time 109s, not serialized)

### 5. Recover state after interruption
FINDING: SIGTERM mid-turn (during a tool call) orphans the --session-id. The
  resumed call did NOT error and did NOT recover the token -- it silently
  started a brand-new conversation ("message_count":1) and answered UNKNOWN.
  This means a driver MUST NOT rely on --session-id reuse for crash recovery;
  it must keep its own external phase-completion checkpoint instead.
FAIL: confirmed: Copilot CLI session state is not crash-durable across a killed process

================================================================
SOME PROTOTYPE CHECKS FAILED (see FAIL lines above)
EXIT=1
```
