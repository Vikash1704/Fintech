%dw 2.0
output application/json
var event = payload
var amount = (event.transaction.amount default 0) as Number
var velocity = (event.velocity.transactionCount default 0) as Number
var category = upper(event.merchant.merchantCategory default "")
var hour = (event.eventTimestamp as DateTime).hour
var highRiskCategories = (p('fraud.highRiskMerchantCategories') splitBy ",") map upper(trim($))
var countryMismatch =
    upper(event.merchant.merchantCountry default "") !=
    upper(event.card.issuingCountry default "")

var hits =
    (if (amount > (p('fraud.amountThreshold') as Number)) [{
        ruleCode: "AMOUNT_HIGH",
        ruleName: "Transaction amount above configured limit",
        ruleWeight: p('fraud.weights.AMOUNT_HIGH') as Number
    }] else [])
    ++
    (if (countryMismatch) [{
        ruleCode: "COUNTRY_MISMATCH",
        ruleName: "Transaction country differs from issuing country",
        ruleWeight: p('fraud.weights.COUNTRY_MISMATCH') as Number
    }] else [])
    ++
    (if (velocity > (p('fraud.velocityLimit') as Number)) [{
        ruleCode: "VELOCITY_HIGH",
        ruleName: "Too many transactions from same card in configured window",
        ruleWeight: p('fraud.weights.VELOCITY_HIGH') as Number
    }] else [])
    ++
    (if (highRiskCategories contains category) [{
        ruleCode: "MERCHANT_HIGH_RISK",
        ruleName: "High risk merchant category",
        ruleWeight: p('fraud.weights.MERCHANT_HIGH_RISK') as Number
    }] else [])
    ++
    (if (hour < (p('fraud.usualHours.start') as Number) or hour >= (p('fraud.usualHours.end') as Number)) [{
        ruleCode: "UNUSUAL_HOUR",
        ruleName: "Transaction outside usual hours",
        ruleWeight: p('fraud.weights.UNUSUAL_HOUR') as Number
    }] else [])

var score = hits reduce ((item, total = 0) -> total + item.ruleWeight)
---
(event - "correlationId") ++ {
    riskScore: score,
    riskBand: if (score >= 70) "HIGH"
              else if (score >= 40) "MEDIUM"
              else "LOW",
    ruleHits: hits,
    correlationId: event.correlationId
}