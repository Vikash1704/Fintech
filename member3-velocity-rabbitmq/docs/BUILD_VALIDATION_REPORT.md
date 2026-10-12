# Build Validation Report — fintech-fraud-detection (Member 3)

## Result: **NOT built, NOT deployed, NOT run.** Static checks only.

The generation sandbox has no Maven, no Anypoint Studio, no Mule runtime, no RabbitMQ/Docker, and cannot reach
`repository.mulesoft.org` or Maven Central (both returned no connection). Therefore **no `mvn clean package` was run**
and no claim of "compiles" or "zero errors" is made.

## Checked and passed (static)
| Check | Result |
|---|---|
| `xmllint --noout` on `pom.xml` and `src/main/mule/fintech-fraud-detection.xml` | well-formed |
| No markdown fences / prose inside the Mule XML | confirmed |
| `doc:id` values | 94, all unique |
| Every `flow-ref` target exists (4 flows) | yes |
| Every `config-ref` (`HTTP_Listener_config`, `AMQP_Config`) and every `objectStore` (`Velocity_Store`, `Velocity_Lock_Store`) is defined | yes |
| Every `${...}` placeholder and every `p('...')` has a key in `application.properties`; no unused keys | yes |
| `pom.xml` declares HTTP, AMQP and Object Store connector dependencies (`mule-plugin` classifier) | yes |
| Required branches: HIGH, LOW/MEDIUM, otherwise (defensive 400); 3 × `until-successful` + `amqp:publish`; `MULE:RETRY_EXHAUSTED` handler per branch; DLQ flow; flow-level handlers for 400/503/503/500 | present |
| Test payload JSON files and `mule-artifact.json` parse as JSON | yes |
| `scripts/setup-rabbitmq-queues.sh` | `bash -n` syntax OK (not executed) |
| ZIP integrity, root folder name, no `target/`, no IDE files, no local paths | see ZIP listing below |
| Card tokens/numbers in log messages | none logged; credentials only in `application.properties` |

## NOT verified (you must confirm in Studio / locally)
1. **Maven build** — never run. Dependency resolution untested.
2. **Connector coordinates/versions** — `mule-amqp-connector 1.9.4`, `mule-http-connector 1.11.3`, `mule-objectstore-connector 1.3.1` were taken from your brief and not checked against Exchange. Compatibility with Mule 4.12.2 not confirmed.
3. **`mule-maven-plugin` version 4.3.0** — chosen from memory; may need to match your Studio's version.
4. **`minMuleVersion` 4.9.0** — deliberately lower than 4.12.2 so it cannot block deployment; Studio may rewrite it.
5. **AMQP Publish XML shape** (`amqp:message` → `amqp:body` / `amqp:properties`, `exchangeName=""` for the default exchange, `deliveryMode: 2`, `priority`, `correlationId` keys) — written from knowledge of connector 1.x, not schema-validated.
6. **All DataWeave scripts** — none executed. Higher-risk spots: `try` from `dw::Runtime`, `mergeWith`, `Number {unit:"milliseconds"}` ↔ DateTime conversions, regex literals, `error.cause.message`.
7. **`os:store failIfPresent` / `os:retrieve default-value` attribute semantics**, and that the lock actually prevents concurrent lost updates (not load-tested; single runtime only).
8. **Error-type behaviour**: that `raise-error` inside `on-error-propagate` replaces the error as intended; that malformed JSON surfaces inside the first `try`.
9. **until-successful attempt count** — documented as 1 + 3 = 4 attempts; confirm from the "Publish attempt" log lines.
10. **Studio import** — project ships without `.project`/`.classpath`; relies on *Import → Anypoint Studio project from File System*.
11. **RabbitMQ 4.x behaviour**, queue scripts (the `.ps1` was not even syntax-checked), message priority 10 on the classic queue, persistence, correlation_id.
12. **HTTP status mapping** (200/202/400/503/500) — implemented, never exercised.

## Design decisions to confirm
* Threshold semantics default to `count > threshold` (`GT`); property `velocity.comparison=GTE` switches. Team contract wording was not available to me.
* Primary failure that was successfully dead-lettered returns **202 DEAD_LETTERED**, not 200.
* `riskLevel` is upper-cased in the published message (documented transformation); Member 2's value is otherwise untouched.
* `transactionId` / `eventId` are optional (preserved when present); `cardToken`, `correlationId`, `riskLevel` are required.
