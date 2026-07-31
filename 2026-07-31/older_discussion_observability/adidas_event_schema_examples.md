# Event Schema Examples — Adidas Clean Room
**Date:** 2026-05-18
**Context:** DV-13856 — sample payloads using Adidas purchase data to illustrate the event contract
**Data fields in scope:** Ramp_ID, Customer_Email_Id, Purchase_Date, Article_Id, Amount, Shoe_Name

---

## Setup — What the Clean Room Looks Like

```
Clean Room:  Adidas x LiveRamp — Shoe Purchase Analytics
Org:         Adidas (org-adidas-uuid)
Questions:   Analyses built on top of Adidas purchase data
Data Connections: Adidas_Purchase_Data_2025 (the CSV dataset)
```

The `Ramp_ID` is the LiveRamp-resolved pseudonymous identifier for each customer.
`Customer_Email_Id` is raw PII — a common scenario is Adidas removing this field
from question output for privacy compliance, which is exactly the kind of event XMI needs to know about.

---

## Scenario A — Question: PII Column Removed (Privacy Compliance)

**What happened:** Adidas's data team removed `Customer_Email_Id` from the output
dimensions of their "Shoe Purchase Analysis" question — likely for GDPR/CCPA compliance.
Any XMI dashboard or export pipeline expecting that column now needs to be updated.

```json
{
  "eventId":     "evt-adidas-001",
  "eventType":   "UPDATED",
  "objectType":  "QUESTION",
  "objectId":    "q-adidas-shoe-purchase-001",
  "objectName":  "Shoe Purchase Analysis",
  "cleanroomId": "cr-adidas-liveramp-2025",
  "orgId":       "org-adidas-uuid",
  "performedBy": "dataops@adidas.com",
  "eventTime":   "2026-05-18T09:15:00Z",
  "changedFields": {
    "dimensions": {
      "removed": ["Customer_Email_Id"],
      "added":   [],
      "current": ["Ramp_ID", "Purchase_Date", "Article_Id", "Amount", "Shoe_Name"]
    }
  }
}
```

**What XMI should do:** Any pipeline or dashboard pulling `Customer_Email_Id` from this
question will now receive an empty or error response. XMI can proactively alert the
Adidas team or disable dependent features before they fail silently.

---

## Scenario B — Question: Multiple Columns Removed

**What happened:** Adidas removes both `Amount` (financial sensitivity) and `Article_Id`
(internal SKU not relevant for the LiveRamp activation use case). Only identity and
product name remain.

```json
{
  "eventId":     "evt-adidas-002",
  "eventType":   "UPDATED",
  "objectType":  "QUESTION",
  "objectId":    "q-adidas-shoe-purchase-001",
  "objectName":  "Shoe Purchase Analysis",
  "cleanroomId": "cr-adidas-liveramp-2025",
  "orgId":       "org-adidas-uuid",
  "performedBy": "dataops@adidas.com",
  "eventTime":   "2026-05-18T10:00:00Z",
  "changedFields": {
    "dimensions": {
      "removed": ["Amount", "Article_Id"],
      "added":   [],
      "current": ["Ramp_ID", "Purchase_Date", "Shoe_Name"]
    }
  }
}
```

---

## Scenario C — Question: New Dimension Added

**What happened:** Adidas adds a `Region` dimension to enable geo-segmented activations.
XMI can now expose regional filtering in their UI.

```json
{
  "eventId":     "evt-adidas-003",
  "eventType":   "UPDATED",
  "objectType":  "QUESTION",
  "objectId":    "q-adidas-shoe-purchase-001",
  "objectName":  "Shoe Purchase Analysis",
  "cleanroomId": "cr-adidas-liveramp-2025",
  "orgId":       "org-adidas-uuid",
  "performedBy": "dataops@adidas.com",
  "eventTime":   "2026-05-18T11:30:00Z",
  "changedFields": {
    "dimensions": {
      "removed": [],
      "added":   ["Region"],
      "current": ["Ramp_ID", "Purchase_Date", "Article_Id", "Amount", "Shoe_Name", "Region"]
    }
  }
}
```

---

## Scenario D — Question: Dataset Assignment Swapped (Q1 → Q2 Data)

**What happened:** The dataset backing the question is refreshed from Q1 2025
purchase data to Q2 2025 purchase data. Any scheduled export or activation
running against the old dataset needs to be re-triggered.

```json
{
  "eventId":     "evt-adidas-004",
  "eventType":   "UPDATED",
  "objectType":  "QUESTION",
  "objectId":    "q-adidas-shoe-purchase-001",
  "objectName":  "Shoe Purchase Analysis",
  "cleanroomId": "cr-adidas-liveramp-2025",
  "orgId":       "org-adidas-uuid",
  "performedBy": "john.smith@adidas.com",
  "eventTime":   "2026-05-18T12:00:00Z",
  "changedFields": {
    "datasetAssignments": {
      "old": "Adidas_Purchase_Data_Q1_2025",
      "new": "Adidas_Purchase_Data_Q2_2025"
    }
  }
}
```

---

## Scenario E — Question: Status Changed (DRAFT → PUBLISHED)

**What happened:** The "Ultraboost Buyers Segment" question is approved and published.
XMI can now make it available for activation in their UI.

```json
{
  "eventId":     "evt-adidas-005",
  "eventType":   "STATUS_CHANGED",
  "objectType":  "QUESTION",
  "objectId":    "q-adidas-ultraboost-segment",
  "objectName":  "Ultraboost Buyers Segment",
  "cleanroomId": "cr-adidas-liveramp-2025",
  "orgId":       "org-adidas-uuid",
  "performedBy": "analytics@adidas.com",
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

## Scenario F — Question: Deleted

**What happened:** The "Stan Smith Holiday Campaign" question is permanently deleted
after the campaign ended. XMI needs to remove it from their activation UI.

```json
{
  "eventId":     "evt-adidas-006",
  "eventType":   "DELETED",
  "objectType":  "QUESTION",
  "objectId":    "q-adidas-stan-smith-holiday",
  "objectName":  "Stan Smith Holiday Campaign",
  "cleanroomId": "cr-adidas-liveramp-2025",
  "orgId":       "org-adidas-uuid",
  "performedBy": "admin@adidas.com",
  "eventTime":   "2026-05-18T16:45:00Z",
  "changedFields": null
}
```

**Note:** `objectName` is preserved on delete — XMI can show "Stan Smith Holiday Campaign
was deleted" to the user instead of just a UUID.

---

## Scenario G — Data Connection: Field Type Changed

**What happened:** The `Amount` field type in the Adidas purchase data connection
changes from `FLOAT` to `STRING` (e.g., due to a source system change that now
includes currency codes like "163.56 USD"). Any aggregation query using `SUM(Amount)`
will now fail at runtime.

```json
{
  "eventId":     "evt-adidas-007",
  "eventType":   "UPDATED",
  "objectType":  "DATA_CONNECTION",
  "objectId":    "dc-adidas-purchase-2025",
  "objectName":  "Adidas_Purchase_Data_2025",
  "cleanroomId": "cr-adidas-liveramp-2025",
  "orgId":       "org-adidas-uuid",
  "performedBy": "system",
  "eventTime":   "2026-05-18T08:00:00Z",
  "changedFields": {
    "outputFields": {
      "Amount": {
        "oldType": "FLOAT",
        "newType": "STRING"
      }
    }
  }
}
```

**What XMI should do:** Surface a warning on any Question or activation that aggregates
`Amount`. Prevents silent downstream failures.

---

## Scenario H — Data Connection: Field Added and Removed

**What happened:** Adidas refreshes the schema of their purchase data connection.
`Customer_Email_Id` is removed (privacy cleanup). A new field `Shoe_Category`
is added (groups Forum Low, Superstar, Stan Smith → Originals; Ultraboost, NMD → Running).

```json
{
  "eventId":     "evt-adidas-008",
  "eventType":   "UPDATED",
  "objectType":  "DATA_CONNECTION",
  "objectId":    "dc-adidas-purchase-2025",
  "objectName":  "Adidas_Purchase_Data_2025",
  "cleanroomId": "cr-adidas-liveramp-2025",
  "orgId":       "org-adidas-uuid",
  "performedBy": "dataops@adidas.com",
  "eventTime":   "2026-05-18T09:00:00Z",
  "changedFields": {
    "outputFields": {
      "added": [
        { "name": "Shoe_Category", "type": "STRING" }
      ],
      "removed": [
        { "name": "Customer_Email_Id", "type": "STRING" }
      ],
      "current": [
        { "name": "Ramp_ID",       "type": "STRING" },
        { "name": "Purchase_Date", "type": "DATE"   },
        { "name": "Article_Id",    "type": "INTEGER"},
        { "name": "Amount",        "type": "FLOAT"  },
        { "name": "Shoe_Name",     "type": "STRING" },
        { "name": "Shoe_Category", "type": "STRING" }
      ]
    }
  }
}
```

---

## Scenario I — Data Connection: Deleted

**What happened:** The 2024 historical purchase data connection is retired and deleted.
Any Question still referencing it will fail.

```json
{
  "eventId":     "evt-adidas-009",
  "eventType":   "DELETED",
  "objectType":  "DATA_CONNECTION",
  "objectId":    "dc-adidas-purchase-2024",
  "objectName":  "Adidas_Purchase_Data_2024",
  "cleanroomId": "cr-adidas-liveramp-2025",
  "orgId":       "org-adidas-uuid",
  "performedBy": "admin@adidas.com",
  "eventTime":   "2026-05-18T17:00:00Z",
  "changedFields": null
}
```

---

## How XMI Would Consume This (Cursor API Example)

XMI stores a cursor and polls every 60 seconds:

```
Step 1 — Initial call:
  GET /cleanrooms/cr-adidas-liveramp-2025/events?since=2026-05-18T08:00:00Z
  → Returns: [evt-adidas-007, evt-adidas-008]

  XMI processes:
    evt-007 → Amount type changed to STRING → flag all SUM(Amount) queries
    evt-008 → Customer_Email_Id removed, Shoe_Category added → update schema cache

  XMI saves cursor: "2026-05-18T09:00:00Z"

Step 2 — 60 seconds later:
  GET /cleanrooms/cr-adidas-liveramp-2025/events?since=2026-05-18T09:00:00Z
  → Returns: [] (nothing new)

  XMI does nothing.

Step 3 — Later:
  GET /cleanrooms/cr-adidas-liveramp-2025/events?since=2026-05-18T09:00:00Z
  → Returns: [evt-adidas-001]

  XMI processes:
    evt-001 → Customer_Email_Id removed from question dimensions
            → disable any UI feature that showed email column
            → alert Adidas team: "Shoe Purchase Analysis no longer returns Customer_Email_Id"

  XMI saves cursor: "2026-05-18T09:15:00Z"
```

---

## Questions to Ask Adidas / XMI on the Call

1. Does the `Shoe_Name` field map to what XMI calls it internally, or do they use `Article_Id` as the primary key for products?
2. When `Amount` type changes, does XMI need to know the old value format or just the type change?
3. The `Ramp_ID` is the pseudonymous LiveRamp ID — is that what XMI uses to join on their side, or do they need a different identity field in the event?
4. When `Customer_Email_Id` is removed (privacy), does XMI need a reason code in the event (`"reason": "PRIVACY_COMPLIANCE"`) or is the removal itself sufficient?
5. Would XMI want `Shoe_Category` groupings surfaced in the event, or just the raw field-level changes?
