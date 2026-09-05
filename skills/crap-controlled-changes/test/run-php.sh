#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$SKILL_DIR/test/fixture-php"
PARSER="$SKILL_DIR/lib/parse_clover.py"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

sed "s|__REPO_ROOT__|$WORK|g" "$FIXTURE_DIR/clover-baseline.xml" > "$WORK/baseline.xml"
sed "s|__REPO_ROOT__|$WORK|g" "$FIXTURE_DIR/clover-current.xml"  > "$WORK/current.xml"

BASE_TSV="$(CRAP_REPO_ROOT="$WORK" CRAP_CHANGED_FILES="src/Branchy.php" \
  python3 "$PARSER" "$WORK/baseline.xml")"
CUR_TSV="$(CRAP_REPO_ROOT="$WORK" CRAP_CHANGED_FILES="src/Branchy.php" \
  python3 "$PARSER" "$WORK/current.xml")"

echo "--- baseline ---"
echo "$BASE_TSV"
echo "--- current ---"
echo "$CUR_TSV"

echo "$BASE_TSV" | grep -q 'src/Branchy.php::CrapFixture\\Branchy::simple'  || { echo "FAIL: baseline missing simple"; exit 1; }
echo "$BASE_TSV" | grep -q 'src/Branchy.php::CrapFixture\\Branchy::branchy' || { echo "FAIL: baseline missing branchy"; exit 1; }
echo "$BASE_TSV" | grep 'branchy' | grep -q $'\t4\t'   || { echo "FAIL: baseline branchy CC != 4"; exit 1; }
echo "$BASE_TSV" | grep 'branchy' | grep -q '20.8'     || { echo "FAIL: baseline branchy CRAP != 20.8"; exit 1; }
echo "$BASE_TSV" | grep 'simple'  | grep -q '100.0'    || { echo "FAIL: baseline simple coverage != 100"; exit 1; }
echo "$CUR_TSV"  | grep 'branchy' | grep -q $'\t5\t'   || { echo "FAIL: current branchy CC != 5"; exit 1; }
echo "$CUR_TSV"  | grep 'branchy' | grep -q '30.0'     || { echo "FAIL: current branchy CRAP != 30.0"; exit 1; }
echo "$CUR_TSV"  | grep 'branchy' | grep -q $'\t0.0\t' || { echo "FAIL: current branchy coverage != 0"; exit 1; }

echo "$BASE_TSV" > "$WORK/base.tsv"
echo "$CUR_TSV"  > "$WORK/cur.tsv"

OUT="$(awk -v BASEFILE="$WORK/base.tsv" -F '\t' '
  function status(s, cov, tag) {
    if (cov != "n/a" && cov+0 < 80 && (tag == "new" || tag == "worsened")) return "NEEDS_TESTS"
    if (s <= 6) return "OK"
    if (s <= 8) return "SOFT"
    return "HARD"
  }
  FILENAME == BASEFILE {
    base_cc[$1] = $2; base_cov[$1] = $3; base_crap[$1] = $4; next
  }
  {
    id=$1; cc=$2; cov=$3; crap=$4
    cur=(crap == "n/a") ? 0 : crap+0
    tag="new"
    if (id in base_cc) {
      base=(base_crap[id] == "n/a") ? 0 : base_crap[id]+0
      tag = (cur > base + 0.05) ? "worsened" : "unchanged"
    }
    printf "%s  cc=%s  cov=%s  crap=%s  %s  (%s)\n", id, cc, cov, crap, status(cur,cov,tag), tag
  }
' "$WORK/base.tsv" "$WORK/cur.tsv")"

echo "--- joined ---"
echo "$OUT"

echo "$OUT" | grep -q 'NEEDS_TESTS.*worsened'  || { echo "FAIL: branchy should be NEEDS_TESTS worsened"; exit 1; }
echo "$OUT" | grep -q 'simple.*OK.*unchanged'  || { echo "FAIL: simple should be OK unchanged"; exit 1; }

echo "OK"
