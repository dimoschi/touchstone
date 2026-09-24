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

# The shared classifier crap-check-php.sh itself calls. This used to be a fourth
# copy of the bands and the join, so the suite passed on its own replica while
# saying nothing about the module that ships.
classify() {
  python3 "$SKILL_DIR/lib/classify_rows.py" \
    --base "$WORK/base.tsv" --current "$WORK/cur.tsv" \
    --layout plain --repo-root "$WORK"
}

OUT="$(classify)"

echo "--- joined ---"
echo "$OUT"

echo "$OUT" | grep -q 'NEEDS_TESTS.*worsened'  || { echo "FAIL: branchy should be NEEDS_TESTS worsened"; exit 1; }
echo "$OUT" | grep -q 'simple.*OK.*unchanged'  || { echo "FAIL: simple should be OK unchanged"; exit 1; }

printf 'crap-soft = 0.5\n' > "$WORK/.crap-gated"
TUNED="$(classify)"
echo "--- with crap-soft = 0.5 ---"
echo "$TUNED"
echo "$TUNED" | grep -q 'simple.*SOFT.*unchanged' || { echo "FAIL: the marker's soft cap did not reach the PHP rows"; exit 1; }

echo "OK"
