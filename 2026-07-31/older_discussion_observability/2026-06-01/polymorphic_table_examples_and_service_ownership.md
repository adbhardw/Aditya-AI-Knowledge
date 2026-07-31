# Polymorphic object_events Table — Concrete Examples + Service Ownership Decision
**Date:** 2026-06-01
**Context:** DV-13856 — concrete row-level examples per object type + where the table lives
**Author:** Aditya Bhardwaj

---

## The Table Schema (reminder)

```sql
CREATE TABLE object_events (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    spec_version     VARCHAR(10)  NOT NULL DEFAULT '1.0',
    source           VARCHAR      NOT NULL,   -- urn:habu:cleanroom:{cleanroom_id}
    type             VARCHAR      NOT NULL,   -- com.habu.cleanroom.{obj_type}.{change}
    org_id           UUID         NOT NULL,
    cleanroom_id     UUID         NOT NULL,
    object_type      VARCHAR      NOT NULL,   -- QUESTION | DATA_CONNECTION | EXPORT_JOB
    object_id        UUID         NOT NULL,
    object_name      VARCHAR,                 -- snapshot at event time
    change_type      VARCHAR      NOT NULL,   -- CREATED | UPDATED | DELETED | STATUS_CHANGED
    changed_fields   JSONB,                   -- shape varies per object_type
    performed_by     VARCHAR,
    performed_by_type VARCHAR     NOT NULL DEFAULT 'USER',
    schema_version   INT          NOT NULL DEFAULT 1,
    idempotency_key  VARCHAR      UNIQUE,
    event_time       TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
```

All three object types use the SAME table. `object_type` is the discriminator.
Only `changed_fields` JSONB differs in shape. Everything else is identical columns.

---

## Event 1 — QUESTION: Dimensions Removed (unhygienix)

**Scenario:** Sarah removes `Customer_Email_Id` from the Adidas Shoe Purchase Question.
This fires from the `UpdateCleanRoomQuestion` handler in unhygienix.

**Proto fields involved:**
- `QuestionDimensions.name` (STRING)
- `QuestionDimensions.type` (UnhygienixFieldType → string representation)
- `QuestionDimensions.filterable` (bool)
- `QuestionDimensions.plottable` (bool)

**Row inserted into object_events:**

```
id                : evt-a1b2c3-uuid
spec_version      : 1.0
source            : urn:habu:cleanroom:cr-adidas-uuid
type              : com.habu.cleanroom.question.updated
org_id            : org-adidas-uuid
cleanroom_id      : cr-adidas-uuid
object_type       : QUESTION
object_id         : q-shoe-purchase-uuid
object_name       : "Shoe Purchase Analysis"
change_type       : UPDATED
changed_fields    : {
                      "dimensions": {
                        "removed": [
                          { "name": "Customer_Email_Id",
                            "type": "STRING",
                            "filterable": true,
                            "plottable": false }
                        ],
                        "added": [],
                        "current": [
                          { "name": "Ramp_ID",       "type": "STRING"  },
                          { "name": "Purchase_Date", "type": "DATE"    },
                          { "name": "Article_Id",    "type": "INTEGER" },
                          { "name": "Shoe_Name",     "type": "STRING"  }
                        ]
                      }
                    }
performed_by      : sarah@adidas.com
performed_by_type : USER
schema_version    : 1
idempotency_key   : q-shoe-purchase-uuid:UPDATED:1748736720000
event_time        : 2026-06-01T10:32:00Z
```

**CloudEvents envelope (what XMI receives via GET /events or webhook POST):**
```json
{
  "specversion": "1.0",
  "id": "evt-a1b2c3-uuid",
  "source": "urn:habu:cleanroom:cr-adidas-uuid",
  "type": "com.habu.cleanroom.question.updated",
  "time": "2026-06-01T10:32:00Z",
  "data": {
    "orgId": "org-adidas-uuid",
    "cleanroomId": "cr-adidas-uuid",
    "objectType": "QUESTION",
    "objectId": "q-shoe-purchase-uuid",
    "objectName": "Shoe Purchase Analysis",
    "changeType": "UPDATED",
    "changedFields": {
      "dimensions": {
        "removed": [{ "name": "Customer_Email_Id", "type": "STRING" }],
        "added":   [],
        "current": [
          { "name": "Ramp_ID",       "type": "STRING"  },
          { "name": "Purchase_Date", "type": "DATE"    },
          { "name": "Article_Id",    "type": "INTEGER" },
          { "name": "Shoe_Name",     "type": "STRING"  }
        ]
      }
    },
    "performedBy": "sarah@adidas.com",
    "performedByType": "USER",
    "schemaVersion": 1
  }
}
```

**What XMI does:** Detects `Customer_Email_Id` removed → disables any UI column that
expected it → alerts Adidas team before their dashboard breaks silently.

---

## Event 2 — DATA_CONNECTION: Field Type Changed (forebitt)

**Scenario:** `Amount` field type changes from `DOUBLE` (ForebittDataType=4) to
`STRING` (ForebittDataType=2) in a DataImportJob's FieldConfiguration.
This fires from forebitt's update handler.

**Proto fields involved (forebitt `FieldConfiguration`):**
- `fieldName` (string)
- `dataType` (ForebittDataType enum: DOUBLE=4, STRING=2, INTEGER=1, DATE=3...)
- `isPii` (bool)
- `isExcluded` (bool)
- `isFilterable` (bool)

**Row inserted into object_events:**

```
id                : evt-d4e5f6-uuid
spec_version      : 1.0
source            : urn:habu:cleanroom:cr-adidas-uuid
type              : com.habu.cleanroom.data_connection.updated
org_id            : org-adidas-uuid
cleanroom_id      : cr-adidas-uuid
object_type       : DATA_CONNECTION
object_id         : dc-adidas-purchase-uuid
object_name       : "Adidas_Purchase_Data_2025"
change_type       : UPDATED
changed_fields    : {
                      "fieldConfigurations": {
                        "typeChanges": [
                          {
                            "fieldName": "Amount",
                            "oldType":   "DOUBLE",
                            "newType":   "STRING"
                          }
                        ],
                        "added":   [],
                        "removed": [],
                        "current": [
                          { "fieldName": "Ramp_ID",
                            "dataType": "STRING",
                            "isPii": false,
                            "isExcluded": false,
                            "isFilterable": false },
                          { "fieldName": "Purchase_Date",
                            "dataType": "DATE",
                            "isPii": false,
                            "isExcluded": false,
                            "isFilterable": true },
                          { "fieldName": "Amount",
                            "dataType": "STRING",
                            "isPii": false,
                            "isExcluded": false,
                            "isFilterable": false },
                          { "fieldName": "Shoe_Name",
                            "dataType": "STRING",
                            "isPii": false,
                            "isExcluded": false,
                            "isFilterable": true }
                        ]
                      }
                    }
performed_by      : system
performed_by_type : SYSTEM
schema_version    : 1
idempotency_key   : dc-adidas-purchase-uuid:UPDATED:1748736900000
event_time        : 2026-06-01T10:35:00Z
```

**CloudEvents envelope:**
```json
{
  "specversion": "1.0",
  "id": "evt-d4e5f6-uuid",
  "type": "com.habu.cleanroom.data_connection.updated",
  "time": "2026-06-01T10:35:00Z",
  "data": {
    "objectType": "DATA_CONNECTION",
    "objectId": "dc-adidas-purchase-uuid",
    "objectName": "Adidas_Purchase_Data_2025",
    "changeType": "UPDATED",
    "changedFields": {
      "fieldConfigurations": {
        "typeChanges": [
          { "fieldName": "Amount", "oldType": "DOUBLE", "newType": "STRING" }
        ],
        "added": [],
        "removed": [],
        "current": [...]
      }
    },
    "performedBy": "system",
    "performedByType": "SYSTEM",
    "schemaVersion": 1
  }
}
```

**What XMI does:** Detects `Amount` type changed from DOUBLE to STRING →
surfaces warning on any Question using `SUM(Amount)` → prevents silent runtime failure.

---

## Event 3 — EXPORT_JOB: Status Changed (picanmix / forebitt flows)

**Scenario:** A `FlowNodeExportJob` status changes from `ACTIVE` to `PAUSED`.
(ForebittStatus: ACTIVE=2, PAUSED=3)

**Proto fields involved (forebitt `FlowNodeExportJob`):**
- `status` (string — "ACTIVE", "PAUSED")
- `channelStatus` (string)
- `name` (string)

**Row inserted into object_events:**

```
id                : evt-g7h8i9-uuid
spec_version      : 1.0
source            : urn:habu:cleanroom:cr-adidas-uuid
type              : com.habu.cleanroom.export_job.status_changed
org_id            : org-adidas-uuid
cleanroom_id      : cr-adidas-uuid
object_type       : EXPORT_JOB
object_id         : exp-adidas-uuid
object_name       : "Adidas Shoe Activation Export"
change_type       : STATUS_CHANGED
changed_fields    : {
                      "status": {
                        "old": "ACTIVE",
                        "new": "PAUSED"
                      },
                      "channelStatus": {
                        "old": "RUNNING",
                        "new": "PAUSED"
                      }
                    }
performed_by      : john@adidas.com
performed_by_type : USER
schema_version    : 1
idempotency_key   : exp-adidas-uuid:STATUS_CHANGED:1748737100000
event_time        : 2026-06-01T10:38:00Z
```

**CloudEvents envelope:**
```json
{
  "specversion": "1.0",
  "id": "evt-g7h8i9-uuid",
  "type": "com.habu.cleanroom.export_job.status_changed",
  "time": "2026-06-01T10:38:00Z",
  "data": {
    "objectType": "EXPORT_JOB",
    "objectId": "exp-adidas-uuid",
    "objectName": "Adidas Shoe Activation Export",
    "changeType": "STATUS_CHANGED",
    "changedFields": {
      "status":        { "old": "ACTIVE",  "new": "PAUSED" },
      "channelStatus": { "old": "RUNNING", "new": "PAUSED" }
    },
    "performedBy": "john@adidas.com",
    "performedByType": "USER",
    "schemaVersion": 1
  }
}
```

---

## Why Polymorphic Works — The Key Point

Same query for ALL three object types:
```sql
SELECT * FROM object_events
WHERE cleanroom_id = 'cr-adidas-uuid'
  AND org_id       = 'org-adidas-uuid'
  AND event_time   > '2026-06-01T10:00:00Z'
ORDER BY event_time DESC
LIMIT 50;
```

Returns QUESTION, DATA_CONNECTION, and EXPORT_JOB rows in one result set.
XMI reads `object_type` to determine how to parse `changed_fields`.
If `object_type = "QUESTION"` → parse `changedFields.dimensions`.
If `object_type = "DATA_CONNECTION"` → parse `changedFields.fieldConfigurations`.
If `object_type = "EXPORT_JOB"` → parse `changedFields.status`.

No JOIN. No UNION. One index on `(cleanroom_id, org_id, event_time DESC)`.

---

## Actual Dependency Graph (from go.mod files)

```
hank        → no domain deps (base library)
ignoramus   → no domain deps (proto only)
moonraker   → hank, ignoramus
forebitt    → hank, ignoramus, moonraker, postaldistrix, primage
picanmix    → forebitt, hank, ignoramus, moonraker, postaldistrix, primage, UNHYGIENIX
unhygienix  → forebitt, hank, ignoramus, moonraker, PICANMIX, postaldistrix, primage
postaldistrix → (imports none of the three — confirmed from go.mod)
```

Key findings:
- unhygienix ↔ picanmix: already a mutual dependency in published versions
- forebitt → nothing in the three (cleanest)
- postaldistrix: imported BY all three, imports NONE of them — perfect neutral service

Call matrix for a single RecordObjectEvent gRPC endpoint:
  Can forebitt  call unhygienix?   NO  — circular
  Can picanmix  call unhygienix?   YES — picanmix already imports unhygienix
  Can all three call postaldistrix? YES — all import it, it imports none of them
  Can all three call a new service? YES — no existing deps

---

## Service Ownership Decision — One Endpoint or Three?

**The problem:** Each object type lives in a different service.
- Questions → unhygienix
- Data Connections → forebitt
- Exports → picanmix / forebitt flows

Three options. Only one avoids circular dependencies AND avoids cursor hell.

### Option A: Table in unhygienix, forebitt/picanmix call unhygienix to write

BLOCKED: forebitt cannot call unhygienix — circular dependency.
picanmix CAN call unhygienix (already imports it), but forebitt cannot.
Ruled out because forebitt (DC events) cannot participate.

### Option B: Three tables, three endpoints, external-api-server aggregates

Cursor pagination across 3 independent DBs is unsolvable cleanly.
If since=T returns 10 question events and 0 DC events from separate DBs,
there is no deterministic merged cursor. Ruled out.

### Option C: Single gRPC endpoint in a NEUTRAL service (RECOMMENDED for MVP)

This is the user's proposed approach — one gRPC endpoint that all three services call.
The table lives in the neutral service.

```
forebitt DC change    → go neutralSvc.RecordObjectEvent(dcEvent)    ─┐
unhygienix Q change   → go neutralSvc.RecordObjectEvent(qEvent)     ─┼→ object_events
picanmix export chg   → go neutralSvc.RecordObjectEvent(exportEvt)  ─┘

external-api-server   → neutralSvc.GetCleanroomEvents(crId, since)
                      → GET /cleanrooms/{id}/events   ← XMI
```

Where does the neutral service live?
- postaldistrix: imported BY all three, imports NONE of them → can host the endpoint
- New dedicated service: cleanest, dedicated ownership, most future-proof
- NOT in unhygienix: forebitt cannot call back (circular)

The call from each service is a non-blocking goroutine:
```go
// In unhygienix UpdateCleanRoomQuestion handler
go func() {
    ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
    defer cancel()
    neutralSvc.RecordObjectEvent(ctx, event)  // non-blocking, mutation not affected
}()
```
This reuses the same "async with timeout" pattern as PublishEventAsyncWithRetry in hank.

### Option D: SNS fan-in consumer (previous recommendation — more infra)

All three publish to SNS → consumer writes to object_events.
Better resilience, but more moving parts (SNS + SQS + consumer).
Preferred if event volume is high or durability guarantees are critical.
Overkill for MVP.

---

## Direct gRPC vs SNS Consumer — Which is Actually Better?

| | Direct async gRPC (Option C) | SNS Consumer (Option D) |
|--|------------------------------|-------------------------|
| User request blocked? | NO (goroutine) | NO (sns.Publish ~1ms) |
| If event service is down? | Event lost (goroutine fails silently) | Event buffered in SQS, delivered when back |
| Event durability | Best-effort | At-least-once guaranteed |
| Infra required | New service + DB | SNS topic + SQS + consumer + DB |
| Simplicity | Simpler | More parts |
| Latency to appear in DB | ~milliseconds | 2–5 seconds |
| Adding new object type | 1 goroutine call | 1 SNS publish call |
| Industry standard for audit | Both acceptable | SNS preferred at scale |

**For MVP (DV-13856 observability):** Option C (direct async gRPC to neutral service)
is simpler to implement, faster to ship, and sufficient for the event volume expected.

**Switch to Option D** if: event volume exceeds hundreds/second, or the team needs
guaranteed at-least-once delivery for compliance reasons.

### Summary

| | Option A | Option B | Option C | Option D |
|-|----------|----------|----------|----------|
| Approach | unhygienix owns table | 3 tables, aggregate | neutral service gRPC | SNS fan-in |
| Circular dep? | YES — blocked | No | No | No |
| Cursor pagination | Simple | HARD | Simple | Simple |
| Infra complexity | Low | Medium | Medium | High |
| Durability | Strong | Strong | Best-effort | At-least-once |
| MVP recommendation | No | No | YES | For scale |
