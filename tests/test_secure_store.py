from pathlib import Path

from quiz_harness.secure_store import SecretStore


def test_secret_store_encrypts_and_reuses_key_file(tmp_path: Path) -> None:
    key_file = tmp_path / "provider.key"
    first = SecretStore(key=None, key_file=key_file)
    encrypted = first.encrypt("sk-test-super-secret")

    assert "sk-test-super-secret" not in encrypted
    assert first.decrypt(encrypted) == "sk-test-super-secret"
    assert first.fingerprint("sk-test-super-secret") != encrypted
    assert first.last_four("sk-test-super-secret") == "cret"
    assert key_file.stat().st_mode & 0o777 == 0o600

    second = SecretStore(key=None, key_file=key_file)
    assert second.decrypt(encrypted) == "sk-test-super-secret"
