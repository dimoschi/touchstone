#!/usr/bin/env python3
"""PreToolUse hook (Bash matcher): refuse to pipe a gate's output anywhere.

`$?` after a pipeline is the LAST command's status, so `mutation-check.sh | tail`
reports tail's exit 0 however the gate ended. Every gate here encodes its verdict
in the exit code (0 green, 1 findings, 2 setup failure), so a pipe converts a red
gate into a reported pass, and `tail`/`head` additionally cut off the findings the
gate exists to print.

Refusing every pipe rather than just `tail` is deliberate, for the reason
crap-commit-gate.py refuses rather than parses: which pipelines preserve status is
a judgement (`tee` keeps the output but still masks the code, `pipefail` is a
shell setting this hook cannot see), and each form guessed wrong is a silent false
green. Redirect to a file and read it instead; nothing is lost, since the file
holds the whole output and the exit code survives.

Exit 2 blocks, with the replacement form on stderr. Tests: test-gate-pipe.sh.
"""

import json
import re
import sys

GATES = ('crap-check.sh', 'crap-commit.sh', 'deadcode-check.sh', 'mutation-check.sh')

QUOTED = re.compile(r'"(?:\\.|[^"\\])*"|\'[^\']*\'')

HELP = '''gate-pipe-gate: do not pipe a gate. `$?` after a pipeline is the last
command's status, so the gate's verdict (0 green, 1 findings, 2 setup failure) is
replaced by the exit code of whatever you piped into, and a red gate reads as a
pass. `tail`/`head` also cut off the findings you need.

Redirect and read the file instead:

  <gate> > /tmp/gate.log 2>&1; echo "EXIT=$?"

then Read /tmp/gate.log. The whole output is there and the exit code is real.'''


def pipes_a_gate(cmd):
    """True if any pipeline segment both names a gate and pipes."""
    for segment in re.split(r'\|\||&&|;', cmd):
        if not any(gate in segment for gate in GATES):
            continue
        if '|' in segment:
            return True
    return False


def main():
    data = json.load(sys.stdin)
    cmd = (data.get('tool_input') or {}).get('command') or ''

    # A commit message may quote a gate's name and a pipe character; blanking
    # quoted spans settles that without a second rule, as in crap-commit-gate.py.
    if not pipes_a_gate(QUOTED.sub(' ', cmd)):
        return 0

    print(HELP, file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main())
