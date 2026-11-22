from pathlib import Path
from typing import Literal

from pydantic import Field, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="CAM_",
        secrets_dir=Path("/run/secrets") if Path("/run/secrets").is_dir() else None,
        hide_input_in_errors=True,
    )

    server_env: Literal["development", "test", "production"]
    database_url: SecretStr = Field(min_length=1)
    db_pool_size: int = Field(default=4, ge=1, le=30)
    request_timeout_seconds: int = Field(default=5, ge=1, le=30)
    log_level: Literal["critical", "error", "warning", "info", "debug"] = "info"

    session_ttl_seconds: int = Field(default=600, ge=60, le=3600)
    discovery_ttl_seconds: int = Field(default=90, ge=30, le=300)
    stun_urls: list[str] = []
    turn_urls: list[str] = []
    turn_shared_secret: SecretStr | None = None

    @model_validator(mode="after")
    def validate_ice_configuration(self):
        if any(not url.startswith(("stun:", "stuns:")) for url in self.stun_urls):
            raise ValueError("Invalid CAM_STUN_URLS")
        if any(not url.startswith(("turn:", "turns:")) for url in self.turn_urls):
            raise ValueError("Invalid CAM_TURN_URLS")
        if self.turn_urls and (
            self.turn_shared_secret is None or not self.turn_shared_secret.get_secret_value()
        ):
            raise ValueError("CAM_TURN_SHARED_SECRET is required when TURN is enabled")
        return self
