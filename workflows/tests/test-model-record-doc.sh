#!/usr/bin/env bash
# Regression test for ticket 107: a delivery run's record named which pipeline
# version ran (#101) but not which models did, and the models an alias
# resolves to can drift underneath an unchanged pipeline version. The fix is
# documentation only -- the workflow script has no filesystem access, so it
# cannot read the per-agent .meta.json/transcript records this needs, and the
# ticket says so explicitly ("the launcher records it, not the script"). These
# are static checks on commands/deliver.md's "Write the run record" section,
# the same section that documents adding run_id, so a future edit cannot drop
# the instruction silently.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness.sh"
DELIVER_MD="$REPO_ROOT/commands/deliver.md"

echo "== static: commands/deliver.md documents building the models map next to run_id"
check "the run_id instruction also names models" \
  "$(grep -Fc 'returned), `models`, and `recorded_on`' "$DELIVER_MD" || true)" 1
check "the JSON example carries a models field" \
  "$(grep -Fc '"models": { "<alias>": ["<model id>", ...] }' "$DELIVER_MD" || true)" 1
check "the source is the per-agent .meta.json for the alias" \
  "$(grep -Fc '.meta.json' "$DELIVER_MD" || true)" 1
check "the source is the agent transcript for the resolved model ID" \
  "$(grep -Fc 'agent-<id>.jsonl' "$DELIVER_MD" || true)" 1
check "an alias resolving to more than one model within a run lists every ID" \
  "$(grep -Fc 'list more than one ID under an alias if a model' "$DELIVER_MD" || true)" 1
check "never built by asking an agent which model it is" \
  "$(grep -Fc 'not by asking an agent which' "$DELIVER_MD" || true)" 1
check "unreadable records are reported, never silently omitted" \
  "$(grep -Fc '{ "unavailable": "<reason>" }' "$DELIVER_MD" || true)" 1
check "it names where the per-agent records live" \
  "$(grep -Fc 'subagents/workflows/<wf_id>/' "$DELIVER_MD" || true)" 1
check "it excludes the harness's <synthetic> placeholder entries" \
  "$(grep -Fc '<synthetic>' "$DELIVER_MD" || true)" 1

finish
