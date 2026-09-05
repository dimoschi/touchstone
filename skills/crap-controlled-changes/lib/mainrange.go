//go:build ignore

// mainrange.go: print the line span of `func main()` for each Go file whose
// path arrives on stdin, one per line, for parse_mutago.py's package-main
// mutation exemption.
//
// Paths come in on stdin rather than argv because `go run x.go a.go b.go`
// reads every trailing .go as another source file, not as an argument.
//
// Output is one TSV row per file that declares it: <path>\t<start>\t<end>.
// Files in another package, files without a main, and files that fail to parse
// are omitted, so a broken toolchain or a syntax error exempts nothing and
// every mutant keeps blocking.
package main

import (
	"bufio"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
)

func main() {
	fset := token.NewFileSet()
	in := bufio.NewScanner(os.Stdin)
	for in.Scan() {
		path := in.Text()
		if path == "" {
			continue
		}
		f, err := parser.ParseFile(fset, path, nil, 0)
		if err != nil || f.Name.Name != "main" {
			continue
		}
		for _, d := range f.Decls {
			fn, ok := d.(*ast.FuncDecl)
			if !ok || fn.Recv != nil || fn.Name.Name != "main" || fn.Body == nil {
				continue
			}
			fmt.Printf("%s\t%d\t%d\n", path,
				fset.Position(fn.Pos()).Line, fset.Position(fn.End()).Line)
		}
	}
}
