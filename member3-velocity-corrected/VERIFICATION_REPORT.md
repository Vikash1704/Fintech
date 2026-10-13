# VERIFICATION REPORT - Member 3 (Velocity + Queue), contract-compliant release

## 1. Project overview
Mule 4 app `fintech-fraud-detection` (Runtime 4.12.2 EE, Java 17, HTTP 1.11.3, AMQP 1.9.4, Object Store 1.3.1).
`POST http://localhost:8082/velocity` receives the **Contract 2** event (Member 2 output), updates the per-`card.cardToken`
sliding-window velocity counter, routes by `riskBand`, publishes the **Contract 3** envelope to RabbitMQ with retry, and sends
exhausted failures to `fraud-dlq` in the **Contract 8** schema. Starting point: the project you uploaded (Studio-imported, with the earlier fixes).

## 2. Contract fields verified (static, against the .docx)
* Input: `eventId`, `eventTimestamp`, `transaction{transactionId,amount,currency,...}`, `card{cardToken,maskedCardNumber,...}`, `customer{customerId,...}`,
  `merchant{merchantId,merchantCountry,...}`, `device{geoCountry,...}`, `riskScore`, `riskBand`, `ruleHits[{ruleCode,ruleName,ruleWeight}]`, `correlationId`.
  Required by validation: all of those used in the output envelope (see list below) + `ruleHits` array shape. `velocity` (optional, upstream) must be an object if present.
* Output envelope: `queueName`, `messagePriority`, `event{eventId, transactionId, cardToken, maskedCardNumber, amount, currency, customerId, merchantId,
  merchantCountry, geoCountry, riskScore, riskBand, ruleHits, correlationId}` - a script confirmed the XML's event keys equal this list, in this order, and nothing is added.
* DLQ: exactly `eventId, correlationId, errorType, errorMessage, failureStage, originalPayload, timestamp`.

## 3. Previous errors - recheck (all preserved)
| Earlier defect | Result |
|---|---|
| `routingKey` attribute invalid -> `amqp:routing-keys`/`amqp:routing-key` | Kept; no `routingKey=` attribute anywhere |
| AMQP properties as DW/CDATA | Kept as attributes (`contentType`, `priority`, `correlationId`); no DW block inside `amqp:properties` |
| Exchange config | Kept `exchangeName="#['']"` (default exchange) |
| Lock key could be null | `velocity-update-flow` is **byte-identical** to the working version (`(vars.cardToken default '')`) |
| `mergeWith` unsupported | Not used anywhere |
| Schema / scope errors | Namespace header identical to working version; primary and DLQ `amqp:publish` elements are identical to the working version apart from the (non-semantic) name/id |
| Studio-only artefacts | `.project`, `.classpath`, `target/` intentionally excluded |
Note: the original project's `target/META-INF/mule-artifact/artifact.ast` (built by Studio from the uploaded XML) is the only evidence that the *previous* XML parsed with the real connectors. It does not cover the new edits.

## 4. Files changed vs. the uploaded project
* `src/main/mule/fintech-fraud-detection.xml` - validation, extraction, routing, envelope, single publish step, response, DLQ message, 503 on dead-letter.
  Velocity flow and failure-injection flow unchanged. The two near-identical HIGH / LOW-MEDIUM publish branches were merged into one `until-successful` + one `amqp:publish`
  (the routing `choice` now only sets queue and priority); `riskLevel` -> `riskBand`.
* `src/main/resources/application.properties` - comment edits + new `dlq.failureStage=queue-publish` (**PROPOSED, needs Member 5's confirmation; not an agreed value**). No existing value changed.
* `README.md` - updated to the new contract/behaviour. `docs/BUILD_VALIDATION_REPORT.md` - replaced with a pointer (old content was stale).
* New: `test-payloads/contract-*.json` (9 files), `VERIFICATION_REPORT.md`, `CONTRACT_CHECKLIST.md`.
* Unchanged: `pom.xml`, `mule-artifact.json`, `scripts/*`, `exchange-docs/home.md`, and the nine original `test-payloads/0*.json` (md5 verified identical; they are legacy flat-format and now act as negative tests that return HTTP 400).

## 5. Build
Command: `mvn -B clean package` (Maven 3.9.11, JDK 21 in this sandbox; project targets 17).
Result: **BLOCKED by dependency access - NOT a successful build.** `org.mule.tools.maven:mule-maven-plugin:4.10.1` could not be resolved
(`Unknown packaging: mule-application`); the proxy answers HTTP 403 for `repository.mulesoft.org` and Maven Central. Nothing was compiled or packaged.
Please run `Maven > Update Project` / Run in Studio, which has your Exchange access.

## 6. Checks actually performed
* `xmllint` well-formedness of the Mule XML; 86 `doc:id` values, all unique; all 4 flow-refs resolve.
* Every `${...}` / `p('...')` key exists in `application.properties`, and none is unused.
* Envelope and DLQ key lists compared with the contract (script). No `fraudScore`/`riskLevel` in `src/`.
* Previously-fixed constructs checked by pattern (section 3); velocity flow and publish elements diffed against the original.
* All new payload files parse as JSON; originals' checksums unchanged.

## 7. NOT performed
* Maven build (blocked, above). Mule deployment / schema validation inside Studio.
* **DataWeave execution** - no DW runtime available; all new scripts (validation, envelope, DLQ, response) are unexecuted. They use only constructs already present in the working version, plus `filter` with a lambda, local `fun`s, `is Object`/`is Array`, and `(key: v) if cond`.
* All runtime tests: 400 on missing field, HIGH/LOW/MEDIUM routing and AMQP priority, velocity counts / independent cards / expiry, retry exhaustion, DLQ payload, no-false-success, RabbitMQ message properties - **NOT RUN**. Manual procedure: README sections 11-18 using `contract-*.json`.
* Credential setup: unchanged `guest/guest` local defaults; nothing new tested.

## 8. Dependencies, ambiguities, behaviour changes to confirm
1. **Dead-letter response is now HTTP 503** (`status: DEAD_LETTERED`), previously 202. Basis: Contract 3 "must not be reported as successfully accepted if it could not be queued". No separate API response contract was supplied; flag to Member 1/5. A caller that retries after a 503 may create a duplicate (the original is already in the DLQ).
2. **`failureStage=queue-publish`** is a proposal. `errorType` is `MULE:RETRY_EXHAUSTED` (the type actually caught); the underlying AMQP cause appears in `errorMessage`.
3. **Velocity vs scoring (OPEN):** Contract §11 expects `VELOCITY_HIGH` in `ruleHits`, but Member 2 scores before Member 3 counts (§4 says the count is "supplied/maintained by Member 3"). Member 3 does not alter `riskBand`/`ruleHits`/`riskScore`. The team must decide how Member 2 obtains the count.
4. Threshold kept at `GT` with 4 (so 5th transaction in 300 s exceeds). Contract example shows count 4 flagged `VELOCITY_HIGH` - may imply `GTE`; unconfirmed.
5. Contract 3 omits `eventTimestamp`, `customerName`, `merchantName` that Contract 4's output lists, and has no `velocity` field. None were added (not checked with Member 4). An upstream `velocity` object is not forwarded in the queue event; it is preserved inside the DLQ `originalPayload`. The velocity result is returned only in the HTTP response.
6. Stricter input validation: Member 3 now rejects (400) events lacking any field it must copy into the envelope (e.g. `device.geoCountry`, `merchant.merchantCountry`). Confirm Member 1/2 always supply them.
7. Publishing via the default exchange silently drops a message if the target queue does not exist; queues must be created first (scripts included). The AMQP `mandatory` flag exists in the connector but was not enabled because its runtime behaviour is unverified.
8. Velocity state is stored before publishing, so a failed publish still counts. Lock is per Mule instance only.

## 9. Import into Anypoint Studio
1. Extract the ZIP; the project folder is `fintech-fraud-detection-m3-corrected`.
2. Studio: *File > Import > Anypoint Studio > Anypoint Studio project from File System*, set Project Root to that folder, Finish. (Or copy the changed files listed in section 4 into your existing project - first copy your project folder as a backup.)
3. Set Java 17 and Mule runtime 4.12.2 EE; right-click project > *Maven > Update Project* (force update). Confirm the Problems panel is clean, then Run As > Mule Application.

## 10. RabbitMQ and properties
`docker run -d --name rabbitmq -p 5672:5672 -p 15672:15672 rabbitmq:4-management` (or start your existing container); run `scripts/setup-rabbitmq-queues.sh` (or `.ps1`) to create `fraud-high-priority` (`x-max-priority=10`), `fraud-standard`, `fraud-dlq`.
`application.properties` (localhost:5672, guest/guest, vhost `/`, HTTP 8082 `/velocity`) is unchanged apart from `dlq.failureStage`.
