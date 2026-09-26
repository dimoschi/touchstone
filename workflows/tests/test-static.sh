#!/usr/bin/env bash
# Static grep assertions on deliver-pipeline.js. Split out of
# test-fix-loop-join.sh (gh-118); see harness.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"

echo "== static: the join reads only v.id, never v.title"
check "no v.title reference remains" \
  "$(grep -c 'v\.title' "$SCRIPT" || true)" 0

echo "== static: EXECUTE_RESULT requires id, exit_code and output per row"
check "EXECUTE_RESULT lists id, exit_code, output in its required array" \
  "$(grep -c "required: \['id', 'exit_code', 'output'\]" "$SCRIPT" || true)" 1
check "no LLM verifier schema (VERDICTS) remains" \
  "$(grep -c '^const VERDICTS' "$SCRIPT" || true)" 0

echo ""
echo "== static: gh-113 -- the marker constant and its interpolation into REPRODUCER_CONTRACT"
check "REPRODUCED_MARKER is the fixed marker line" \
  "$(grep -Fc "const REPRODUCED_MARKER = 'TOUCHSTONE_DEFECT_REPRODUCED'" "$SCRIPT" || true)" 1
check "REPRODUCER_CONTRACT interpolates the constant, not a copy of the string" \
  "$(grep -Fc 'Print ${REPRODUCED_MARKER} on a line of' "$SCRIPT" || true)" 1
check "the contract states a nonzero exit without the marker is not a demonstration" \
  "$(grep -Fc 'failing to run, never as a demonstration' "$SCRIPT" || true)" 1
check "the contract demands a self-contained command" \
  "$(grep -Fc 'The command must be self-contained: set any environment' "$SCRIPT" || true)" 1
check "outcomeOf is the one pure function deciding a row's disposition" \
  "$(grep -Fc 'const outcomeOf = (row) =>' "$SCRIPT" || true)" 1
check "the executor prompt asks for combined stdout+stderr verbatim and complete" \
  "$(grep -Fc 'verbatim and complete -- do not summarise, truncate, or interpret' "$SCRIPT" || true)" 1

echo ""
echo "== static: gh-106 -- FINDINGS requires category from the closed enum, first among its properties"
check "category is required" \
  "$(grep -c "required: \['category', 'title', 'file', 'claim', 'evidence'\]" "$SCRIPT" || true)" 1
check "the closed category enum lists all nine" \
  "$(grep -Fc "['wrong-result', 'crash', 'gate-bypass', 'unmet-criterion'," "$SCRIPT" || true)" 1
check "BLOCKING_CATEGORIES names exactly the four blocking categories" \
  "$(grep -Fc "new Set(['wrong-result', 'crash', 'gate-bypass', 'unmet-criterion'])" "$SCRIPT" || true)" 1
check "MAX_FINDINGS_PER_LENS is 5" \
  "$(grep -Fc 'const MAX_FINDINGS_PER_LENS = 5' "$SCRIPT" || true)" 1
check "every lens is told an empty list is the expected result for a correct change" \
  "$(grep -Fc 'empty list is the expected result for a correct change' "$SCRIPT" || true)" 1
check "the requirements lens carries needsTicket, so ticketSpec() reaches only it" \
  "$(grep -Fc 'needsTicket: true' "$SCRIPT" || true)" 1
check "classify() is a pure script function, never a prompt's own judgement" \
  "$(grep -Fc 'const classify = (f, ctx) =>' "$SCRIPT" || true)" 1

echo ""
echo "== static: BRANCH requires dirty on every response"
# A haiku-at-low-effort branch agent that simply omits dirty must fail schema
# validation, not have it default to false and mask a dirty checkout as clean.
check "BRANCH's required array lists dirty" \
  "$(grep -c "required: \['created', 'branch', 'base', 'path', 'detail', 'dirty'\]" "$SCRIPT" || true)" 1

echo "== static: BRANCH's halt_reason enum covers the merged and occupied halts, not just ambiguous and wrong-ticket"
check "halt_reason enum lists all five" \
  "$(grep -c "enum: \['none', 'ambiguous', 'wrong-ticket', 'merged', 'occupied'\]" "$SCRIPT" || true)" 1

echo ""
echo "== static: treeAgent tells every phase where scratch work goes (gh-40)"
# treeAgent() builds the prompt every phase (triage, plan, implement, fix,
# review, mutation) shares, so one addition here reaches all of them. Without
# it, an agent reproducing a behaviour defaults to /tmp, which resolves git
# identity and signing config from the global config instead of the worktree.
check "the scratch path is resolved from the worktree's own git dir, not /tmp" \
  "$(grep -Fc 'git-path touchstone-scratch' "$SCRIPT" || true)" 1
check "it still names /tmp as the default it exists to replace" \
  "$(grep -Fc 'anything you would otherwise drop in /tmp' "$SCRIPT" || true)" 1
check "it does not route the scratch path through info/exclude" \
  "$(grep -Fc 'git-path info/exclude' "$SCRIPT" || true)" 0
check "it does not edit .gitignore, which would dirty the tree the baseline reads" \
  "$(grep -Fc 'covered by .gitignore (add an entry there if it is not)' "$SCRIPT" || true)" 0
check "it does not cite a fixture path only touchstone's own repo has" \
  "$(grep -Fc 'run-go-unmeasurable.sh' "$SCRIPT" || true)" 0
check "it spells out signing off with an explicit test identity" \
  "$(grep -Fc 'commit.gpgsign=false' "$SCRIPT" || true)" 1
check "the scratch commit recipe carries git -C, not just init" \
  "$(grep -Fc 'git -C <scratch path> -c commit.gpgsign=false' "$SCRIPT" || true)" 1
# git -C needs the directory to exist, and --git-path only names it, so the
# form that creates it is the one that has to be spelled out.
check "the recipe creates the directory rather than assuming it" \
  "$(grep -Fc 'git init -q <scratch path> creates the directory' "$SCRIPT" || true)" 1
check "it stages before committing, so the commit is not empty" \
  "$(grep -Fc 'git -C <scratch path> add -A' "$SCRIPT" || true)" 1
check "it passes a message, so the commit cannot open an editor" \
  "$(grep -Fc 'commit -q -m scratch' "$SCRIPT" || true)" 1

echo "== static: the verifier's brief no longer demands order or a verbatim title"
# The old instruction, word for word. A hit elsewhere in the file (an
# unrelated comment, or this test's own header explaining the old bug) must
# not trip this, so the check is the exact old phrase, not the bare word.
check "the old 'title verbatim' instruction is gone" \
  "$(grep -Fc 'with the same title verbatim' "$SCRIPT" || true)" 0
check "the old 'one verdict per finding ... in the same order' instruction is gone" \
  "$(grep -Fc 'in the same order, with the same' "$SCRIPT" || true)" 0
# The verify brief, the staleness probe and the cross-lens dedup brief. Every
# brief that lists findings renders the id, because every one of them is joined
# back on it.
check "each brief that lists findings renders its id in brackets" \
  "$(grep -c '\[\${f\.id}\]' "$SCRIPT" || true)" 2

echo ""
echo "== static: the staleness probe checks evidence, not merely the file"
# Wrapped across two lines in the source, same as the old --oneline check, so
# checked as two substrings rather than one.
check "the probe reads the diff (git log -p), not just the commit list" \
  "$(grep -Fc 'git log -p' "$SCRIPT" || true)" 1
check "the probe still scopes the diff to <recorded_at>..HEAD" \
  "$(grep -Fc '<recorded_at>..HEAD' "$SCRIPT" || true)" 1
check "the probe hands the finding's evidence to the agent" \
  "$(grep -Fc 'Evidence: ${f.evidence}' "$SCRIPT" || true)" 1

echo ""
echo "== staleness probe: the git command against a real scratch repo"
# The prompt wraps this across two lines; checked as two substrings rather
# than one so a rewrap does not make this test outrun the actual source.
check "the prompt gives the path-scoping half of the command" \
  "$(grep -Fc -- '-- <file>' "$SCRIPT" || true)" 1

echo ""
echo "== static: the scored/gateNote comments agree on which phases feed measured"
check "the aggregate comment does not stop the scope at the fix loop" \
  "$(grep -Fc 'from here through the fix loop' "$SCRIPT" || true)" 0
check "the aggregate comment names the mutation loop, matching gatesPayload's own comment" \
  "$(grep -Fc 'from here through the mutation loop' "$SCRIPT" || true)" 1

echo ""
echo "== static: gh-118 -- every agent dispatch passes through dispatch(), never agent() directly"
check "the only real 'await agent(' call site is dispatch's own" \
  "$(grep -c 'await agent(' "$SCRIPT" || true)" 1
check "that one call site is inside dispatch, not a bare top-level call" \
  "$(grep -Fc 'return await agent(prompt, opts)' "$SCRIPT" || true)" 1
check "no separate ticket/plugin:version/gate:opt-in/checks:discover/run-record labels remain" \
  "$(grep -cE "label: '(ticket|plugin:version|gate:opt-in|checks:discover|run-record)'" "$SCRIPT" || true)" 0

echo ""
echo "== static: gh-118 -- the shared native-tools and generated-files sentences reach every prompt that needs them"
check "NATIVE_TOOLS reaches implement, checks:fix, fix and reviewOf" \
  "$(grep -Fc '${NATIVE_TOOLS}' "$SCRIPT" || true)" 4
check "GENERATED_FILES reaches implement, checks:fix and fix, not reviewOf" \
  "$(grep -Fc '${GENERATED_FILES}' "$SCRIPT" || true)" 3

finish
