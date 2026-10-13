from madstudio_engine import models


def test_catalog_has_a_default_transcriber():
    ids = [m["id"] for m in models.catalog()]
    assert len(ids) == len(set(ids))
    assert models.default_for("transcribe") == "whisper-turbo"


def test_installed_state_follows_marker_file():
    assert not models.is_installed("whisper-small")
    path = models.model_path("whisper-small")
    path.mkdir(parents=True)
    assert not models.is_installed("whisper-small")  # unfinished download
    (path / ".complete").touch()
    assert models.is_installed("whisper-small")
    assert models.default_for("transcribe") == "whisper-small"  # prefers what is installed
    models.remove("whisper-small")
    assert not models.is_installed("whisper-small")


def test_fit_labels():
    mac = {"ram_gb": 8, "disk_free_gb": 50}
    assert models.fit({"size_gb": 1.6, "ram_gb": 2}, mac)["fit"] == "ok"
    assert models.fit({"size_gb": 3.1, "ram_gb": 4}, mac)["fit"] == "slow"
    assert models.fit({"size_gb": 16, "ram_gb": 18}, mac)["fit"] == "no_memory"
    assert models.fit({"size_gb": 60, "ram_gb": 2}, mac)["fit"] == "no_disk"
