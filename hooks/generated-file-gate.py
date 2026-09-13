#!/usr/bin/env python3
"""PreToolUse hook (Edit|Write|MultiEdit matcher): refuse to hand-edit generated files.

A generated file is overwritten by its generator, so an edit here is lost at the
next `make gen-models` / `make gen-mocks` / `make proto` and, worse, is lost
silently: the code compiles and the tests pass until someone regenerates. The
fix always lives upstream, in the SQL query, the proto, or the interface.

Detection is the file's own marker wherever one can exist. `*.sql.go`, `*.pb.go`,
`mock_*.go` and friends are a naming convention each generator opts into, and a
path pattern is wrong in both directions: it misses generators nobody listed and
catches hand-written files that happen to match. A line that says both
"generated" and "DO NOT EDIT", or carries `@generated`, is the marker Go, sqlc,
mockgen, protoc, swaggo and prettier all already emit.

GENERATED_NAMES is the exception, and a narrow one: JSON has no comment syntax,
so a swagger spec has nowhere to carry a marker at all. These are exact
basenames that no project hand-writes, not a pattern standing in for the marker.

Checked in the incoming content as well as on disk, so writing a fresh generated
file is refused too, not just editing one that already exists.

Not airtight: a heredoc through Bash reaches neither this hook nor the file
tools. That is the escape valve for the rare case a generator's output genuinely
must be patched, and it is deliberately inconvenient rather than absent.

Exit 2 blocks. Tests: test-generated-file.sh.
"""

import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from copilot_session_evidence import canonical_path
from hook_invocation import normalize_invocation, tool_input_path

HEADER_LINES = 10

GENERATED_NAMES = frozenset({'swagger.json', 'swagger.yaml'})
EDIT_TOOLS = frozenset({'Edit', 'Write', 'MultiEdit'})

MARKER = re.compile(r'@generated|(?=.*\bgenerated\b)(?=.*\bDO NOT EDIT\b)', re.I)

HELP = '''generated-file-gate: {reason}

An edit here survives only until the next regeneration, and disappears without a
failure when it goes. Change the source the generator reads, then re-run it:

  sqlc      edit database/queries/*.sql   then `make gen-models`
  mockgen   edit the interface            then `make gen-mocks`
  protoc    edit proto/*.proto            then `make proto`
  swag      edit the handler annotations  then `make swagger`

The repo's CLAUDE.md names the exact command where it differs.'''


def is_generated(text):
    for line in text.split('\n')[:HEADER_LINES]:
        if MARKER.search(line):
            return True
    return False


def main():
    data = json.load(sys.stdin)
    invocation = normalize_invocation(data)
    tool_input = data.get('tool_input') or {}
    if not isinstance(tool_input, dict):
        tool_input = {}
    path = tool_input_path(tool_input)
    if invocation is not None and invocation.host == 'copilot' \
            and invocation.event == 'pre_tool_use' \
            and invocation.tool_name in EDIT_TOOLS \
            and path is not None:
        path = canonical_path(path, invocation.cwd)
    if not path:
        return 0

    if os.path.basename(path) in GENERATED_NAMES:
        reason = f'{path} is generator output; a JSON or YAML spec has no comment syntax to say so in.'
    elif is_generated(tool_input.get('content') or ''):
        reason = f'{path} is generated: the content being written says so in its header.'
    else:
        try:
            with open(path, errors='replace') as handle:
                head = ''.join(next(handle, '') for _ in range(HEADER_LINES))
        except OSError:
            return 0
        if not is_generated(head):
            return 0
        reason = f'{path} is generated, and says so in its header.'

    print(HELP.format(reason=reason), file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main())
