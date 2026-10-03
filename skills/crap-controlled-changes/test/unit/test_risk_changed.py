import warnings

import risk_changed

PY = '''\
import os


def top(a):
    return a


class Box:
    @staticmethod
    def make():
        return Box()

    async def fetch(self):
        def inner():
            return 1
        return inner()


def last():
    return 3
'''


def test_python_ids_name_a_function_or_a_method_the_way_the_gate_does():
    assert risk_changed.python_ids('m.py', PY, {5}) == {'m.py::top'}
    assert risk_changed.python_ids('m.py', PY, {11}) == {'m.py::Box.make'}
    assert risk_changed.python_ids('m.py', PY, {13}) == {'m.py::Box.fetch'}


def test_python_ids_count_a_decorator_and_a_closure_line_as_a_change_to_the_function():
    assert risk_changed.python_ids('m.py', PY, {9}) == {'m.py::Box.make'}
    assert risk_changed.python_ids('m.py', PY, {15}) == {'m.py::Box.fetch'}


def test_python_ids_leave_out_a_line_outside_every_function():
    assert risk_changed.python_ids('m.py', PY, {1, 8, 12, 17}) == set()


def test_python_ids_hold_every_function_a_change_reaches():
    assert risk_changed.python_ids('m.py', PY, {4, 20}) == {'m.py::top', 'm.py::last'}


def test_python_ids_find_a_function_declared_under_a_condition():
    source = 'if True:\n    def maybe():\n        return 1\n'
    assert risk_changed.python_ids('m.py', source, {3}) == {'m.py::maybe'}


def test_python_ids_do_not_turn_a_warning_about_the_analysed_source_into_a_failure():
    source = "def f():\n    return '\\d'\n"
    with warnings.catch_warnings():
        warnings.simplefilter('error')
        assert risk_changed.python_ids('m.py', source, {2}) == {'m.py::f'}


def test_python_ids_of_source_that_does_not_parse_is_empty():
    assert risk_changed.python_ids('m.py', 'def broken(:\n', {1}) == set()


GO = '''\
package calc

import "fmt"

func Double(x int) int {
\treturn x * 2
}

type Box struct{}

func (b *Box) Open() {
\tfmt.Println()
}

func (Box) Close() {}

func Generic[T any](v T) T {
\treturn v
}

func (t Tree[T]) Walk() {
}

func (s *Stack[U]) Push(v U) {
\ts.n++
}

func (p Pair[K, V]) Get() {
\t_ = p
}
'''


def go_ids(line):
    return risk_changed.go_ids('calc.go', GO, {line})


def test_go_ids_name_a_function_by_package_and_a_method_by_its_receiver_type():
    assert go_ids(6) == {'calc.Double'}
    assert go_ids(12) == {'calc.Box.Open'}
    assert go_ids(15) == {'calc.Box.Close'}
    assert go_ids(18) == {'calc.Generic'}


def test_go_ids_keep_the_type_parameter_of_a_generic_receiver_as_written():
    assert go_ids(21) == {'calc.Tree[T].Walk'}
    assert go_ids(25) == {'calc.Stack[U].Push'}


def test_go_ids_leave_out_a_receiver_with_several_type_parameters():
    # go-crap names every such receiver `<unknown>`, so its row may be another method's.
    assert go_ids(29) == set()


def test_go_ids_count_the_signature_line_and_leave_out_a_line_outside_every_function():
    assert risk_changed.go_ids('calc.go', GO, {5}) == {'calc.Double'}
    assert risk_changed.go_ids('calc.go', GO, {1, 3, 9}) == set()


def test_go_ids_hold_every_function_a_change_reaches():
    assert risk_changed.go_ids('calc.go', GO, {6, 12}) == {'calc.Double', 'calc.Box.Open'}


def test_go_ids_without_a_package_clause_is_empty():
    assert risk_changed.go_ids('calc.go', 'func A() {\n}\n', {1}) == set()


PHP = '''\
<?php

namespace App;

abstract class Calc
{
    public function triple(int $x): int
    {
        return $x * 3;
    }

    abstract protected function hook(): void;

    public static function one(): int { return 1; }
}

function helper()
{
    return 1;
}
'''


def php_ids(line):
    return risk_changed.php_ids('src/Calc.php', PHP, {line})


def test_php_ids_name_a_method_by_its_namespaced_class():
    assert php_ids(8) == {'src/Calc.php::App\\Calc::triple'}
    assert php_ids(9) == {'src/Calc.php::App\\Calc::triple'}
    assert php_ids(12) == {'src/Calc.php::App\\Calc::hook'}
    assert php_ids(14) == {'src/Calc.php::App\\Calc::one'}


def test_php_ids_put_a_function_outside_any_class_under_global():
    assert risk_changed.php_ids('src/Calc.php', PHP, {19}) == {'src/Calc.php::<global>::helper'}


def test_php_ids_leave_out_a_line_outside_every_function():
    assert risk_changed.php_ids('src/Calc.php', PHP, {1, 3, 6, 11, 13, 15}) == set()


def test_php_ids_run_a_function_that_never_closes_to_the_end_of_the_file():
    source = '<?php\nfunction lone()\n{\n    return 1;\n'
    assert risk_changed.php_ids('lone.php', source, {4}) == {'lone.php::<global>::lone'}
    assert risk_changed.php_ids('lone.php', source, {1}) == set()


def test_php_ids_without_a_namespace_use_the_bare_class_name():
    source = '<?php\nclass Plain\n{\n    function run()\n    {\n        return 1;\n    }\n}\n'
    assert risk_changed.php_ids('Plain.php', source, {6}) == {'Plain.php::Plain::run'}


def test_changed_ids_reads_the_lines_a_commit_added_to_each_source_file(repo):
    repo.commit({'lib.py': 'def keep():\n    return 1\n\n\ndef edit():\n    return 2\n',
                 'README.md': 'a\n'})
    head = repo.commit({'lib.py': 'def keep():\n    return 1\n\n\ndef edit():\n    return 3\n',
                        'README.md': 'b\n', 'notes.sh': 'echo hi\n'})
    assert risk_changed.changed_ids(str(repo.path), head) == {'lib.py::edit'}


def test_changed_ids_counts_a_python_function_the_commit_only_removed_lines_from(repo):
    repo.commit({'lib.py': 'def risky(a):\n    if a is None:\n        raise ValueError\n'
                           '    return a\n\n\ndef keep():\n    return 1\n'})
    head = repo.commit({'lib.py': 'def risky(a):\n    return a\n\n\ndef keep():\n    return 1\n'})
    assert risk_changed.changed_ids(str(repo.path), head) == {'lib.py::risky'}


def test_changed_ids_counts_a_function_whose_last_line_the_commit_removed(repo):
    repo.commit({'lib.py': 'def a():\n    x = 1\n    return x\n\n\ndef b():\n    return 2\n'})
    head = repo.commit({'lib.py': 'def a():\n    x = 1\n\n\ndef b():\n    return 2\n'})
    assert risk_changed.changed_ids(str(repo.path), head) == {'lib.py::a'}


def test_changed_ids_counts_a_go_function_the_commit_only_removed_lines_from(repo):
    repo.commit({'a.go': 'package a\n\nfunc F(n int) int {\n\tif n < 0 {\n\t\treturn 0\n\t}\n'
                         '\treturn n\n}\n\nfunc G() int {\n\treturn 1\n}\n'})
    head = repo.commit({'a.go': 'package a\n\nfunc F(n int) int {\n\treturn n\n}\n\n'
                                'func G() int {\n\treturn 1\n}\n'})
    assert risk_changed.changed_ids(str(repo.path), head) == {'a.F'}


def test_changed_ids_leaves_out_the_neighbours_of_a_function_the_commit_removed_whole(repo):
    repo.commit({'lib.py': 'def a():\n    return 1\n\n\ndef gone():\n    return 2\n\n\n'
                           'def b():\n    return 3\n'})
    head = repo.commit({'lib.py': 'def a():\n    return 1\n\n\ndef b():\n    return 3\n'})
    assert risk_changed.changed_ids(str(repo.path), head) <= {'lib.py::gone'}


def test_changed_ids_of_a_first_commit_holds_every_function_in_it(repo):
    first = repo.commit({'lib.py': 'def a():\n    return 1\n\n\ndef b():\n    return 2\n'})
    assert risk_changed.changed_ids(str(repo.path), first) == {'lib.py::a', 'lib.py::b'}


def test_changed_ids_leaves_out_a_file_the_commit_deleted(repo):
    repo.commit({'gone.py': 'def f():\n    return 1\n', 'keep.py': 'x = 1\n'})
    head = repo.commit({'gone.py': None})
    assert risk_changed.changed_ids(str(repo.path), head) == set()


def test_changed_ids_reads_all_three_languages(repo):
    head = repo.commit({'a.go': 'package a\n\nfunc F() int {\n\treturn 1\n}\n',
                        'b.php': '<?php\nclass B\n{\n    function m()\n    {\n        return 1;\n'
                                 '    }\n}\n',
                        'c.py': 'def f():\n    return 1\n'})
    assert risk_changed.changed_ids(str(repo.path), head) == {
        'a.F', 'b.php::B::m', 'c.py::f'}


def test_python_ids_keep_the_class_of_a_method_declared_under_a_condition():
    source = 'class Box:\n    if True:\n        def maybe(self):\n            return 1\n'
    assert risk_changed.python_ids('m.py', source, {4}) == {'m.py::Box.maybe'}


def test_go_receiver_with_two_type_parameters_is_none_however_they_are_spaced():
    assert risk_changed.go_receiver('Pair', '[K,V]') is None
    assert risk_changed.go_receiver('Pair', '[K, V]') is None
    assert risk_changed.go_receiver('Tree', '[T]') == 'Tree[T]'
    assert risk_changed.go_receiver('Box', None) == 'Box'


def test_php_end_of_a_one_line_function_with_trailing_space_is_that_line():
    lines = ['    function a() { return 1; }  ', 'x', '    }']
    assert risk_changed.php_end(lines, 0, '    ') == 1


def test_php_end_does_not_look_back_at_an_earlier_closing_brace():
    lines = ['    }', '    function a()', '    {', '        x', '    }']
    assert risk_changed.php_end(lines, 1, '    ') == 5


def test_php_end_accepts_a_closing_brace_on_the_line_after_the_declaration():
    lines = ['    function a()', '    }', 'x']
    assert risk_changed.php_end(lines, 0, '    ') == 2


def test_php_functions_before_any_class_that_are_indented_belong_to_global():
    text = '<?php\n    function early() {}\nclass K\n{\n}\n'
    assert list(risk_changed.php_functions(text)) == [(2, 2, '<global>', 'early')]


def test_changed_ids_reads_source_and_diff_with_undecodable_bytes(repo):
    repo.commit({'c.py': b'def f():\n    return 1  # \xff\n'})
    head = repo.commit({'c.py': b'def f():\n    return 2  # \xff\n'})
    assert risk_changed.changed_ids(str(repo.path), head) == {'c.py::f'}


def test_changed_ids_asks_git_for_a_bare_quoted_zero_context_diff(repo, monkeypatch):
    head = repo.commit({'c.py': 'def f():\n    return 1\n'})
    calls = []
    real = risk_changed.git

    def spy(path, *args):
        calls.append(args)
        return real(path, *args)

    monkeypatch.setattr(risk_changed, 'git', spy)
    risk_changed.changed_ids(str(repo.path), head)
    assert calls == [('-c', 'core.quotePath=true', 'show', '--format=', '-U0', '--no-color',
                      '--no-renames', head)]
