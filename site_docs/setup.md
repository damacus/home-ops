---
title: The setup
layout: documentation
---

# The setup

Start here to understand what runs in the house and which bit to look at next.
The manifests describe the intended setup; they aren’t a live health report.

## How it fits together

Radxa nodes run K3s. Flux takes the configuration in this repository and reconciles
it into the cluster. Cilium handles pod networking and service addresses;
Traefik handles the HTTP edge. External Secrets brings credentials in from
1Password. Stateful applications use CloudNativePG, Longhorn and RustFS as
appropriate. Grafana, VictoriaMetrics and Loki help explain what went wrong.

- [Service guides](applications/index.erb): what an application does and how to look after it.
- [Edge routing](../docs/EDGE-ROUTING.md): hostnames, HTTPRoute and Traefik.
- [Provisioning](../provisioning/README.md): build an image, enrol a node or recover without a working cluster.
- [Repository tooling](../docs/tooling.md): install the tools and find the commands.
- [Backup design](../docs/ADR-0001-pull-based-backup-and-portable-recovery.md): the proposed independent recovery layer and what still needs proving.

## When you need to change something

Find its configuration and operating guide first. Use `task --list` for cluster
operations and `mise tasks` for node provisioning. Changes go through a PR and
Flux; an emergency live change needs bringing back into Git afterwards.

For a broken service, start at [Debugging](debugging.erb). For the reason behind
a surprising choice, try [History](history.erb). The useful mistakes are kept there.
