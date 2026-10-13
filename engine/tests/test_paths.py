import pytest

from madstudio_engine import models, paths


@pytest.mark.parametrize("same_disk", [True, False])
def test_models_move_to_a_chosen_folder_and_back(tmp_path, monkeypatch, same_disk):
    monkeypatch.setenv("MADSTUDIO_HOME", str(tmp_path / "home"))
    monkeypatch.setattr(paths, "_same_disk", lambda a, b: same_disk)
    model = paths.models_dir() / "whisper-x"
    model.mkdir()
    (model / "weights.bin").write_bytes(b"x" * 1000)
    (model / ".complete").touch()
    (paths.models_dir() / "choice.json").write_text("{}")
    assert models.is_installed("whisper-x")

    external = tmp_path / "external"
    external.mkdir()
    status = paths.move_models(str(external))
    assert status["path"].endswith(paths.MODELS_FOLDER_NAME) and status["available"]
    assert models.is_installed("whisper-x")                     # found in the new place
    assert (external / paths.MODELS_FOLDER_NAME / "whisper-x" / "weights.bin").stat().st_size == 1000
    assert not (tmp_path / "home" / "models" / "whisper-x").exists()

    paths.move_models("")                                        # back to the default place
    assert models.is_installed("whisper-x") and paths.models_dir() == paths.default_models_dir()


def test_an_unplugged_disk_shows_nothing_installed(tmp_path, monkeypatch):
    monkeypatch.setenv("MADSTUDIO_HOME", str(tmp_path / "home"))
    paths.save_settings({"models_dir": "/Volumes/Нет такого диска/MadStudio — модели"})
    status = paths.models_dir_status()
    assert status["available"] is False
    assert not models.is_installed("whisper-turbo")


def test_moving_needs_free_space(tmp_path, monkeypatch):
    import shutil
    from collections import namedtuple

    monkeypatch.setenv("MADSTUDIO_HOME", str(tmp_path / "home"))
    (paths.models_dir() / "big").mkdir()
    (paths.models_dir() / "big" / "w.bin").write_bytes(b"x" * 10)
    usage = namedtuple("usage", "total used free")
    monkeypatch.setattr(shutil, "disk_usage", lambda p: usage(1, 1, 0))
    with pytest.raises(RuntimeError, match="не хватит места"):
        paths.move_models(str(tmp_path / "small"))
