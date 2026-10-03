import io
import json

import crap_rows
import scored_ledger

ROW_OK = 'lib/a.py::f                  complexity=3   coverage=100.0%  CRAP=3.0  OK           (new)'
ROW_SOFT = 'lib/a.py::g                  complexity=7   coverage=60.5%   CRAP=14.2 SOFT         (worsened)'
ROW_MAIN = 'main.run                     complexity=9   coverage=n/a    CRAP=n/a    HARD_MAIN    (unchanged)'


def test_parse_rows_reads_each_report_row_and_ignores_everything_else():
    lines = ['== python ==', ROW_OK, '', 'some note', ROW_SOFT, 'COMMIT_OK']
    assert crap_rows.parse_rows(lines) == [
        {'id': 'lib/a.py::f', 'cc': 3.0, 'cov': 100.0, 'crap': 3.0, 'status': 'OK', 'tag': 'new'},
        {'id': 'lib/a.py::g', 'cc': 7.0, 'cov': 60.5, 'crap': 14.2, 'status': 'SOFT',
         'tag': 'worsened'}]


def test_parse_rows_keeps_a_main_function_with_no_coverage_or_crap_as_none():
    assert crap_rows.parse_rows([ROW_MAIN]) == [
        {'id': 'main.run', 'cc': 9.0, 'cov': None, 'crap': None, 'status': 'HARD_MAIN',
         'tag': 'unchanged'}]


def test_record_stores_rows_under_the_tree_and_reads_them_back(tmp_path):
    store = str(tmp_path / 'rows.json')
    rows = crap_rows.parse_rows([ROW_OK])
    crap_rows.record(store, 'tree1', rows)
    assert crap_rows.rows_for_tree(store, 'tree1') == rows
    assert json.loads((tmp_path / 'rows.json').read_text()) == {'tree1': rows}


def test_rows_for_tree_is_none_without_a_store_or_an_entry_and_empty_when_recorded_empty(tmp_path):
    store = str(tmp_path / 'rows.json')
    assert crap_rows.rows_for_tree(store, 'tree1') is None
    crap_rows.record(store, 'tree2', [])
    assert crap_rows.rows_for_tree(store, 'tree1') is None
    assert crap_rows.rows_for_tree(store, 'tree2') == []


def test_a_later_run_replaces_the_rows_of_the_same_tree(tmp_path):
    store = str(tmp_path / 'rows.json')
    crap_rows.record(store, 'tree1', crap_rows.parse_rows([ROW_SOFT]))
    crap_rows.record(store, 'tree1', crap_rows.parse_rows([ROW_OK]))
    assert [r['id'] for r in crap_rows.rows_for_tree(store, 'tree1')] == ['lib/a.py::f']


def test_an_empty_report_never_replaces_recorded_rows(tmp_path):
    store = str(tmp_path / 'rows.json')
    rows = crap_rows.parse_rows([ROW_OK])
    crap_rows.record(store, 'tree1', rows)
    crap_rows.record(store, 'tree1', [])
    assert crap_rows.rows_for_tree(store, 'tree1') == rows


def test_record_keeps_the_other_trees(tmp_path):
    store = str(tmp_path / 'rows.json')
    crap_rows.record(store, 'tree1', crap_rows.parse_rows([ROW_OK]))
    crap_rows.record(store, 'tree2', crap_rows.parse_rows([ROW_SOFT]))
    assert sorted(scored_ledger.load(store)) == ['tree1', 'tree2']


def test_main_records_the_rows_on_stdin(tmp_path, monkeypatch):
    store = str(tmp_path / 'rows.json')
    monkeypatch.setattr('sys.stdin', io.StringIO(f'== python ==\n{ROW_OK}\n'))
    assert crap_rows.main(['record', store, '--tree', 'abc123']) == 0
    assert crap_rows.rows_for_tree(store, 'abc123') == crap_rows.parse_rows([ROW_OK])


def test_main_records_an_empty_report_when_stdin_has_no_rows(tmp_path, monkeypatch):
    store = str(tmp_path / 'rows.json')
    monkeypatch.setattr('sys.stdin', io.StringIO(''))
    assert crap_rows.main(['record', store, '--tree', 'abc123']) == 0
    assert crap_rows.rows_for_tree(store, 'abc123') == []


def test_main_refuses_a_call_with_no_tree(tmp_path, monkeypatch):
    monkeypatch.setattr('sys.stdin', io.StringIO(''))
    try:
        crap_rows.main(['record', str(tmp_path / 'rows.json')])
        assert False, 'expected SystemExit'
    except SystemExit as exc:
        assert exc.code == 2


def test_record_takes_the_lock_that_belongs_to_the_store(tmp_path):
    store = str(tmp_path / 'rows.json')
    crap_rows.record(store, 'tree1', [])
    assert (tmp_path / 'rows.json.lock').exists()


def test_main_names_itself_and_its_arguments_in_the_usage_line(tmp_path, capsys):
    try:
        crap_rows.main([])
        assert False, 'expected SystemExit'
    except SystemExit as exc:
        assert exc.code == 2
    err = capsys.readouterr().err
    assert err.startswith('usage: crap_rows.py [-h] --tree TREE {record} store\n')
    assert 'the following arguments are required: command, store, --tree' in err


def test_main_refuses_a_command_other_than_record(tmp_path, capsys):
    try:
        crap_rows.main(['forget', str(tmp_path / 'rows.json'), '--tree', 't'])
        assert False, 'expected SystemExit'
    except SystemExit as exc:
        assert exc.code == 2
    assert "invalid choice: 'forget' (choose from" in capsys.readouterr().err
