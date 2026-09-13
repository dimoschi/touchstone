import io
from pathlib import Path
from types import SimpleNamespace

from conftest import load_script

smoke_logger = load_script(Path(__file__).resolve().parent / "copilot-hook-smoke-logger.py")


def test_usage_error_on_wrong_arity(monkeypatch, capsys):
    monkeypatch.setattr("sys.argv", ["copilot-hook-smoke-logger.py", "only-one-arg"])
    assert smoke_logger.main() == 2
    assert "usage:" in capsys.readouterr().err


def test_record_failure_is_reported(monkeypatch, tmp_path, capsys):
    def boom(hook_key, raw):
        raise OSError("disk full")

    monkeypatch.setattr(smoke_logger, "record_hook_input", boom)
    monkeypatch.setattr("sys.argv", ["copilot-hook-smoke-logger.py", "/runner.py", "key"])
    monkeypatch.setattr("sys.stdin", SimpleNamespace(buffer=io.BytesIO(b"{}")))
    assert smoke_logger.main() == 1
    assert "could not record hook stdin" in capsys.readouterr().err


def test_runner_start_failure_is_reported(monkeypatch, capsys):
    monkeypatch.setattr(smoke_logger, "record_hook_input", lambda *a, **k: None)

    def boom(*a, **k):
        raise OSError("no such file")

    monkeypatch.setattr(smoke_logger.subprocess, "run", boom)
    monkeypatch.setattr("sys.argv", ["copilot-hook-smoke-logger.py", "/runner.py", "key"])
    monkeypatch.setattr("sys.stdin", SimpleNamespace(buffer=io.BytesIO(b"{}")))
    assert smoke_logger.main() == 1
    assert "could not start runner" in capsys.readouterr().err


def test_passes_through_runner_output_and_exit_code(monkeypatch, capsys):
    monkeypatch.setattr(smoke_logger, "record_hook_input", lambda *a, **k: None)

    def fake_run(argv, input, capture_output, check):
        assert argv[-1] == "hook-key"
        return SimpleNamespace(stdout=b"out-bytes", stderr=b"err-bytes", returncode=3)

    monkeypatch.setattr(smoke_logger.subprocess, "run", fake_run)
    monkeypatch.setattr("sys.argv", ["copilot-hook-smoke-logger.py", "/runner.py", "hook-key"])
    monkeypatch.setattr("sys.stdin", SimpleNamespace(buffer=io.BytesIO(b"stdin-bytes")))
    rc = smoke_logger.main()
    out = capsys.readouterr()
    assert rc == 3
