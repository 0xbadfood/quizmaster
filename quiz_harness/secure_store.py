from __future__ import annotations

import hashlib
import os
from pathlib import Path

from cryptography.fernet import Fernet, InvalidToken


class SecretStoreError(RuntimeError):
    pass


class SecretStore:
    def __init__(self, *, key: str | None, key_file: Path) -> None:
        self.key_file = key_file
        self._fernet = Fernet(self._load_key(key))

    def _load_key(self, configured: str | None) -> bytes:
        if configured:
            candidate = configured.strip().encode("ascii")
            try:
                Fernet(candidate)
            except (ValueError, TypeError) as exc:
                raise SecretStoreError(
                    "QUIZ_SECRET_KEY must be a valid Fernet key"
                ) from exc
            return candidate
        if self.key_file.exists():
            candidate = self.key_file.read_bytes().strip()
            try:
                Fernet(candidate)
            except (ValueError, TypeError) as exc:
                raise SecretStoreError(
                    f"invalid provider secret key file: {self.key_file}"
                ) from exc
            return candidate
        self.key_file.parent.mkdir(parents=True, exist_ok=True)
        candidate = Fernet.generate_key()
        descriptor = os.open(
            self.key_file,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
        )
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(candidate + b"\n")
        return candidate

    def encrypt(self, secret: str) -> str:
        value = secret.strip()
        if not value:
            raise SecretStoreError("secret must not be empty")
        return self._fernet.encrypt(value.encode("utf-8")).decode("ascii")

    def decrypt(self, ciphertext: str | None) -> str | None:
        if not ciphertext:
            return None
        try:
            return self._fernet.decrypt(ciphertext.encode("ascii")).decode("utf-8")
        except (InvalidToken, ValueError, UnicodeError) as exc:
            raise SecretStoreError("could not decrypt provider secret") from exc

    @staticmethod
    def fingerprint(secret: str) -> str:
        return hashlib.sha256(secret.strip().encode("utf-8")).hexdigest()

    @staticmethod
    def last_four(secret: str) -> str:
        return secret.strip()[-4:]
