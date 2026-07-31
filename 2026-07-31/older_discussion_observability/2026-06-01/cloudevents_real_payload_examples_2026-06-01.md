# CloudEvents Payload Examples — Real Habu Data
**Date:** 2026-06-01
**Purpose:** Convince TLM that object_events schema + CloudEvents v1.0 envelope is industry standard
**Data source:** Real export job IDs + data import job IDs from Habu production-like data

---

## How to read these examples

Each scenario shows THREE things:
1. **What triggers the event** — the actual mutation that happened
2. **What row lands in `object_events` table** — the DB record
3. **What the consumer receives** — the full CloudEvents v1.0 JSON envelope

The `changedFields` JSONB captures a structural diff: `{ field: { from: X, to: Y } }`.
This is the same pattern GitHub Webhooks, Stripe Events, and Salesforce Platform Events use.

---

## Scenario 1 — DATA CONNECTION: Stage Transition (CONFIGURATION_COMPLETE → MAPPING_REQUIRED)

**Real data:** `cvs_lcr-modified_txns_hq` (ID: `97b6cf60-f8be-48aa-b7a0-ec112c1fb801`)
The BigQuery source data connection required re-mapping after a schema push to `modified_txns_hq`.

### What triggered it
```
User or automated job changed stage from CONFIGURATION_COMPLETE → MAPPING_REQUIRED
Organization: 26ffde05-f377-4115-98a7-158aecd3174a
Performed by: sreekar.s@liveramp.com (based on updatedByUser in real data)
```

### Row inserted into object_events table
```sql
INSERT INTO object_events (
  event_id, cleanroom_id, org_id,
  object_type, object_id,
  event_type, changed_fields,
  performed_by, schema_version, event_time, cursor_position
) VALUES (
  'evt-a1b2c3d4-e5f6-7890-abcd-ef1234567890',
  'cr-cleanroom-uuid-here',
  '26ffde05-f377-4115-98a7-158aecd3174a',
  'DATA_CONNECTION',
  '97b6cf60-f8be-48aa-b7a0-ec112c1fb801',   -- exact ID from real data
  'com.habu.cleanroom.data_connection.updated',
  '{
    "stage": {
      "from": "CONFIGURATION_COMPLETE",
      "to":   "MAPPING_REQUIRED"
    },
    "dataSourceName": {
      "unchanged": "Google Cloud Big Query"
    },
    "sourceTable": {
      "unchanged": "modified_txns_hq"
    }
  }',
  'sreekar.s@liveramp.com',
  1,
  '2026-02-05T04:18:35.095472Z',   -- exact updatedAt from real data
  4822
);
```

### CloudEvents v1.0 envelope delivered to consumer
```json
{
  "specversion":       "1.0",
  "id":                "evt-a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "source":            "urn:habu:cleanroom:cr-cleanroom-uuid-here",
  "type":              "com.habu.cleanroom.data_connection.updated",
  "time":              "2026-02-05T04:18:35.095472Z",
  "datacontenttype":   "application/json",
  "schemaurl":         "https://schema.habu.com/events/v1/data_connection.updated.json",
  "traceparent":       "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
  "data": {
    "orgId":            "26ffde05-f377-4115-98a7-158aecd3174a",
    "cleanroomId":      "cr-cleanroom-uuid-here",
    "objectType":       "DATA_CONNECTION",
    "objectId":         "97b6cf60-f8be-48aa-b7a0-ec112c1fb801",
    "objectName":       "cvs_lcr-modified_txns_hq",
    "changeType":       "UPDATED",
    "changedFields": {
      "stage": {
        "from": "CONFIGURATION_COMPLETE",
        "to":   "MAPPING_REQUIRED"
      }
    },
    "context": {
      "dataSourceName": "Google Cloud Big Query",
      "dataTypeName":   "Generic",
      "category":       "AE Hosted",
      "sourceTable":    "modified_txns_hq",
      "sourceDataset":  "cvs_lcr",
      "projectId":      "lranalytics-us-557216"
    },
    "performedBy":      "sreekar.s@liveramp.com",
    "schemaVersion":    1,
    "idempotencyKey":   "sha256-7f83b1657ff1fc53b92dc18148a1d65dfc2d4b1fa3d677284addd200126d9069",
    "cursor":           "eyJsYXN0X2N1cnNvciI6NDgyMn0="
  }
}
```

**Why TLM cares:** `stage: CONFIGURATION_COMPLETE → MAPPING_REQUIRED` is exactly the kind of lifecycle transition XMI needs to know about to pause downstream workflows. With polling they'd catch it 60s late. With push webhook they get it in under 2 seconds.

---

## Scenario 2 — DATA CONNECTION: Field Type Changed in Schema Snapshot

**Real data:** `cvs_lcr-CMX_DE_COMBINED_TXN_V` (ID: `d1351401-9471-4c6b-b4e6-93b319c11125`)
A BigQuery schema push changed field `transaction_amount` from FLOAT64 → STRING (upstream pipeline change).
The data connection's `schema_snapshot` JSONB is updated by the data import job.

### What triggered it
```
Data import job completed and schema re-sync detected field type drift.
Organization: 26ffde05-f377-4115-98a7-158aecd3174a
Table: CMX_DE_COMBINED_TXN_V in dataset cvs_lcr (project: lranalytics-us-557216)
Performed by: system:data-import-service (automated)
```

### Row inserted into object_events table
```sql
INSERT INTO object_events VALUES (
  'evt-b2c3d4e5-f6a7-8901-bcde-f12345678901',
  'cr-cleanroom-uuid-here',
  '26ffde05-f377-4115-98a7-158aecd3174a',
  'DATA_CONNECTION',
  'd1351401-9471-4c6b-b4e6-93b319c11125',   -- exact ID from real data
  'com.habu.cleanroom.data_connection.schema_changed',
  '{
    "schemaSnapshot": {
      "fieldsChanged": [
        {
          "fieldName":  "transaction_amount",
          "fieldFrom":  { "type": "FLOAT64",  "nullable": true },
          "fieldTo":    { "type": "STRING",   "nullable": true }
        }
      ],
      "fieldsAdded":   [],
      "fieldsRemoved": []
    },
    "stage": {
      "from": "CONFIGURATION_COMPLETE",
      "to":   "MAPPING_REQUIRED"
    }
  }',
  'system:data-import-service',
  1,
  '2026-03-24T21:52:21.201567Z',   -- exact updatedAt from real data
  4823
);
```

### CloudEvents v1.0 envelope
```json
{
  "specversion":       "1.0",
  "id":                "evt-b2c3d4e5-f6a7-8901-bcde-f12345678901",
  "source":            "urn:habu:cleanroom:cr-cleanroom-uuid-here",
  "type":              "com.habu.cleanroom.data_connection.schema_changed",
  "time":              "2026-03-24T21:52:21.201567Z",
  "datacontenttype":   "application/json",
  "schemaurl":         "https://schema.habu.com/events/v1/data_connection.schema_changed.json",
  "traceparent":       "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
  "data": {
    "orgId":       "26ffde05-f377-4115-98a7-158aecd3174a",
    "cleanroomId": "cr-cleanroom-uuid-here",
    "objectType":  "DATA_CONNECTION",
    "objectId":    "d1351401-9471-4c6b-b4e6-93b319c11125",
    "objectName":  "cvs_lcr-CMX_DE_COMBINED_TXN_V",
    "changeType":  "SCHEMA_CHANGED",
    "changedFields": {
      "schemaSnapshot": {
        "fieldsChanged": [
          {
            "fieldName": "transaction_amount",
            "fieldFrom": { "type": "FLOAT64", "nullable": true },
            "fieldTo":   { "type": "STRING",  "nullable": true }
          }
        ],
        "fieldsAdded":   [],
        "fieldsRemoved": []
      },
      "stage": {
        "from": "CONFIGURATION_COMPLETE",
        "to":   "MAPPING_REQUIRED"
      }
    },
    "context": {
      "dataSourceName":  "Google Cloud Big Query",
      "projectId":       "lranalytics-us-557216",
      "sourceDataset":   "cvs_lcr",
      "sourceTable":     "CMX_DE_COMBINED_TXN_V",
      "temporaryDataset":"cvs_lcr_temporary",
      "usesPartitions":  true,
      "useCases":        ["CLEANROOM_QUESTIONS"]
    },
    "performedBy":    "system:data-import-service",
    "schemaVersion":  1,
    "idempotencyKey": "sha256-3a7bd3e2360a3d29aa625519ad9dc8e11d25f2aa",
    "cursor":         "eyJsYXN0X2N1cnNvciI6NDgyM30="
  }
}
```

**Why TLM cares:** XMI has a Question running against `transaction_amount` expecting FLOAT64. When this event fires, XMI's workflow can immediately flag the question as "schema drift detected" and pause the export — instead of getting a cryptic type error 6 hours later when the export job runs.

---

## Scenario 3 — EXPORT JOB: Status Transition (PENDING → RUNNING → COMPLETED)

**Real data:** `TestGCSnetwork / Q1` (ID: `c7de5be7-9b8e-42bc-83ff-3ecaa7a454a4`)
Export job for Question `CRQ--CRQ-062947` to GCS via partner account `TestGCSnetwork`.

### Three events fired in sequence (same export job ID, different event types)

#### Event 3a: PENDING → RUNNING
```json
{
  "specversion":     "1.0",
  "id":              "evt-c3d4e5f6-a7b8-9012-cdef-123456789012",
  "source":          "urn:habu:cleanroom:cr-cleanroom-uuid-here",
  "type":            "com.habu.cleanroom.export_job.run_started",
  "time":            "2025-10-08T08:50:00.000000Z",
  "datacontenttype": "application/json",
  "schemaurl":       "https://schema.habu.com/events/v1/export_job.run_started.json",
  "data": {
    "orgId":       "02617c50-a923-4877-a968-6465d5d2baaa",
    "cleanroomId": "cr-cleanroom-uuid-here",
    "objectType":  "EXPORT_JOB",
    "objectId":    "c7de5be7-9b8e-42bc-83ff-3ecaa7a454a4",
    "objectName":  "TestGCSnetwork / Q1",
    "changeType":  "UPDATED",
    "changedFields": {
      "runStatus": {
        "from": "RUN_STATUS_UNKNOWN",
        "to":   "RUNNING"
      }
    },
    "context": {
      "dataExportJobType":   "Question Run Export",
      "jobStatus":           "ACTIVE",
      "partnerName":         "GCS Export",
      "partnerAccountName":  "TestGCSnetwork",
      "partnerAccountId":    "2b939eaa-4253-4914-bf66-a65b83fa9383",
      "questionId":          "d94ccaeb-d0f9-4665-8a42-378f9f030f57",
      "questionDisplayName": "CRQ--CRQ-062947",
      "exportDestination":   "Google Cloud Storage"
    },
    "performedBy":   "system:cronos-scheduler",
    "schemaVersion": 1,
    "cursor":        "eyJsYXN0X2N1cnNvciI6NDgyNH0="
  }
}
```

#### Event 3b: RUNNING → COMPLETED (the one XMI most cares about)
```json
{
  "specversion":     "1.0",
  "id":              "evt-d4e5f6a7-b8c9-0123-defa-234567890123",
  "source":          "urn:habu:cleanroom:cr-cleanroom-uuid-here",
  "type":            "com.habu.cleanroom.export_job.run_completed",
  "time":            "2025-10-08T08:58:56.952745Z",
  "datacontenttype": "application/json",
  "schemaurl":       "https://schema.habu.com/events/v1/export_job.run_completed.json",
  "data": {
    "orgId":       "02617c50-a923-4877-a968-6465d5d2baaa",
    "cleanroomId": "cr-cleanroom-uuid-here",
    "objectType":  "EXPORT_JOB",
    "objectId":    "c7de5be7-9b8e-42bc-83ff-3ecaa7a454a4",
    "objectName":  "TestGCSnetwork / Q1",
    "changeType":  "UPDATED",
    "changedFields": {
      "runStatus": {
        "from": "RUNNING",
        "to":   "COMPLETED"
      },
      "jobLastRunTime": {
        "from": null,
        "to":   "2025-10-08T08:58:56.952745Z"
      }
    },
    "context": {
      "dataExportJobType":   "Question Run Export",
      "jobStatus":           "ACTIVE",
      "partnerName":         "GCS Export",
      "partnerAccountId":    "2b939eaa-4253-4914-bf66-a65b83fa9383",
      "questionId":          "d94ccaeb-d0f9-4665-8a42-378f9f030f57",
      "questionDisplayName": "CRQ--CRQ-062947",
      "exportDestination":   "Google Cloud Storage",
      "durationSeconds":     536
    },
    "performedBy":   "system:cronos-export-worker",
    "schemaVersion": 1,
    "idempotencyKey":"sha256-9e107d9d372bb6826bd81d3542a419d6",
    "cursor":        "eyJsYXN0X2N1cnNvciI6NDgyNX0="
  }
}
```

#### Event 3c: ACTIVE → DELETED (export job removed from cleanroom)
```json
{
  "specversion":     "1.0",
  "id":              "evt-e5f6a7b8-c9d0-1234-efab-345678901234",
  "source":          "urn:habu:cleanroom:cr-cleanroom-uuid-here",
  "type":            "com.habu.cleanroom.export_job.deleted",
  "time":            "2026-01-15T14:22:00.000000Z",
  "datacontenttype": "application/json",
  "schemaurl":       "https://schema.habu.com/events/v1/export_job.deleted.json",
  "data": {
    "orgId":       "02617c50-a923-4877-a968-6465d5d2baaa",
    "cleanroomId": "cr-cleanroom-uuid-here",
    "objectType":  "EXPORT_JOB",
    "objectId":    "c7de5be7-9b8e-42bc-83ff-3ecaa7a454a4",
    "objectName":  "TestGCSnetwork / Q1",
    "changeType":  "DELETED",
    "changedFields": {
      "status": {
        "from": "ACTIVE",
        "to":   "DELETED"
      },
      "deletedAt": {
        "from": null,
        "to":   "2026-01-15T14:22:00.000000Z"
      }
    },
    "context": {
      "dataExportJobType":   "Question Run Export",
      "partnerAccountId":    "2b939eaa-4253-4914-bf66-a65b83fa9383",
      "questionId":          "d94ccaeb-d0f9-4665-8a42-378f9f030f57",
      "questionDisplayName": "CRQ--CRQ-062947"
    },
    "performedBy":   "sreekar.s@liveramp.com",
    "schemaVersion": 1,
    "cursor":        "eyJsYXN0X2N1cnNvciI6NDgyNn0="
  }
}
```

---

## Scenario 4 — EXPORT JOB: Second job, no questionID (standalone export)

**Real data:** Second export job (ID: `9e7a2606-e3ec-433a-8c1b-9a2886dc5ee8`)
This job has `questionID: ""` — it's not linked to a specific question run. Status updated 2025-10-03.

```json
{
  "specversion":     "1.0",
  "id":              "evt-f6a7b8c9-d0e1-2345-fabc-456789012345",
  "source":          "urn:habu:cleanroom:cr-cleanroom-uuid-here",
  "type":            "com.habu.cleanroom.export_job.updated",
  "time":            "2025-10-03T05:00:53.748330Z",
  "datacontenttype": "application/json",
  "schemaurl":       "https://schema.habu.com/events/v1/export_job.updated.json",
  "data": {
    "orgId":       "02617c50-a923-4877-a968-6465d5d2baaa",
    "cleanroomId": "cr-cleanroom-uuid-here",
    "objectType":  "EXPORT_JOB",
    "objectId":    "9e7a2606-e3ec-433a-8c1b-9a2886dc5ee8",
    "objectName":  "TestGCSnetwork / Q1",
    "changeType":  "UPDATED",
    "changedFields": {
      "jobLastRunTime": {
        "from": null,
        "to":   "2025-10-03T05:00:53.748330Z"
      }
    },
    "context": {
      "dataExportJobType":  "Question Run Export",
      "jobStatus":          "ACTIVE",
      "partnerName":        "GCS Export",
      "partnerAccountId":   "2b939eaa-4253-4914-bf66-a65b83fa9383",
      "questionId":         null,
      "questionDisplayName":"CRQ--",
      "note":               "Export job not linked to a specific question run"
    },
    "performedBy":   "sreekar.s@liveramp.com",
    "schemaVersion": 1,
    "cursor":        "eyJsYXN0X2N1cnNvciI6NDgyN30="
  }
}
```

---

## What the object_events table looks like after all 4 scenarios run

```sql
SELECT event_id, object_type, object_id, event_type, performed_by, event_time, cursor_position
FROM object_events
WHERE cleanroom_id = 'cr-cleanroom-uuid-here'
ORDER BY cursor_position;

┌──────────────────┬────────────────┬──────────────────────────────────────┬─────────────────────────────────────────────────────┬────────────────────────────┬─────────────────────────────┬─────────────────┐
│ event_id         │ object_type    │ object_id                            │ event_type                                          │ performed_by               │ event_time                  │ cursor_position │
├──────────────────┼────────────────┼──────────────────────────────────────┼─────────────────────────────────────────────────────┼────────────────────────────┼─────────────────────────────┼─────────────────┤
│ evt-a1b2c3d4...  │ DATA_CONNECTION│ 97b6cf60-f8be-48aa-b7a0-ec112c1fb801 │ com.habu.cleanroom.data_connection.updated          │ sreekar.s@liveramp.com     │ 2026-02-05T04:18:35.095472Z │ 4822            │
│ evt-b2c3d4e5...  │ DATA_CONNECTION│ d1351401-9471-4c6b-b4e6-93b319c11125 │ com.habu.cleanroom.data_connection.schema_changed   │ system:data-import-service │ 2026-03-24T21:52:21.201567Z │ 4823            │
│ evt-c3d4e5f6...  │ EXPORT_JOB     │ c7de5be7-9b8e-42bc-83ff-3ecaa7a454a4 │ com.habu.cleanroom.export_job.run_started           │ system:cronos-scheduler    │ 2025-10-08T08:50:00.000000Z │ 4824            │
│ evt-d4e5f6a7...  │ EXPORT_JOB     │ c7de5be7-9b8e-42bc-83ff-3ecaa7a454a4 │ com.habu.cleanroom.export_job.run_completed         │ system:cronos-export-worker│ 2025-10-08T08:58:56.952745Z │ 4825            │
│ evt-f6a7b8c9...  │ EXPORT_JOB     │ 9e7a2606-e3ec-433a-8c1b-9a2886dc5ee8 │ com.habu.cleanroom.export_job.updated               │ sreekar.s@liveramp.com     │ 2025-10-03T05:00:53.748330Z │ 4826            │
│ evt-e5f6a7b8...  │ EXPORT_JOB     │ c7de5be7-9b8e-42bc-83ff-3ecaa7a454a4 │ com.habu.cleanroom.export_job.deleted               │ sreekar.s@liveramp.com     │ 2026-01-15T14:22:00.000000Z │ 4827            │
└──────────────────┴────────────────┴──────────────────────────────────────┴─────────────────────────────────────────────────────┴────────────────────────────┴─────────────────────────────┴─────────────────┘
```

---

## Event type taxonomy (full list for the proto / schema registry)

```
com.habu.cleanroom.question.created
com.habu.cleanroom.question.updated         ← columns added/removed/renamed
com.habu.cleanroom.question.deleted
com.habu.cleanroom.question.status_changed  ← DRAFT → ACTIVE → DELETED

com.habu.cleanroom.data_connection.created
com.habu.cleanroom.data_connection.updated           ← stage, status change
com.habu.cleanroom.data_connection.schema_changed    ← field type drift, add/remove
com.habu.cleanroom.data_connection.deleted

com.habu.cleanroom.export_job.created
com.habu.cleanroom.export_job.updated
com.habu.cleanroom.export_job.run_started
com.habu.cleanroom.export_job.run_completed
com.habu.cleanroom.export_job.run_failed
com.habu.cleanroom.export_job.deleted
```

All follow `com.habu.cleanroom.<object_type>.<action>` — same naming convention as
GitHub (`com.github.push`), Stripe (`payment_intent.created`), Salesforce Platform Events.

---

## Vendor-neutrality proof

Same payload, three clouds, zero transformation needed:

| Cloud | Native consumer | What they use from the payload |
|---|---|---|
| **GCP (XMI)** | GCP Eventarc triggers on `type` field natively | `specversion`, `type`, `source`, `data` |
| **Azure (MSFT)** | Azure Event Grid CloudEvents schema mode | Same JSON verbatim, no conversion |
| **AWS (Habu internal)** | AWS EventBridge CloudEvents support (GA 2023) | Same JSON verbatim |

The `schemaurl` field points to Habu's schema registry — consumers validate their received
payload against the published JSON Schema. When `schemaVersion` bumps from 1 → 2,
consumers that only read v1 fields keep working (additive evolution).

---

## Full Database Schema (PostgreSQL DDL)

### Table 1: object_events — the append-only event store

```sql
-- Flyway migration: V2025_10_01__create_object_events.sql
-- Owned by: unhygienix service
-- Purpose: append-only audit log for cleanroom object mutations

CREATE SEQUENCE IF NOT EXISTS object_events_cursor_seq
    START WITH 1
    INCREMENT BY 1
    NO CYCLE;

CREATE TABLE IF NOT EXISTS object_events (

    -- Identity
    event_id          UUID            NOT NULL  DEFAULT gen_random_uuid(),
    cursor_position   BIGINT          NOT NULL  DEFAULT nextval('object_events_cursor_seq'),

    -- Tenant / scope
    org_id            UUID            NOT NULL,
    cleanroom_id      UUID            NOT NULL,

    -- Object being tracked
    object_type       VARCHAR(50)     NOT NULL,
    -- Allowed values: 'QUESTION', 'DATA_CONNECTION', 'EXPORT_JOB'
    -- Enforced by app layer, not DB constraint, to allow future types without migration

    object_id         UUID            NOT NULL,
    object_name       VARCHAR(500)    NOT NULL  DEFAULT '',

    -- Event classification
    event_type        VARCHAR(200)    NOT NULL,
    -- Pattern: com.habu.cleanroom.<object_type>.<action>
    -- e.g.   : com.habu.cleanroom.export_job.run_completed

    change_type       VARCHAR(50)     NOT NULL,
    -- Allowed values: 'CREATED', 'UPDATED', 'DELETED', 'SCHEMA_CHANGED'

    -- Payload
    changed_fields    JSONB           NOT NULL  DEFAULT '{}',
    -- Structure: { "fieldName": { "from": <old>, "to": <new> } }
    -- For structural diffs (schema): { "schemaSnapshot": { "fieldsChanged": [...] } }

    context_fields    JSONB           NOT NULL  DEFAULT '{}',
    -- Immutable snapshot of non-changed fields for consumer context
    -- e.g. partnerAccountId, questionDisplayName, dataSourceName

    -- Actor
    performed_by      VARCHAR(500)    NOT NULL,
    -- Format: email (human) or "system:<service-name>" (automated)

    -- Schema versioning (for forward/backward compat)
    schema_version    INTEGER         NOT NULL  DEFAULT 1,

    -- Idempotency
    idempotency_key   VARCHAR(100)    NOT NULL  DEFAULT '',
    -- SHA-256(org_id + object_id + event_type + event_time)
    -- Prevents duplicate rows if interceptor fires twice on transaction retry

    -- Timestamps
    event_time        TIMESTAMPTZ     NOT NULL,
    -- Wall-clock time of the mutation (from the source service)

    created_at        TIMESTAMPTZ     NOT NULL  DEFAULT NOW(),
    -- Time the row was inserted into object_events (may differ from event_time by ~1ms)

    -- Hard constraints
    CONSTRAINT pk_object_events PRIMARY KEY (event_id),
    CONSTRAINT uq_object_events_cursor UNIQUE (cursor_position),
    CONSTRAINT uq_object_events_idempotency UNIQUE (idempotency_key)
    -- If idempotency_key is empty string, UNIQUE does not deduplicate — app must set it
);

-- ─── INDEXES ─────────────────────────────────────────────────────────────────

-- Primary read path: consumer pages forward by cleanroom + cursor
CREATE INDEX IF NOT EXISTS idx_oe_cleanroom_cursor
    ON object_events (cleanroom_id, cursor_position ASC);

-- Org-scoped reads (external API filters by org via JWT claim)
CREATE INDEX IF NOT EXISTS idx_oe_org_cursor
    ON object_events (org_id, cursor_position ASC);

-- Object-specific history (e.g. "show all events for export job c7de5be7...")
CREATE INDEX IF NOT EXISTS idx_oe_object_history
    ON object_events (object_id, cursor_position ASC);

-- Event type filtering (e.g. objectType=EXPORT_JOB)
CREATE INDEX IF NOT EXISTS idx_oe_cleanroom_type_cursor
    ON object_events (cleanroom_id, object_type, cursor_position ASC);

-- TTL window: partial index used by the 90-day cleanup job
CREATE INDEX IF NOT EXISTS idx_oe_event_time_ttl
    ON object_events (event_time)
    WHERE event_time > NOW() - INTERVAL '90 days';

-- JSONB GIN index: allows querying changed_fields contents
-- e.g. WHERE changed_fields @> '{"stage": {"to": "MAPPING_REQUIRED"}}'
CREATE INDEX IF NOT EXISTS idx_oe_changed_fields_gin
    ON object_events USING GIN (changed_fields);

-- ─── RETENTION POLICY ────────────────────────────────────────────────────────

-- Run nightly by a cronos cleanup job:
-- DELETE FROM object_events WHERE event_time < NOW() - INTERVAL '90 days';
-- NOTE: object_events is append-only — no UPDATE, no soft DELETE, no status column.
-- Retention is hard delete after TTL. Consumers that need longer history must archive.

-- ─── PERMISSIONS ─────────────────────────────────────────────────────────────

GRANT SELECT, INSERT ON object_events TO unhygienix_app;
-- No UPDATE, no DELETE for the app role.
-- Only the cleanup job (service role) has DELETE permission.
REVOKE UPDATE ON object_events FROM unhygienix_app;
REVOKE DELETE ON object_events FROM unhygienix_app;
```

---

### Table 2: callback_registrations — webhook consumer registry

```sql
-- Flyway migration: V2025_10_02__create_callback_registrations.sql
-- Owned by: unhygienix service (accessed via external-api-server endpoints)
-- Purpose: stores webhook endpoint registrations from external consumers (XMI, MSFT, etc.)

CREATE TABLE IF NOT EXISTS callback_registrations (

    id                  UUID            NOT NULL  DEFAULT gen_random_uuid(),

    -- Scope
    org_id              UUID            NOT NULL,
    cleanroom_id        UUID            NOT NULL,

    -- What to watch
    object_type         VARCHAR(50)     NOT NULL,
    -- 'QUESTION', 'DATA_CONNECTION', 'EXPORT_JOB', '*' (all types)

    object_id           UUID,
    -- NULL = subscribe to all objects of object_type in this cleanroom
    -- Non-null = subscribe to one specific object (e.g. one export job)

    monitored_fields    TEXT[]          NOT NULL  DEFAULT '{}',
    -- e.g. {'stage', 'status', 'runStatus', 'schemaSnapshot'}
    -- Empty array = all fields trigger delivery

    -- Delivery target
    callback_url        TEXT            NOT NULL,
    -- KMS envelope-encrypted at rest, decrypted only at delivery time
    -- Stored as: base64(KMS.encrypt(plaintext_url))

    -- Auth for delivery
    auth_config         JSONB           NOT NULL  DEFAULT '{}',
    -- KMS envelope-encrypted at rest
    -- Structure: { "authType": "BEARER" | "HMAC" | "NONE", "authValue": "<encrypted>" }

    -- HMAC signing
    signing_secret      VARCHAR(500)    NOT NULL,
    -- KMS envelope-encrypted at rest
    -- Format: whsec_<base64url-random-32-bytes>
    -- Exposed ONE TIME in the 201 Created response. Never again.

    -- State
    status              VARCHAR(20)     NOT NULL  DEFAULT 'ACTIVE',
    -- 'ACTIVE', 'PAUSED', 'SUSPENDED'
    -- SUSPENDED: set automatically when failure_count >= max_delivery_attempts

    failure_count       INTEGER         NOT NULL  DEFAULT 0,
    -- Incremented on each delivery failure. Reset to 0 on first success.

    max_delivery_attempts INTEGER        NOT NULL  DEFAULT 5,

    -- Metadata
    created_at          TIMESTAMPTZ     NOT NULL  DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL  DEFAULT NOW(),
    last_delivery_at    TIMESTAMPTZ,
    -- Null until first successful delivery

    created_by          VARCHAR(500)    NOT NULL,
    -- Email of the engineer who registered the callback

    -- Constraints
    CONSTRAINT pk_callback_registrations PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_cr_cleanroom_type
    ON callback_registrations (cleanroom_id, object_type, status);

CREATE INDEX IF NOT EXISTS idx_cr_org
    ON callback_registrations (org_id, status);
```

---

### Table 3: delivery_log — per-event delivery audit

```sql
-- Flyway migration: V2025_10_03__create_delivery_log.sql
-- Owned by: unhygienix service
-- Purpose: audit trail of every HTTP delivery attempt to a registered callback

CREATE TABLE IF NOT EXISTS delivery_log (

    id                  UUID            NOT NULL  DEFAULT gen_random_uuid(),

    -- What was delivered
    event_id            UUID            NOT NULL,
    -- FK → object_events.event_id (not enforced with FK constraint — object_events is append-only)

    registration_id     UUID            NOT NULL,
    -- FK → callback_registrations.id

    -- Delivery attempt details
    attempt_number      INTEGER         NOT NULL,
    -- 1-indexed. 1 = first attempt, 5 = fifth (final before DLQ)

    http_status         INTEGER,
    -- Null if connection timed out. 200/201 = success. 4xx = consumer rejected. 5xx = retry.

    latency_ms          INTEGER,
    -- Time from HTTP POST sent to response received. Null on timeout.

    error_message       TEXT,
    -- Null on success. Contains exception message or HTTP error body on failure.

    -- Timing
    delivered_at        TIMESTAMPTZ     NOT NULL  DEFAULT NOW(),

    -- Outcome
    outcome             VARCHAR(20)     NOT NULL,
    -- 'SUCCESS', 'FAILURE_RETRYABLE', 'FAILURE_TERMINAL', 'TIMEOUT', 'SKIPPED'
    -- SKIPPED: changedFields did not intersect monitoredFields — no delivery needed

    CONSTRAINT pk_delivery_log PRIMARY KEY (id)
);

CREATE INDEX IF NOT EXISTS idx_dl_event_id
    ON delivery_log (event_id);

CREATE INDEX IF NOT EXISTS idx_dl_registration_id
    ON delivery_log (registration_id, delivered_at DESC);

CREATE INDEX IF NOT EXISTS idx_dl_outcome_time
    ON delivery_log (outcome, delivered_at DESC)
    WHERE outcome IN ('FAILURE_RETRYABLE', 'FAILURE_TERMINAL', 'TIMEOUT');
-- Partial index — only failure rows, keeps index small
```

---

## Proto Definition (gRPC — unhygienix)

```protobuf
// File: proto/unhygienix/events.proto
// Service: unhygienix
// Consumed by: external-api-server (exposes as REST GET /v1/cleanrooms/{id}/events)
//              topgallant UI (calls directly via internal gRPC channel)

syntax = "proto3";

package com.habu.proto.unhygienix;

option java_multiple_files = true;
option java_package        = "com.habu.proto.unhygienix";

// ─── Request / Response ──────────────────────────────────────────────────────

message GetCleanroomEventsRequest {
    string cleanroom_id    = 1;  // required
    int64  since_cursor    = 2;  // 0 = from the beginning
    string object_type     = 3;  // "" = all types; "QUESTION" | "DATA_CONNECTION" | "EXPORT_JOB"
    string object_id       = 4;  // "" = all objects of object_type
    int32  limit           = 5;  // max 100, default 25
    string org_id          = 6;  // injected from JWT org_id claim by external-api-server
}

message GetCleanroomEventsResponse {
    repeated ObjectEvent events      = 1;
    int64                next_cursor = 2;  // pass as since_cursor in the next request
    bool                 has_more    = 3;  // false = consumer is caught up
    int32                total_count = 4;  // total matching events (for UI pagination)
}

// ─── Core event message ───────────────────────────────────────────────────────

message ObjectEvent {
    string event_id         = 1;   // UUID
    string cleanroom_id     = 2;   // UUID
    string org_id           = 3;   // UUID
    string object_type      = 4;   // QUESTION | DATA_CONNECTION | EXPORT_JOB
    string object_id        = 5;   // UUID of the mutated entity
    string object_name      = 6;   // human-readable name at time of event
    string event_type       = 7;   // com.habu.cleanroom.<type>.<action>
    string change_type      = 8;   // CREATED | UPDATED | DELETED | SCHEMA_CHANGED
    string changed_fields   = 9;   // JSONB serialized as string (diff payload)
    string context_fields   = 10;  // JSONB serialized as string (snapshot context)
    string performed_by     = 11;  // email or system:<service-name>
    int32  schema_version   = 12;  // 1 (bumped on breaking change)
    string idempotency_key  = 13;  // SHA-256 dedup key
    string event_time       = 14;  // RFC 3339 UTC string: 2026-02-05T04:18:35.095472Z
    int64  cursor_position  = 15;  // monotonic cursor for pagination
}

// ─── Service definition ───────────────────────────────────────────────────────

service CleanroomEventService {

    // Pull: cursor-based paging. Called by UI (internal) and external-api-server (external REST).
    rpc GetCleanroomEvents (GetCleanroomEventsRequest)
        returns (GetCleanroomEventsResponse);

    // Server-streaming: long-poll variant for internal consumers that want real-time push.
    // Client sends one request; server streams events as they arrive (internal use only).
    rpc StreamCleanroomEvents (GetCleanroomEventsRequest)
        returns (stream ObjectEvent);
}
```

---

## JSON Schema — CloudEvents data payload (schema registry)

This is what `schemaurl` in each CloudEvents envelope points to.
Consumers SHOULD validate inbound payloads against this. `schemaVersion` is the migration key.

```json
{
  "$schema":     "https://json-schema.org/draft/2020-12/schema",
  "$id":         "https://schema.habu.com/events/v1/cleanroom_object_event.json",
  "title":       "HabuCleanroomObjectEvent",
  "description": "CloudEvents data payload for all cleanroom object mutations. schemaVersion=1.",
  "type":        "object",

  "required": [
    "orgId", "cleanroomId", "objectType", "objectId", "objectName",
    "changeType", "changedFields", "performedBy", "schemaVersion", "cursor"
  ],

  "properties": {

    "orgId": {
      "type":        "string",
      "format":      "uuid",
      "description": "Organization that owns the cleanroom.",
      "examples":    ["02617c50-a923-4877-a968-6465d5d2baaa"]
    },

    "cleanroomId": {
      "type":    "string",
      "format":  "uuid",
      "examples":["cr-cleanroom-uuid-here"]
    },

    "objectType": {
      "type": "string",
      "enum": ["QUESTION", "DATA_CONNECTION", "EXPORT_JOB"],
      "description": "Type of cleanroom entity that was mutated."
    },

    "objectId": {
      "type":    "string",
      "format":  "uuid",
      "description": "ID of the specific entity instance (question, data connection, export job).",
      "examples": [
        "c7de5be7-9b8e-42bc-83ff-3ecaa7a454a4",
        "d1351401-9471-4c6b-b4e6-93b319c11125",
        "97b6cf60-f8be-48aa-b7a0-ec112c1fb801"
      ]
    },

    "objectName": {
      "type":        "string",
      "description": "Human-readable name of the entity at time of event.",
      "examples":    ["TestGCSnetwork / Q1", "cvs_lcr-CMX_DE_COMBINED_TXN_V"]
    },

    "changeType": {
      "type": "string",
      "enum": ["CREATED", "UPDATED", "DELETED", "SCHEMA_CHANGED"],
      "description": "High-level mutation classification."
    },

    "changedFields": {
      "type":        "object",
      "description": "Structural diff. Each key is a field name. Value is {from, to} or nested diff.",
      "additionalProperties": {
        "oneOf": [
          {
            "type": "object",
            "required": ["from", "to"],
            "properties": {
              "from": { "description": "Value before the mutation. Null for CREATED events." },
              "to":   { "description": "Value after the mutation.  Null for DELETED events." }
            }
          },
          {
            "type":        "object",
            "description": "Nested diff for structural fields (e.g. schemaSnapshot, dimensions)."
          }
        ]
      },
      "examples": [
        {
          "stage": { "from": "CONFIGURATION_COMPLETE", "to": "MAPPING_REQUIRED" }
        },
        {
          "runStatus":     { "from": "RUNNING",  "to": "COMPLETED" },
          "jobLastRunTime":{ "from": null,        "to": "2025-10-08T08:58:56.952745Z" }
        },
        {
          "schemaSnapshot": {
            "fieldsChanged": [
              { "fieldName": "transaction_amount",
                "fieldFrom": { "type": "FLOAT64", "nullable": true },
                "fieldTo":   { "type": "STRING",  "nullable": true } }
            ],
            "fieldsAdded":   [],
            "fieldsRemoved": []
          }
        }
      ]
    },

    "context": {
      "type":        "object",
      "description": "Immutable snapshot of contextual fields. NOT a diff — these did not change.",
      "properties": {
        "dataSourceName":     { "type": ["string", "null"] },
        "partnerName":        { "type": ["string", "null"] },
        "partnerAccountId":   { "type": ["string", "null"], "format": "uuid" },
        "questionId":         { "type": ["string", "null"], "format": "uuid" },
        "questionDisplayName":{ "type": ["string", "null"] },
        "exportDestination":  { "type": ["string", "null"] },
        "durationSeconds":    { "type": ["integer", "null"] },
        "sourceTable":        { "type": ["string", "null"] },
        "sourceDataset":      { "type": ["string", "null"] },
        "projectId":          { "type": ["string", "null"] }
      }
    },

    "performedBy": {
      "type":        "string",
      "description": "Actor. Human email or system:<service-name> for automated mutations.",
      "examples":    ["sreekar.s@liveramp.com", "system:cronos-export-worker", "system:data-import-service"]
    },

    "schemaVersion": {
      "type":        "integer",
      "minimum":     1,
      "description": "Schema version of this data payload. Bumped on breaking changes. Consumers MUST handle unknown future versions gracefully.",
      "examples":    [1]
    },

    "idempotencyKey": {
      "type":        "string",
      "description": "SHA-256(orgId+objectId+eventType+eventTime). Consumers use this to deduplicate at-least-once delivery.",
      "examples":    ["sha256-9e107d9d372bb6826bd81d3542a419d6"]
    },

    "cursor": {
      "type":        "string",
      "description": "Opaque base64url cursor. Pass as ?since= in the next GET /events call to page forward.",
      "examples":    ["eyJsYXN0X2N1cnNvciI6NDgyNX0="]
    }
  },

  "additionalProperties": false,

  "$defs": {
    "schemaVersionHistory": {
      "description": "Migration notes per schemaVersion bump.",
      "1": "Initial version. Fields: orgId, cleanroomId, objectType, objectId, objectName, changeType, changedFields, context, performedBy, schemaVersion, idempotencyKey, cursor.",
      "2_planned": "Will add: cleanroomName (string). Additive — v1 consumers unaffected."
    }
  }
}
```

---

## Schema summary table (one-liner for TLM whiteboard)

| Component | What it is | Where it lives |
|---|---|---|
| `object_events` | Append-only PostgreSQL table. One row per mutation. Never updated. | unhygienix DB |
| `callback_registrations` | Webhook consumer registry. One row per `POST /callbacks`. | unhygienix DB |
| `delivery_log` | Per-attempt delivery audit. Queryable SLA evidence. | unhygienix DB |
| `CleanroomEventService` proto | gRPC definition for `GetCleanroomEvents` + `StreamCleanroomEvents`. | unhygienix service |
| CloudEvents envelope | CNCF v1.0 wrapper around every payload. Fields: `specversion`, `id`, `source`, `type`, `time`, `data`. | JSON over HTTPS / gRPC |
| JSON Schema | Machine-readable contract at `schemaurl`. Consumers validate payloads against it. | Habu schema registry |
| `cursor_position` SEQUENCE | Monotonically increasing PostgreSQL sequence. Clients pass `?since=<cursor>` to page. | unhygienix DB |
| `idempotency_key` | SHA-256 of (orgId + objectId + eventType + eventTime). Prevents duplicate rows on retry. | `object_events` column |