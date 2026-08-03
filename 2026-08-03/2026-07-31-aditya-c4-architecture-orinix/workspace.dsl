/*
 * Orinix Change Event Platform — C4 Level 2 Container Diagram
 *
 * Structurizr DSL conversion of the Mermaid container diagram in
 *   02-containers.md  §1 "The container diagram"
 *
 * Source of truth for all architectural claims:
 *   adbhardw/Aditya-AI-Knowledge @ master, commit 0fe9858
 *   2026-07-31/2026-07-30-aditya-architect-followup
 *
 * Tickets: DV-13856 (platform), DV-15090 / DV-15091 (M1), DV-15496 (epic),
 *          DV-15621 (XMI polling / rate limiting)
 *
 * STATUS MODEL — carried over from the Mermaid colour coding, expressed as tags:
 *   Built     🟩  exists today
 *   Agreed    🟦  design agreed, not yet built
 *   Proposed  🟧  recommended, AWAITING ARCHITECT APPROVAL  (decision D1)
 *   Future    ⬜  named as a direction, not in M1 scope
 *   Risk      ⚠️  carries a called-out architectural risk
 *
 * The single open decision is the forebitt -> habu-observability-events
 * relationship. Everything downstream of the SNS topic is agreed.
 *
 * Render with:  structurizr-lite  (docker run -p 8080:8080 -v $PWD:/usr/local/structurizr structurizr/lite)
 */

workspace "Orinix Change Event Platform" "C4 Level 2 container view of the Clean Room change-event and partner-notification platform." {

    !identifiers flat

    model {

        # ---------------------------------------------------------------
        # People
        # ---------------------------------------------------------------

        customer = person "Clean Room Customer" "Operator at a customer organisation (e.g. Adidas). Creates and edits Data Connections, Flows and Questions." {
            tags "Person"
        }

        # ---------------------------------------------------------------
        # Software System: LiveRamp Clean Room Platform  (the producer side)
        # ---------------------------------------------------------------

        cleanRoomPlatform = softwareSystem "LiveRamp Clean Room Platform" "Owns Clean Room business resources — Data Connections, Flows, Flow Runs and Questions — and their lifecycle." {
            tags "Software System" "Internal" "Built"

            cleanRoomUi = container "Clean Room UI" "Where the user action originates. Create and edit connections, flows and questions." "Web" {
                tags "Container" "Built"
            }

            forebitt = container "forebitt" "Owns Data Connections and Import Jobs. The M1 event producer. A single create writes 5 rows across 2 tables inside one transaction." "Go, gRPC + grpc-gateway" {
                tags "Container" "Built" "Producer"
            }

            unhygienix = container "unhygienix" "Owns Flows and Flow Runs. Needed for XMI use cases 2-4 (flow-run state, flow chaining, onboarding)." "Go" {
                tags "Container" "Future" "Producer"
            }

            picanmix = container "picanmix" "Owns Questions." "Go" {
                tags "Container" "Future" "Producer"
            }

            forebittDb = container "forebitt Postgres" "data_import_jobs (the connection) + organization_job_parameters (one row PER SETTING). The business object does not match the storage." "PostgreSQL" {
                tags "Container" "Database" "Built"
            }

            hank = container "hank" "Shared library providing TWO INDEPENDENT pipelines that never call each other: GORM audit hooks (stdout only) and a hand-invoked SNS event publisher. C5: shared by unhygienix, forebitt, primage, picanmix and pegleg — any change lands in every service." "Shared Go library" {
                tags "Container" "Built" "Risk"
            }
        }

        # ---------------------------------------------------------------
        # Software System: AWS Event Transport
        # Modelled as its own boundary because the Mermaid source places these
        # between — and outside — both the producer and Orinix boundaries.
        # ---------------------------------------------------------------

        eventTransport = softwareSystem "AWS Event Transport" "Managed messaging carrying change events from producers to Orinix, and the existing thin events to legacy consumers." {
            tags "Software System" "Internal"

            observabilityTopic = container "habu-observability-events" "NEW Standard topic, isolated from existing consumers by construction. Standard rather than FIFO because the existing FIFO topic sets MessageGroupId to the request ID, so updates to the same object from different requests are ALREADY unordered." "AWS SNS (Standard)" {
                tags "Container" "Queue" "Agreed"
            }

            ingestQueue = container "Orinix ingest queue" "Buffers and decouples: forebitt never waits on Orinix, Orinix downtime accumulates rather than losing messages, and a poison message is isolated instead of blocking the stream." "AWS SQS + DLQ/redrive" {
                tags "Container" "Queue" "Agreed"
            }

            legacyTopic = container "habu_events_topic.fifo" "Existing thin events. UNCHANGED — constraint C1. Its pegleg subscription filter already matches 'dataImportJob', which is why a new topic is required." "AWS SNS (FIFO)" {
                tags "Container" "Queue" "Built"
            }
        }

        # ---------------------------------------------------------------
        # Software System: Orinix Change Event Platform  (the new system)
        # ---------------------------------------------------------------

        orinix = softwareSystem "Orinix Change Event Platform" "Turns Clean Room resource changes into durable, replayable business events and delivers them to subscribed consumers. Adding a consumer is a configuration row, not a code change in 10+ producer repositories." {
            tags "Software System" "Internal" "Agreed"

            ingestWorker = container "Ingest Worker" "Consumes the SQS queue and writes events idempotently, so SQS redelivery and crash-before-ack are both safe." "Not stated in source" {
                tags "Container" "Agreed"
            }

            objectEvents = container "object_events" "The durable, replayable event history. UNIQUE(idempotency_key) provides de-duplication. WARNING: hard 90-day delete in the DDL, versus multi-year audit retention." "PostgreSQL" {
                tags "Container" "Database" "Agreed" "Risk"
            }

            pullApi = container "Pull API" "GetCleanroomEvents — cursor-based catch-up and replay. Lets a consumer self-heal after downtime." "gRPC / HTTP" {
                tags "Container" "Built"
            }

            deliveryWorkers = container "Delivery Workers" "Fans one event out to every registered subscription: webhook and GCP Pub/Sub, with retry and DLQ." "Not stated in source" {
                tags "Container" "Built"
            }

            coldTier = container "Cold / archive tier" "Long retention for the compliance tier (constraint C3). Designed, not built." "Object storage" {
                tags "Container" "Database" "Future"
            }
        }

        # ---------------------------------------------------------------
        # External systems
        # ---------------------------------------------------------------

        xmi = softwareSystem "XMI Platform" "External partner. Reacts to Clean Room changes: chains flows, triggers runs, tracks connection readiness. Currently POLLS our API — DV-15621." {
            tags "Software System" "External System"
        }

        peglegJanus = softwareSystem "pegleg / janus" "Existing internal consumers of the FIFO topic. Constraint C1: MUST NOT BE DISTURBED." {
            tags "Software System" "External System" "Built"
        }

        logMetrics = softwareSystem "Loki / Datadog" "Grafana Cloud Loki via the Alloy agent, and Datadog. Receives Hank's 'Audit Log:' stdout lines. Explicitly CANNOT back the read API." {
            tags "Software System" "External System" "Built"
        }

        # ---------------------------------------------------------------
        # Relationships — all 21 edges from the Mermaid source
        # ---------------------------------------------------------------

        # -- user entry ------------------------------------------------
        customer -> cleanRoomUi "Creates / updates / deletes resources using" "HTTPS"
        cleanRoomUi -> forebitt "Makes API calls to" "JSON over HTTPS (grpc-gateway)"

        # -- producer internals ----------------------------------------
        forebitt -> forebittDb "Reads from and writes to. One user action = 5 row writes in 1 transaction" "SQL/TCP"
        forebitt -> hank "Uses" "Go library"
        unhygienix -> hank "Uses" "Go library"
        picanmix -> hank "Uses" "Go library"

        # -- THE OPEN DECISION (D1) ------------------------------------
        forebitt -> observabilityTopic "PROPOSED (D1): publishes EXACTLY ONE business event per user action, emitted at dataConnections_v2.go:378 where the complete business object is already in hand" "JSON over SNS" {
            tags "Relationship" "Proposed" "Event Path"
        }
        unhygienix -> observabilityTopic "Will publish Flow / Flow Run events" "JSON over SNS" {
            tags "Relationship" "Future"
        }
        picanmix -> observabilityTopic "Will publish Question events" "JSON over SNS" {
            tags "Relationship" "Future"
        }

        # -- existing pipelines, unchanged ------------------------------
        hank -> legacyTopic "Publishes existing thin events from ~15 hand-written call sites in forebitt" "SNS FIFO" {
            tags "Relationship" "Built"
        }
        hank -> logMetrics "Writes 'Audit Log:' lines — a SEPARATE pipeline that never touches the event publisher" "stdout -> Alloy agent" {
            tags "Relationship" "Built"
        }
        legacyTopic -> peglegJanus "Delivers existing thin events to" "SNS -> SQS" {
            tags "Relationship" "Built"
        }

        # -- ingest path ------------------------------------------------
        observabilityTopic -> ingestQueue "Subscription" "SNS -> SQS" {
            tags "Relationship" "Event Path"
        }
        ingestQueue -> ingestWorker "Delivers messages to" "Long-poll receive" {
            tags "Relationship" "Event Path"
        }
        ingestWorker -> objectEvents "INSERT ... ON CONFLICT DO NOTHING on idempotency_key" "SQL/TCP" {
            tags "Relationship" "Event Path"
        }

        # -- read + delivery paths --------------------------------------
        # NOTE: the Mermaid source draws these as object_events -> API / Workers
        # (data-flow direction). Modelled here in C4 convention as the reader
        # initiating the call. Same two relationships, semantically correct.
        pullApi -> objectEvents "Reads pages of events by cursor from" "SQL/TCP"
        deliveryWorkers -> objectEvents "Reads undelivered events from" "SQL/TCP"
        objectEvents -> coldTier "Aged out beyond the 90-day boundary into" "Archival job" {
            tags "Relationship" "Future"
        }

        # -- egress to the partner --------------------------------------
        deliveryWorkers -> xmi "Delivers change events by signed webhook to" "HTTPS egress to the public internet" {
            tags "Relationship" "Event Path"
        }
        deliveryWorkers -> xmi "Delivers change events by Pub/Sub to" "GCP Pub/Sub (cross-cloud)" {
            tags "Relationship" "Event Path"
        }
        xmi -> pullApi "Pulls missed events by cursor from" "GetCleanroomEvents" {
            tags "Relationship" "Event Path"
        }
    }

    views {

        # ---------------------------------------------------------------
        # C4 Level 2 — Container diagram
        #
        # Scoped to Orinix, with the producer and transport containers
        # explicitly included so all three software system boundaries are
        # rendered in a single Level 2 view.
        # ---------------------------------------------------------------

        container orinix "L2_Containers" "C4 Level 2 — Container diagram for the Orinix Change Event Platform and the Clean Room producers that feed it." {
            # NOTE: no "include *" here. In a container view scoped to Orinix,
            # "include *" pulls related OUT-OF-SCOPE elements in at SOFTWARE SYSTEM
            # level, which outranks an explicitly-included container of that same
            # system -- collapsing the AWS Event Transport boundary and rolling its
            # relationships up. Listing every element explicitly keeps all three
            # boundaries expanded to their containers.

            include customer

            # LiveRamp Clean Room Platform (producer boundary)
            include cleanRoomUi forebitt unhygienix picanmix forebittDb hank

            # AWS Event Transport (messaging boundary)
            include observabilityTopic ingestQueue legacyTopic

            # Orinix Change Event Platform (new system boundary)
            include ingestWorker objectEvents pullApi deliveryWorkers coldTier

            # External systems
            include xmi peglegJanus logMetrics

            autoLayout lr 300 200
        }

        # ---------------------------------------------------------------
        # Styles
        # ---------------------------------------------------------------

        styles {

            # --- base C4 element types ---------------------------------

            element "Person" {
                shape Person
                background #08427b
                color #ffffff
                fontSize 22
            }

            element "Software System" {
                shape RoundedBox
                background #1168bd
                color #ffffff
            }

            element "Container" {
                shape RoundedBox
                background #438dd5
                color #ffffff
            }

            element "Database" {
                shape Cylinder
                background #b3b3b3
                color #000000
            }

            element "Queue" {
                shape Pipe
                background #dae8fc
                color #000000
            }

            element "External System" {
                shape RoundedBox
                background #999999
                color #ffffff
            }

            # --- status overlay (declared AFTER the base types so it wins) ---

            element "Built" {
                background #d5e8d4
                stroke #82b366
                color #000000
            }

            element "Agreed" {
                background #dae8fc
                stroke #6c8ebf
                color #000000
            }

            element "Proposed" {
                background #ffe6cc
                stroke #d79b00
                color #000000
            }

            element "Future" {
                background #f5f5f5
                stroke #b3b3b3
                color #666666
                opacity 60
            }

            element "Risk" {
                stroke #b85450
                strokeWidth 6
            }

            # --- relationships -----------------------------------------

            relationship "Relationship" {
                thickness 2
                color #707070
                routing Direct
            }

            relationship "Event Path" {
                thickness 4
                color #333333
            }

            relationship "Proposed" {
                thickness 5
                color #d79b00
                dashed true
            }

            relationship "Future" {
                dashed true
                color #b3b3b3
                opacity 50
            }

            relationship "Built" {
                color #82b366
            }
        }
    }
}
