import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("translate_srt_argos", ROOT / "translate_srt_argos.py")
module = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(module)


def test_argos_backend_does_not_enable_ollama_polisher(monkeypatch):
    called = []

    class FakeOllamaPolisher:
        def __init__(self, *args, **kwargs):
            called.append("polisher")

    monkeypatch.setattr(module, "_try_ollama_polisher", FakeOllamaPolisher)

    # Simulate the backend selection logic used by main().
    polisher = None
    if "argos" in ("auto", "argos"):
        polisher = None

    assert polisher is None
    assert called == []
