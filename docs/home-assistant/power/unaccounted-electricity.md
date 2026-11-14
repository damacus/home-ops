---
doc_type: history
description: Calculation method from the retired electricity report.
---

# Historical unaccounted electricity analysis

The manual electricity report and its Task command have been retired. This
page retains the calculation method for interpreting earlier reports; it is
not a current operating procedure. Use Home Assistant's Energy dashboard for
current consumption data.

## Method

The report uses the latest complete short-term statistics timestamp as the end
of a 24-hour window.

1. Whole-home energy is the change in the Octopus electricity meter's
   accumulative-consumption statistic.
2. Accounted energy is the combined change from the device-consumption sensors
   configured in the Home Assistant Energy dashboard when this script was
   created.
3. Unaccounted energy is whole-home energy minus accounted energy.
4. Residual demand is whole-home current demand minus one non-overlapping power
   sensor for each accounted load.
5. Residual samples are reduced to five-minute medians. This limits false peaks
   caused by sensors updating at slightly different times.
6. Estimated base load is the 10th percentile of the five-minute residual.
7. The normal upper bound is the 90th percentile.
8. The spike threshold is the 95th percentile. A spike is reported only when
   two or more consecutive five-minute bins meet that threshold.

The task fails instead of returning a partial result when required entities are
missing, energy statistics do not span the complete window, or residual-demand
coverage is below 95%.

## Limits

The retired report used a snapshot of the Energy dashboard device list. Its
results do not automatically reflect later dashboard or sensor changes.

Unaccounted demand includes genuinely unmetered loads, modelled standby errors,
meter precision, and remaining timing differences. A reported spike is a reason
to correlate entity state changes; it does not identify a device by itself.
