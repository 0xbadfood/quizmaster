from __future__ import annotations

import json
import re
import subprocess
import threading
from collections import deque
from pathlib import Path
from typing import Any, Callable

from scripts.prepare_remotion_quiz import (
    RENDERER_ROOT,
    _resolve_background,
    prepare_sets,
)


class StudioVideoError(RuntimeError):
    pass


class StudioVideoStore:
    def __init__(self, bundle_root: Path, video_root: Path) -> None:
        self.bundle_root = bundle_root
        self.video_root = video_root
        self._render_lock = threading.Lock()

    @staticmethod
    def _read_json(path: Path) -> dict[str, Any]:
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise StudioVideoError(f"cannot read {path}: {exc}") from exc
        if not isinstance(value, dict):
            raise StudioVideoError(f"expected a JSON object in {path}")
        return value

    def inventory(self, category_slug: str) -> dict[str, Any]:
        pointer = self._read_json(self.bundle_root / category_slug / "current.json")
        version = int(pointer["bundle_version"])
        content = (
            self.bundle_root
            / category_slug
            / f"versions/{version:06d}/content"
        )
        document = self._read_json(content / "category.json")
        quiz_sets = [
            {
                "set_id": str(item["quiz_id"]),
                "number": int(item["number"]),
                "difficulty": str(item["difficulty"]),
                "title": str(item["title"]),
                "question_count": int(item.get("question_count", 10)),
                "questions": [
                    {
                        "number": question_number,
                        "question_id": str(question.get("question_id") or ""),
                        "question": str(question.get("question") or ""),
                    }
                    for question_number, question in enumerate(
                        self._read_json(content / item["questions_file"]).get(
                            "questions", []
                        ),
                        start=1,
                    )
                ],
            }
            for item in document.get("quizzes", [])
        ]
        backgrounds: dict[str, bool] = {}
        for orientation in ("portrait", "landscape"):
            try:
                _resolve_background(
                    category=category_slug,
                    orientation=orientation,
                    content=content,
                    category_document=document,
                )
            except (OSError, ValueError):
                backgrounds[orientation] = False
            else:
                backgrounds[orientation] = True
        return {
            "bundle_version": version,
            "content": content,
            "document": document,
            "sets": quiz_sets,
            "backgrounds": backgrounds,
        }

    def resolve_selection(
        self,
        *,
        category_slug: str,
        orientation: str,
        set_ids: list[str],
        question_numbers: list[int] | None = None,
    ) -> dict[str, Any]:
        inventory = self.inventory(category_slug)
        if orientation not in {"portrait", "landscape"}:
            raise StudioVideoError(f"unsupported orientation: {orientation}")
        if not inventory["backgrounds"][orientation]:
            raise StudioVideoError(
                f"{orientation} video background is not available for {category_slug}"
            )
        by_id = {item["set_id"]: item for item in inventory["sets"]}
        if len(set_ids) != len(set(set_ids)):
            raise StudioVideoError("quiz set selection contains duplicates")
        try:
            source_sets = [by_id[set_id] for set_id in set_ids]
        except KeyError as exc:
            raise StudioVideoError(f"quiz set is not published: {exc.args[0]}") from exc
        question_count = sum(item["question_count"] for item in source_sets)
        maximum = 10 if orientation == "portrait" else 50
        if not source_sets:
            raise StudioVideoError("select at least one quiz set")
        if question_count > maximum:
            raise StudioVideoError(
                f"{orientation} videos support at most {maximum} questions"
            )
        if any(item["question_count"] != 10 for item in source_sets):
            raise StudioVideoError("every selected quiz set must contain 10 questions")
        selected = [
            {
                key: item[key]
                for key in (
                    "set_id",
                    "number",
                    "difficulty",
                    "title",
                    "question_count",
                )
            }
            for item in source_sets
        ]
        if question_numbers is not None:
            if orientation != "portrait":
                raise StudioVideoError(
                    "individual question selection is available only for portrait videos"
                )
            if len(selected) != 1:
                raise StudioVideoError(
                    "portrait question selection requires exactly one quiz set"
                )
            if len(question_numbers) != len(set(question_numbers)):
                raise StudioVideoError("question selection contains duplicates")
            selected_numbers = sorted(question_numbers)
            invalid = [
                number
                for number in selected_numbers
                if number < 1 or number > source_sets[0]["question_count"]
            ]
            if invalid:
                raise StudioVideoError(
                    "question numbers must be between 1 and 10: "
                    + ", ".join(str(number) for number in invalid)
                )
            if not selected_numbers:
                raise StudioVideoError("select at least one question")
            selected[0]["question_numbers"] = selected_numbers
            selected[0]["question_count"] = len(selected_numbers)
            question_count = len(selected_numbers)
        return {
            **inventory,
            "selected": selected,
            "question_count": question_count,
        }

    def render(
        self,
        *,
        video_id: str,
        category_slug: str,
        orientation: str,
        bundle_version: int,
        selections: list[dict[str, Any]],
        concurrency: int,
        crf: int,
        progress: Callable[[str, float | None], None],
    ) -> dict[str, Any]:
        remotion = RENDERER_ROOT / "node_modules/.bin/remotion"
        if not remotion.is_file():
            raise StudioVideoError("Remotion dependencies are not installed")
        selection_tuples = [
            (
                str(item["difficulty"]),
                int(item["number"]),
                item.get("question_numbers"),
            )
            for item in selections
        ]
        output_dir = self.video_root / category_slug
        output_dir.mkdir(parents=True, exist_ok=True)
        file_name = f"{category_slug}-{orientation}-{video_id[:10]}.mp4"
        output = output_dir / file_name

        progress("Waiting for the video renderer", 0.03)
        with self._render_lock:
            progress("Preparing published quiz assets", 0.06)
            prepare_sets(
                category_slug,
                selection_tuples,
                orientation=orientation,
                bundle_version=bundle_version,
            )
            command = [
                str(remotion),
                "render",
                "src/index.ts",
                "QuizVideo",
                str(output),
                "--codec=h264",
                f"--crf={crf}",
                f"--concurrency={concurrency}",
                "--overwrite",
            ]
            progress("Rendering video", 0.1)
            process = subprocess.Popen(
                command,
                cwd=RENDERER_ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                errors="replace",
            )
            recent: deque[str] = deque(maxlen=30)
            assert process.stdout is not None
            for line in process.stdout:
                clean = line.strip()
                if clean:
                    recent.append(clean)
                match = re.search(r"Rendered\s+(\d+)/(\d+)", clean)
                if match and int(match.group(2)):
                    complete, total = (int(value) for value in match.groups())
                    progress(
                        f"Rendering frames {complete:,}/{total:,}",
                        0.1 + 0.84 * complete / total,
                    )
            return_code = process.wait()
            if return_code:
                detail = "\n".join(recent) or f"Remotion exited with {return_code}"
                raise StudioVideoError(detail)

        progress("Indexing completed video", 0.96)
        duration = self._duration(output)
        return {
            "status": "complete",
            "file_name": file_name,
            "file_path": str(output.resolve()),
            "file_bytes": output.stat().st_size,
            "duration_seconds": duration,
        }

    @staticmethod
    def _duration(path: Path) -> float | None:
        try:
            result = subprocess.run(
                [
                    "ffprobe",
                    "-v",
                    "error",
                    "-show_entries",
                    "format=duration",
                    "-of",
                    "default=noprint_wrappers=1:nokey=1",
                    str(path),
                ],
                check=True,
                capture_output=True,
                text=True,
                timeout=30,
            )
            return round(float(result.stdout.strip()), 3)
        except (OSError, ValueError, subprocess.SubprocessError):
            return None
