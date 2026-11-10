"""SQLite state: what happened to each video, so work is never done twice."""

from __future__ import annotations

import sqlite3
import time
from pathlib import Path

# Status values
IMPORTING = "importing"  # import into Photos started; if seen at startup, a crash happened
REPLACED = "replaced"  # new video is in Photos, original waits in the delete album
DELETED = "deleted"  # original was moved to Recently Deleted
NOT_WORTH = "not_worth"  # already well compressed, original kept
SKIPPED = "skipped"  # video type we do not touch
FAILED = "failed"  # error; retried until max_attempts
NEEDS_REVIEW = "needs_review"  # crash during import; a person must check for a duplicate

FINAL = {REPLACED, DELETED, NOT_WORTH, SKIPPED, NEEDS_REVIEW, IMPORTING}

_SCHEMA = """
CREATE TABLE IF NOT EXISTS videos (
    uuid       TEXT PRIMARY KEY,
    filename   TEXT,
    status     TEXT NOT NULL,
    orig_size  INTEGER,
    new_size   INTEGER,
    new_uuid   TEXT,
    attempts   INTEGER NOT NULL DEFAULT 0,
    detail     TEXT,
    updated_at REAL NOT NULL
)
"""


class State:
    def __init__(self, path: Path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(path)
        self.db.row_factory = sqlite3.Row
        self.db.execute(_SCHEMA)
        self.db.commit()

    def close(self) -> None:
        self.db.close()

    def get(self, uuid: str) -> sqlite3.Row | None:
        return self.db.execute("SELECT * FROM videos WHERE uuid = ?", (uuid,)).fetchone()

    def set(self, uuid: str, status: str, *, filename: str | None = None,
            orig_size: int | None = None, new_size: int | None = None,
            new_uuid: str | None = None, detail: str | None = None) -> None:
        """Insert or update a row. Values left as None keep their old value."""
        self.db.execute(
            """
            INSERT INTO videos (uuid, filename, status, orig_size, new_size, new_uuid,
                                attempts, detail, updated_at)
            VALUES (:uuid, :filename, :status, :orig_size, :new_size, :new_uuid,
                    :attempts, :detail, :now)
            ON CONFLICT(uuid) DO UPDATE SET
                status = excluded.status,
                filename = COALESCE(excluded.filename, filename),
                orig_size = COALESCE(excluded.orig_size, orig_size),
                new_size = COALESCE(excluded.new_size, new_size),
                new_uuid = COALESCE(excluded.new_uuid, new_uuid),
                attempts = attempts + excluded.attempts,
                detail = excluded.detail,
                updated_at = excluded.updated_at
            """,
            dict(uuid=uuid, filename=filename, status=status, orig_size=orig_size,
                 new_size=new_size, new_uuid=new_uuid,
                 attempts=1 if status == FAILED else 0, detail=detail, now=time.time()),
        )
        self.db.commit()

    def by_status(self, status: str) -> list[sqlite3.Row]:
        return self.db.execute(
            "SELECT * FROM videos WHERE status = ? ORDER BY updated_at", (status,)
        ).fetchall()

    def recover_interrupted(self) -> int:
        """Rows left in IMPORTING mean a crash mid-import. Flag them for a person."""
        cur = self.db.execute(
            "UPDATE videos SET status = ?, detail = ? WHERE status = ?",
            (NEEDS_REVIEW,
             "Interrupted during import. Check Photos for a duplicate of this video.",
             IMPORTING),
        )
        self.db.commit()
        return cur.rowcount

    def summary(self) -> list[sqlite3.Row]:
        return self.db.execute(
            """
            SELECT status, COUNT(*) AS n,
                   COALESCE(SUM(orig_size), 0) AS orig,
                   COALESCE(SUM(new_size), 0) AS new
            FROM videos GROUP BY status ORDER BY status
            """
        ).fetchall()
