#!/usr/bin/env bash
# Live E2E test for the PHP module against the real infection binary. Skips unless
# php (^8.3, with a coverage driver), infection and phpunit are all present, since
# most machines here have none of them; run-mutation-php-config.sh covers the same
# contract with a stub and always runs.
#
# Locate the toolchain with PHP_BIN, INFECTION_PHAR and PHPUNIT_PHAR, or leave them
# unset to auto-detect a mise php and the usual paths. The repo built here has no
# composer: phpunit gets a bootstrap that requires the sources directly, which is
# also the shape infection's `bootstrap` config key expects.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$SKILL_DIR/lib/mutation-check-php.sh"

PHP_BIN="${PHP_BIN:-$(ls -d "$HOME"/.local/share/mise/installs/php/8.[345].* 2>/dev/null | tail -1)/bin/php}"
INFECTION_PHAR="${INFECTION_PHAR:-$HOME/.local/bin/infection}"
PHPUNIT_PHAR="${PHPUNIT_PHAR:-/tmp/phpunit-11.phar}"

command -v git >/dev/null       || { echo "SKIP: git not on PATH"; exit 0; }
[ -x "$PHP_BIN" ]               || { echo "SKIP: no php ^8.3 found (set PHP_BIN)"; exit 0; }
[ -f "$INFECTION_PHAR" ]        || { echo "SKIP: no infection (set INFECTION_PHAR)"; exit 0; }
[ -f "$PHPUNIT_PHAR" ]          || { echo "SKIP: no phpunit (set PHPUNIT_PHAR)"; exit 0; }
# Not `php -m | grep -q`: grep -q exits on the first match, php takes SIGPIPE, and
# pipefail then reports the pipeline as failed, so this skipped at random.
case "$("$PHP_BIN" -m)" in
  *pcov*|*xdebug*|*Xdebug*) ;;
  *) echo "SKIP: php has no coverage driver"; exit 0 ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

commit() {
  GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
    git commit -q "$@"
}

run() {
  RC=0
  OUT="$(MUTATION_BASE=main MUTATION_FILES=src/Calc.php \
         MUTATION_PHP_INFECTION="$PHP_BIN $INFECTION_PHAR" "$MODULE" 2>&1)" || RC=$?
}

git init -qb main
mkdir -p src tests
cat > src/Calc.php <<'EOF'
<?php
final class Calc
{
    public function classify(int $n): string
    {
        if ($n < 0) {
            return 'negative';
        }
        return 'nonnegative';
    }
}
EOF
cat > tests/bootstrap.php <<'EOF'
<?php
require __DIR__ . '/../src/Calc.php';
EOF
cat > phpunit.xml <<'EOF'
<?xml version="1.0"?>
<phpunit bootstrap="tests/bootstrap.php" colors="false">
  <testsuites>
    <testsuite name="unit">
      <directory>tests</directory>
    </testsuite>
  </testsuites>
  <source>
    <include><directory>src</directory></include>
  </source>
</phpunit>
EOF
cat > infection.json <<'EOF'
{
  "source": { "directories": ["src"] },
  "bootstrap": "tests/bootstrap.php",
  "phpUnit": { "customPath": "PHPUNIT_PLACEHOLDER" }
}
EOF
sed -i '' "s|PHPUNIT_PLACEHOLDER|$PHPUNIT_PHAR|" infection.json
# A test that executes the method without distinguishing its branches: coverage is
# 100%, and every mutant of the comparison and both returns still passes.
cat > tests/CalcTest.php <<'EOF'
<?php
use PHPUnit\Framework\TestCase;

final class CalcTest extends TestCase
{
    public function testClassifyRuns(): void
    {
        $c = new Calc();
        $this->assertIsString($c->classify(-1));
        $this->assertIsString($c->classify(1));
    }
}
EOF
git add -A
commit -m baseline

git checkout -qb feature
cat >> src/Calc.php <<'EOF'
EOF
python3 - <<'PY'
import pathlib
p = pathlib.Path('src/Calc.php')
s = p.read_text().replace("""    public function classify(int $n): string
""", """    public function label(int $n): string
    {
        if ($n > 10) {
            return 'big';
        }
        return 'small';
    }

    public function classify(int $n): string
""")
p.write_text(s)
PY
git add src/Calc.php
commit -m "feat: add label, executed but not asserted"

echo "--- phase 1: a mutant that no assertion distinguishes is reported SURVIVED ---"
cat >> tests/CalcTest.php <<'EOF'
EOF
python3 - <<'PY'
import pathlib
p = pathlib.Path('tests/CalcTest.php')
s = p.read_text().replace("""    public function testClassifyRuns(): void""", """    public function testLabelRuns(): void
    {
        $c = new Calc();
        $this->assertIsString($c->label(50));
    }

    public function testClassifyRuns(): void""")
p.write_text(s)
PY
git add tests/CalcTest.php
commit -m "test: execute label without asserting it"
run
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: expected a measured run (exit 0), got $RC"; exit 1; }
echo "$OUT" | grep -q "SURVIVED" || { echo "FAIL: no survivor from an unasserted branch"; exit 1; }
# Anchored: a row that merely *contains* src/Calc.php passes even when the whole
# absolute path is printed, which is how the symlinked-tmpdir bug hid.
echo "$OUT" | grep -qE "^src/Calc\.php:[0-9]+ " || { echo "FAIL: survivor path not relativised to the repo root"; exit 1; }
echo "$OUT" | grep -q "id=.*@src/Calc.php" || { echo "FAIL: mutant id not repo-relative"; exit 1; }

echo "--- phase 2: asserting the actual values kills them ---"
python3 - <<'PY'
import pathlib
p = pathlib.Path('tests/CalcTest.php')
s = p.read_text().replace("""        $this->assertIsString($c->label(50));""", """        $this->assertSame('big', $c->label(50));
        $this->assertSame('small', $c->label(10));
        $this->assertSame('small', $c->label(0));""")
p.write_text(s)
PY
git add tests/CalcTest.php
commit -m "test: assert label's actual values"
run
echo "$OUT"
[ "$RC" -eq 0 ] || { echo "FAIL: expected exit 0, got $RC"; exit 1; }
echo "$OUT" | grep -q "SURVIVED" && { echo "FAIL: survivors remain after precise assertions"; exit 1; }
echo "$OUT" | grep -q "all mutants on changed lines were killed" || { echo "FAIL: expected the all-killed message"; exit 1; }

echo "--- phase 3: no merged config left in the repo ---"
ls -1 . | grep -q "infection-gate" && { echo "FAIL: merged config left behind"; exit 1; }

echo "MUTATION PHP LIVE OK"
