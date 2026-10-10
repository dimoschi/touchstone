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

The command is read with a small tokenizer, not a shell parser. Quoted strings
and heredoc bodies are data, except a quoted word ending in a gate's name, a
heredoc fed to bash/sh/zsh, and `$(...)` in an unquoted heredoc body. Groups
(`{}`, `()`, do/done, if/fi, case/esac) are tracked, so a pipe after a group
that ran a gate is refused at any depth. Known limits: code run from inside a
quoted string (`bash -c "..."`), shell functions, ANSI-C `$'...'` quoting and
obfuscated gate names get past it, and a gate's name used as a search argument
(`grep crap-check.sh f | wc`) is refused although harmless.

Exit 2 blocks, with the replacement form on stderr. Tests: test-gate-pipe.sh.
"""

import json
import re
import sys

GATES = ('crap-check.sh', 'crap-commit.sh', 'deadcode-check.sh', 'mutation-check.sh')

# Arithmetic comes first so the `<<` in `$((1 << 3))` is not read as a heredoc.
DATA = re.compile(r"""
    \$?\(\((?:[^()]|\([^()]*\))*\)\)
  | (?<!<)<<-?[ \t]*(?P<delim>(?:'[^']*'|"[^"]*"|[^\s;&|<>()])+)
  | '[^']*' | "(?:\\.|[^"\\])*"
  | \\.
  | .
""", re.VERBOSE | re.DOTALL)

# Redirections come first so `>|` and `&>` are never read as a pipe or a list.
# A quoted string stays inside its word, so its `|` and `;` are not operators.
TOKEN = re.compile(r"""
    &>>? | [<>]& | >\| | >> | <<?<? | >
  | \|\| | \|& | && | [|;&\n()]
  | (?:'[^']*'|"(?:\\.|[^"\\])*"|\\.|[^\s|;&<>()\\'"])+
""", re.VERBOSE | re.DOTALL)

# A word names a gate when it ends in the gate's file name, quoted or not, so a
# quoted path runs the gate but a sentence that mentions one does not.
GATE_WORD = re.compile(r'(?:^["\']?|/)(?:' + '|'.join(map(re.escape, GATES)) + r')["\']?$')
SHELL = re.compile(r'(?:^|[\s/])(?:ba|z)?sh(?=\s|$)')
SUBSTITUTION = re.compile(r'\$\((?:[^()]|\([^()]*\))*\)')
QUOTE_CHARS = re.compile(r'[\'"\\]')

PIPES = ('|', '|&')
BREAKS = PIPES + ('||', '&&', ';', '&', '\n')
CLOSERS = {'(': ')', '{': '}', 'do': 'done', 'if': 'fi', 'case': 'esac'}
# Tokens after which the next word is in command position, where keywords count.
STARTERS = BREAKS + ('(', ')', '{', 'do', 'if', 'then', 'elif', 'else')

HELP = '''gate-pipe-gate: do not pipe a gate. `$?` after a pipeline is the last
command's status, so the gate's verdict (0 green, 1 findings, 2 setup failure) is
replaced by the exit code of whatever you piped into, and a red gate reads as a
pass. `tail`/`head` also cut off the findings you need.

Redirect and read the file instead:

  <gate> > /tmp/gate.log 2>&1; echo "EXIT=$?"

then Read /tmp/gate.log. The whole output is there and the exit code is real.'''


def heredoc_body(cmd, pos, delim):
    """The heredoc body starting at `pos` and ending at `delim`, and the position after it."""
    end = re.compile(r'^\t*' + re.escape(delim) + '$', re.MULTILINE).search(cmd, pos)
    if end:
        return cmd[pos:end.start()], end.end()
    return cmd[pos:], len(cmd)


def body_commands(body, raw_delim, fed_to_shell):
    """The parts of a heredoc body that run as commands."""
    if fed_to_shell:
        return [command_text(body)]
    subs = () if QUOTE_CHARS.search(raw_delim) else SUBSTITUTION.findall(body)
    return [command_text(sub) for sub in subs]


def read_heredocs(cmd, pos, heredocs, kept):
    """Append the commands in each pending heredoc body to `kept`; return the position after them."""
    for raw_delim, fed_to_shell in heredocs:
        body, pos = heredoc_body(cmd, pos, QUOTE_CHARS.sub('', raw_delim))
        kept.extend(body_commands(body, raw_delim, fed_to_shell))
    return pos


def feeds_shell(text):
    """True if the simple command at the end of `text` runs bash, sh or zsh."""
    return bool(SHELL.search(re.split(r'[;&|\n()]', text)[-1]))


def command_text(cmd):
    """`cmd` with heredoc bodies reduced to the commands they run."""
    kept, heredocs, pos = [], [], 0
    while pos < len(cmd):
        m = DATA.match(cmd, pos)
        pos = m.end()
        if m['delim']:
            heredocs.append((m['delim'], feeds_shell(''.join(kept))))
        else:
            kept.append(m.group())
        if m.group() == '\n':
            pos = read_heredocs(cmd, pos, heredocs, kept)
            heredocs = []
    return ''.join(kept)


class Group:
    """A compound command or the top level, as the token walk sees it."""

    def __init__(self, closer):
        self.closer = closer
        self.element_runs_gate = False
        self.runs_gate = False

    def ran(self, gate):
        self.element_runs_gate |= gate
        self.runs_gate |= gate


class Walk:
    """The open groups, and whether the next word is in command position."""

    def __init__(self):
        self.stack = [Group(None)]
        self.at_start = True

    def closes(self, token):
        return token == self.stack[-1].closer and (token == ')' or self.at_start)

    def opens(self, token):
        return token == '(' or (self.at_start and token in CLOSERS)

    def step(self, token):
        if self.closes(token):
            inner = self.stack.pop()
            self.stack[-1].ran(inner.runs_gate)
        elif self.opens(token):
            self.stack.append(Group(CLOSERS[token]))
        elif token in BREAKS:
            self.stack[-1].element_runs_gate = False
        else:
            self.stack[-1].ran(bool(GATE_WORD.search(token)))
        self.at_start = token in STARTERS


def pipes_a_gate(cmd):
    """True if a pipe follows a pipeline element, at any group depth, that runs a gate."""
    walk = Walk()
    for token in TOKEN.findall(command_text(cmd)):
        if token in PIPES and walk.stack[-1].element_runs_gate:
            return True
        walk.step(token)
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
