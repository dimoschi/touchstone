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
'''


def go_ids(line):
    return risk_changed.go_ids('calc.go', GO, {line})


def test_go_ids_name_a_function_by_package_and_a_method_by_its_receiver_type():
    assert go_ids(6) == {'calc.Double'}
    assert go_ids(12) == {'calc.Box.Open'}
    assert go_ids(15) == {'calc.Box.Close'}
    assert go_ids(18) == {'calc.Generic'}
    assert go_ids(21) == {'calc.Tree.Walk'}


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
