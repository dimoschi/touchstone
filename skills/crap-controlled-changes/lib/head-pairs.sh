# head_pairs <ref>: reads paths on stdin, emits "<path> <blob>" for each path's
# blob at <ref>, skipping paths absent from that ref. Shared by crap-check.sh
# and mutation-check.sh so their ledgers key blobs identically; a silent drift
# between the two would mis-key one of them.
head_pairs() {
  local ref="$1" p blob
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    blob="$(git rev-parse --quiet --verify "${ref}:$p" 2>/dev/null || true)"
    [ -n "$blob" ] && printf '%s %s\n' "$p" "$blob"
  done
  return 0
}
