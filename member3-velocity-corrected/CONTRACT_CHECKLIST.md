# Contract checklist - Member 3 (Velocity + Queue)

Authority: `FinTech_Payment_Fraud_Team_Contract.docx` (section numbers below). Status key: PASS = verified by the checks named;
STATIC = verified by reading/static checks only (no Mule runtime, no DataWeave execution available); OPEN = needs a team decision.

| # | Requirement (contract §) | Where | Evidence | Status |
|---|---|---|---|---|
| 1 | Input is Contract 2: nested `transaction`, `card`, `customer`, `merchant`, `device` + `riskScore`, `riskBand`, `ruleHits`, `correlationId` (§4) | "Validate Required Fields" transform | Script read; payloads `contract-*.json` use this shape | STATIC |
| 2 | No `fraudScore` / `riskLevel` in the executable path (task) | whole XML | grep: 0 occurrences in `src/`; they remain only in legacy test payloads + docs describing rejection | PASS |
| 3 | Velocity key is `card.cardToken` (§3) | "Extract cardToken" transform | XML read; token pattern + full-card-number rejection kept | STATIC |
| 4 | `eventId`, `transactionId`, `correlationId` retained throughout (§1) | envelope, DLQ, responses | Envelope key check against §5 list | STATIC |
| 5 | Never log/store a full card number (§1) | validation, loggers | Loggers print only correlationId/queue/riskBand/velocity count; PAN-like `cardToken`/`maskedCardNumber` and `cardNumber`/`pan`/`cvv` fields rejected | STATIC |
| 6 | Routing: HIGH -> `fraud-high-priority`, LOW/MEDIUM -> `fraud-standard` (§5) | "Choice - Route by riskBand" | XML read; priorities 10 / 0 from properties | STATIC (not run) |
| 7 | Queue envelope = `{queueName, messagePriority, event{14 fields}}` (§5) | "Build Queue Envelope (Contract 3)" | Script check: event keys == contract list, in order; nothing added | STATIC |
| 8 | `queueName` / `messagePriority` equal the real AMQP destination / priority | envelope + `amqp:publish` | Same `vars.targetQueue` / `vars.messagePriority` feed both; byte-identical publish element vs. previously working version | STATIC |
| 9 | `ruleHits` and `riskScore` passed through unchanged; `riskBand` never altered by velocity (§4/§5) | envelope | Pass-through expression; only `upper(trim())` on `riskBand` for comparison | STATIC |
| 10 | Publish retried a configurable number of times (§5) | `until-successful` (`retry.*`) | Unchanged: 1 + 3 = 4 attempts, 1000 ms | STATIC |
| 11 | Retry exhausted -> original payload + failure reason to DLQ (§5, §8) | `dead-letter-after-retry-exhausted-flow` | DLQ keys == the 7 Contract 8 fields | STATIC |
| 12 | Event not reported as accepted if it could not be queued (§5) | DLQ flow sets 503; DLQ failure -> 503 | Behaviour change from 202; see report | STATIC / OPEN (confirm API response contract) |
| 13 | Velocity: per-card sliding window, threshold 4, `GT`, TTL 600 s, lock (previously agreed config) | `velocity-update-flow` | Flow is byte-identical to the previously working version | PASS (unchanged) / runtime NOT RUN |
| 14 | Velocity detection -> `VELOCITY_HIGH` in `ruleHits` (§11) | not implemented in Member 3 | Member 2 owns scoring (§2, §4) | OPEN - needs Member 2 / team |
| 15 | `failureStage` value for queue failures (§8 shows only `fraud-persistence`) | `dlq.failureStage=queue-publish` | Property exists and is used | OPEN - PROPOSED, Member 5 must confirm |
| 16 | Contract 3 carries no `eventTimestamp`, `customerName`, `merchantName` that Contract 4 output lists (§5 vs §6) | n/a | Not added (no confirmed Member 4 compatibility) | OPEN - Member 4 |
| 17 | Upstream `velocity` object (§4) not discarded | `vars.originalTransaction`, DLQ `originalPayload` | Not forwarded in the queue event (Contract 3 has no velocity field); preserved in the DLQ original payload | OPEN - confirm with Member 4 whether it is wanted |
| 18 | Member 3 MUnit (§9) | n/a | Out of scope - teammate | NOT DONE (by instruction) |
