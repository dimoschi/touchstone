"""Which of the scored functions a commit changed.

`crap-check.sh` scores every function in each staged file, so a recorded row does
not say whether the commit edited that function. A function counts as changed
when its body or signature holds a line the commit added, or held one it removed
(read from the parent's copy of the file, so deleting a whole function marks
none of its neighbours). The ids built here are the ones the gate prints:
`<path>::<name>` for Python (`Class.method` for a method), `<package>.<name>` or
`<package>.<Type>.<name>` for Go (`<Type>[T]` for a generic one),
`<path>::<namespaced class>::<method>` for PHP.
A function whose id cannot be built the way the gate builds it reads as not
changed, which leaves it out of the figures rather than putting a wrong one in.
"""

import ast
import re
import warnings

from risk_core import added_lines, language_of, removed_lines
from risk_reach import enclosing_func
from risk_tools import cat_file, git

FUNCTIONS = (ast.FunctionDef, ast.AsyncFunctionDef)
GO_PACKAGE = re.compile(r'^package\s+(\w+)', re.MULTILINE)
GO_FUNC = re.compile(
    r'func\s+(?:\(\s*(?:\w+\s+)?\*?(?P<recv>\w+)(?P<targs>\[[^\]]*\])?[^)]*\)\s*)?(?P<name>\w+)')
PHP_NAMESPACE = re.compile(r'^namespace\s+([\w\\]+)', re.MULTILINE)
PHP_CLASS = re.compile(r'^\s*(?:(?:abstract|final|readonly)\s+)*(?:class|trait|enum)\s+(\w+)')
PHP_FUNCTION = re.compile(
    r'^(\s*)(?:(?:public|protected|private|static|final|abstract)\s+)*function\s+&?(\w+)\s*\(')


def python_functions(node, owner=None):
    """(name, def node) of each function and method under `node`; a closure is no row."""
    for child in ast.iter_child_nodes(node):
        if isinstance(child, FUNCTIONS):
            yield (f'{owner}.{child.name}' if owner else child.name), child
        elif isinstance(child, ast.ClassDef):
            yield from python_functions(child, child.name)
        else:
            yield from python_functions(child, owner)


def first_line(node):
    return min([node.lineno, *(d.lineno for d in node.decorator_list)])


def parse_python(text):
    # An invalid escape in the analysed source is its own business, not a warning of ours.
    with warnings.catch_warnings():
        warnings.simplefilter('ignore')
        return ast.parse(text)


def python_ids(path, text, added):
    try:
        tree = parse_python(text)
    except (SyntaxError, ValueError):
        return set()
    return {f'{path}::{name}' for name, node in python_functions(tree)
            if not added.isdisjoint(range(first_line(node), node.end_lineno + 1))}


def go_receiver(recv, targs):
    """The receiver type as the gate prints it, or None. go-crap v0.5.0 keeps the
    one type parameter of a generic type as written, and names every type with two
    or more `<unknown>`, an id several methods share."""
    if not targs:
        return recv
    names = targs[1:-1].split(',')
    return f'{recv}[{names[0].strip()}]' if len(names) == 1 else None


def go_id(package, match):
    recv = match.group('recv')
    if not recv:
        return f"{package}.{match.group('name')}"
    owner = go_receiver(recv, match.group('targs'))
    return f"{package}.{owner}.{match.group('name')}" if owner else None


def go_ids(path, text, added):
    package = GO_PACKAGE.search(text)
    lines = text.splitlines()
    decls = {enclosing_func(lines, n) for n in added} - {None}
    matches = (GO_FUNC.match(lines[decl - 1]) for decl in decls)
    return {go_id(package.group(1), m) for m in matches if m and package} - {None}


def php_end(lines, start, indent):
    """1-based last line of the function declared on 0-based line `start`: the
    line that ends a one-line or bodiless declaration, else its closing brace."""
    if lines[start].rstrip().endswith(('}', ';')):
        return start + 1
    for end in range(start + 1, len(lines)):
        if lines[end].startswith(indent + '}'):
            return end + 1
    return len(lines)


def php_functions(text):
    """(first line, last line, class, name) of each function in `text`; a function
    that is not indented sits outside every class."""
    namespace = PHP_NAMESPACE.search(text)
    lines = text.splitlines()
    owner = '<global>'
    for i, line in enumerate(lines):
        cls = PHP_CLASS.match(line)
        if cls:
            owner = f'{namespace.group(1)}\\{cls.group(1)}' if namespace else cls.group(1)
        fn = PHP_FUNCTION.match(line)
        if fn:
            klass = owner if fn.group(1) else '<global>'
            yield i + 1, php_end(lines, i, fn.group(1)), klass, fn.group(2)


def php_ids(path, text, added):
    return {f'{path}::{owner}::{name}' for first, last, owner, name in php_functions(text)
            if not added.isdisjoint(range(first, last + 1))}


FINDERS = {'go': go_ids, 'python': python_ids, 'php': php_ids}


def file_ids(repo, rev, path, lines):
    finder = FINDERS.get(language_of(path))
    data = cat_file(repo, rev, path) if finder else None
    return finder(path, data.decode(errors='replace'), lines) if data is not None else set()


def changed_ids(repo, sha):
    """{row id} of the scored functions the commit `sha` changed."""
    done = git(repo, '-c', 'core.quotePath=true', 'show', '--format=', '-U0', '--no-color',
               '--no-renames', sha)
    diff = done.stdout.decode(errors='replace')
    added = (file_ids(repo, sha, path, lines) for path, lines in added_lines(diff).items())
    removed = (file_ids(repo, f'{sha}^', path, lines)
               for path, lines in removed_lines(diff).items() if lines)
    return set().union(*added, *removed)
