from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any, Callable
from urllib.parse import urlencode

import httpx
from openai import APIError, OpenAI
from pydantic import Field

from .client import VLLMClient, VLLMError
from .models import StrictModel


YOUTUBE_UPLOAD_SCOPE = "https://www.googleapis.com/auth/youtube.upload"
GOOGLE_AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token"
GOOGLE_REVOKE_URL = "https://oauth2.googleapis.com/revoke"
YOUTUBE_API_ROOT = "https://www.googleapis.com/youtube/v3"
YOUTUBE_UPLOAD_ROOT = "https://www.googleapis.com/upload/youtube/v3"


class YouTubePublishError(RuntimeError):
    pass


class YouTubeDescriptionDraft(StrictModel):
    description: str = Field(min_length=80, max_length=4000)


def normalize_description(raw: str) -> str:
    text = raw.strip()
    if text.startswith("```") and text.endswith("```"):
        lines = text.splitlines()
        if len(lines) >= 3:
            text = "\n".join(lines[1:-1]).strip()
    try:
        return YouTubeDescriptionDraft.model_validate_json(text).description
    except ValueError:
        pass
    if text.casefold().startswith("description:"):
        text = text.split(":", 1)[1].lstrip()
    return YouTubeDescriptionDraft(description=text).description


def authorization_url(
    *, client_id: str, redirect_uri: str, state: str
) -> str:
    return GOOGLE_AUTH_URL + "?" + urlencode(
        {
            "client_id": client_id,
            "redirect_uri": redirect_uri,
            "response_type": "code",
            "scope": YOUTUBE_UPLOAD_SCOPE,
            "access_type": "offline",
            "include_granted_scopes": "true",
            "prompt": "consent",
            "state": state,
        }
    )


class YouTubeClient:
    def __init__(
        self,
        *,
        timeout_seconds: float = 120.0,
        transport: httpx.BaseTransport | None = None,
    ) -> None:
        self._client = httpx.Client(
            timeout=timeout_seconds,
            follow_redirects=False,
            transport=transport,
        )

    def __enter__(self) -> YouTubeClient:
        return self

    def __exit__(self, *args: object) -> None:
        self.close()

    def close(self) -> None:
        self._client.close()

    @staticmethod
    def _oauth_payload(response: httpx.Response, action: str) -> dict[str, Any]:
        try:
            response.raise_for_status()
            payload = response.json()
        except (httpx.HTTPError, ValueError) as exc:
            detail = response.text[:1000]
            raise YouTubePublishError(f"Google {action} failed: {detail or exc}") from exc
        if not isinstance(payload, dict):
            raise YouTubePublishError(f"Google {action} returned an invalid response")
        return payload

    def exchange_code(
        self,
        *,
        client_id: str,
        client_secret: str,
        code: str,
        redirect_uri: str,
    ) -> dict[str, Any]:
        response = self._client.post(
            GOOGLE_TOKEN_URL,
            data={
                "client_id": client_id,
                "client_secret": client_secret,
                "code": code,
                "grant_type": "authorization_code",
                "redirect_uri": redirect_uri,
            },
        )
        payload = self._oauth_payload(response, "authorization")
        if not payload.get("access_token"):
            raise YouTubePublishError("Google authorization returned no access token")
        if not payload.get("refresh_token"):
            raise YouTubePublishError(
                "Google returned no refresh token; revoke access and connect again"
            )
        return payload

    def refresh_access_token(
        self,
        *,
        client_id: str,
        client_secret: str,
        refresh_token: str,
    ) -> str:
        response = self._client.post(
            GOOGLE_TOKEN_URL,
            data={
                "client_id": client_id,
                "client_secret": client_secret,
                "refresh_token": refresh_token,
                "grant_type": "refresh_token",
            },
        )
        payload = self._oauth_payload(response, "token refresh")
        access_token = payload.get("access_token")
        if not isinstance(access_token, str) or not access_token:
            raise YouTubePublishError("Google token refresh returned no access token")
        return access_token

    def channel_identity(self, access_token: str) -> tuple[str | None, str | None]:
        try:
            response = self._client.get(
                f"{YOUTUBE_API_ROOT}/channels",
                params={"part": "id,snippet", "mine": "true", "maxResults": 1},
                headers={"Authorization": f"Bearer {access_token}"},
            )
            response.raise_for_status()
            items = response.json().get("items", [])
            if not items:
                return None, None
            item = items[0]
            return item.get("id"), item.get("snippet", {}).get("title")
        except (httpx.HTTPError, ValueError, KeyError, IndexError, TypeError):
            return None, None

    def revoke(self, token: str) -> None:
        try:
            self._client.post(GOOGLE_REVOKE_URL, data={"token": token})
        except httpx.HTTPError:
            pass

    def upload_video(
        self,
        *,
        access_token: str,
        video_path: Path,
        title: str,
        description: str,
        privacy_status: str,
        progress: Callable[[str, float | None], None],
        chunk_bytes: int = 8 * 1024 * 1024,
        retries: int = 4,
    ) -> dict[str, Any]:
        file_size = video_path.stat().st_size
        if file_size <= 0:
            raise YouTubePublishError("video file is empty")
        metadata = {
            "snippet": {
                "title": title,
                "description": description,
                "categoryId": "27",
                "tags": ["kids quiz", "educational quiz", "Quizmaster"],
            },
            "status": {
                "privacyStatus": privacy_status,
                "selfDeclaredMadeForKids": True,
            },
        }
        progress("Starting resumable YouTube upload", 0.05)
        try:
            response = self._client.post(
                f"{YOUTUBE_UPLOAD_ROOT}/videos",
                params={"uploadType": "resumable", "part": "snippet,status"},
                headers={
                    "Authorization": f"Bearer {access_token}",
                    "Content-Type": "application/json; charset=UTF-8",
                    "X-Upload-Content-Length": str(file_size),
                    "X-Upload-Content-Type": "video/mp4",
                },
                json=metadata,
            )
            response.raise_for_status()
        except httpx.HTTPError as exc:
            detail = getattr(exc, "response", None)
            body = detail.text[:1000] if detail is not None else str(exc)
            raise YouTubePublishError(f"could not start YouTube upload: {body}") from exc
        upload_url = response.headers.get("Location")
        if not upload_url:
            raise YouTubePublishError("YouTube returned no resumable upload URL")

        offset = 0
        with video_path.open("rb") as source:
            while offset < file_size:
                source.seek(offset)
                chunk = source.read(min(chunk_bytes, file_size - offset))
                if not chunk:
                    raise YouTubePublishError("video ended before the expected file size")
                last_byte = offset + len(chunk) - 1
                upload_response: httpx.Response | None = None
                for attempt in range(retries + 1):
                    try:
                        upload_response = self._client.put(
                            upload_url,
                            headers={
                                "Authorization": f"Bearer {access_token}",
                                "Content-Type": "video/mp4",
                                "Content-Length": str(len(chunk)),
                                "Content-Range": f"bytes {offset}-{last_byte}/{file_size}",
                            },
                            content=chunk,
                        )
                    except httpx.HTTPError as exc:
                        if attempt >= retries:
                            raise YouTubePublishError(
                                f"YouTube upload failed at byte {offset}: {exc}"
                            ) from exc
                        time.sleep(min(2**attempt, 8))
                        continue
                    if upload_response.status_code >= 500 and attempt < retries:
                        time.sleep(min(2**attempt, 8))
                        continue
                    break
                assert upload_response is not None
                if upload_response.status_code == 308:
                    acknowledged = upload_response.headers.get("Range", "")
                    try:
                        offset = int(acknowledged.rsplit("-", 1)[1]) + 1
                    except (IndexError, ValueError):
                        offset = last_byte + 1
                    progress(
                        f"Uploading to YouTube {offset:,}/{file_size:,} bytes",
                        0.08 + 0.88 * offset / file_size,
                    )
                    continue
                if upload_response.status_code not in {200, 201}:
                    raise YouTubePublishError(
                        "YouTube upload failed: " + upload_response.text[:1000]
                    )
                try:
                    payload = upload_response.json()
                except ValueError as exc:
                    raise YouTubePublishError(
                        "YouTube completed the upload without video metadata"
                    ) from exc
                youtube_id = payload.get("id")
                if not isinstance(youtube_id, str) or not youtube_id:
                    raise YouTubePublishError("YouTube returned no video ID")
                progress("YouTube upload complete", 0.98)
                return {
                    "youtube_video_id": youtube_id,
                    "youtube_url": f"https://youtu.be/{youtube_id}",
                    "privacy_status": privacy_status,
                }
        raise YouTubePublishError("YouTube upload did not complete")


def deployed_video_questions(
    *, bundle_root: Path, video: dict[str, Any]
) -> list[dict[str, str]]:
    content = (
        bundle_root
        / video["category_slug"]
        / f"versions/{int(video['bundle_version']):06d}/content"
    )
    category = json.loads((content / "category.json").read_text(encoding="utf-8"))
    records = {str(item["quiz_id"]): item for item in category.get("quizzes", [])}
    questions: list[dict[str, str]] = []
    for selection in video["selections"]:
        set_id = str(selection.get("set_id") or selection.get("quiz_id") or "")
        record = records.get(set_id)
        if record is None:
            raise YouTubePublishError(f"published quiz set is missing: {set_id}")
        quiz = json.loads((content / record["questions_file"]).read_text(encoding="utf-8"))
        selected_numbers = selection.get("question_numbers")
        allowed = set(selected_numbers) if selected_numbers else None
        for question_number, question in enumerate(quiz.get("questions", []), start=1):
            if allowed is not None and question_number not in allowed:
                continue
            correct_id = question.get("correct_choice_id")
            answer = next(
                (
                    str(choice.get("label") or "")
                    for choice in question.get("choices", [])
                    if choice.get("choice_id") == correct_id
                ),
                "",
            )
            questions.append(
                {
                    "question": str(question.get("question") or ""),
                    "answer": answer,
                    "explanation": str(question.get("explanation") or ""),
                }
            )
    return questions


def description_prompt(
    *, video: dict[str, Any], questions: list[dict[str, str]]
) -> str:
    compact = [
        {"question": item["question"], "learning_point": item["explanation"]}
        for item in questions
    ]
    return f"""Write a polished YouTube description for this children's quiz video.

Video title: {video['title']}
Category: {video['category_slug']}
Difficulty and source sets: {json.dumps(video['selections'], ensure_ascii=True)}
Question count: {video['question_count']}

Requirements:
- Write for both children and parents in clear, warm language.
- Summarize the subjects and learning value without revealing correct answers.
- Mention that viewers get time to answer before each explanation.
- Use two short paragraphs, one concise call to action, and 3-5 relevant hashtags.
- Do not claim official affiliation, certification, or guaranteed learning outcomes.
- Do not mention how the video was generated.

Questions and learning points:
{json.dumps(compact, indent=2, ensure_ascii=True)}
"""


def generate_description(
    *,
    video: dict[str, Any],
    questions: list[dict[str, str]],
    provider: dict[str, Any],
    model: str,
    secret: str | None,
) -> str:
    prompt = description_prompt(video=video, questions=questions)
    if provider["provider_type"] == "openai_compatible_llm":
        try:
            with VLLMClient(
                provider["base_url"], timeout_seconds=300, api_key=secret
            ) as client:
                raw = client.generate_text(
                    model=model,
                    messages=[
                        {
                            "role": "system",
                            "content": (
                                "You are an educational video editor. Return only the "
                                "final YouTube description as plain text. Do not use a "
                                "JSON wrapper or a Markdown code fence."
                            ),
                        },
                        {"role": "user", "content": prompt},
                    ],
                    seed=20260821,
                    temperature=0.4,
                    max_tokens=1800,
                )
            return normalize_description(raw)
        except (OSError, ValueError, VLLMError) as exc:
            raise YouTubePublishError(f"description generation failed: {exc}") from exc
    if provider["provider_type"] == "openai_images":
        if not secret:
            raise YouTubePublishError("OpenAI API key is not configured")
        try:
            with OpenAI(
                api_key=secret,
                base_url=provider["base_url"],
                timeout=300,
            ) as client:
                response = client.responses.parse(
                    model=model,
                    instructions=(
                        "You are an educational video editor. Follow the supplied "
                        "format and do not reveal quiz answers."
                    ),
                    input=prompt,
                    text_format=YouTubeDescriptionDraft,
                    reasoning={"effort": "low"},
                    max_output_tokens=1800,
                    store=False,
                )
        except APIError as exc:
            raise YouTubePublishError(f"description generation failed: {exc}") from exc
        if response.output_parsed is None:
            raise YouTubePublishError("description generation returned no content")
        return response.output_parsed.description
    raise YouTubePublishError("select an LLM-capable provider")
