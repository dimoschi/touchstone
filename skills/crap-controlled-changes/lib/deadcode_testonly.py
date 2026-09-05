#!/usr/bin/env python3
"""Packages that only tests import, read off `go list` import edges.

A cross-package test helper (net/http/httptest, and every `<thing>test` package
that follows it) cannot live in testdata/, because the go tool ignores that
directory and nothing there is importable. It has to be an ordinary package, so
it sits inside the deadcode gate's scope permanently, and every method it will
ever have is unreachable from every main. Naming is no help either: the helper
may be called ovntest, testutil, fixtures or harness.

The import graph decides it without a convention. A package that appears in some
package's TestImports or XTestImports and in nobody's Imports has no non-test
consumer by construction. A package imported by nothing at all does NOT qualify:
a helper package nobody uses yet is exactly what the gate should still catch.

Reads `go list -deps -f '{{.ImportPath}}|{{join .Imports " "}}|{{join
.TestImports " "}}|{{join .XTestImports " "}}' ./...` on stdin, one package per
line. Import paths cannot contain '|', so the split is unambiguous. Prints the
qualifying import paths, one per line.
"""

import sys


def main():
    prod, test = set(), set()
    for line in sys.stdin:
        parts = line.rstrip('\n').split('|')
        if len(parts) != 4:
            continue
        _, imports, test_imports, xtest_imports = parts
        prod.update(imports.split())
        test.update(test_imports.split())
        test.update(xtest_imports.split())

    for pkg in sorted(test - prod):
        print(pkg)
    return 0


if __name__ == '__main__':
    sys.exit(main())
