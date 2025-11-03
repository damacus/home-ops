# n8n TODO List

## Security Improvements
- [ ] **Investigate secure_cookie: true** - Test if we can enable secure cookies with end-to-end HTTPS
- [ ] **Review authentication settings** - Consider implementing OAuth/OIDC integration with Dex
- [ ] **Network policies** - Add Kubernetes NetworkPolicies to restrict traffic flow

## Performance & Scaling
- [ ] **Enable worker nodes** - Configure separate worker pods for better performance
- [ ] **Enable webhook pods** - Set up dedicated webhook processing pods
- [ ] **Resource optimization** - Monitor and adjust CPU/memory limits based on usage
- [x] **Redis optimization** - Consider dedicated Redis instance for n8n vs shared

## Monitoring & Observability
- [ ] **Add Prometheus metrics** - Configure n8n metrics export
  <https://docs.n8n.io/hosting/configuration/configuration-examples/prometheus/>
- [ ] **Create Grafana dashboard** - Build monitoring dashboard for n8n workflows
  <https://docs.n8n.io/hosting/configuration/configuration-examples/grafana/>
- [ ] **Set up alerting** - Configure alerts for failed workflows and system health
- [ ] **Log aggregation** - Ensure logs are properly collected and searchable

## Backup & Recovery
- [ ] **Workflow backup strategy** - Implement automated workflow export/backup
- [ ] **Test database recovery** - Validate CNPG backup/restore procedures
- [ ] **Document recovery process** - Create runbook for disaster recovery

## Configuration
- [ ] **Environment-specific settings** - Review configuration for production readiness
- [ ] **SSL/TLS review** - Investigate end-to-end encryption options
- [ ] **Storage optimization** - Consider persistent volume sizing and performance

## Integration
- [ ] **External service connections** - Document and secure external API integrations
- [ ] **Webhook security** - Implement webhook authentication and validation
- [ ] **Service mesh integration** - Consider Istio/Linkerd integration if adopted

## Documentation
- [ ] **User guide** - Create documentation for team workflow development
- [ ] **Deployment guide** - Document the deployment and configuration process
- [ ] **Troubleshooting guide** - Common issues and solutions

## Future Enhancements
- [ ] **High availability** - Multi-replica setup with proper session handling
- [ ] **External database** - Consider migrating to external PostgreSQL if needed
- [ ] **Custom nodes** - Evaluate and implement custom n8n nodes for specific use cases
