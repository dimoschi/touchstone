# Signal B: PHP Procedure

Run this from the repo root after staging your changes (`git add ...`).

## Setup

The PHP module needs:

1. **Composer-managed PHPUnit.** Run `composer install` so `vendor/bin/phpunit` exists. Most Laravel and Symfony projects already have it as a dev dependency.
2. **A coverage driver.** PCOV (fast) or Xdebug. Check with `php -m | grep -iE 'pcov|xdebug'`. On mise-managed PHP, you typically install the extension once and reference it from `~/.config/mise/php/conf.d/*.ini`.
3. **Python 3** on PATH (used by the parser in `lib/parse_clover.py`).

If `vendor/bin/phpunit` is missing the helper prints a remediation hint.

## Recommended: Use the Helper

```bash
crap-check.sh
# or, to target a repo other than the process cwd (e.g. a worktree):
crap-check.sh <absolute-repo-path>
```

Every run prints the repo root and branch it resolved as its first line of
output. With no leading path it resolves from the cwd, exactly as before; a
leading path that is not a git repository refuses with exit 2 rather than
falling back to the cwd.

The dispatcher detects staged `.php` files (excluding `tests/`, `**/Tests/`, and `**/*Test.php`) and invokes `lib/crap-check-php.sh`. That module:

1. Stashes any other working-tree changes.
2. Runs PHPUnit with `--coverage-clover` against HEAD to capture a baseline.
3. Restores your working tree.
4. Runs PHPUnit again against the staged changes.
5. Parses both Clover XMLs (PHPUnit already emits per-method `complexity` and `crap`), joins by `<file>::<class>::<method>`, classifies with the same thresholds Go uses, and prints one row per changed method:

   ```
   <file>::<Class>::<method>  complexity=<c>  coverage=<cov>%  CRAP=<score>  [OK|SOFT|HARD|NEEDS_TESTS]  (new|unchanged|worsened)
   ```

Apply the Decision Policy in `SKILL.md` to the output. The PHP module emits the same status tokens as Go; only `OK_MAIN`/`HARD_MAIN` don't apply (PHP has no `package main` analogue).

## Performance

The configured PHPUnit suite runs **twice** (baseline + current). On a large Laravel app this can be slow. Scope the suite via:

```bash
PHPUNIT_ARGS="--testsuite=Unit" crap-check.sh
```

Other useful scopings: `--filter=ClassNameOrPattern`, `--group=somegroup`, or pointing at a specific test directory.

If `vendor/bin/phpunit` isn't where the helper looks, override with `PHPUNIT_BIN=path/to/phpunit`.

## Manual Equivalent (if the helper is unavailable)

1. Identify changed PHP files:
   ```bash
   git diff --name-only --cached -- '*.php' ':(exclude)tests/**' ':(exclude)**/*Test.php'
   ```
2. Capture a current Clover report:
   ```bash
   vendor/bin/phpunit --coverage-clover=cur.xml [--testsuite=Unit]
   ```
3. Stash, repeat against HEAD into `base.xml`, then unstash.
4. Parse both reports and compare per method. Apply thresholds: ≤6 OK, (6, 8] SOFT, >8 HARD. If coverage <80% and the method is new or worsened, the status is `NEEDS_TESTS` — add tests first, do not refactor.

The helper exists to keep the stash dance and the per-method join out of your hands.

## Caveats and known gaps (prototype)

- A changed file that is **never exercised by any test** produces no Clover data at all: PHPUnit's Clover writer omits a `<file>` element entirely for a file it never loaded. In the current phase that is could-not-measure: the run exits 4 and names the file rather than reporting a false `coverage=0.0%`, same as Python's blind spot for a file no test imports. Mitigation: at least run the `Unit` suite so all unit-tested code paths fire; if a changed class genuinely has no test, write one (the skill's TDD-first rule already requires this).
- **Free functions** (PHP code outside a class) won't appear in PHPUnit's Clover writer. Framework code is almost always class-based, so this is rarely an issue; if your project does use free functions, they go unscored rather than scored as zero.
- The class-vs-method line mapping uses a simple "most recent `<class>` whose start line ≤ method line" heuristic. For files with multiple classes and no `start`/`line` attribute on `<class>`, all methods get attributed to the first class. Real-world Laravel code is one-class-per-file, so this is fine in practice.
- **A whole phase that produces no Clover report is a warning, not a hard failure, only in the baseline phase.** There every changed file reads as unmeasured, and every method tags `new` against an empty baseline rather than compared to HEAD. The current phase has no baseline to fall back to: every changed file goes through the same could-not-measure path as the "never exercised by any test" caveat above and exits 4, whether the whole suite failed to produce a report or only one file was absent from an otherwise-present one -- it is one mechanism, not two. When gitignored PHP files are present the baseline warning names them: `git stash --include-untracked` does not stash ignored files, so they survive from the current tree into the baseline.

## Signal C: the mutation gate needs an infection config

The PHP mutation module (`lib/mutation-check-php.sh`) requires the repo to carry an
infection config, and refuses with exit 2 if there is none. Minimum viable:

```json
{ "source": { "directories": ["src"] } }
```

Use `app` for Laravel. Commit it: which directories hold source, and which are
excluded, is a project decision, and a gate that guesses will measure the wrong
thing in the next repo. The gate copies that config with a `logs.json` logger
injected, because **infection 0.34 has no `--logger-json` flag** and exposes the
per-mutant report only as a config key. It writes the copy beside the original,
since infection resolves every relative path in a config against that config's own
directory, and deletes it afterwards.

If the repo has an `infection.json5`, provide an `infection.json` as well or point
`MUTATION_PHP_CONFIG` at one: JSON5 (comments, trailing commas) cannot be parsed
here, and the gate refuses rather than mangling settings silently.

`MUTATION_PHP_THREADS` bounds parallel mutants, defaulting to cores/4 like the Go
module. Raise it on a machine that can take it; lower it to 1 if the suite contends
on a shared database.

**Toolchain.** `php -v` failing does not mean PHP is missing: it comes from mise and
needs no global version set, so look in `~/.local/share/mise/installs/php/` first.
Those builds already carry pcov, which is the coverage driver infection needs. There
is no composer or phpunit here, so `MUTATION_PHP_INFECTION` wants a php-prefixed
invocation and phpunit wants a phar:

```
MUTATION_PHP_INFECTION="$HOME/.local/share/mise/installs/php/8.4.18/bin/php $HOME/.local/bin/infection"
```

`test/run-mutation-php-live.sh` runs the whole thing against the real binary and
skips cleanly when any of php, infection or phpunit is absent.
