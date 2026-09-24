# OPTIONAL: email from Azure Managed Grafana (monitoring option A)

Azure Managed Grafana (Standard tier) configures SMTP on the Azure resource.

```bash
az grafana update --name amg-tpgpoc --resource-group rg-tpgpoc \
  --smtp enabled --host smtp.example.com:587 \
  --user <smtp-user> --password <smtp-password> \
  --from-address tpg-alerts@example.com --from-name "Tanzu Postgres POC" \
  --start-tls-policy MandatoryStartTLS --skip-verify false
```

Check the flags with `az grafana update --help` for your amg extension version. The
same settings are in the Azure portal: Azure Managed Grafana resource, Settings,
Configuration, Email Settings. Terraform users can set the `smtp` block of
`azurerm_dashboard_grafana` instead.

Then, in Grafana: Alerting, Contact points, add an Email contact point named
`tpg-email`, and set it as the default notification policy receiver.
