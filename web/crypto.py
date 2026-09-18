import os
from cryptography.fernet import Fernet

_KEY_FILE = os.environ.get(
    "SECRET_KEY_FILE",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "secret.key"),
)


def _load_or_create_key():
    key = os.environ.get("APP_MASTER_KEY")
    if key:
        return key.encode()
    if os.path.exists(_KEY_FILE):
        with open(_KEY_FILE, "rb") as fh:
            return fh.read().strip()
    key = Fernet.generate_key()
    dir_path = os.path.dirname(_KEY_FILE)
    if dir_path:
        os.makedirs(dir_path, exist_ok=True)
    with open(_KEY_FILE, "wb") as fh:
        fh.write(key)
    try:
        os.chmod(_KEY_FILE, 0o600)
    except OSError:
        pass
    return key


_fernet = Fernet(_load_or_create_key())


def encrypt_secret(plaintext: str) -> str:
    if not plaintext:
        return ""
    return _fernet.encrypt(plaintext.encode()).decode()


def decrypt_secret(ciphertext: str) -> str:
    if not ciphertext:
        return ""
    try:
        return _fernet.decrypt(ciphertext.encode()).decode()
    except Exception:
        return ""