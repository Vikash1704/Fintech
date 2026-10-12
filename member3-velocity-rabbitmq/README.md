# fintech-fraud-detection — Member 3 (Velocity Counter, Priority Routing, Retry, DLQ)

Mule 4 project for the FinTech Payment Fraud Detection hackathon.
**Scope of this project (Member 3):** sliding-window velocity counting per `cardToken`, enrichment, routing by the
`riskLevel` supplied by Member 2, retry on publish, and dead-letter handling. It does **not** compute `riskScore`,
`riskLevel` or rule hits and never overwrites Member 2's decision (it only upper-cases `riskLevel`).

> **Honesty note.** This project was generated in an environment with no Maven access, no Anypoint Studio, no Mule
> runtime and no RabbitMQ. Nothing here has been compiled or run. See `docs/BUILD_VALIDATION_REPORT.md` for exactly
> what was and was not checked. Expect to fix small things on first import (section 19 lists the likely ones).

| Item | Value |
|---|---|
| Project / artifact | `fintech-fraud-detection` |
| Main flow | `fintech-fraud-detectionFlow` |
| Mule runtime | 4.12.2 EE (`app.runtime` in pom, `minMuleVersion` 4.9.0 in `mule-artifact.json`) |
| Java | 17 |
| Connectors | HTTP 1.11.3, AMQP 1.9.4, Object Store 1.3.1 (as you specified; **not verified against Exchange**) |
| Endpoint | `POST http://localhost:8082/velocity` |
| Queues | `fraud-high-priority` (classic, `x-max-priority=10`), `fraud-standard`, `fraud-dlq` |

## How it works

```
HTTP Listener (POST /velocity)
 → Preserve original transaction (vars.originalTransaction)
 → Validate required fields            (400 on failure, nothing published)
 → Extract cardToken / correlationId / riskLevel
 → velocity-update-flow  (per-card lock → retrieve → prune expired → add current → count → store → unlock)
 → Build enriched transaction JSON
 → Choice
     HIGH          → Until Successful → Publish fraud-high-priority (priority 10)
     LOW | MEDIUM  → Until Successful → Publish fraud-standard      (priority 0)
     (retries exhausted) → build DLQ envelope → Publish fraud-dlq (single attempt)
 → HTTP JSON response
```

All published messages: `contentType=application/json`, `deliveryMode=2` (persistent), AMQP `correlation_id` = the
transaction's `correlationId`. `eventId`, `transactionId`, `correlationId` and every other original field are preserved.

### Velocity semantics (please confirm with the team)

* **Sliding window**, not a TTL counter. Per `cardToken` the Object Store holds a JSON list of epoch-millisecond
  timestamps. On each request: load → drop timestamps `< referenceTime − windowSeconds` → add the current one → count → save.
  Date maths is done on epoch milliseconds (plain numbers), so no date-subtraction functions are used.
* Defaults: `velocity.windowSeconds=300`, `velocity.threshold=4`.
* **Threshold rule — ASSUMPTION:** `velocity.comparison=GT` ⇒ `thresholdExceeded = count > 4` ("more than 4 in 5 minutes"):
  the 5th transaction in the window is the first to exceed it. Set `velocity.comparison=GTE` for "4 or more".
  The team contract text I was given does not say which; **confirm and change the property, not the code.**
  `thresholdExceeded` is informational for Member 2 / dashboards — Member 3 does **not** use it for routing.
* The Object Store entry TTL (`velocity.store.ttlSeconds`, default 600) is only housekeeping. It must be ≥ the window.
* Time source: `velocity.useEventTimestamp=false` (default) uses server time, so a caller cannot manipulate the count.
  Set it to `true` only for the deterministic expiry test (section 16); the transaction's `timestamp` is then required.

### Concurrency (read this)

`Object Store retrieve` + `store` is a read-modify-write and is **not atomic by itself**; the Object Store connector
has no compare-and-set. To reduce lost updates this project takes a short per-`cardToken` lock using `os:store`
with `failIfPresent="true"` on a non-persistent lock store (retry 20 × 100 ms, lock TTL 30 s), and releases it on
success and on error. That is an *implemented* mitigation, but:

* it has **not been load-tested**;
* the lock store is per Mule runtime instance — it does **not** coordinate multiple workers/replicas;
* if the lock cannot be obtained, the request fails with HTTP 503 (`VELOCITY_BUSY`) and nothing is published.

For a true multi-node production design use an external atomic store (e.g. Redis sorted set / Lua).

### Retry semantics

`until-successful maxRetries=3, millisBetweenRetries=1000` = **1 initial attempt + 3 retries = 4 attempts in total**
(roughly 3 s of waiting). Each attempt logs `Publish attempt correlationId=…`, so you can count them yourself in the
Studio console during the DLQ test (section 18) and confirm that this holds on your runtime.
When attempts are exhausted the scope raises `MULE:RETRY_EXHAUSTED`; only that error type is handled by the DLQ path
(validation, DataWeave or Object Store errors are **not** dead-lettered; they return 400/500).
The DLQ publish itself is a **single attempt with no retry and no further error handling loop**: if it fails the error
`FRAUD:DLQ_PUBLISH_FAILED` is raised and the client gets HTTP 503.

### HTTP status codes

| Situation | HTTP | `status` in body |
|---|---|---|
| Published to the primary queue | **200** | `PUBLISHED` |
| Invalid input (nothing published) | **400** | `REJECTED` (+ `error.details`) |
| Primary publish failed after retries, **DLQ publish succeeded** | **202** | `DEAD_LETTERED` (`routing.published=false`, `routing.deadLettered=true`) |
| Primary failed **and** DLQ publish failed | **503** | `FAILED` (`error.code=DLQ_PUBLISH_FAILED`) — transaction is in no queue, caller must retry |
| Could not obtain the velocity lock | **503** | `FAILED` (`VELOCITY_BUSY`) |
| Any other unexpected error | **500** | `FAILED` (`INTERNAL_ERROR`) |

Responses never contain stack traces, credentials or connection details. Card numbers are never stored or logged:
`cardToken` is the key, only `maskedCardNumber` is retained, and bodies containing `cardNumber`/`pan`/`cvv` fields, or a
`cardToken`/`maskedCardNumber` that looks like a 13–19 digit card number, are rejected with 400 (the offending value is not echoed).

Note: if the primary publish fails the velocity count for that request has **already been stored** (the transaction did
occur and is counted). Resending the same transaction after a 503 will count it again.

---

## 1. Prerequisites
* Docker Desktop, Anypoint Studio (Mule runtime 4.12.2 EE installed), JDK 17, internet access to Anypoint Exchange / MuleSoft Maven repositories.
* An Anypoint account configured in Studio (needed for the AMQP connector from Exchange).
* `curl` (Windows 10/11 ships `curl.exe`) or Postman.

## 2. Start Docker Desktop
Wait until it says "Engine running".

## 3. Start (or create) RabbitMQ
```
docker ps -a --filter "name=rabbit"
```
* Container exists → `docker start <container-name>`.
* Does not exist → `docker run -d --name rabbitmq -p 5672:5672 -p 15672:15672 rabbitmq:4-management`

## 4. Verify the management UI
Open http://localhost:15672 and log in with `guest` / `guest`.

## 5. Verify / create the queues and priority configuration

**Queue priority.** Only `fraud-high-priority` needs `x-max-priority=10`. RabbitMQ does **not** allow changing queue arguments
of an existing queue, and messages sent with a priority to a queue without `x-max-priority` are accepted but not prioritised.
This project never deletes or recreates queues.

Safe setup (creates only what is missing, warns about mismatches):
```
# macOS / Linux / Git Bash
./scripts/setup-rabbitmq-queues.sh
# Windows PowerShell
powershell -ExecutionPolicy Bypass -File .\scripts\setup-rabbitmq-queues.ps1
```
Or by hand in the UI: *Queues and Streams → Add a new queue* → Type **Classic**, Name `fraud-high-priority`, Durability **Durable**,
under Arguments add `x-max-priority` = `10` (type Number) → Add queue. Repeat for `fraud-standard` and `fraud-dlq` with no arguments.

Verify: the `fraud-high-priority` row shows the `Pri` feature (or open it and check *Arguments → x-max-priority: 10*).
If it already exists **without** `x-max-priority`, that is your decision to make: either delete it yourself in the UI
(destroys its messages) and re-run the script, or declare a new queue name and change `amqp.queue.high`.

> The flows publish through the **default exchange** using the queue name as routing key. If a queue does not exist the broker
> silently drops the message while Mule still reports success — so always verify the three queues exist before testing.

## 6. Extract the ZIP
Extract `fintech-fraud-detection-member3.zip`; you get a folder `fintech-fraud-detection/`.

## 7. Import into Anypoint Studio
*File → Import → Anypoint Studio → Anypoint Studio project from File System* → *Project Root* = the extracted
`fintech-fraud-detection` folder → Finish. (Studio adds its own `.project`/`.classpath`; they are intentionally not in the ZIP.)

## 8. Java 17 and Mule runtime
* *Window → Preferences → Java → Installed JREs*: add/select a **JDK 17** and make it the default (or set it for this project:
  right-click project → *Properties → Java Build Path → Libraries*).
* Right-click project → *Properties → Mule → Runtime* (or *Anypoint Studio → Mule Runtime*) → select **Mule Server 4.12.2 EE**.

## 9. Resolve Maven dependencies
Right-click the project → *Maven → Update Project…* (Force Update). If the AMQP connector cannot be downloaded, add your
Anypoint credentials in Maven `settings.xml` for server id `anypoint-exchange-v3` (see section 19).

## 10. Deploy
Right-click `src/main/mule/fintech-fraud-detection.xml` → *Run As → Mule Application*. Wait for
`Started app 'fintech-fraud-detection'` / `DEPLOYED` in the console.

## 11. Verify the listener
```
curl -i -X POST http://localhost:8082/velocity -H "Content-Type: application/json" -d "{}"
```
Expect **HTTP 400** with `"status":"REJECTED"` (proves listener, validation and error handler are live).

## 12–14. Test HIGH, LOW, MEDIUM routing
From the project folder (same command on Windows with `curl.exe`):
```
curl -s -X POST http://localhost:8082/velocity -H "Content-Type: application/json" --data-binary "@test-payloads/01-high.json"
curl -s -X POST http://localhost:8082/velocity -H "Content-Type: application/json" --data-binary "@test-payloads/02-low.json"
curl -s -X POST http://localhost:8082/velocity -H "Content-Type: application/json" --data-binary "@test-payloads/03-medium.json"
```
Expected (HTTP 200), abbreviated:
```json
{
  "status": "PUBLISHED",
  "correlationId": "corr-high-0001",
  "eventId": "evt-1001",
  "transactionId": "txn-1001",
  "routing": { "riskLevel": "HIGH", "queue": "fraud-high-priority", "priority": 10, "published": true, "deadLettered": false },
  "velocity": { "count": 1, "windowType": "SLIDING", "windowSeconds": 300, "expiredRemoved": 0, "threshold": 4,
                "comparison": "GT", "thresholdExceeded": false, "timestampSource": "SERVER_TIME", "windowStart": "…", "windowEnd": "…" },
  "transaction": { "...all original fields...": "…", "riskLevel": "HIGH", "velocity": { "count": 1, "…": "…" } }
}
```
RabbitMQ: HIGH → 1 message in `fraud-high-priority`; LOW and MEDIUM → `routing.queue = fraud-standard`, `priority = 0`, 2 messages in `fraud-standard`.
(If you run these tests more than once the counts in the response increase; see section 16 for resetting.)

## 15. Repeated transactions, same cardToken
```
# bash
for i in 1 2 3 4 5; do curl -s -X POST http://localhost:8082/velocity -H "Content-Type: application/json" --data-binary "@test-payloads/04-repeat-same-card.json"; echo; done
# PowerShell
1..5 | ForEach-Object { curl.exe -s -X POST http://localhost:8082/velocity -H "Content-Type: application/json" --data-binary "@test-payloads/04-repeat-same-card.json"; "" }
```
Within 5 minutes, with `GT` and threshold 4, `velocity.count` is **1, 2, 3, 4, 5** and `thresholdExceeded` is **false, false, false, false, true**.
All five go to `fraud-standard` (riskLevel LOW — velocity does not change routing). With `GTE` the 4th would already be `true`.

## 16. Expiration of timestamps outside the 5-minute window
*Option A (real time):* send `04-repeat-same-card.json` twice, wait 5 minutes + a few seconds, send again → `count` is **1** and the
response shows `expiredRemoved: 2` for the first request after the wait.

*Option B (deterministic, no waiting):* set `velocity.useEventTimestamp=true` in `application.properties`, **restart** the app, then send in order:
```
curl -s -X POST http://localhost:8082/velocity -H "Content-Type: application/json" --data-binary "@test-payloads/07-expiry-event-time-1.json"   # 10:00
curl -s -X POST http://localhost:8082/velocity -H "Content-Type: application/json" --data-binary "@test-payloads/07-expiry-event-time-2.json"   # 10:02
curl -s -X POST http://localhost:8082/velocity -H "Content-Type: application/json" --data-binary "@test-payloads/07-expiry-event-time-3.json"   # 10:06
```
Expected counts **1, 2, 2**: at 10:06 the window starts at 10:01, so the 10:00 entry is dropped (`expiredRemoved: 1`) and 10:02 + 10:06 remain.
Set the property back to `false` afterwards. (The velocity store is persistent: to reset a card, use a new `cardToken` or restart with a cleared Mule `.mule` data folder.)

## 17. Verify message priority and correlationId in RabbitMQ
Management UI → *Queues* → `fraud-high-priority` → *Get messages* → Ack mode **Nack message requeue true**, Messages **1** → *Get Message(s)*.
Check: `priority: 10`, `delivery_mode: 2`, `content_type: application/json`, `correlation_id: corr-high-0001`, and a JSON body containing `eventId`,
`transactionId`, `velocity`. Repeat for `fraud-standard` (`priority: 0`). Requeue-true leaves the messages in place.

## 18. Verify retry exhaustion and DLQ routing (controlled test)
**Method A — injected primary failure (expects HTTP 202):**
1. In `application.properties` set `test.injectPrimaryPublishFailure=true`, restart the app.
2. `curl -i -X POST http://localhost:8082/velocity -H "Content-Type: application/json" --data-binary "@test-payloads/06-retry-dlq-test.json"`
3. Console: `TEST MODE: injecting…` / `Publish attempt…` lines (expected 4 attempts about 1 s apart), then `…transaction dead-lettered…`.
4. Response: HTTP **202**, `"status":"DEAD_LETTERED"`, `routing.published=false`, `routing.deadLetterQueue="fraud-dlq"`.
5. RabbitMQ: `fraud-dlq` has 1 message with `correlation_id: corr-dlq-0001` and an envelope containing `eventId`, `transactionId`, `correlationId`,
   `failure.errorType`, a sanitised `failure.reason`, `retry.totalAttempts: 4`, `originalTransaction` and `enrichedTransaction`. `fraud-high-priority` has **no** new message.
6. Set the property back to `false` and restart.

**Method B — DLQ failure (expects HTTP 503):** `docker stop <rabbit-container>`, send any valid payload, expect HTTP **503**
`DLQ_PUBLISH_FAILED` after roughly 3+ s of retries (connection timeouts may add time). `docker start <rabbit-container>` afterwards.

## 19. Troubleshooting
| Symptom | Likely cause / fix |
|---|---|
| `Missing artifact … mule-amqp-connector:1.9.4` / cannot resolve plugin | Version/coordinates unverified. Add Exchange credentials (`settings.xml`, server id `anypoint-exchange-v3`), or in Studio *Add module* and let it pick the available AMQP version, then align `pom.xml`. |
| `mule-maven-plugin` version error / "Unknown packaging mule-application" | Set `mule.maven.plugin.version` to the one used by a fresh Studio project on your install. |
| Studio: unknown element `amqp:message`/`amqp:properties`, or `exchangeName` rejected | The AMQP Publish element shape was written from memory. Open the Publish component in the Studio UI, set Body = `#[payload]`, Exchange = (empty/default), Routing key = `#[vars.targetQueue]`, Properties as in the XML, and compare the generated XML. |
| `Unable to find a flow named …` / `Could not resolve property placeholder` | Property missing or file not on classpath; keep `application.properties` in `src/main/resources`. |
| Deployment fails with DataWeave error | DataWeave was **not executed** during generation. The console shows script, line and column; the scripts are in the `ee:transform` elements. |
| `ACCESS_REFUSED` / connection refused | RabbitMQ not running, wrong port, or credentials differ from `application.properties`. |
| Messages "published" but queue empty | Target queue does not exist (default-exchange publish is silently dropped). Run the setup script. |
| Priority not shown / not honoured | `fraud-high-priority` lacks `x-max-priority=10` (section 5). |
| Port 8082 already in use | Change `http.port`. |
| `503 VELOCITY_BUSY` after an app crash | A stale lock (non-persistent store; restart clears it, otherwise it expires after 30 s). |

## Manual steps still required after import
1. Create/verify the three queues (section 5) — nothing declares them automatically.
2. Confirm the `GT` vs `GTE` threshold semantics with the team.
3. Resolve Maven dependencies; fix any version/coordinate mismatch reported by Studio.
4. Run the tests in sections 11–18 once to confirm behaviour on your runtime.
