# ADR 0001: Defer network hardware refresh

## Status

Accepted

## Date

2026-05-18

## Context

The current home network has known performance constraints:

- The UDM Pro should remain the router/firewall and should not become the internal switching backbone.
- The UNAS Pro has a 10Gb/s link that is currently underutilised.
- The Office Flex and `daniels-MBP` can use a faster path than the current 1Gb/s-constrained topology.
- The Radxa `node-*` hosts have 2.5GbE NICs, but there is not enough current multigig access switching to use that capacity.
- The US16-150W provides useful PoE and USP-RPS-backed maintenance resilience.
- Power draw matters; the network/rack is already a meaningful part of the home's baseline consumption.
- New physical cabling or fibre between the house and garage is not available because of garden constraints.

The investigated upgrade options all have material tradeoffs:

- `USW-Pro-Max-16-PoE` is the best-fit future US16 replacement for current port count, but it has only four 2.5GbE ports, uses an external AC/DC adapter, does not have USP RPS input, and needs a rack-mount accessory for a clean rack install.
- `USW-Pro-Max-24-PoE` preserves more capability, including more multigig PoE and USP RPS input, but is expensive and over-sized for the current port count.
- `USW-Pro-Max-24` has more multigig capacity and USP RPS input, but no PoE, so it does not replace the US16 by itself.
- `USW-Enterprise-8-PoE` is labelled Vintage and is physically too small for the intended rack direction.
- `USW-Pro-XG-8-PoE` is technically capable but has an unattractive idle power profile for this environment.
- `U7 Outdoor` and `U7 Pro Outdoor` are better-shaped options for a wireless garage backhaul than indoor APs, but replacing the current `U6 LR <-> U6 Mesh` path is not justified without measured pain.

## Decision

Do not buy replacement network switches or garage APs right now.

Keep the current hardware in place until there is measured pain or a stronger upgrade case.

The preferred future sequence remains:

1. Add a `USW-Aggregation` first if internal backbone performance becomes a priority.
2. Defer replacing the US16-150W until the loss of USP-RPS-backed access switching is acceptable.
3. If the US16 is replaced later and current port-count assumptions still hold, prefer `USW-Pro-Max-16-PoE` as the access switch, while explicitly accepting its four-port multigig limit and lack of USP RPS input.
4. Do not upgrade the house-to-garage wireless backhaul unless UniFi metrics or real workload tests show that the current path is unstable or too slow.

## Consequences

This avoids spending money on a like-for-like refresh that is mostly newer hardware rather than a decisive capability improvement.

The known limitations remain:

- Radxa nodes stay constrained by current 1Gb/s access paths until a multigig access switch is justified.
- MacBook-to-UNAS performance may remain below the best-case 2.5Gb/s client path until the core topology changes.
- The US16-150W remains a useful but older 1Gb/s PoE switch.
- The garage remains dependent on wireless backhaul.

The benefit is that the network keeps the existing RPS-backed PoE behaviour, avoids unnecessary power increase, and preserves budget for a more decisive future change.

## Revisit triggers

Reopen this decision if one or more of the following happens:

- Time Machine or large file transfers to the UNAS are measurably blocked by the current topology.
- Radxa node workloads need sustained storage/network throughput above 1Gb/s.
- Garage connectivity becomes unstable or too slow for real workloads.
- The US16-150W becomes unreliable, unsupported, or too power-expensive to keep.
- A better 8-16 port UniFi rack switch appears with enough 2.5GbE PoE ports, acceptable idle power, clean rack fit, and a better power-resilience story.

