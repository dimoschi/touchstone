#!/usr/bin/env bash
# run-go-ids.sh: the ids lib/crapper_spans.py gives Go functions, with the real crapper.
#
# A function's id is what its refactor attempts are filed under in
# crap-check-state.json, so it has to stay what it was when go-crap named it: a
# method is "<pkg>.<receiver as written, minus its star>.<name>", type
# parameters included. crapper's own namespace drops them.

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SKILL_DIR/lib"

command -v uv >/dev/null || { echo "SKIP: uv not on PATH"; exit 0; }

. "$LIB_DIR/tool-versions.sh"
. "$LIB_DIR/uv-pinned.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

printf 'module example.com/ids\n\ngo 1.21\n' > "$WORK/go.mod"
cat > "$WORK/ids.go" <<'GO'
package ids

type Stack[T any] struct{ items []T }

func (s *Stack[T]) Push(v T) { s.items = append(s.items, v) }

func (s Stack[T]) Len() int { return len(s.items) }

type Widget struct{}

func (w *Widget) Run() {}

func (Widget) Name() string { return "widget" }

func Plain() {}
GO

pinned_run crapper "$CRAPPER_SHA_DEFAULT" "${CRAP_CRAPPER_RUN:-}" \
  "$LIB_DIR/crapper_spans.py" --root "$WORK" ids.go > "$WORK/rows.tsv"

GOT="$(cut -f5 "$WORK/rows.tsv")"
WANT='ids.Stack[T].Push
ids.Stack[T].Len
ids.Widget.Run
ids.Widget.Name
ids.Plain'

if [ "$GOT" = "$WANT" ]; then
  echo "OK"
else
  echo "FAILED: ids differ"
  printf 'got:\n%s\nwant:\n%s\n' "$GOT" "$WANT"
  exit 1
fi
