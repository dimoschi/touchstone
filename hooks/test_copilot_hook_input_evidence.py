import stat

import copilot_hook_input_evidence as chie


def test_no_env_is_a_no_op(monkeypatch, tmp_path):
    monkeypatch.delenv(chie.EVIDENCE_ENV, raising=False)
    chie.record_hook_input("key", b"payload")
    assert list(tmp_path.iterdir()) == []


def test_writes_locked_down_evidence_file(monkeypatch, tmp_path):
    evidence_dir = tmp_path / "evidence"
    monkeypatch.setenv(chie.EVIDENCE_ENV, str(evidence_dir))
    chie.record_hook_input("crap-commit", b'{"hello": true}')

    files = list(evidence_dir.iterdir())
    assert len(files) == 1
    assert files[0].name.startswith("crap-commit-")
    assert files[0].read_bytes() == b'{"hello": true}'
    assert stat.S_IMODE(files[0].stat().st_mode) == stat.S_IRUSR | stat.S_IWUSR
    assert stat.S_IMODE(evidence_dir.stat().st_mode) == stat.S_IRWXU


def test_reuses_existing_directory(monkeypatch, tmp_path):
    evidence_dir = tmp_path / "evidence"
    evidence_dir.mkdir(mode=0o700)
    monkeypatch.setenv(chie.EVIDENCE_ENV, str(evidence_dir))
    chie.record_hook_input("key", b"a")
    chie.record_hook_input("key", b"b")
    assert len(list(evidence_dir.iterdir())) == 2
