from madstudio_engine.device import device_info


def test_device_info():
    info = device_info()
    assert info["ram_gb"] > 0
    assert info["python"].startswith("3.12")
