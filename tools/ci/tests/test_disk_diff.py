"""tools/ci/disk-diff.py `--own` (M8.T16): another container's content-free writes are `foreign`, not violations;
a phrase in them is still a LEAK; the run's own container stays strict."""
from conftest import load

dd = load("disk-diff")


def test_own_isolates_other_containers(tmp_path):
    sup = tmp_path / "Library" / "Application Support"
    own = sup / "AntiChat-T20-1"
    shared = sup / "AntiChat-Dev" / "Models" / "img"
    own.mkdir(parents=True)
    shared.mkdir(parents=True)
    before = dd.snapshot(tmp_path)
    (shared / "x.gguf.part").write_bytes(b"\0" * 64)  # another track's download
    r = dd.diff(before, tmp_path, ["quillfeather"], str(own))
    assert r["pass"] and r["entries"][0]["verdict"].startswith("foreign")
    (shared / "leak.txt").write_text("a quillfeather phrase")
    r = dd.diff(before, tmp_path, ["quillfeather"], str(own))
    assert not r["pass"] and str(shared / "leak.txt") in r["violations"]
    (shared / "leak.txt").unlink()
    (own / "chat.sqlite").write_bytes(b"x")  # this run's own container: strict
    r = dd.diff(before, tmp_path, ["quillfeather"], str(own))
    assert r["violations"] == [str(own / "chat.sqlite")]
    # Without --own every container is strict (the old behaviour).
    assert str(shared / "x.gguf.part") in dd.diff(before, tmp_path, ["quillfeather"])["violations"]


def test_session_ledger_appends_only_with_ledger_keys(tmp_path):
    """M9.T06's test-build session ledger (pid/time/paths only) must not fail AT-NFR-PR3; anything else in it does."""
    logs = tmp_path / "Library" / "Logs" / "AntiChat-Dev"
    logs.mkdir(parents=True)
    ledger = logs / "sessions.jsonl"
    ledger.write_text('{"event":"end","pid":1,"t":1.0}\n')
    before = dd.snapshot(tmp_path)
    with ledger.open("a") as f:
        f.write('{"bundle":"/x/AntiChat.app","bundleID":"app.antichat.AntiChat.dev","container":"/c","event":"start",'
                '"kind":"IncognitoProbe","pid":7,"t":2.0,"uitest":false}\n{"event":"end","pid":7,"t":3.0}\n')
    r = dd.diff(before, tmp_path, ["quillfeather"])
    assert r["pass"], r
    assert r["entries"][0]["verdict"].startswith("allowed: test-build session ledger")
    # An unknown key (e.g. chat text) in an appended line is a violation.
    with ledger.open("a") as f:
        f.write('{"event":"start","pid":8,"t":4.0,"title":"Groceries"}\n')
    assert not dd.diff(before, tmp_path, ["quillfeather"])["pass"]
    # A fixture phrase anywhere in the appended bytes is a LEAK.
    ledger.write_text('{"event":"end","pid":1,"t":1.0}\n')
    before = dd.snapshot(tmp_path)
    with ledger.open("a") as f:
        f.write('{"event":"start","pid":9,"t":5.0,"container":"/quillfeather"}\n')
    r = dd.diff(before, tmp_path, ["quillfeather"])
    assert r["entries"][0]["verdict"] == "LEAK" and not r["pass"]
    # A rewrite (not an append) is a violation even with valid lines.
    before = dd.snapshot(tmp_path)
    ledger.unlink()
    ledger.write_text('{"event":"end","pid":1,"t":1.0}\n')
    assert not dd.diff(before, tmp_path, ["quillfeather"])["pass"]
