# Event Schema Proposal — XMI Integration Pitch
**Date:** 2026-05-18
**Ticket:** DV-13856 | Clean Room Observability
**Author:** Aditya Bhardwaj
**Status:** Draft for XMI review

---

## What We Are Proposing

When a Clean Room object (Question, Data Connection) changes in Habu, XMI receives a structured
event describing exactly what changed, who changed it, and when.

Two consumption options — XMI picks what fits their stack:

| Option | How | Latency | Setup on XMI side |
|--------|-----|---------|-------------------|
| **A — Cursor API (pull)** | XMI calls our endpoint on a timer with a timestamp cursor | ~30–60s (polling interval) | Call an HTTPS API — no server needed |
| **B — Webhook (push)** | XMI registers an HTTPS URL; Habu calls it on every change | ~2–5s (async delivery) | Run an HTTPS endpoint that accepts inbound POSTs |

Both options return **the same event payload structure** — XMI writes the handler once.

---

## Option A — Cursor-Based Polling API

### Request

```
GET /cleanrooms/{cleanroomId}/events?since=2026-05-18T10:00:00Z&objectType=QUESTION

Authorization: Bearer <xmi-api-token>
```

### Query Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `since` | ISO 8601 timestamp | Yes | Return only events after this timestamp (XMI stores and advances this cursor) |
| `objectType` | `QUESTION` \| `DATA_CONNECTION` \| `ALL` | No | Filter by object type. Defaults to ALL. |
| `limit` | integer | No | Max events per page. Default 100, max 500. |
| `cursor` | string | No | Opaque pagination cursor returned in previous response for large result sets |

### Response Envelope

```json
{
  "events": [ ...see event objects below... ],
  "nextCursor": "eyJldmVudFRpbWUiOiIyMDI2LTA1LTE4VDEwOjMxOjQ1WiJ9",
  "hasMore": false
}
```

`nextCursor` — pass this as `cursor=` on the next call. Opaque string, do not parse.
`hasMore` — if `true`, call again immediately with `nextCursor` to get the rest.

---

## Option B — Webhook Registration (Push)

### Step 1: XMI registers a callback URL (one-time)

```
POST /cleanrooms/{cleanroomId}/callbacks

Authorization: Bearer <xmi-api-token>
Content-Type: application/json

{
  "objectType": "ALL",
  "callbackUrl": "https://xmi.liveramp.com/habu-events",
  "monitoredFields": ["dimensions", "status", "name", "outputFields"],
  "authConfig": {
    "authType": "BEARER",
    "authValue": "eyJhbGciOiJSUzI1..."
  }
}
```

### Step 2: Registration response (Habu returns a signing secret)

```json
{
  "id": "cb-456",
  "objectType": "ALL",
  "callbackUrl": "https://xmi.liveramp.com/habu-events",
  "monitoredFields": ["dimensions", "status", "name", "outputFields"],
  "signingSecret": "whsec_a3f9c2b1d4e8f2...",
  "createdAt": "2026-05-18T10:00:00Z"
}
```

**XMI stores `signingSecret`** — used to verify every inbound POST is genuinely from Habu.

### Step 3: Habu calls XMI on every change

```
POST https://xmi.liveramp.com/habu-events

Authorization:     Bearer eyJhbGciOiJSUzI1...    ← auth token XMI provided at registration
Content-Type:      application/json
X-Habu-Signature:  sha256=a3f9c2b1...             ← HMAC of body using signingSecret
X-Habu-Event-Id:   evt-901-uuid                   ← stable ID for idempotency
X-Habu-Timestamp:  1747562400                     ← unix epoch; reject if >300s old
```

Body: same event object structure as the cursor API (see below).

XMI responds `200 OK` to acknowledge. Habu retries on `4xx`/`5xx` with backoff.

---

## Event Object Structure (shared by both options)

### Common Fields (all event types)

```json
{
  "eventId":      "evt-901-uuid",
  "eventType":    "UPDATED",
  "objectType":   "QUESTION",
  "objectId":     "q-123-abc",
  "objectName":   "Revenue Analysis",
  "cleanroomId":  "cr-abc-xyz",
  "orgId":        "org-liveramp-uuid",
  "performedBy":  "sarah@acme.com",
  "eventTime":    "2026-05-18T10:32:00Z",
  "changedFields": { ...varies by event type, see scenarios below... }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `eventId` | UUID | Stable unique ID. Use for idempotency — deduplicate on this if Habu delivers twice. |
| `eventType` | enum | `CREATED`, `UPDATED`, `DELETED`, `STATUS_CHANGED` |
| `objectType` | enum | `QUESTION`, `DATA_CONNECTION` |
| `objectId` | UUID | Habu's internal ID for the object |
| `objectName` | string | Name of the object **at the time of the event** (preserved even on delete) |
| `cleanroomId` | UUID | Clean room this object belongs to |
| `orgId` | UUID | Org that owns this event (for multi-tenant filtering) |
| `performedBy` | string | Email of the user who made the change, or `"system"` for automated changes |
| `eventTime` | ISO 8601 | When the change happened in Habu |
| `changedFields` | object | Field-level diff — structure varies by event type (see below) |

---

## Scenario A — Question: Output Columns Removed

**Trigger:** A user removes `customer_segment` and `channel` from a Question's output dimensions.

```json
{
  "eventId":     "evt-901",
  "eventType":   "UPDATED",
  "objectType":  "QUESTION",
  "objectId":    "q-123",
  "objectName":  "Revenue Analysis",
  "cleanroomId": "cr-abc",
  "orgId":       "org-liveramp",
  "performedBy": "sarah@acme.com",
  "eventTime":   "2026-05-18T10:32:00Z",
  "changedFields": {
    "dimensions": {
      "removed": ["customer_segment", "channel"],
      "added":   [],
      "current": ["revenue", "region", "date"]
    }
  }
}
```

**What XMI should do:** Any dashboard or pipeline expecting `customer_segment` or `channel`
in the output will now fail. XMI can proactively alert users or disable dependent features.

---

## Scenario B — Question: Dataset Assignment Swapped

**Trigger:** The dataset powering a Question is switched from `Q1_Sales_2026` to `Q2_Sales_2026`.

```json
{
  "eventId":     "evt-902",
  "eventType":   "UPDATED",
  "objectType":  "QUESTION",
  "objectId":    "q-123",
  "objectName":  "Revenue Analysis",
  "cleanroomId": "cr-abc",
  "orgId":       "org-liveramp",
  "performedBy": "john@acme.com",
  "eventTime":   "2026-05-18T11:00:00Z",
  "changedFields": {
    "datasetAssignments": {
      "old": "Q1_Sales_2026",
      "new": "Q2_Sales_2026"
    }
  }
}
```

---

## Scenario C — Question: Status Changed

**Trigger:** A Question moves from `DRAFT` to `PUBLISHED`.

```json
{
  "eventId":     "evt-903",
  "eventType":   "STATUS_CHANGED",
  "objectType":  "QUESTION",
  "objectId":    "q-456",
  "objectName":  "Attribution Model",
  "cleanroomId": "cr-abc",
  "orgId":       "org-liveramp",
  "performedBy": "sarah@acme.com",
  "eventTime":   "2026-05-18T13:00:00Z",
  "changedFields": {
    "status": {
      "old": "DRAFT",
      "new": "PUBLISHED"
    }
  }
}
```

---

## Scenario D — Question: Deleted

**Trigger:** A Question is permanently deleted.

```json
{
  "eventId":     "evt-904",
  "eventType":   "DELETED",
  "objectType":  "QUESTION",
  "objectId":    "q-789",
  "objectName":  "Lookalike Segments",
  "cleanroomId": "cr-abc",
  "orgId":       "org-liveramp",
  "performedBy": "admin@liveramp.com",
  "eventTime":   "2026-05-18T16:45:00Z",
  "changedFields": null
}
```

**Note:** `objectName` is preserved even on delete so XMI can display a meaningful message
to the user ("The question 'Lookalike Segments' was deleted").

---

## Scenario E — Data Connection: Field Type Changed

**Trigger:** `purchase_count` field type changes from `Integer` to `String`.

```json
{
  "eventId":     "evt-905",
  "eventType":   "UPDATED",
  "objectType":  "DATA_CONNECTION",
  "objectId":    "dc-456",
  "objectName":  "CRM_Import",
  "cleanroomId": "cr-abc",
  "orgId":       "org-liveramp",
  "performedBy": "john@acme.com",
  "eventTime":   "2026-05-18T11:15:00Z",
  "changedFields": {
    "outputFields": {
      "purchase_count": {
        "oldType": "INTEGER",
        "newType": "STRING"
      }
    }
  }
}
```

**What XMI should do:** Any SQL using `SUM(purchase_count)` will fail at runtime.
XMI can surface a warning before the next query run.

---

## Scenario F — Data Connection: Fields Added and Removed

**Trigger:** Schema update adds a new field `loyalty_score` and removes `churn_flag`.

```json
{
  "eventId":     "evt-906",
  "eventType":   "UPDATED",
  "objectType":  "DATA_CONNECTION",
  "objectId":    "dc-456",
  "objectName":  "CRM_Import",
  "cleanroomId": "cr-abc",
  "orgId":       "org-liveramp",
  "performedBy": "system",
  "eventTime":   "2026-05-18T14:00:00Z",
  "changedFields": {
    "outputFields": {
      "added":   [{ "name": "loyalty_score", "type": "FLOAT" }],
      "removed": [{ "name": "churn_flag",    "type": "BOOLEAN" }],
      "current": [
        { "name": "customer_id",   "type": "STRING" },
        { "name": "purchase_count","type": "INTEGER" },
        { "name": "loyalty_score", "type": "FLOAT" }
      ]
    }
  }
}
```

---

## Questions for XMI (to ask on the call)

1. **Schema fit** — Do these field names and structure match what your system can consume,
   or do you need a different shape for `changedFields`?

2. **Which events matter most?** — Column removals and deletes are highest-priority for us to ship first.
   Are there event types here you would never consume? Any missing?

3. **Pull vs push** — Does Option A (cursor API, you poll us) work for your team,
   or do you need sub-second push (Option B webhook)?
   Do you have an HTTPS endpoint you could expose for inbound POSTs?

4. **Polling frequency** — If cursor API, what interval is acceptable for your use case?
   (30s? 60s? We want to size our DB index accordingly.)

5. **Idempotency** — Are you able to deduplicate on `eventId` on your side,
   or do you need us to guarantee exactly-once?

6. **`objectName` on delete** — Is preserving the name at deletion time enough,
   or do you need us to return the full object snapshot at the time it was deleted?

---

## Open Items (to resolve before V1 build)

- [ ] XMI confirms: cursor API or webhook?
- [ ] XMI confirms: `changedFields` structure works as-is or needs adjustment
- [ ] Agree on which object types are in scope for first integration (Questions only, or DCs too?)
- [ ] Agree on polling interval / SLA if cursor API chosen
- [ ] Confirm org_id is sufficient for tenant filtering on XMI's side
