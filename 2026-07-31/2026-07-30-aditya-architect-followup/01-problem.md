# 01 — The Problem, From First Principles

## 1. Start with the analogy

Imagine a large warehouse. A partner company sends us goods, we process them, and
the partner needs to start their own work the moment ours is finished.

**How does the partner find out?**

Today they **phone us every few minutes** and ask "is order 4471 done yet?" This
works, but as the number of orders grows the phone lines jam. Most calls are
wasted — the answer is usually "not yet." This is exactly our situation: XMI polls
our API, and DV-15621 records that the resulting rate-limiting problem "should be
helped by enabling pub/sub for status instead of polling."

So we agree: **we will call them instead.** Now two questions appear, and they are
the whole of this discussion.

### Question A — What do we say on the call?

- *"Something changed with order 4471."* The partner still has to phone us back to
  find out what. We have not removed the phone calls, we have just added a
  doorbell in front of them.
- *"Order 4471 is now packed."* The partner can act immediately. This is useful.
- *"Order 4471 moved from picking to packed, and the delivery address changed from
  A to B."* Now they can act **and** show their customer a history.

### Question B — Who writes the note?

- **The clerk who handled the order.** They know the customer asked for one thing:
  "process order 4471." They know what it looked like before and after. They can
  write one clear note.
- **A camera watching the shelves.** It sees five boxes move. It does not know
  those five movements were one order. It does not know which box is "the order"
  and which are "items inside the order." It cannot see who was holding them.

The clerk is our service-layer code. The camera is Hank's automatic row hooks, or
change data capture. **This document is mostly about why the clerk writes a better
note, and what it costs us to ask them to write it.**

---

## 2. Now the real problem

XMI (a partner team) has four confirmed needs for M1:

1. Tell us when a **Data Connection's stage** changes.
2. Tell us when a **Flow Run's state** changes (STARTED / COMPLETED / FAILED).
3. When **Flow 1 completes, we want to trigger Flow 2** (flow chaining).
4. During cleanroom onboarding, **when all datasets are assigned, trigger a run**.

Beyond XMI, there is a second customer for the same stream: Josh's audit-log
expansion needs "who changed what, when" across the platform for compliance.

Both want notifications about change. They want **different amounts of detail**,
which is why the design keeps pulling in two directions.

---

## 3. Why this problem exists at all

Three reasons, and they are all consequences of decisions that were reasonable at
the time.

### 3.1 A "Data Connection" is not one row

**[VERIFIED]** It is stored across two tables:

| Table | What it holds |
|---|---|
| `data_import_jobs` | the connection itself — name, source, stage, status |
| `organization_job_parameters` | its settings, **one row per setting** |

So the business object the user sees does not match the storage. Any mechanism
that works at the row level sees pieces, not the object.

### 3.2 The settings are saved by delete-then-reinsert

**[VERIFIED]** `forebitt/db/job_parameters.go:109-167`
(`SetOrganizationJobParametersInTransaction`):

```go
ClearOrganizationJobParameters(tx, ...)      // :121 — deletes ALL settings
for _, inParamObj := range inParamObjs {
    inParamObj.ID = uuid.New().String()      // :150 — brand new ID every save
    tx.Create(inParamObj)                    // :154
}
```

Two consequences that matter enormously later:

- Changing **one** setting rewrites **all** of them.
- Every setting gets a **new primary key on every save**, so row identity does not
  survive an edit. Nothing can be matched up by ID across a change.

### 3.3 The existing notification mechanism was built for a different purpose

**[VERIFIED]** `hank/events/model.go:3` — what we publish today:

```go
type EventStruct struct {
    Service    string            // "forebitt"
    Action     string            // "create" | "update" | "delete"
    Object     string            // "dataImportJob"
    ObjectID   string            // the uuid
    Attributes map[string]string // a bag of strings
}
```

An ID and a bag of strings. This was designed to tell **our own** internal
services "go look at this thing." It was never designed to tell an **external
partner** what changed. That is why we cannot simply point XMI at the existing
topic — the payload does not contain the information they need, no matter which
topic it travels on.

---

## 4. The constraints we are designing inside

| # | Constraint | Where it comes from | Consequence |
|---|---|---|---|
| C1 | Do not disturb pegleg or janus | They consume the existing SNS topic in production | **[VERIFIED]** `orinjade/aws/modules/habu-events/pegleg.tf:17` — pegleg's filter policy already matches `"dataImportJob"`, so publishing our new messages to the existing topic would land them in pegleg's queue. Forces a new topic. |
| C2 | Delivery must be at-least-once to XMI | Partner contract | Needs an idempotency key and stored history, hence `object_events` |
| C3 | The audit tier needs long retention | Compliance | `object_events` has a hard 90-day delete in its DDL; a second tier is needed |
| C4 | We cannot leak secrets | Security review | **[VERIFIED]** `primage/models/models.go:219-226` — the `Credential` table has a `Value` column and uses the same Hank audit embed. Any generic "log all field values" approach writes secrets somewhere. |
| C5 | Hank is shared | **[VERIFIED]** used by unhygienix, forebitt, primage, picanmix, pegleg | Any change to Hank lands in every service on the next version bump |
| C6 | Three live entry points, not one | **[VERIFIED]** all three are registered HTTP routes | Whatever we do, we do it in more than one place |

---

## 5. Why this discussion matters

**It is the last cheap moment.** The receiving side is built. The producer side
touches other people's code in other repos. Once XMI integrates against a message
shape, changing that shape becomes a coordinated multi-team release.

Concretely, three things get locked in by this decision:

1. **How much XMI can do without calling us back.** If the message is thin, we
   have not actually replaced polling — we have added a doorbell in front of it.
2. **Whether the observability product is possible.** The product we are pitching
   shows a customer what happened to their data connection over time. A history
   of "updated, updated, updated" cannot produce that screen.
3. **Whether our database schema becomes an external contract.** Two of the five
   options in `03` expose table and column names to XMI. If we choose one of
   those, renaming a column later breaks a partner integration.

---

## 6. What "good" looks like

A single message per user action that:

- names the **business object** ("DATA_CONNECTION"), not the tables
- carries enough state that XMI can act **without calling us back**
- says **who** did it
- has a **stable ID** so duplicates can be discarded
- can be **replayed** if the consumer was down
- does not expose our internal schema or any secret

Keep this list. In `04` every option is scored against exactly these seven points.

---

**Next:** [02-current-design.md](02-current-design.md) — one real request, traced
line by line.
