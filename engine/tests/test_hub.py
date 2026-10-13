from madstudio_engine import hub


def test_size_and_format_are_read_from_mlx_names():
    d = hub.describe("mlx-community/Qwen3-4B-Instruct-2507-4bit", "text")
    assert d["params_b"] == 4.0 and d["precision"] == "4 бит" and 2.0 <= d["size_gb"] <= 2.4
    w = hub.describe("mlx-community/whisper-large-v3-turbo", "transcribe")
    assert w["params_b"] == 0.809 and w["precision"] == "FP16"
    s = hub.describe("mlx-community/Qwen3-0.6B-8bit", "text")
    assert s["params_b"] == 0.6 and s["precision"] == "8 бит"


def test_every_task_looks_only_in_its_own_family(monkeypatch):
    urls = []
    monkeypatch.setattr(hub, "_get", lambda url, timeout=15: urls.append(url) or [
        {"id": "mlx-community/Qwen3-Embedding-0.6B-4bit", "downloads": 9}, {"id": "mlx-community/Qwen3-1.7B-4bit", "downloads": 5}])
    found = hub.search("text", "qwen3")
    assert "pipeline_tag=text-generation" in urls[0] and "author=mlx-community" in urls[0]
    assert [m["title"] for m in found] == ["Qwen3-1.7B-4bit"]        # an embedding model can't write
    hub.search("voice")
    assert "search=F5-TTS" in urls[1]
    assert hub.search("separate") == []                              # no online family: catalog only


def test_a_newer_version_on_hugging_face_is_offered_as_an_update(tmp_path, monkeypatch):
    import types

    import huggingface_hub

    from madstudio_engine import models

    monkeypatch.setenv("MADSTUDIO_HOME", str(tmp_path))
    models.add_user_model({"id": "hub--a--b", "task": "text", "title": "b", "repo": "a/b", "size_gb": 1, "ram_gb": 1})
    folder = models.model_path("hub--a--b")
    folder.mkdir(parents=True)
    (folder / ".complete").touch()
    sha = {"value": "v1"}
    monkeypatch.setattr(huggingface_hub, "HfApi", lambda: types.SimpleNamespace(
        model_info=lambda repo: types.SimpleNamespace(sha=sha["value"])))
    assert models.updates() == []                       # first look: v1 is what is installed
    sha["value"] = "v2"
    assert [u["id"] for u in models.updates()] == ["hub--a--b"]
    models.use("hub--a--b")
    assert models.default_for("text") == "hub--a--b"
    models.remove("hub--a--b")
    assert all(m["id"] != "hub--a--b" for m in models.catalog())
    assert models.default_for("text") != "hub--a--b"    # a removed choice falls back to the catalog
