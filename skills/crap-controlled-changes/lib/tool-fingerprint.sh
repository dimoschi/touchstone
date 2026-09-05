# tool_fingerprint <paths> <analyzer> <version>: what a ledger record is valid
# for beyond the blob, since a score belongs to the tool that produced it and not
# only to the content. Empty means "do not share this record across branches":
# php and python have no version handshake cheap enough to ask for per run, so a
# pass touching either stays branch-local rather than claiming more than it knows.
tool_fingerprint() {
  if printf '%s\n' "$1" | grep -qE '\.(php|py)$'; then
    return 0
  fi
  command -v go >/dev/null || return 0
  printf 'go=%s %s=%s' "$(go env GOVERSION)" "$2" "$3"
}
