-- V022: the operator can revoke a granted approval before it is consumed.
--
-- Until now a decided row was frozen except for the one-time consume latch,
-- so an approval could not be taken back once granted. When a reviewed
-- payload was superseded (PT-181, 2026-11-26: AP-141..147 pinned scripts a
-- review had found unsafe), the only way to stop `consume` passing was to
-- spend the approval by consuming it unused.
--
-- `revoked` is a new terminal status. Only an approved, unconsumed row may
-- move to it, once, recording who revoked it, when and why. Everything else
-- about the row stays as decided. A revoked row is immutable.
-- SQLite cannot change a CHECK in place, so the table is rebuilt as in V018:
-- same columns and CHECKs plus the three revoke columns, then the indexes
-- (V018 status/seq, V020 per-requester pending dedupe) and the tamper
-- triggers. INSERT into the new table does not fire the UPDATE triggers.

CREATE TABLE approvals_v22 (
    id              TEXT PRIMARY KEY,
    seq             INTEGER NOT NULL UNIQUE,
    kind            TEXT NOT NULL CHECK (kind IN ('email','ebay','spend','destroy','external','budget','other')),
    title           TEXT NOT NULL,
    request_note    TEXT,
    payload         BLOB,
    payload_kind    TEXT CHECK (payload_kind IS NULL OR payload_kind IN ('file','json')),
    payload_name    TEXT,
    payload_bytes   INTEGER,
    payload_ref     TEXT,
    digest          TEXT NOT NULL CHECK (length(digest) = 64 AND digest NOT GLOB '*[^0-9a-f]*'),
    requester       TEXT NOT NULL,
    task_uuid       TEXT,
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','approved','rejected','withdrawn','expired','revoked')),
    decided_by      TEXT,
    decided_via     TEXT CHECK (decided_via IS NULL OR decided_via IN ('cli','dashboard','telegram','api')),
    decision_note   TEXT,
    created_at      TEXT NOT NULL,
    decided_at      TEXT,
    expires_at      TEXT,
    notified_at     TEXT,
    consumed_at     TEXT,
    consumed_by     TEXT,
    revoked_at      TEXT,
    revoked_by      TEXT,
    revoke_note     TEXT,
    CHECK ((payload IS NULL) = (payload_kind IS NULL)),
    -- A revoked row was approved and never consumed; only revoked rows
    -- carry revoke fields.
    CHECK ((status = 'revoked') = (revoked_at IS NOT NULL AND revoked_by IS NOT NULL)),
    CHECK (status <> 'revoked' OR consumed_at IS NULL)
);

INSERT INTO approvals_v22 (
    id, seq, kind, title, request_note, payload, payload_kind, payload_name,
    payload_bytes, payload_ref, digest, requester, task_uuid, status,
    decided_by, decided_via, decision_note, created_at, decided_at,
    expires_at, notified_at, consumed_at, consumed_by
)
SELECT
    id, seq, kind, title, request_note, payload, payload_kind, payload_name,
    payload_bytes, payload_ref, digest, requester, task_uuid, status,
    decided_by, decided_via, decision_note, created_at, decided_at,
    expires_at, notified_at, consumed_at, consumed_by
FROM approvals;
DROP TABLE approvals;
ALTER TABLE approvals_v22 RENAME TO approvals;

CREATE UNIQUE INDEX idx_approvals_pending_requester_digest
    ON approvals(lower(requester), digest) WHERE status = 'pending';

CREATE INDEX idx_approvals_status_seq ON approvals(status, seq);

-- digest / payload / payload_kind are write-once.
CREATE TRIGGER approvals_immutable_payload
BEFORE UPDATE OF digest, payload, payload_kind ON approvals
BEGIN
    SELECT RAISE(ABORT, 'approvals: digest, payload, and payload_kind are immutable');
END;

-- Once decided, exactly two mutations are legal, each on an approved,
-- unconsumed row: the one-time consume latch (consumed_at/consumed_by NULL
-- to a value), or the one-time revoke (status approved to revoked and
-- revoked_at/revoked_by/revoke_note set). Every other column must stay as
-- decided. Rejected, withdrawn, expired, consumed and revoked rows are
-- immutable. notified_at may still be set while status is pending (this
-- trigger does not fire).
CREATE TRIGGER approvals_lock_after_decision
BEFORE UPDATE ON approvals
WHEN OLD.status IS NOT 'pending'
BEGIN
    SELECT CASE
        WHEN OLD.status = 'approved'
         AND OLD.consumed_at IS NULL
         AND NEW.id IS OLD.id
         AND NEW.seq IS OLD.seq
         AND NEW.kind IS OLD.kind
         AND NEW.title IS OLD.title
         AND NEW.request_note IS OLD.request_note
         AND NEW.payload IS OLD.payload
         AND NEW.payload_kind IS OLD.payload_kind
         AND NEW.payload_name IS OLD.payload_name
         AND NEW.payload_bytes IS OLD.payload_bytes
         AND NEW.payload_ref IS OLD.payload_ref
         AND NEW.digest IS OLD.digest
         AND NEW.requester IS OLD.requester
         AND NEW.task_uuid IS OLD.task_uuid
         AND NEW.decided_by IS OLD.decided_by
         AND NEW.decided_via IS OLD.decided_via
         AND NEW.decision_note IS OLD.decision_note
         AND NEW.created_at IS OLD.created_at
         AND NEW.decided_at IS OLD.decided_at
         AND NEW.expires_at IS OLD.expires_at
         AND NEW.notified_at IS OLD.notified_at
         AND (
             -- consume latch
             (    OLD.consumed_by IS NULL
              AND NEW.consumed_at IS NOT NULL
              AND NEW.consumed_by IS NOT NULL
              AND NEW.status IS OLD.status
              AND OLD.revoked_at IS NULL AND NEW.revoked_at IS NULL
              AND OLD.revoked_by IS NULL AND NEW.revoked_by IS NULL
              AND OLD.revoke_note IS NULL AND NEW.revoke_note IS NULL)
             OR
             -- revoke
             (    NEW.status = 'revoked'
              AND NEW.consumed_at IS NULL
              AND NEW.consumed_by IS OLD.consumed_by
              AND OLD.revoked_at IS NULL AND NEW.revoked_at IS NOT NULL
              AND OLD.revoked_by IS NULL AND NEW.revoked_by IS NOT NULL
              AND OLD.revoke_note IS NULL)
         )
        THEN NULL
        ELSE RAISE(ABORT, 'approvals: decided row is immutable except one-time consume or revoke')
    END;
END;
