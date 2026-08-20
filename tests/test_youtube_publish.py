import json
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import httpx

from quiz_harness.youtube_publish import (
    YOUTUBE_UPLOAD_SCOPE,
    YouTubeClient,
    authorization_url,
    deployed_video_questions,
    description_prompt,
)


def test_authorization_url_requests_offline_upload_access() -> None:
    url = authorization_url(
        client_id="client.apps.googleusercontent.com",
        redirect_uri="https://quiz.example/oauth/callback",
        state="one-time-state",
    )
    query = parse_qs(urlparse(url).query)

    assert query["scope"] == [YOUTUBE_UPLOAD_SCOPE]
    assert query["access_type"] == ["offline"]
    assert query["prompt"] == ["consent"]
    assert query["state"] == ["one-time-state"]


def test_refresh_access_token_uses_the_stored_refresh_token() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        form = parse_qs(request.content.decode("utf-8"))
        assert form["grant_type"] == ["refresh_token"]
        assert form["refresh_token"] == ["refresh-token"]
        return httpx.Response(200, json={"access_token": "fresh-access-token"})

    with YouTubeClient(transport=httpx.MockTransport(handler)) as client:
        token = client.refresh_access_token(
            client_id="client-id",
            client_secret="client-secret",
            refresh_token="refresh-token",
        )

    assert token == "fresh-access-token"


def test_resumable_upload_sends_metadata_and_multiple_chunks(tmp_path: Path) -> None:
    video = tmp_path / "quiz.mp4"
    video.write_bytes(b"0123456789")
    ranges: list[str] = []
    metadata: dict[str, object] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "POST":
            metadata.update(json.loads(request.content))
            assert request.headers["X-Upload-Content-Length"] == "10"
            return httpx.Response(
                200, headers={"Location": "https://upload.example/session"}
            )
        ranges.append(request.headers["Content-Range"])
        if len(ranges) == 1:
            assert request.content == b"012345"
            return httpx.Response(308, headers={"Range": "bytes=0-5"})
        assert request.content == b"6789"
        return httpx.Response(201, json={"id": "youtube-video-id"})

    progress: list[tuple[str, float | None]] = []
    with YouTubeClient(transport=httpx.MockTransport(handler)) as client:
        result = client.upload_video(
            access_token="access-token",
            video_path=video,
            title="Geography Quiz",
            description="Test your geography knowledge.",
            privacy_status="unlisted",
            progress=lambda message, value: progress.append((message, value)),
            chunk_bytes=6,
        )

    assert ranges == ["bytes 0-5/10", "bytes 6-9/10"]
    assert metadata["status"] == {
        "privacyStatus": "unlisted",
        "selfDeclaredMadeForKids": True,
    }
    assert metadata["snippet"]["categoryId"] == "27"
    assert result["youtube_url"] == "https://youtu.be/youtube-video-id"
    assert progress[-1][0] == "YouTube upload complete"


def test_deployed_video_questions_use_the_exact_selected_sets(tmp_path: Path) -> None:
    content = tmp_path / "geography/versions/000003/content"
    quiz_dir = content / "quizzes/beginner"
    quiz_dir.mkdir(parents=True)
    (content / "category.json").write_text(
        json.dumps(
            {
                "quizzes": [
                    {
                        "quiz_id": "geography_beginner_01",
                        "questions_file": (
                            "quizzes/beginner/geography_beginner_01.json"
                        ),
                    },
                    {
                        "quiz_id": "geography_beginner_02",
                        "questions_file": (
                            "quizzes/beginner/geography_beginner_02.json"
                        ),
                    },
                ]
            }
        ),
        encoding="utf-8",
    )
    for number, animal in ((1, "Tiger"), (2, "Elephant")):
        (quiz_dir / f"geography_beginner_0{number}.json").write_text(
            json.dumps(
                {
                    "questions": [
                        {
                            "question": f"Which answer belongs to set {number}?",
                            "choices": [
                                {"choice_id": "a", "label": animal},
                                {"choice_id": "b", "label": "Dolphin"},
                            ],
                            "correct_choice_id": "a",
                            "explanation": f"{animal} is the learning point.",
                        }
                    ]
                }
            ),
            encoding="utf-8",
        )
    video = {
        "category_slug": "geography",
        "bundle_version": 3,
        "title": "Geography Quiz",
        "question_count": 1,
        "selections": [
            {"set_id": "geography_beginner_02", "question_count": 1}
        ],
    }

    questions = deployed_video_questions(bundle_root=tmp_path, video=video)

    assert questions == [
        {
            "question": "Which answer belongs to set 2?",
            "answer": "Elephant",
            "explanation": "Elephant is the learning point.",
        }
    ]
    prompt = description_prompt(video=video, questions=questions)
    assert "without revealing correct answers" in prompt
    assert "Which answer belongs to set 2?" in prompt
