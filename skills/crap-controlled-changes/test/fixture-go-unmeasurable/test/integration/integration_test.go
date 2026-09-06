package integration

import "testing"

// TestNeedsDatabase stands in for the live-service integration suites that make
// `go test ./...` unrunnable locally, such as packages needing Postgres or a
// message broker. crap4go's default test command therefore fails and it emits
// no CRAP report at all.
func TestNeedsDatabase(t *testing.T) {
	t.Fatal("dial unix /private/tmp/.s.PGSQL.5432: connect: no such file or directory")
}
