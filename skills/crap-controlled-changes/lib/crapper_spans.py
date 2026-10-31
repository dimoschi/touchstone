#!/usr/bin/env python3
"""Function spans and complexity from crapper, one tab-separated row per function.

Usage: crapper_spans.py --root DIR file...

Files are repo-relative to --root and are Go or Python. Each row is
  <file> <start line> <end line> <complexity> <name> <package>
where <name> is what a CRAP row is keyed on: "Class.method" or "func" for Python,
"pkg.func" or "pkg.Recv.method" for Go (<package> is the Go package clause, and
empty for Python). A Go receiver is named as written, minus its star and every
space, type parameters included (`pkg.Map[K,V].Get`): crapper's own namespace
drops them, and the id is what a function's refactor attempts are filed under.
It carries no whitespace because the Go rows that carry it downstream are split
on whitespace.

crapper is imported, never run as a command: its CLI writes .metrics/*.edn into
the project, and its coverage step installs tools and reports 0% when it fails.
It is not importable outside the environment lib/uv-pinned.sh builds, so this is
run through that. An import or read failure is an error, and nothing is printed
until every file has been read, so a caller never takes a short list for a whole
one.
"""

import argparse
import os
import sys
from types import SimpleNamespace

LANGUAGES = {".py": "python", ".go": "go"}


def _crapper():
    from crapper.languages import functions_in_file, golang, python
    from crapper.languages.treesitter import (child_of_type, descendants, node_text, parse,
                                              start_line)
    return SimpleNamespace(functions_in_file=functions_in_file, golang=golang, python=python,
                           child_of_type=child_of_type, descendants=descendants,
                           node_text=node_text, parse=parse, start_line=start_line)


def _inside(namespace, prefix):
    """What crapper added to `prefix` to make `namespace`: the classes or the receiver."""
    return namespace[len(prefix):].lstrip(".")


def _qualified(name, scope):
    return f"{scope}.{name}" if scope else name


def python_rows(crapper, functions, source, path, root):
    module = crapper.python._module_namespace(path, root)
    return [(fn, _qualified(fn.name, _inside(fn.namespace, module)), "") for fn in functions]


def _receiver_type(crapper, data, method):
    receiver = crapper.child_of_type(method, "parameter_list")
    declaration = crapper.child_of_type(receiver, "parameter_declaration")
    written = crapper.node_text(data, declaration.child_by_field_name("type"))
    return "".join(written.split()).removeprefix("*")


def go_rows(crapper, functions, source, path, root):
    data, tree = crapper.parse(source, "go")
    package = crapper.golang._package_clause(data, tree.root_node)
    receivers = {crapper.start_line(node): _receiver_type(crapper, data, node)
                 for node in crapper.descendants(tree.root_node) if node.type == "method_declaration"}
    return [(fn, f"{package}.{_qualified(fn.name, receivers.get(fn.start_line))}", package)
            for fn in functions]


ROWS = {"python": python_rows, "go": go_rows}


def rows_for(crapper, path, root):
    language = LANGUAGES.get(os.path.splitext(path)[1])
    if language is None:
        raise SystemExit(f"crapper_spans: {path} is neither a Go nor a Python file")
    with open(os.path.join(root, path), "rb") as handle:
        source = handle.read().decode(errors="replace")
    functions = crapper.functions_in_file(language, source, path, root)
    return [(path, fn.start_line, fn.end_line, fn.complexity, name, package)
            for fn, name, package in ROWS[language](crapper, functions, source, path, root)]


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("files", nargs="+")
    args = parser.parse_args(argv)
    crapper = _crapper()
    rows = [row for path in args.files for row in rows_for(crapper, path, args.root)]
    for row in rows:
        print("\t".join(str(field) for field in row))
    return 0


if __name__ == "__main__":
    sys.exit(main())
