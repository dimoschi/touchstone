import os
import xml.etree.ElementTree as ET

import parse_clover


def _file_el(*, classes=(), lines=()):
    """classes: [(name, namespace, start_attr, start_value)]
    lines: [(num, type, extra_attrs_dict)]
    """
    el = ET.Element("file")
    for name, ns, start_attr, start_value in classes:
        attrs = {"name": name}
        if ns is not None:
            attrs["namespace"] = ns
        if start_attr is not None:
            attrs[start_attr] = start_value
        ET.SubElement(el, "class", attrs)
    for num, typ, extra in lines:
        attrs = {"num": str(num), "type": typ}
        attrs.update(extra)
        ET.SubElement(el, "line", attrs)
    return el


def test_build_class_map_no_classes_returns_global():
    el = _file_el(lines=[(3, "method", {"name": "m"})])
    lines = [(3, el.find("line"))]
    assert parse_clover.build_class_map(el, lines) == {3: "<global>"}


def test_build_class_map_single_class_used_for_every_method():
    el = _file_el(classes=[("Foo", "App", "start", "1")],
                   lines=[(3, "method", {}), (10, "method", {})])
    lines = [(ln.get("num") and int(ln.get("num")), ln) for ln in el.findall("line")]
    result = parse_clover.build_class_map(el, lines)
    assert result == {3: "App\\Foo", 10: "App\\Foo"}


def test_build_class_map_name_already_namespace_qualified():
    el = _file_el(classes=[("App\\Foo", "App", "start", "1")], lines=[(3, "method", {})])
    lines = [(3, el.find("line"))]
    assert parse_clover.build_class_map(el, lines) == {3: "App\\Foo"}


def test_build_class_map_no_namespace_uses_bare_name():
    el = _file_el(classes=[("Foo", None, "start", "1")], lines=[(3, "method", {})])
    lines = [(3, el.find("line"))]
    assert parse_clover.build_class_map(el, lines) == {3: "Foo"}


def test_build_class_map_falls_back_to_line_attr():
    el = _file_el(classes=[("Foo", "App", "line", "1")], lines=[(3, "method", {})])
    lines = [(3, el.find("line"))]
    assert parse_clover.build_class_map(el, lines) == {3: "App\\Foo"}


def test_build_class_map_invalid_start_is_none():
    el = _file_el(classes=[("Foo", "App", "start", "not-a-number")], lines=[(3, "method", {})])
    lines = [(3, el.find("line"))]
    assert parse_clover.build_class_map(el, lines) == {3: "App\\Foo"}


def test_build_class_map_all_none_starts_uses_first_class():
    el = ET.Element("file")
    ET.SubElement(el, "class", {"name": "First", "namespace": "App"})
    ET.SubElement(el, "class", {"name": "Second", "namespace": "App"})
    line = ET.SubElement(el, "line", {"num": "3", "type": "method"})
    assert parse_clover.build_class_map(el, [(3, line)]) == {3: "App\\First"}


def test_build_class_map_picks_nearest_preceding_class_start():
    el = ET.Element("file")
    ET.SubElement(el, "class", {"name": "First", "namespace": "App", "start": "1"})
    ET.SubElement(el, "class", {"name": "Second", "namespace": "App", "start": "10"})
    line_a = ET.SubElement(el, "line", {"num": "5", "type": "method"})
    line_b = ET.SubElement(el, "line", {"num": "12", "type": "method"})
    result = parse_clover.build_class_map(el, [(5, line_a), (12, line_b)])
    assert result == {5: "App\\First", 12: "App\\Second"}


def _clover_doc(abs_path, class_attrs, lines_xml):
    return f'''<coverage>
  <project>
    <file name="{abs_path}">
      <class {class_attrs}/>
      {lines_xml}
    </file>
  </project>
</coverage>'''


def test_main_returns_early_when_nothing_changed(monkeypatch, tmp_path):
    xml_path = tmp_path / "clover.xml"
    xml_path.write_text("<coverage/>")
    monkeypatch.delenv("CRAP_CHANGED_FILES", raising=False)
    monkeypatch.setattr("sys.argv", ["parse_clover.py", str(xml_path)])
    assert parse_clover.main() == 0


def test_main_returns_zero_on_parse_error(monkeypatch, tmp_path):
    xml_path = tmp_path / "clover.xml"
    xml_path.write_text("not xml at all <<<")
    monkeypatch.setenv("CRAP_CHANGED_FILES", "src/Foo.php")
    monkeypatch.setattr("sys.argv", ["parse_clover.py", str(xml_path)])
    assert parse_clover.main() == 0


def test_main_changed_file_absent_from_clover_report_produces_no_rows(monkeypatch, tmp_path, capsys):
    # No row is built for a file Clover never mentions -- there is nothing to
    # join against -- but --unmeasured-out still names it, which is what lets
    # crap-check-php.sh refuse (exit 4) instead of reading this as a clean,
    # COMMIT_OK pass on a file that was never measured at all.
    repo_root = tmp_path / "repo"
    (repo_root / "src").mkdir(parents=True)
    abs_other = str(repo_root / "src" / "Bar.php")
    doc = f'''<coverage>
  <project>
    <file name="{abs_other}">
      <class name="Bar" namespace="App" start="1"/>
      <line num="1" type="method" name="baz" complexity="1" crap="1.0"/>
    </file>
  </project>
</coverage>'''
    xml_path = tmp_path / "clover.xml"
    xml_path.write_text(doc)
    out_path = tmp_path / "unmeasured.txt"
    monkeypatch.setenv("CRAP_REPO_ROOT", str(repo_root))
    monkeypatch.setenv("CRAP_CHANGED_FILES", "src/Foo.php")
    monkeypatch.setattr(
        "sys.argv", ["parse_clover.py", str(xml_path), "--unmeasured-out", str(out_path)]
    )
    assert parse_clover.main() == 0
    assert capsys.readouterr().out == ""
    assert out_path.read_text() == "src/Foo.php\n"


def test_main_writes_nothing_to_unmeasured_out_when_changed_file_is_present(monkeypatch, tmp_path, capsys):
    repo_root = tmp_path / "repo"
    repo_root.mkdir()
    abs_changed = str(repo_root / "Foo.php")
    doc = f'''<coverage>
  <project>
    <file name="{abs_changed}">
      <class name="Foo" namespace="" start="1"/>
      <line num="1" type="method" name="bar" count="1"/>
    </file>
  </project>
</coverage>'''
    xml_path = tmp_path / "clover.xml"
    xml_path.write_text(doc)
    out_path = tmp_path / "unmeasured.txt"
    monkeypatch.setenv("CRAP_REPO_ROOT", str(repo_root))
    monkeypatch.setenv("CRAP_CHANGED_FILES", "Foo.php")
    monkeypatch.setattr(
        "sys.argv", ["parse_clover.py", str(xml_path), "--unmeasured-out", str(out_path)]
    )
    assert parse_clover.main() == 0
    assert out_path.read_text() == ""


def test_main_parse_error_marks_every_changed_file_unmeasured(monkeypatch, tmp_path, capsys):
    xml_path = tmp_path / "clover.xml"
    xml_path.write_text("not xml at all <<<")
    out_path = tmp_path / "unmeasured.txt"
    monkeypatch.setenv("CRAP_CHANGED_FILES", "src/Foo.php\nsrc/Bar.php")
    monkeypatch.setattr(
        "sys.argv", ["parse_clover.py", str(xml_path), "--unmeasured-out", str(out_path)]
    )
    assert parse_clover.main() == 0
    assert capsys.readouterr().out == ""
    assert out_path.read_text() == "src/Bar.php\nsrc/Foo.php\n"


def test_main_without_crap_changed_files_set_writes_no_unmeasured_file(monkeypatch, tmp_path):
    xml_path = tmp_path / "clover.xml"
    xml_path.write_text("<coverage/>")
    out_path = tmp_path / "unmeasured.txt"
    monkeypatch.delenv("CRAP_CHANGED_FILES", raising=False)
    monkeypatch.setattr(
        "sys.argv", ["parse_clover.py", str(xml_path), "--unmeasured-out", str(out_path)]
    )
    assert parse_clover.main() == 0
    # Nothing was asked about, so the caller must not be handed an unmeasured
    # list at all -- an invented entry there is what makes crap-check-php.sh
    # refuse with exit 4.
    assert not out_path.exists()


def test_main_reads_only_file_elements_as_files(monkeypatch, tmp_path, capsys):
    # A <class name=...> is a class name, not a path. Treating one as a file
    # would let a class that happens to be named like a changed path mark that
    # path measured, hiding the very refusal --unmeasured-out exists for.
    repo_root = tmp_path / "repo"
    (repo_root / "src").mkdir(parents=True)
    abs_foo = str(repo_root / "src" / "Foo.php")
    abs_bar = str(repo_root / "src" / "Bar.php")
    doc = f'''<coverage>
  <project>
    <file name="{abs_bar}">
      <class name="{abs_foo}" namespace=""/>
      <line num="1" type="method" name="baz" count="1"/>
    </file>
  </project>
</coverage>'''
    xml_path = tmp_path / "clover.xml"
    xml_path.write_text(doc)
    out_path = tmp_path / "unmeasured.txt"
    monkeypatch.setenv("CRAP_REPO_ROOT", str(repo_root))
    monkeypatch.setenv("CRAP_CHANGED_FILES", "src/Foo.php")
    monkeypatch.setattr(
        "sys.argv", ["parse_clover.py", str(xml_path), "--unmeasured-out", str(out_path)]
    )
    assert parse_clover.main() == 0
    assert capsys.readouterr().out == ""
    assert out_path.read_text() == "src/Foo.php\n"


def test_main_file_without_a_name_is_resolved_from_the_empty_string_and_skipped(monkeypatch, tmp_path, capsys):
    # "" is what makes an unnamed <file> unresolvable (relpath refuses it), so
    # it is skipped instead of being joined into some path under the repo root.
    # The files after it are still read.
    repo_root = tmp_path / "repo"
    repo_root.mkdir()
    abs_changed = str(repo_root / "Foo.php")
    doc = f'''<coverage>
  <project>
    <file>
      <line num="1" type="method" name="ghost" count="1"/>
    </file>
    <file name="{abs_changed}">
      <class name="Foo" namespace="" start="1"/>
      <line num="1" type="method" name="bar" count="1"/>
    </file>
  </project>
</coverage>'''
    xml_path = tmp_path / "clover.xml"
    xml_path.write_text(doc)
    monkeypatch.setenv("CRAP_REPO_ROOT", str(repo_root))
    monkeypatch.setenv("CRAP_CHANGED_FILES", "Foo.php")
    monkeypatch.setattr("sys.argv", ["parse_clover.py", str(xml_path)])

    seen = []
    real_relpath = os.path.relpath

    def spy(path, start):
        seen.append(path)
        return real_relpath(path, start)

    monkeypatch.setattr(parse_clover.os.path, "relpath", spy)
    assert parse_clover.main() == 0
    assert seen[0] == ""
    assert capsys.readouterr().out == "Foo.php::Foo::bar\t0\t100.0\tn/a\n"


def test_main_keeps_reading_files_after_an_unchanged_one(monkeypatch, tmp_path, capsys):
    repo_root = tmp_path / "repo"
    (repo_root / "src").mkdir(parents=True)
    abs_changed = str(repo_root / "src" / "Foo.php")
    abs_other = str(repo_root / "src" / "Bar.php")
    doc = f'''<coverage>
  <project>
    <file name="{abs_other}">
      <class name="Bar" namespace="App" start="1"/>
      <line num="1" type="method" name="baz" complexity="1" crap="1.0" count="1"/>
    </file>
    <file name="{abs_changed}">
      <class name="Foo" namespace="App" start="1"/>
      <line num="1" type="method" name="bar" complexity="2" crap="2.1" count="1"/>
    </file>
  </project>
</coverage>'''
    xml_path = tmp_path / "clover.xml"
    xml_path.write_text(doc)
    monkeypatch.setenv("CRAP_REPO_ROOT", str(repo_root))
    monkeypatch.setenv("CRAP_CHANGED_FILES", "src/Foo.php")
    monkeypatch.setattr("sys.argv", ["parse_clover.py", str(xml_path)])
    assert parse_clover.main() == 0
    assert capsys.readouterr().out == "src/Foo.php::App\\Foo::bar\t2\t100.0\t2.1\n"


def test_main_line_without_a_num_is_treated_as_line_zero(monkeypatch, tmp_path, capsys):
    # Missing num defaults to 0, which sorts the line ahead of every numbered
    # one; two of them keep their document order, which only holds while the
    # sort keys on the number alone.
    repo_root = tmp_path / "repo"
    repo_root.mkdir()
    abs_changed = str(repo_root / "Foo.php")
    doc = f'''<coverage>
  <project>
    <file name="{abs_changed}">
      <class name="Foo" namespace="" start="1"/>
      <line num="1" type="method" name="bar" count="1"/>
      <line type="method" name="ghostA" count="1"/>
      <line type="method" name="ghostB" count="1"/>
    </file>
  </project>
</coverage>'''
    xml_path = tmp_path / "clover.xml"
    xml_path.write_text(doc)
    monkeypatch.setenv("CRAP_REPO_ROOT", str(repo_root))
    monkeypatch.setenv("CRAP_CHANGED_FILES", "Foo.php")
    monkeypatch.setattr("sys.argv", ["parse_clover.py", str(xml_path)])
    assert parse_clover.main() == 0
    assert capsys.readouterr().out == (
        "Foo.php::Foo::ghostA\t0\t100.0\tn/a\n"
        "Foo.php::Foo::ghostB\t0\t100.0\tn/a\n"
        "Foo.php::Foo::bar\t0\t100.0\tn/a\n"
    )


def test_main_keeps_reading_lines_after_a_non_numeric_num(monkeypatch, tmp_path, capsys):
    repo_root = tmp_path / "repo"
    repo_root.mkdir()
    abs_changed = str(repo_root / "Foo.php")
    doc = f'''<coverage>
  <project>
    <file name="{abs_changed}">
      <class name="Foo" namespace="" start="1"/>
      <line num="not-a-number" type="stmt" count="1"/>
      <line num="1" type="method" name="bar" count="1"/>
    </file>
  </project>
</coverage>'''
    xml_path = tmp_path / "clover.xml"
    xml_path.write_text(doc)
    monkeypatch.setenv("CRAP_REPO_ROOT", str(repo_root))
    monkeypatch.setenv("CRAP_CHANGED_FILES", "Foo.php")
    monkeypatch.setattr("sys.argv", ["parse_clover.py", str(xml_path)])
    assert parse_clover.main() == 0
    assert capsys.readouterr().out == "Foo.php::Foo::bar\t0\t100.0\tn/a\n"


def test_main_method_body_ends_at_the_next_method(monkeypatch, tmp_path, capsys):
    repo_root = tmp_path / "repo"
    repo_root.mkdir()
    abs_changed = str(repo_root / "Foo.php")
    doc = f'''<coverage>
  <project>
    <file name="{abs_changed}">
      <class name="Foo" namespace="" start="1"/>
      <line num="1" type="method" name="first" complexity="2" crap="2.0"/>
      <line num="2" type="stmt" count="1"/>
      <line num="5" type="method" name="second" complexity="3" crap="9.0"/>
      <line num="6" type="stmt" count="0"/>
    </file>
  </project>
</coverage>'''
    xml_path = tmp_path / "clover.xml"
    xml_path.write_text(doc)
    monkeypatch.setenv("CRAP_REPO_ROOT", str(repo_root))
    monkeypatch.setenv("CRAP_CHANGED_FILES", "Foo.php")
    monkeypatch.setattr("sys.argv", ["parse_clover.py", str(xml_path)])
    assert parse_clover.main() == 0
    assert capsys.readouterr().out == (
        "Foo.php::Foo::first\t2\t100.0\t2.0\n"
        "Foo.php::Foo::second\t3\t0.0\t9.0\n"
    )


def test_main_counts_every_covered_statement(monkeypatch, tmp_path, capsys):
    repo_root = tmp_path / "repo"
    repo_root.mkdir()
    abs_changed = str(repo_root / "Foo.php")
    doc = f'''<coverage>
  <project>
    <file name="{abs_changed}">
      <class name="Foo" namespace="" start="1"/>
      <line num="1" type="method" name="bar" complexity="1" crap="1.0"/>
      <line num="2" type="stmt" count="1"/>
      <line num="3" type="stmt" count="1"/>
      <line num="4" type="stmt" count="0"/>
    </file>
  </project>
</coverage>'''
    xml_path = tmp_path / "clover.xml"
    xml_path.write_text(doc)
    monkeypatch.setenv("CRAP_REPO_ROOT", str(repo_root))
    monkeypatch.setenv("CRAP_CHANGED_FILES", "Foo.php")
    monkeypatch.setattr("sys.argv", ["parse_clover.py", str(xml_path)])
    assert parse_clover.main() == 0
    assert capsys.readouterr().out == "Foo.php::Foo::bar\t1\t66.7\t1.0\n"


def test_main_statement_without_a_count_is_uncovered(monkeypatch, tmp_path, capsys):
    repo_root = tmp_path / "repo"
    repo_root.mkdir()
    abs_changed = str(repo_root / "Foo.php")
    doc = f'''<coverage>
  <project>
    <file name="{abs_changed}">
      <class name="Foo" namespace="" start="1"/>
      <line num="1" type="method" name="bar" count="1"/>
      <line num="2" type="stmt"/>
    </file>
  </project>
</coverage>'''
    xml_path = tmp_path / "clover.xml"
    xml_path.write_text(doc)
    monkeypatch.setenv("CRAP_REPO_ROOT", str(repo_root))
    monkeypatch.setenv("CRAP_CHANGED_FILES", "Foo.php")
    monkeypatch.setattr("sys.argv", ["parse_clover.py", str(xml_path)])
    assert parse_clover.main() == 0
    assert capsys.readouterr().out == "Foo.php::Foo::bar\t0\t0.0\tn/a\n"


def test_main_method_without_a_count_and_no_statements_is_zero_not_unknown(monkeypatch, tmp_path, capsys):
    repo_root = tmp_path / "repo"
    repo_root.mkdir()
    abs_changed = str(repo_root / "Foo.php")
    doc = f'''<coverage>
  <project>
    <file name="{abs_changed}">
      <class name="Foo" namespace="" start="1"/>
      <line num="1" type="method" name="bar"/>
    </file>
  </project>
</coverage>'''
    xml_path = tmp_path / "clover.xml"
    xml_path.write_text(doc)
    monkeypatch.setenv("CRAP_REPO_ROOT", str(repo_root))
    monkeypatch.setenv("CRAP_CHANGED_FILES", "Foo.php")
    monkeypatch.setattr("sys.argv", ["parse_clover.py", str(xml_path)])
    assert parse_clover.main() == 0
    assert capsys.readouterr().out == "Foo.php::Foo::bar\t0\t0.0\tn/a\n"


def test_main_method_without_a_name_is_reported_as_anon(monkeypatch, tmp_path, capsys):
    repo_root = tmp_path / "repo"
    repo_root.mkdir()
    abs_changed = str(repo_root / "Foo.php")
    doc = f'''<coverage>
  <project>
    <file name="{abs_changed}">
      <class name="Foo" namespace="" start="1"/>
      <line num="1" type="method" count="1"/>
    </file>
  </project>
</coverage>'''
    xml_path = tmp_path / "clover.xml"
    xml_path.write_text(doc)
    monkeypatch.setenv("CRAP_REPO_ROOT", str(repo_root))
    monkeypatch.setenv("CRAP_CHANGED_FILES", "Foo.php")
    monkeypatch.setattr("sys.argv", ["parse_clover.py", str(xml_path)])
    assert parse_clover.main() == 0
    assert capsys.readouterr().out == "Foo.php::Foo::<anon>\t0\t100.0\tn/a\n"


def test_main_skips_unchanged_and_unresolvable_files(monkeypatch, tmp_path, capsys):
    repo_root = tmp_path / "repo"
    (repo_root / "src").mkdir(parents=True)
    abs_changed = str(repo_root / "src" / "Foo.php")
    abs_other = str(repo_root / "src" / "Bar.php")
    doc = f'''<coverage>
  <project>
    <file name="{abs_changed}">
      <class name="Foo" namespace="App" start="1"/>
      <line num="1" type="method" name="bar" complexity="2" crap="2.1"/>
      <line num="2" type="stmt" count="1"/>
      <line num="3" type="stmt" count="0"/>
    </file>
    <file name="{abs_other}">
      <class name="Bar" namespace="App" start="1"/>
      <line num="1" type="method" name="baz" complexity="1" crap="1.0"/>
    </file>
  </project>
</coverage>'''
    xml_path = tmp_path / "clover.xml"
    xml_path.write_text(doc)
    monkeypatch.setenv("CRAP_REPO_ROOT", str(repo_root))
    monkeypatch.setenv("CRAP_CHANGED_FILES", "src/Foo.php")
    monkeypatch.setattr("sys.argv", ["parse_clover.py", str(xml_path)])
    assert parse_clover.main() == 0
    out = capsys.readouterr().out
    assert "src/Foo.php::App\\Foo::bar\t2\t50.0\t2.1\n" == out


def test_main_method_with_no_statements_uses_method_line_count(monkeypatch, tmp_path, capsys):
    repo_root = tmp_path / "repo"
    repo_root.mkdir()
    abs_changed = str(repo_root / "Foo.php")
    doc = f'''<coverage>
  <project>
    <file name="{abs_changed}">
      <class name="Foo" namespace="" start="1"/>
      <line num="1" type="method" name="hitOnce" count="1"/>
      <line num="5" type="method" name="neverHit" count="0"/>
    </file>
  </project>
</coverage>'''
    xml_path = tmp_path / "clover.xml"
    xml_path.write_text(doc)
    monkeypatch.setenv("CRAP_REPO_ROOT", str(repo_root))
    monkeypatch.setenv("CRAP_CHANGED_FILES", "Foo.php")
    monkeypatch.setattr("sys.argv", ["parse_clover.py", str(xml_path)])
    assert parse_clover.main() == 0
    out = capsys.readouterr().out.splitlines()
    assert out[0] == "Foo.php::Foo::hitOnce\t0\t100.0\tn/a"
    assert out[1] == "Foo.php::Foo::neverHit\t0\t0.0\tn/a"


def test_main_skips_file_when_relpath_raises_value_error(monkeypatch, tmp_path, capsys):
    doc = '<coverage><project><file name="unresolvable"><line num="1" type="method" name="m"/></file></project></coverage>'
    xml_path = tmp_path / "clover.xml"
    xml_path.write_text(doc)
    monkeypatch.setenv("CRAP_REPO_ROOT", str(tmp_path))
    monkeypatch.setenv("CRAP_CHANGED_FILES", "whatever.php")
    monkeypatch.setattr("sys.argv", ["parse_clover.py", str(xml_path)])

    real_relpath = os.path.relpath

    def boom(path, start):
        if path == "unresolvable":
            raise ValueError("no common drive")
        return real_relpath(path, start)

    monkeypatch.setattr(parse_clover.os.path, "relpath", boom)
    assert parse_clover.main() == 0
    assert capsys.readouterr().out == ""


def test_main_skips_line_with_non_numeric_num(monkeypatch, tmp_path, capsys):
    repo_root = tmp_path / "repo"
    repo_root.mkdir()
    abs_changed = str(repo_root / "Foo.php")
    doc = f'''<coverage>
  <project>
    <file name="{abs_changed}">
      <class name="Foo" namespace="" start="1"/>
      <line num="1" type="method" name="bar" count="1"/>
      <line num="not-a-number" type="stmt" count="1"/>
    </file>
  </project>
</coverage>'''
    xml_path = tmp_path / "clover.xml"
    xml_path.write_text(doc)
    monkeypatch.setenv("CRAP_REPO_ROOT", str(repo_root))
    monkeypatch.setenv("CRAP_CHANGED_FILES", "Foo.php")
    monkeypatch.setattr("sys.argv", ["parse_clover.py", str(xml_path)])
    assert parse_clover.main() == 0
    out = capsys.readouterr().out
    assert out == "Foo.php::Foo::bar\t0\t100.0\tn/a\n"


def test_main_non_stmt_line_inside_method_is_skipped_and_bad_counts_are_ignored(monkeypatch, tmp_path, capsys):
    repo_root = tmp_path / "repo"
    repo_root.mkdir()
    abs_changed = str(repo_root / "Foo.php")
    doc = f'''<coverage>
  <project>
    <file name="{abs_changed}">
      <class name="Foo" namespace="" start="1"/>
      <line num="1" type="method" name="bar" count="not-a-number"/>
      <line num="2" type="stmt" count="not-a-number"/>
      <line num="3" type="condition" count="1"/>
      <line num="4" type="stmt" count="1"/>
    </file>
  </project>
</coverage>'''
    xml_path = tmp_path / "clover.xml"
    xml_path.write_text(doc)
    monkeypatch.setenv("CRAP_REPO_ROOT", str(repo_root))
    monkeypatch.setenv("CRAP_CHANGED_FILES", "Foo.php")
    monkeypatch.setattr("sys.argv", ["parse_clover.py", str(xml_path)])
    assert parse_clover.main() == 0
    out = capsys.readouterr().out
    # 2 stmt lines total (num 2 and 4); num 2's bad count is treated as not-covered,
    # the condition line (num 3) is not a stmt so it does not count either way.
    assert out == "Foo.php::Foo::bar\t0\t50.0\tn/a\n"


def test_main_method_with_no_statements_and_bad_count_is_n_a(monkeypatch, tmp_path, capsys):
    repo_root = tmp_path / "repo"
    repo_root.mkdir()
    abs_changed = str(repo_root / "Foo.php")
    doc = f'''<coverage>
  <project>
    <file name="{abs_changed}">
      <class name="Foo" namespace="" start="1"/>
      <line num="1" type="method" name="bar" count="not-a-number"/>
    </file>
  </project>
</coverage>'''
    xml_path = tmp_path / "clover.xml"
    xml_path.write_text(doc)
    monkeypatch.setenv("CRAP_REPO_ROOT", str(repo_root))
    monkeypatch.setenv("CRAP_CHANGED_FILES", "Foo.php")
    monkeypatch.setattr("sys.argv", ["parse_clover.py", str(xml_path)])
    assert parse_clover.main() == 0
    assert capsys.readouterr().out == "Foo.php::Foo::bar\t0\tn/a\tn/a\n"


def test_build_class_map_mixed_none_and_real_starts_skips_none_entries():
    el = ET.Element("file")
    ET.SubElement(el, "class", {"name": "Unpositioned", "namespace": "App"})
    ET.SubElement(el, "class", {"name": "First", "namespace": "App", "start": "1"})
    ET.SubElement(el, "class", {"name": "Second", "namespace": "App", "start": "10"})
    line_a = ET.SubElement(el, "line", {"num": "5", "type": "method"})
    line_b = ET.SubElement(el, "line", {"num": "12", "type": "method"})
    result = parse_clover.build_class_map(el, [(5, line_a), (12, line_b)])
    assert result == {5: "App\\First", 12: "App\\Second"}
