from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Any, AsyncIterator

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response, StreamingResponse


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_BUNDLE_ROOT = Path(
    os.getenv("QUIZ_DELIVERY_ROOT", ROOT / "dist/category_bundles")
)
SLUG_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")


def _read_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise HTTPException(status_code=404, detail="bundle resource not found") from exc
    except (OSError, json.JSONDecodeError) as exc:
        raise HTTPException(status_code=500, detail="bundle registry is invalid") from exc
    if not isinstance(data, dict):
        raise HTTPException(status_code=500, detail="bundle registry is invalid")
    return data


def _category_root(bundle_root: Path, slug: str) -> Path:
    if not SLUG_PATTERN.fullmatch(slug):
        raise HTTPException(status_code=404, detail="category not found")
    return bundle_root / slug


def _record_for_version(bundle_root: Path, slug: str, version: int) -> dict[str, Any]:
    if version < 1:
        raise HTTPException(status_code=404, detail="bundle version not found")
    root = _category_root(bundle_root, slug)
    return _full_access_record(
        _read_json(root / "versions" / f"{version:06d}" / "record.json")
    )


def _full_access_record(record: dict[str, Any]) -> dict[str, Any]:
    variants = record.get("access_variants", {})
    if isinstance(variants, dict):
        full = variants.get("full_library")
        if isinstance(full, dict) and isinstance(full.get("archive_file"), str):
            return full
    return record


def _current_record(bundle_root: Path, slug: str) -> dict[str, Any]:
    root = _category_root(bundle_root, slug)
    pointer = _read_json(root / "current.json")
    record_file = pointer.get("record_file")
    if not isinstance(record_file, str) or not record_file.startswith("versions/"):
        raise HTTPException(status_code=500, detail="current bundle pointer is invalid")
    return _full_access_record(_read_json(root / record_file))


def _summary(slug: str, record: dict[str, Any]) -> dict[str, Any]:
    version = int(record["bundle_version"])
    return {
        "category": record["category"],
        "bundle_id": record["bundle_id"],
        "bundle_version": version,
        "content_hash": record["content_hash"],
        "archive_bytes": record["archive_bytes"],
        "archive_sha256": record["archive_sha256"],
        "minimum_renderer_version": record["minimum_renderer_version"],
        "quiz_count": record["quiz_count"],
        "question_count": record["question_count"],
        "generated_at_utc": record["generated_at_utc"],
        "category_url": f"/api/v1/categories/{slug}",
        "selector_url": f"/api/v1/categories/{slug}/selector",
        "bundle_metadata_url": (
            f"/api/v1/categories/{slug}/bundles/{version}"
        ),
        "bundle_download_url": (
            f"/api/v1/categories/{slug}/bundles/{version}/download"
        ),
        "access": {
            "has_full_access": True,
            "free_quiz_limit": 1,
            "free_quiz_difficulty": "beginner",
        },
    }


def _etag(value: str) -> str:
    return f'"{value}"'


def _json_response(
    request: Request,
    payload: dict[str, Any],
    *,
    etag_value: str,
    cache_control: str,
) -> Response:
    etag = _etag(etag_value)
    headers = {"ETag": etag, "Cache-Control": cache_control}
    if request.headers.get("if-none-match") == etag:
        return Response(status_code=304, headers=headers)
    return JSONResponse(payload, headers=headers)


def _archive_response(
    request: Request,
    *,
    bundle_root: Path,
    slug: str,
    record: dict[str, Any],
) -> Response:
    category_root = _category_root(bundle_root, slug)
    archive_file = record.get("archive_file")
    if not isinstance(archive_file, str) or not archive_file.startswith("versions/"):
        raise HTTPException(status_code=500, detail="bundle archive record is invalid")
    archive = category_root / archive_file
    if not archive.is_file():
        raise HTTPException(status_code=404, detail="bundle archive not found")
    etag = _etag(record["archive_sha256"])
    headers = {
        "ETag": etag,
        "Cache-Control": "public, max-age=31536000, immutable",
        "X-Content-SHA256": record["archive_sha256"],
    }
    if request.headers.get("if-none-match") == etag:
        return Response(status_code=304, headers=headers)
    headers["Content-Length"] = str(archive.stat().st_size)
    headers["Content-Disposition"] = (
        f'attachment; filename="{Path(archive_file).name}"'
    )
    return StreamingResponse(
        _stream_file(archive),
        media_type="application/zip",
        headers=headers,
    )


async def _stream_file(path: Path, chunk_size: int = 1024 * 1024) -> AsyncIterator[bytes]:
    with path.open("rb") as handle:
        while chunk := handle.read(chunk_size):
            yield chunk


def create_app(bundle_root: Path | None = None) -> FastAPI:
    root = Path(bundle_root or DEFAULT_BUNDLE_ROOT)
    app = FastAPI(
        title="Quiz Category Delivery API",
        version="1.0.0",
        docs_url="/docs",
        redoc_url=None,
    )
    app.state.bundle_root = root
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_methods=["GET", "HEAD", "OPTIONS"],
        allow_headers=["*"],
        expose_headers=["ETag", "X-Content-SHA256", "Content-Length"],
    )

    @app.get("/health")
    async def health() -> dict[str, Any]:
        category_count = sum(
            1
            for path in root.iterdir()
            if path.is_dir() and (path / "current.json").is_file()
        ) if root.exists() else 0
        return {
            "status": "ok",
            "service": "quizapi",
            "api_version": "v1",
            "category_count": category_count,
        }

    @app.get("/api/v1/categories")
    async def categories(request: Request) -> Response:
        items = []
        if root.exists():
            for path in sorted(item for item in root.iterdir() if item.is_dir()):
                if not (path / "current.json").is_file():
                    continue
                record = _current_record(root, path.name)
                items.append(_summary(path.name, record))
        digest = "-".join(
            f"{item['bundle_id']}:{item['bundle_version']}:{item['content_hash']}"
            for item in items
        ) or "empty"
        return _json_response(
            request,
            {
                "schema_version": "category_catalog_v1",
                "categories": items,
            },
            etag_value=digest,
            cache_control="public, max-age=60, must-revalidate",
        )

    @app.get("/api/v1/categories/{slug}")
    async def category(slug: str, request: Request) -> Response:
        record = _current_record(root, slug)
        payload = {
            "schema_version": "category_delivery_v1",
            **_summary(slug, record),
            "versions_url": f"/api/v1/categories/{slug}/versions",
        }
        return _json_response(
            request,
            payload,
            etag_value=record["content_hash"],
            cache_control="public, max-age=60, must-revalidate",
        )

    @app.get("/api/v1/categories/{slug}/selector")
    async def selector(slug: str, request: Request) -> Response:
        record = _current_record(root, slug)
        asset = record.get("category", {}).get("selector_asset")
        if not isinstance(asset, str):
            raise HTTPException(status_code=500, detail="selector asset is not registered")
        content = (
            _category_root(root, slug)
            / "versions"
            / f"{int(record['bundle_version']):06d}"
            / "content"
        )
        path = content / asset
        if not path.is_file():
            raise HTTPException(status_code=404, detail="selector asset not found")
        etag_value = next(
            (
                item["sha256"]
                for item in record.get("files", [])
                if item.get("path") == asset
            ),
            record["content_hash"],
        )
        etag = _etag(etag_value)
        headers = {
            "ETag": etag,
            "Cache-Control": "public, max-age=60, must-revalidate",
        }
        if request.headers.get("if-none-match") == etag:
            return Response(status_code=304, headers=headers)
        headers["Content-Length"] = str(path.stat().st_size)
        return Response(path.read_bytes(), media_type="image/webp", headers=headers)

    @app.get("/api/v1/categories/{slug}/versions")
    async def versions(slug: str, request: Request) -> Response:
        category_root = _category_root(root, slug)
        versions_root = category_root / "versions"
        if not versions_root.exists():
            raise HTTPException(status_code=404, detail="category not found")
        records = [
            _read_json(path / "record.json")
            for path in sorted(
                (item for item in versions_root.iterdir() if item.is_dir()),
                reverse=True,
            )
            if (path / "record.json").is_file()
        ]
        current = _current_record(root, slug)
        payload = {
            "schema_version": "category_versions_v1",
            "category_id": slug,
            "current_version": current["bundle_version"],
            "versions": [_summary(slug, record) for record in records],
        }
        return _json_response(
            request,
            payload,
            etag_value="-".join(record["content_hash"] for record in records),
            cache_control="public, max-age=60, must-revalidate",
        )

    @app.get("/api/v1/categories/{slug}/bundle")
    @app.get("/api/v1/categories/{slug}/bundles/current")
    async def current_bundle(slug: str, request: Request) -> Response:
        record = _current_record(root, slug)
        return _json_response(
            request,
            {"schema_version": "category_bundle_delivery_v1", **_summary(slug, record)},
            etag_value=record["content_hash"],
            cache_control="public, max-age=60, must-revalidate",
        )

    @app.get("/api/v1/categories/{slug}/bundles/{version}")
    async def bundle_version(slug: str, version: int, request: Request) -> Response:
        record = _record_for_version(root, slug, version)
        return _json_response(
            request,
            {"schema_version": "category_bundle_delivery_v1", **_summary(slug, record)},
            etag_value=record["content_hash"],
            cache_control="public, max-age=31536000, immutable",
        )

    @app.get("/api/v1/categories/{slug}/bundle.zip")
    async def current_download(slug: str, request: Request) -> Response:
        return _archive_response(
            request,
            bundle_root=root,
            slug=slug,
            record=_current_record(root, slug),
        )

    @app.get("/api/v1/categories/{slug}/bundles/{version}/download")
    async def version_download(slug: str, version: int, request: Request) -> Response:
        return _archive_response(
            request,
            bundle_root=root,
            slug=slug,
            record=_record_for_version(root, slug, version),
        )

    return app


app = create_app()
