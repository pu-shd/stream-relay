// Cost guardrails.
//
// Provisioned in IaC rather than clicked in the portal, so a teardown/redeploy cycle
// cannot silently drop them. That matters more here than usual: this service is *designed*
// to be destroyed and recreated, and a guardrail that only exists in the portal would
// survive exactly one rehearsal drill.
//
// HLS is public by default, which makes the egress downside unbounded. The projection of
// ~$423/mo egress assumes 10 Apple TVs; nothing stops a scraper multiplying it.

@description('Budget name.')
param budgetName string

@description('Monthly budget ceiling, USD. Alerts fire at percentages of this.')
param budgetAlertUsd int

@description('Warning threshold, USD. Converted to a percentage of the ceiling.')
param budgetWarnUsd int

@description('Email addresses to notify.')
param notificationEmails array

@description('Budget start date, YYYY-MM-01. Must be the first of a month; Azure rejects anything else.')
param startDate string

var warnPercent = min(100, max(1, int((budgetWarnUsd * 100) / budgetAlertUsd)))

resource budget 'Microsoft.Consumption/budgets@2023-05-01' = {
  name: budgetName
  properties: {
    category: 'Cost'
    amount: budgetAlertUsd
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: startDate
    }
    filter: {}
    notifications: {
      // Actual spend, at the warning level.
      warnActual: {
        enabled: true
        operator: 'GreaterThan'
        threshold: warnPercent
        contactEmails: notificationEmails
        thresholdType: 'Actual'
      }
      // Actual spend, at the ceiling.
      alertActual: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 100
        contactEmails: notificationEmails
        thresholdType: 'Actual'
      }
      // FORECAST, not just actual. This is the one that matters for a runaway-egress
      // incident: by the time actual spend crosses the ceiling the money is already
      // spent, whereas a forecast breach warns while there is still time to run
      // scripts/restrict.sh.
      forecastBreach: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 100
        contactEmails: notificationEmails
        thresholdType: 'Forecasted'
      }
    }
  }
}

output budgetId string = budget.id
output warnPercent int = warnPercent
