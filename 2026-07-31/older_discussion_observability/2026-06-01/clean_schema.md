# Clean Schema — changedFields Uniform Design
**Date:** 2026-06-01
**Author:** Aditya Bhardwaj
**Rule:** One shape for all object types — `{ "field": { "from": X, "to": Y } }`. No exceptions.

---

## The Three Canonical Examples

### Example 1 — DATA_CONNECTION: stage moved MAPPING_REQUIRED → CONFIGURATION_COMPLETE

```json
{
  "specversion":     "1.0",
  "id":              "evt-a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "source":          "urn:habu:cleanroom:cr-abc",
  "type":            "com.habu.cleanroom.data_connection.updated",
  "time":            "2026-02-05T04:18:35.095472Z",
  "datacontenttype": "application/json",
  "data": {
    "objectType":  "DATA_CONNECTION",
    "objectId":    "97b6cf60-f8be-48aa-b7a0-ec112c1fb801",
    "objectName":  "cvs_lcr-modified_txns_hq",
    "changeType":  "UPDATED",
    "changedFields": {
      "stage": {
        "from": "MAPPING_REQUIRED",
        "to":   "CONFIGURATION_COMPLETE"
      }
    },
    "performedBy":   "sreekar.s@liveramp.com",
    "schemaVersion": 1
  }
}
```

---

### Example 2 — QUESTION: SQL query text changed

```json
{
  "specversion":     "1.0",
  "id":              "evt-b2c3d4e5-f6a7-8901-bcde-f12345678901",
  "source":          "urn:habu:cleanroom:cr-abc",
  "type":            "com.habu.cleanroom.question.updated",
  "time":            "2026-05-12T10:32:00Z",
  "datacontenttype": "application/json",
  "data": {
    "objectType":  "QUESTION",
    "objectId":    "d94ccaeb-d0f9-4665-8a42-378f9f030f57",
    "objectName":  "Revenue Analysis",
    "changeType":  "UPDATED",
    "changedFields": {
      "sqlQuery": {
        "from": "SELECT ramp_id, purchase_date FROM adidas_data WHERE amount > 100",
        "to":   "SELECT ramp_id, purchase_date, shoe_category FROM adidas_data WHERE amount > 50"
      }
    },
    "performedBy":   "sarah@acme.com",
    "schemaVersion": 1
  }
}
```

---

### Example 3 — EXPORT_JOB: destination path changed

```json
{
  "specversion":     "1.0",
  "id":              "evt-c3d4e5f6-a7b8-9012-cdef-123456789012",
  "source":          "urn:habu:cleanroom:cr-abc",
  "type":            "com.habu.cleanroom.export_job.updated",
  "time":            "2026-05-15T08:45:00Z",
  "datacontenttype": "application/json",
  "data": {
    "objectType":  "EXPORT_JOB",
    "objectId":    "c7de5be7-9b8e-42bc-83ff-3ecaa7a454a4",
    "objectName":  "TestGCSnetwork / Q1",
    "changeType":  "UPDATED",
    "changedFields": {
      "destination": {
        "from": "s3://a/a.bcs",
        "to":   "s3://b/b.abc"
      }
    },
    "performedBy":   "sreekar.s@liveramp.com",
    "schemaVersion": 1
  }
}
```

---

## Why One Shape for All Three

Consumer code that reads `changedFields` is **identical** for all three object types — zero branching:

```java
// Works for DATA_CONNECTION, QUESTION, and EXPORT_JOB without a switch/if
for (Map.Entry<String, JsonNode> entry : changedFields.fields()) {
    String fieldName = entry.getKey();            // "stage" | "sqlQuery" | "destination"
    String fromValue = entry.getValue().get("from").asText();
    String toValue   = entry.getValue().get("to").asText();
    log.info("Field '{}' changed: '{}' → '{}'", fieldName, fromValue, toValue);
}
```

If shapes differed per object type, every consumer would need:

```java
// What you must write if shapes are inconsistent — DON'T do this
switch (event.getObjectType()) {
    case "DATA_CONNECTION": parseOldNewShape(changedFields);   break;
    case "QUESTION":        parseFromToShape(changedFields);   break;
    case "EXPORT_JOB":      parseRemovedAddedShape(changedFields); break;
}
```

Stripe, GitHub Webhooks, and Salesforce Platform Events all use the flat
`{ field: { from, to } }` shape — the consumer doesn't need to know
what kind of object changed to parse the diff.

---

## Proto Schema

```protobuf
// File: proto/unhygienix/events.proto
// Package: com.habu.proto.unhygienix

syntax = "proto3";
package com.habu.proto.unhygienix;

option java_multiple_files = true;
option java_package        = "com.habu.proto.unhygienix";

// ── Core diff value: every changed field carries from + to ──────────────────

message FieldDiff {
    string from = 1;   // serialized value before mutation (JSON string, number, or null)
    string to   = 2;   // serialized value after  mutation (JSON string, number, or null)
    // Arrays and objects are serialized to JSON string
    // e.g. for a list field: from = "[\"revenue\",\"region\"]"
    //                        to   = "[\"revenue\",\"region\",\"date\"]"
}

// ── ObjectEvent: one row in object_events table ─────────────────────────────

message ObjectEvent {
    string event_id         = 1;   // UUID — idempotency key
    string cleanroom_id     = 2;   // UUID
    string org_id           = 3;   // UUID — injected from JWT, never trusted from caller
    string object_type      = 4;   // "QUESTION" | "DATA_CONNECTION" | "EXPORT_JOB"
    string object_id        = 5;   // UUID of the mutated entity
    string object_name      = 6;   // human-readable name at time of event
    string event_type       = 7;   // com.habu.cleanroom.<object_type>.<action>
    string change_type      = 8;   // "CREATED" | "UPDATED" | "DELETED"

    // changedFields: key = field name, value = { from, to }
    // Uniform shape for ALL object types — no per-type branching in consumers
    // Examples:
    //   DATA_CONNECTION: { "stage":       { from: "MAPPING_REQUIRED", to: "CONFIGURATION_COMPLETE" } }
    //   QUESTION:        { "sqlQuery":    { from: "SELECT ...",        to: "SELECT ..." } }
    //   EXPORT_JOB:      { "destination": { from: "s3://a/a.bcs",     to: "s3://b/b.abc" } }
    map<string, FieldDiff> changed_fields = 9;

    string performed_by     = 10;  // email or "system:<service-name>"
    int32  schema_version   = 11;  // 1 — bumped only on breaking changes
    string idempotency_key  = 12;  // SHA-256(org_id + object_id + event_type + event_time)
    string event_time       = 13;  // RFC 3339 UTC: 2026-02-05T04:18:35.095472Z
    int64  cursor_position  = 14;  // monotonically increasing PostgreSQL sequence
    string cursor           = 15;  // opaque base64url cursor for ?since= pagination
}

// ── Request / Response ──────────────────────────────────────────────────────

message GetCleanroomEventsRequest {
    string cleanroom_id = 1;  // required
    int64  since_cursor = 2;  // 0 = from beginning
    string object_type  = 3;  // "" = all; "QUESTION" | "DATA_CONNECTION" | "EXPORT_JOB"
    string object_id    = 4;  // "" = all objects of object_type
    int32  limit        = 5;  // max 100, default 25
    string org_id       = 6;  // injected from JWT org_id claim by external-api-server
}

message GetCleanroomEventsResponse {
    repeated ObjectEvent events      = 1;
    int64                next_cursor = 2;  // pass as since_cursor in next request
    bool                 has_more    = 3;  // false = consumer is caught up
    int32                total_count = 4;  // for UI pagination
}

// ── Service ─────────────────────────────────────────────────────────────────

service CleanroomEventService {
    // Cursor-based pull: used by Activity Feed UI and external REST API
    rpc GetCleanroomEvents (GetCleanroomEventsRequest)
        returns (GetCleanroomEventsResponse);

    // Server-streaming: internal real-time consumers only (not exposed externally)
    rpc StreamCleanroomEvents (GetCleanroomEventsRequest)
        returns (stream ObjectEvent);
}
```

---

## OpenAPI / YAML Schema

```yaml
# File: openapi/events.yaml
# Endpoint: GET /v1/cleanrooms/{cleanroomId}/events
# Auth: Bearer JWT (org_id claim auto-injected — consumer sees only their org's events)

openapi: "3.1.0"
info:
  title: Habu Cleanroom Events API
  version: "1"
  description: >
    Cursor-based pull API for cleanroom object mutation events.
    Envelope follows CNCF CloudEvents v1.0 — natively consumed by
    GCP Eventarc, Azure Event Grid, and AWS EventBridge without transformation.

paths:
  /v1/cleanrooms/{cleanroomId}/events:
    get:
      summary: Get cleanroom events (cursor-based)
      operationId: getCleanroomEvents
      parameters:
        - name: cleanroomId
          in: path
          required: true
          schema: { type: string, format: uuid }
        - name: since
          in: query
          description: Opaque cursor from previous response. Omit to start from beginning.
          schema: { type: string }
          example: "eyJsYXN0X2N1cnNvciI6NDgyNX0="
        - name: objectType
          in: query
          description: Filter by object type. Omit for all types.
          schema:
            type: string
            enum: [QUESTION, DATA_CONNECTION, EXPORT_JOB]
        - name: limit
          in: query
          schema: { type: integer, minimum: 1, maximum: 100, default: 25 }
      responses:
        "200":
          description: Success
          headers:
            ETag:
              description: Cursor fingerprint for conditional GET (304 on no new events)
              schema: { type: string }
            X-Next-Cursor:
              description: Same as response body nextCursor. Convenience header.
              schema: { type: string }
            X-RateLimit-Limit:
              schema: { type: integer }
            X-RateLimit-Remaining:
              schema: { type: integer }
            X-RateLimit-Reset:
              description: Unix timestamp when the rate-limit window resets
              schema: { type: integer }
          content:
            application/cloudevents-batch+json:
              schema:
                type: object
                required: [events, nextCursor, hasMore]
                properties:
                  events:
                    type: array
                    items:
                      $ref: "#/components/schemas/CloudEvent"
                  nextCursor:
                    type: string
                    description: Pass as ?since= in the next request.
                    example: "eyJsYXN0X2N1cnNvciI6NDgyNX0="
                  hasMore:
                    type: boolean
                    description: false means the consumer is fully caught up.
                  totalCount:
                    type: integer
                    description: Total matching events (for UI pagination display).
        "304":
          description: No new events since the ETag cursor. Body is empty.
        "429":
          description: Rate limit exceeded.
          headers:
            Retry-After:
              schema: { type: integer }

components:
  schemas:

    # ── CNCF CloudEvents v1.0 envelope ────────────────────────────────────────
    CloudEvent:
      type: object
      required:
        - specversion
        - id
        - source
        - type
        - time
        - datacontenttype
        - data
      properties:
        specversion:
          type: string
          enum: ["1.0"]
        id:
          type: string
          format: uuid
          description: Unique event ID. Use for deduplication.
          example: "evt-a1b2c3d4-e5f6-7890-abcd-ef1234567890"
        source:
          type: string
          description: URN of the originating cleanroom.
          example: "urn:habu:cleanroom:cr-abc"
        type:
          type: string
          description: Event type. Pattern — com.habu.cleanroom.<objectType>.<action>
          example: "com.habu.cleanroom.data_connection.updated"
          enum:
            - com.habu.cleanroom.question.created
            - com.habu.cleanroom.question.updated
            - com.habu.cleanroom.question.deleted
            - com.habu.cleanroom.data_connection.created
            - com.habu.cleanroom.data_connection.updated
            - com.habu.cleanroom.data_connection.deleted
            - com.habu.cleanroom.export_job.created
            - com.habu.cleanroom.export_job.updated
            - com.habu.cleanroom.export_job.run_started
            - com.habu.cleanroom.export_job.run_completed
            - com.habu.cleanroom.export_job.run_failed
            - com.habu.cleanroom.export_job.deleted
        time:
          type: string
          format: date-time
          description: RFC 3339 UTC timestamp of the mutation.
          example: "2026-02-05T04:18:35.095472Z"
        datacontenttype:
          type: string
          enum: ["application/json"]
        schemaurl:
          type: string
          format: uri
          description: JSON Schema URL for the data payload. Use to validate.
          example: "https://schema.habu.com/events/v1/cleanroom_object_event.json"
        traceparent:
          type: string
          description: W3C Trace Context header. Correlate with Habu's originating trace.
          example: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
        data:
          $ref: "#/components/schemas/ObjectEventData"

    # ── Event data payload — uniform shape for all three object types ──────────
    ObjectEventData:
      type: object
      required:
        - orgId
        - cleanroomId
        - objectType
        - objectId
        - objectName
        - changeType
        - changedFields
        - performedBy
        - schemaVersion
        - cursor
      properties:

        orgId:
          type: string
          format: uuid
          example: "02617c50-a923-4877-a968-6465d5d2baaa"

        cleanroomId:
          type: string
          format: uuid
          example: "cr-abc"

        objectType:
          type: string
          enum: [QUESTION, DATA_CONNECTION, EXPORT_JOB]

        objectId:
          type: string
          format: uuid
          examples:
            dataConnection: "97b6cf60-f8be-48aa-b7a0-ec112c1fb801"
            question:       "d94ccaeb-d0f9-4665-8a42-378f9f030f57"
            exportJob:      "c7de5be7-9b8e-42bc-83ff-3ecaa7a454a4"

        objectName:
          type: string
          examples:
            dataConnection: "cvs_lcr-modified_txns_hq"
            question:       "Revenue Analysis"
            exportJob:      "TestGCSnetwork / Q1"

        changeType:
          type: string
          enum: [CREATED, UPDATED, DELETED]

        # ── changedFields: THE uniform diff shape ────────────────────────────
        # Same structure regardless of objectType.
        # Key   = field name that changed
        # Value = { from: <old value>, to: <new value> }
        changedFields:
          type: object
          description: >
            Structural diff. Each key is a field that changed.
            Value is always { from, to }. Uniform for ALL object types.
            Arrays and nested objects are serialized to JSON string.
          additionalProperties:
            $ref: "#/components/schemas/FieldDiff"
          examples:

            dataConnectionStageChange:
              summary: DATA_CONNECTION — stage moved MAPPING_REQUIRED → CONFIGURATION_COMPLETE
              value:
                stage:
                  from: "MAPPING_REQUIRED"
                  to:   "CONFIGURATION_COMPLETE"

            questionSqlChange:
              summary: QUESTION — SQL query text changed
              value:
                sqlQuery:
                  from: "SELECT ramp_id, purchase_date FROM adidas_data WHERE amount > 100"
                  to:   "SELECT ramp_id, purchase_date, shoe_category FROM adidas_data WHERE amount > 50"

            exportJobDestinationChange:
              summary: EXPORT_JOB — destination path changed
              value:
                destination:
                  from: "s3://a/a.bcs"
                  to:   "s3://b/b.abc"

        performedBy:
          type: string
          description: Human email or "system:<service-name>" for automated mutations.
          examples:
            human: "sreekar.s@liveramp.com"
            system: "system:cronos-export-worker"

        schemaVersion:
          type: integer
          minimum: 1
          description: Bumped only on breaking changes. Consumers MUST handle unknown future versions.
          example: 1

        idempotencyKey:
          type: string
          description: SHA-256(orgId+objectId+eventType+eventTime). Use to deduplicate at-least-once delivery.
          example: "sha256-9e107d9d372bb6826bd81d3542a419d6"

        cursor:
          type: string
          description: Opaque base64url cursor. Pass as ?since= in the next request.
          example: "eyJsYXN0X2N1cnNvciI6NDgyNX0="

    # ── FieldDiff: the one reusable diff value ───────────────────────────────
    FieldDiff:
      type: object
      required: [from, to]
      description: >
        Before/after value for one changed field.
        from = value before mutation. to = value after mutation.
        Null string "null" used for CREATED (from) and DELETED (to) events.
      properties:
        from:
          description: Value before the mutation.
          example: "MAPPING_REQUIRED"
        to:
          description: Value after the mutation.
          example: "CONFIGURATION_COMPLETE"
      example:
        from: "MAPPING_REQUIRED"
        to:   "CONFIGURATION_COMPLETE"
```
