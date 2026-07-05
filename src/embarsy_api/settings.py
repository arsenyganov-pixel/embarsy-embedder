from __future__ import annotations

from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    host: str = Field(default="127.0.0.1", alias="EMBARSY_HOST")
    api_port: int = Field(default=8000, alias="EMBARSY_API_PORT")
    api_key: str = Field(default="", alias="EMBARSY_API_KEY")

    ollama_base_url: str = Field(default="http://127.0.0.1:11434", alias="OLLAMA_BASE_URL")
    ollama_model: str = Field(default="qwen3-embedding", alias="OLLAMA_MODEL")
    ollama_keep_alive: str = Field(default="30m", alias="OLLAMA_KEEP_ALIVE")

    embedding_dimension: int = Field(default=1024, alias="EMBARSY_EMBEDDING_DIMENSION")
    embedding_instruction: str = Field(
        default=(
            "Represent this codebase search text so semantically related code snippets, "
            "symbols, files, and natural-language questions are close in vector space."
        ),
        alias="EMBARSY_EMBEDDING_INSTRUCTION",
    )
    request_timeout_seconds: float = Field(default=120.0, alias="EMBARSY_REQUEST_TIMEOUT_SECONDS")

    qdrant_base_url: str = Field(default="http://127.0.0.1:6333", alias="QDRANT_BASE_URL")
    qdrant_api_key: str = Field(default="", alias="QDRANT_API_KEY")


@lru_cache
def get_settings() -> Settings:
    return Settings()
