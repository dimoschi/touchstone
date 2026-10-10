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

# A quoted string or a heredoc body is data, not command line. An unquoted
# heredoc body can expand `$(...)`, but reading it as commands refused files
# that merely describe a piped gate.
DATA = re.compile(r"""
    (?<!<)<<-?[ \t]*(?P<delim>(?:'[^']*'|"[^"]*"|[^\s;&|<>()])+)
  | (?P<quoted>'[^']*'|"(?:\\.|[^"\\])*")
  | \\.
  | .
""", re.VERBOSE | re.DOTALL)

# Redirections come first so `>|` and `&>` are never read as a pipe or a list.
TOKEN = re.compile(r"""
    &>>? | [<>]& | >\| | >> | <<?<? | >
  | \|\| | \|& | && | [|;&\n()]
  | (?:\\.|[^\s|;&<>()\\])+
""", re.VERBOSE | re.DOTALL)

PIPES = ('|', '|&')
OPENS = ('(', '{')
CLOSES = (')', '}')
BREAKS = PIPES + ('||', '&&', ';', '&', '\n')

HELP = '''gate-pipe-gate: do not pipe a gate. `$?` after a pipeline is the last
command's status, so the gate's verdict (0 green, 1 findings, 2 setup failure) is
replaced by the exit code of whatever you piped into, and a red gate reads as a
pass. `tail`/`head` also cut off the findings you need.

Redirect and read the file instead:

  <gate> > /tmp/gate.log 2>&1; echo "EXIT=$?"

then Read /tmp/gate.log. The whole output is there and the exit code is real.'''


def skip_heredoc_bodies(cmd, pos, delims):
    """Return the position after the bodies of `delims`, which start at `pos`."""
    for delim in delims:
        end = re.compile(r'^\t*' + re.escape(delim) + '$', re.MULTILINE).search(cmd, pos)
        pos = end.end() if end else len(cmd)
    return pos


def command_text(cmd):
    """`cmd` with quoted strings and heredoc bodies removed."""
    kept, delims, pos = [], [], 0
    while pos < len(cmd):
        m = DATA.match(cmd, pos)
        pos = m.end()
        if m['delim']:
            delims.append(re.sub(r'[\'"\\]', '', m['delim']))
        elif m['quoted'] is None:
            kept.append(m.group())
        if m.group() == '\n':
            pos = skip_heredoc_bodies(cmd, pos, delims)
            delims = []
    return ''.join(kept)


class Group:
    """A brace group, subshell or the top level, as the token walk sees it."""

    def __init__(self):
        self.element_runs_gate = False
        self.runs_gate = False

    def ran(self, gate):
        self.element_runs_gate |= gate
        self.runs_gate |= gate


def step(stack, token):
    if token in OPENS:
        stack.append(Group())
    elif token in CLOSES and len(stack) > 1:
        inner = stack.pop()
        stack[-1].ran(inner.runs_gate)
    elif token in BREAKS:
        stack[-1].element_runs_gate = False
    else:
        stack[-1].ran(any(gate in token for gate in GATES))


def pipes_a_gate(cmd):
    """True if a pipe follows a pipeline element, at any group depth, that runs a gate."""
    stack = [Group()]
    for token in TOKEN.findall(command_text(cmd)):
        if token in PIPES and stack[-1].element_runs_gate:
            return True
        step(stack, token)
    return False


def main():
    data = json.load(sys.stdin)
    cmd = (data.get('tool_input') or {}).get('command')

    if cmd and pipes_a_gate(cmd):
        print(HELP, file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
