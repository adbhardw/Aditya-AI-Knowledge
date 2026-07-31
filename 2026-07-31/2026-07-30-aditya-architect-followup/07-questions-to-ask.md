# 07 — Questions I Should Ask Them

The goal of the meeting is to learn, not only to get a signature. These are ordered
so that if we only get through the first four, they are the ones that matter.

---

## The four that block work

### Q1 — Is a Data Connection event scoped to the organisation or the cleanroom?

*Context:* our event format uses `source: urn:habu:cleanroom:<cleanroom-id>` and
`object_events` is queried by `cleanroom_id`. But `DataImportJob` carries
`OrganizationID` and **no cleanroom ID at all**
(`forebitt/models/data_import_job.go:20`). A connection is org-scoped and can serve
several cleanrooms.

*Options:* (a) emit as an organisation event with a null cleanroom, (b) emit one copy
per attached cleanroom, (c) emit once and let orinix expand at read time.

*Why I need the answer:* it decides the primary query key for the whole table, and it
is cheap now and expensive later.

### Q2 — Are the V1 data-connection APIs still serving traffic?

I have confirmed all three routes are registered:
`POST /v2/organization/{orgId}/data-connection`,
`POST /forebitt/v1/organization/{orgId}/dataConnection`, and the import-job route. I
have **not** confirmed which receive traffic. This is the difference between
instrumenting 3 sites and 7, and between needing the double-emit guard or not.

If V1 is dead, is deleting it in scope for someone?

### Q3 — Do we need a delivery guarantee for M1, or is best-effort acceptable?

Today the publish is fire-and-forget: the error is logged and swallowed
(`job_service.go:1602-1605`). Failure mode is loss, never a phantom event. A
transactional outbox closes it and is real scope.

*What I actually want to know:* what do we tell XMI in the contract? I would rather
promise best-effort and deliver it than promise at-least-once and not.

### Q4 — Should we go straight to the request-scoped buffer instead of per-handler emits?

Option 5 in `03-design-options.md`: handlers append to a per-request list, one piece
of middleware publishes on success. It makes double-emission structurally impossible
and gives a single place for retries and the outbox later, at the cost of
indirection. For 7 sites I leaned against it — but you have seen this pattern age in
more codebases than I have. Does it earn its keep here?

---

## Design and long-term architecture

5. When unhygineix and picanmix start producing the same events, where should the
   message contract live? A shared Go module, or a written JSON schema with each
   service owning its own struct? I lean towards the schema as the contract, so we do
   not repeat the coupling we are avoiding by not widening `hevent.EventStruct` —
   but I would like to hear the counter-argument.

6. Should the audit-log work and the XMI notification work stay as two mechanisms,
   or is there a version where one feeds the other? My current view is that they
   answer different questions and should stay separate, with Hank's hooks serving
   audit. Is that how you see it, Josh?

7. `object_events` has a hard 90-day delete in its DDL. Audit-grade retention is
   measured in years. Is the hot-tier/cold-tier split (archive to object storage,
   one read API routing by age) the right shape, and is it M2 or M3?

## Operational

8. What is our normal practice for a new SNS topic plus SQS queue — who owns the
   Terraform, and what is the lead time? I want to know whether to build behind an
   empty-ARN guard or wait.

9. How would we detect that forebitt wrote a row and no event arrived? Is there an
   existing pattern for that kind of end-to-end check, or would this be the first?

10. Has anyone measured the p99 of `UpdateDataConnectionV2`? I am adding one indexed
    read and I would rather quote a number than an adjective.

## Scalability

11. What volume should I design for — events per day at current scale, and at the
    scale we expect when the audit expansion lands? This determines whether the
    Standard-versus-FIFO topic decision matters in practice or only in principle.

12. If a consumer falls badly behind, what is the intended behaviour — grow the
    queue, drop, or apply back-pressure to producers? I have not designed for
    back-pressure at all.

## Security

13. For Level 2 payloads we send field values to an external partner. Who signs off
    on the field allow-list, and is there an existing classification of which columns
    are safe to export?

14. Settings can contain customer-identifying values — `DataLocation` and
    `SampleFilePath` are full S3 URIs, and `TableName` names a customer's table. Is
    sending those to XMI already covered by an existing agreement, or does it need
    review?

## Observability and maintainability

15. If the emit block drifts out of sync with the handler during a future refactor,
    what would catch it in our current CI? Would you want a test that fails when a
    write path does not emit?

16. Is there an existing convention in the platform for versioning an
    externally-consumed message schema? I would rather follow one than invent one.

## Product direction

17. Is a customer-facing history view ("who changed this connection and when") on the
    roadmap? If yes, that settles the Level 1 versus Level 2 question immediately and
    I should stop treating it as open.

18. Jon's read-access auditing ask has no emit point anywhere today. Worth noting
    that reads do not write rows, so **no** database-level mechanism can capture them
    — only the service layer can. Does that change how you weigh today's decision?

---

## The question I most want answered

> Given that the row-level mechanisms give us either the values or the actor but
> never both, and the service layer gives us both plus the business object — is there
> a reason you would still prefer a row-level mechanism that I am not seeing?

If the answer is no, I have approval. If the answer is yes, I have learned the thing
I came for.
