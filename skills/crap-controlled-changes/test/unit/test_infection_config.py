import json

import infection_config


def test_rejects_relative_report_path(monkeypatch, tmp_path, capsys):
    src = tmp_path / "infection.json"
    src.write_text("{}")
    monkeypatch.setattr("sys.argv", ["infection_config.py", str(src), str(tmp_path / "dest.json"), "relative/report.json"])
    rc = infection_config.main()
    assert rc == 2
    assert "must be absolute" in capsys.readouterr().err


def test_rejects_non_json_config(monkeypatch, tmp_path, capsys):
    src = tmp_path / "infection.json"
    src.write_text("{not json,,,")
    dest = tmp_path / "dest.json"
    monkeypatch.setattr("sys.argv", ["infection_config.py", str(src), str(dest), str(tmp_path / "report.json")])
    rc = infection_config.main()
    assert rc == 2
    assert "cannot parse" in capsys.readouterr().err
    assert not dest.exists()


def test_injects_logs_json_preserving_existing_keys(monkeypatch, tmp_path):
    src = tmp_path / "infection.json"
    src.write_text(json.dumps({
        "source": {"directories": ["src"]},
        "logs": {"text": "infection.log"},
    }))
    dest = tmp_path / "dest.json"
    report = tmp_path / "report.json"
    monkeypatch.setattr("sys.argv", ["infection_config.py", str(src), str(dest), str(report)])
    rc = infection_config.main()
    assert rc == 0
    written = json.loads(dest.read_text())
    assert written["source"] == {"directories": ["src"]}
    assert written["logs"]["text"] == "infection.log"
    assert written["logs"]["json"] == str(report)


def test_injects_logs_key_when_absent(monkeypatch, tmp_path):
    src = tmp_path / "infection.json"
    src.write_text(json.dumps({"source": {"directories": ["src"]}}))
    dest = tmp_path / "dest.json"
    report = tmp_path / "report.json"
    monkeypatch.setattr("sys.argv", ["infection_config.py", str(src), str(dest), str(report)])
    assert infection_config.main() == 0
    written = json.loads(dest.read_text())
    assert written["logs"] == {"json": str(report)}
