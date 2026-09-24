"""The gate's thresholds, and the row classification built on them.

Every language module reads its bands from here. They used to live in three awk
programs that were edited separately, so a change to the policy was a three-file
edit and the modules could disagree about what a row meant while all reporting
green.
"""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path
from typing import NamedTuple

MARKER = ".crap-gated"


class Thresholds(NamedTuple):
    soft: float
    hard: float
    main: float
    cognitive: float


DEFAULTS = Thresholds(soft=6.0, hard=8.0, main=5.0, cognitive=15.0)

# The marker's other lines are gitignore-style exemption patterns, so a key added
# here must also be skipped by lib/unsupported-sources.sh or it becomes a pattern.
SETTINGS = {
    "crap-soft": "soft",
    "crap-hard": "hard",
    "main-complexity": "main",
    "cognitive-complexity": "cognitive",
}


def _setting(line):
    """(field, value) for a threshold line, or None for anything else in the marker.

    A commented-out setting needs no special case: '#' stays attached to the key,
    which then matches nothing in SETTINGS.
    """
    key, sep, value = line.partition("=")
    field = SETTINGS.get(key.strip())
    if not sep or field is None:
        return None
    try:
        number = float(value.partition("#")[0].strip())
    except ValueError:
        return None
    # "inf" and "nan" both parse as floats, and an infinite cap makes
    # min_coverage search for a complexity it will never reach.
    return (field, number) if math.isfinite(number) else None


def parse(text):
    """Every threshold setting in a marker's text, keyed by Thresholds field."""
    found = (_setting(line) for line in text.splitlines())
    return dict(setting for setting in found if setting)


def crap(cc, cov):
    """CRAP for one function: complexity^2 * (1 - coverage)^3 + complexity."""
    return cc * cc * (1.0 - cov / 100.0) ** 3 + cc


def implied_coverage(cc, hard):
    """Lowest coverage at which this complexity scores within the hard cap.

    0 where the cap passes the function untested, 100 where no amount of coverage
    brings it under. Clamped rather than branched: a negative ratio raised to a
    fractional power is a complex number in Python, and a ratio above 1 would
    imply a coverage over 100%.
    """
    room = min(max((hard - cc) / float(cc * cc), 0.0), 1.0)
    return 100.0 * (1.0 - room ** (1.0 / 3.0))


def min_coverage(hard):
    """The coverage a new or worsened function owes whatever its complexity.

    CRAP on its own lets a trivial function through at no coverage at all, which
    is the one case it cannot speak about: the score is already under any usable
    cap before coverage is considered. So the requirement is the lowest non-zero
    coverage the cap asks of anything, i.e. what it asks of the smallest
    complexity it will not pass untested. It moves with the cap rather than
    standing beside it as a second number to keep in step.
    """
    cc = 1
    while implied_coverage(cc, hard) == 0:
        cc += 1
    return implied_coverage(cc, hard)


def band(score, th):
    """The band a CRAP score falls in, before coverage is considered."""
    if score <= th.soft:
        return "OK"
    if score <= th.hard:
        return "SOFT"
    return "HARD"


def _undertested(cc, cov, band_name, th):
    """Whether this row's problem is missing tests rather than structure."""
    if cov < min_coverage(th.hard):
        return True
    # Past the floor, the two terms of CRAP say which half is at fault. A score
    # the coverage term dominates is a testing gap, and sending the author to
    # refactor a function that only lacks tests is the wrong instruction.
    return band_name != "OK" and cc * (1.0 - cov / 100.0) ** 3 > 1.0


def classify(cc, score, cov, tag, is_main, th):
    """The status for one measured function.

    Only a function this branch added or worsened can owe tests: one left no
    worse than it was found is judged on its score alone.
    """
    if is_main:
        return "OK_MAIN" if score <= th.main else "HARD_MAIN"
    band_name = band(score, th)
    if cov is None or tag not in ("new", "worsened"):
        return band_name
    return "NEEDS_TESTS" if _undertested(cc, cov, band_name, th) else band_name


def load(repo_root):
    """Thresholds for a repo, falling back to DEFAULTS for anything it omits.

    A marker that cannot be read is not an error: the gate has shipped values for
    every setting, so an unreadable one costs the repo its overrides, not its run.
    """
    try:
        text = (Path(repo_root) / MARKER).read_text()
    except OSError:
        return DEFAULTS
    return DEFAULTS._replace(**parse(text))


def shell_value(value):
    """A setting as the shell should see it: gocognit and complexipy take ints."""
    return str(int(value)) if value == int(value) else str(value)


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--show", required=True,
                        choices=sorted(Thresholds._fields) + ["min-coverage"])
    args = parser.parse_args(argv)
    settings = load(args.repo_root)
    value = (min_coverage(settings.hard) if args.show == "min-coverage"
             else getattr(settings, args.show))
    print(shell_value(value))
    return 0


if __name__ == "__main__":
    sys.exit(main())
