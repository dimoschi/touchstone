#!/usr/bin/env python3
"""Parse a PHPUnit Clover XML file and emit per-method CRAP rows.

Reads:
  argv[1]                 - path to clover.xml
  env CRAP_CHANGED_FILES  - newline-separated repo-relative paths to filter on
  env CRAP_REPO_ROOT      - repo root, used to resolve absolute file= attrs

Emits to stdout, tab-separated, one method per line:
  <id>\t<complexity>\t<coverage_pct>\t<crap>

Where <id> is "<relpath>::<className>::<methodName>" and <coverage_pct> is
the fraction of executable statement lines inside the method body that were
hit at least once. CRAP is taken directly from PHPUnit's Clover output.
"""

import os
import sys
import xml.etree.ElementTree as ET


def main() -> int:
    xml_path = sys.argv[1]
    repo_root = os.path.abspath(os.environ.get("CRAP_REPO_ROOT", os.getcwd()))
    changed = {
        os.path.normpath(p)
        for p in os.environ.get("CRAP_CHANGED_FILES", "").splitlines()
        if p.strip()
    }
    if not changed:
        return 0

    try:
        tree = ET.parse(xml_path)
    except ET.ParseError:
        return 0
    root = tree.getroot()

    for file_el in root.iter("file"):
        abs_path = file_el.get("name") or ""
        try:
            rel = os.path.normpath(os.path.relpath(abs_path, repo_root))
        except ValueError:
            continue
        if rel not in changed:
            continue

        # Index lines by num for slicing into per-method ranges.
        lines = []
        for ln in file_el.findall("line"):
            try:
                num = int(ln.get("num", "0"))
            except ValueError:
                continue
            lines.append((num, ln))
        lines.sort(key=lambda t: t[0])

        # Method boundaries: each method runs from its line to one before the next method line.
        method_indices = [i for i, (_, ln) in enumerate(lines) if ln.get("type") == "method"]
        method_indices.append(len(lines))

        class_for_line = build_class_map(file_el, lines)

        for k in range(len(method_indices) - 1):
            start = method_indices[k]
            end = method_indices[k + 1]
            m_num, m_ln = lines[start]
            name = m_ln.get("name") or "<anon>"
            cc = m_ln.get("complexity") or "0"
            crap = m_ln.get("crap") or "n/a"

            covered = total = 0
            for _, ln in lines[start + 1 : end]:
                if ln.get("type") != "stmt":
                    continue
                total += 1
                try:
                    if int(ln.get("count", "0")) > 0:
                        covered += 1
                except ValueError:
                    pass

            if total == 0:
                try:
                    if int(m_ln.get("count", "0")) > 0:
                        cov_pct = "100.0"
                    else:
                        cov_pct = "0.0"
                except ValueError:
                    cov_pct = "n/a"
            else:
                cov_pct = f"{(covered / total) * 100:.1f}"

            klass = class_for_line.get(m_num, "<global>")
            ident = f"{rel}::{klass}::{name}"
            print(f"{ident}\t{cc}\t{cov_pct}\t{crap}")

    return 0


def build_class_map(file_el, lines):
    """Return {line_num: ClassName} for every method-line in the file.

    Clover lists <class> children with their own line ranges via the
    accompanying <metrics> on the class is not consistent across PHPUnit
    versions, so we approximate: assign each method line to the most recent
    class whose start_line attribute is <= the method's line. If <class>
    has no start_line attribute, fall back to namespace-qualified name from
    the single class in the file (typical for one-class-per-file PHP).
    """
    classes = []
    for cls in file_el.findall("class"):
        ns = cls.get("namespace") or ""
        name = cls.get("name") or "<anon>"
        full = f"{ns}\\{name}" if ns else name
        start = cls.get("start") or cls.get("line")
        try:
            start_num = int(start) if start else None
        except ValueError:
            start_num = None
        classes.append((start_num, full))

    method_lines = [num for num, ln in lines if ln.get("type") == "method"]

    if not classes:
        return {n: "<global>" for n in method_lines}

    if len(classes) == 1 or all(s is None for s, _ in classes):
        only = classes[0][1]
        return {n: only for n in method_lines}

    classes_sorted = sorted(classes, key=lambda t: (t[0] is None, t[0] or 0))
    result = {}
    for n in method_lines:
        chosen = classes_sorted[0][1]
        for start, full in classes_sorted:
            if start is None:
                continue
            if start <= n:
                chosen = full
            else:
                break
        result[n] = chosen
    return result


if __name__ == "__main__":
    sys.exit(main())
