#!/usr/bin/env python3
"""Generate the fleet dashboard, Grafana-managed alert rules and PrometheusRules
from one definition, so the managed and standalone options stay identical.

Usage: python3 monitoring/grafana/generate.py   (run from the repository root)
Requires PyYAML.
"""
import copy
import json
import os
import re
import yaml

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MON = os.path.join(ROOT, "monitoring")

# NOTE: argo_workflows_* counter names get a _total suffix in Prometheus exposition.
# Confirm on the hub: curl -s http://<controller-metrics-svc>:8080/metrics | grep tpg_

ALERTS = [
    dict(uid="tpg-instance-not-running", title="Postgres instance not Running",
         expr='1 - max by (cluster, instance_namespace, instance_name) (tanzu_postgres_instance_state{state="Running"})',
         op="gt", threshold=0, for_="5m", severity="critical",
         summary="{{ $labels.cluster }}/{{ $labels.instance_name }} is not in the Running state"),
    dict(uid="tpg-instance-count-dropped", title="Postgres instance count dropped",
         expr='count by (cluster) (tanzu_postgres_instance_state{state="Running"} offset 1h) - count by (cluster) (tanzu_postgres_instance_state{state="Running"})',
         op="gt", threshold=0, for_="0m", severity="warning",
         summary="Fewer Postgres instances on {{ $labels.cluster }} than one hour ago"),
    dict(uid="tpg-replicas-below-desired", title="Postgres pod replicas below desired",
         expr='max by (cluster, namespace, statefulset) (kube_statefulset_replicas{namespace=~"pg-.*"}) - max by (cluster, namespace, statefulset) (kube_statefulset_status_replicas_ready{namespace=~"pg-.*"})',
         op="gt", threshold=0, for_="10m", severity="warning",
         summary="{{ $labels.cluster }}/{{ $labels.statefulset }} has fewer ready pods than desired"),
    dict(uid="tpg-backup-failed", title="Postgres backup failed (24h)",
         expr='count by (cluster, instance_namespace, instance_name) ((tanzu_postgres_backup_phase{phase="Failed"} == 1) and on (cluster, instance_namespace, backup_name) ((time() - tanzu_postgres_backup_created_timestamp) < 86400))',
         op="gt", threshold=0, for_="0m", severity="critical",
         summary="A backup of {{ $labels.cluster }}/{{ $labels.instance_name }} failed in the last 24 hours"),
    dict(uid="tpg-backup-running-long", title="Postgres backup running too long",
         expr='max by (cluster, instance_namespace, instance_name, backup_name) (tanzu_postgres_backup_phase{phase="Running"})',
         op="gt", threshold=0, for_="3h", severity="warning",
         summary="Backup {{ $labels.backup_name }} on {{ $labels.cluster }} has been running for more than 3 hours"),
    dict(uid="tpg-no-recent-backup", title="No successful Postgres backup in 26h",
         expr='(time() - max by (cluster, instance_namespace, instance_name) (tanzu_postgres_backup_completed_timestamp and on (cluster, instance_namespace, backup_name) (tanzu_postgres_backup_phase{phase="Succeeded"} == 1))) / 3600',
         op="gt", threshold=26, for_="0m", severity="critical",
         summary="No successful backup of {{ $labels.cluster }}/{{ $labels.instance_name }} for more than 26 hours"),
    dict(uid="tpg-backup-skipped", title="Postgres backup skipped (previous still running)",
         expr='sum by (cluster, instance_name) (increase(argo_workflows_tpg_backup_result_total{result="SKIPPED_IN_PROGRESS"}[1h]))',
         op="gt", threshold=0, for_="0m", severity="warning",
         summary="The backup workflow skipped {{ $labels.cluster }}/{{ $labels.instance_name }} because the previous backup was still running"),
    dict(uid="tpg-restore-failed", title="Postgres restore failed (24h)",
         expr='count by (cluster, instance_namespace, target_instance) ((tanzu_postgres_restore_phase{phase="Failed"} == 1) and on (cluster, instance_namespace, restore_name) ((time() - tanzu_postgres_restore_created_timestamp) < 86400))',
         op="gt", threshold=0, for_="0m", severity="critical",
         summary="A restore to {{ $labels.cluster }}/{{ $labels.target_instance }} failed in the last 24 hours"),
    dict(uid="tpg-replication-lag", title="Postgres replication lag high",
         expr='max by (cluster, postgres_instance) (pg_replication_lag_seconds)',
         op="gt", threshold=30, for_="5m", severity="warning",
         summary="Replication lag on {{ $labels.cluster }}/{{ $labels.postgres_instance }} is above 30 seconds"),
    dict(uid="tpg-wal-archiving-failing", title="Postgres WAL archiving failing",
         expr='sum by (cluster, postgres_instance) (increase(pg_stat_archiver_failed_count[15m]))',
         op="gt", threshold=0, for_="0m", severity="critical",
         summary="WAL archiving is failing on {{ $labels.cluster }}/{{ $labels.postgres_instance }}; point-in-time recovery is at risk"),
    dict(uid="tpg-connections-high", title="Postgres connections above 80%",
         expr='sum by (cluster, postgres_instance) (pg_stat_activity_count) / max by (cluster, postgres_instance) (pg_settings_max_connections)',
         op="gt", threshold=0.8, for_="10m", severity="warning",
         summary="{{ $labels.cluster }}/{{ $labels.postgres_instance }} uses more than 80% of max_connections"),
    # ---- Delete workflows (tpg-delete-instance, tpg-delete-apps)
    dict(uid="tpg-delete-failed", title="Instance delete failed",
         expr='sum by (cluster, instance_name) (increase(argo_workflows_tpg_delete_result_total{result!="SUCCEEDED"}[1h]))',
         op="gt", threshold=0, for_="0m", severity="warning",
         summary="A delete of {{ $labels.cluster }}/{{ $labels.instance_name }} did not succeed; the instance may be half deleted"),
    # ---- Vault on the hub (unseal mode shamir: sealed after every vault-0 restart)
    dict(uid="tpg-vault-sealed", title="Vault sealed or not reporting",
         expr='(1 - max(vault_core_unsealed)) or absent(vault_core_unsealed)',
         op="gt", threshold=0, for_="2m", severity="critical",
         summary="Vault on the hub is sealed (or its metrics are missing): workflows fail with VAULT_SEALED and secrets are not refreshed. Unseal it with tpg-aks-infra scripts/run.sh ... --only vault-unseal"),
    dict(uid="tpg-exporter-down", title="postgres-exporter target down",
         expr='1 - max by (cluster, postgres_instance) (up{postgres_instance!=""})',
         op="gt", threshold=0, for_="5m", severity="warning",
         summary="postgres-exporter on {{ $labels.cluster }}/{{ $labels.postgres_instance }} cannot be scraped"),
]

FOLDER_UID = "tpg-postgres"
FOLDER_TITLE = "Tanzu Postgres"
GROUP = "tpg-postgres"


def grafana_rule(a, ds_uid):
    return {
        "uid": a["uid"],
        "title": a["title"],
        "condition": "C",
        "data": [
            {"refId": "A", "relativeTimeRange": {"from": 900, "to": 0}, "datasourceUid": ds_uid,
             "model": {"refId": "A", "expr": a["expr"], "instant": True, "range": False,
                       "intervalMs": 60000, "maxDataPoints": 43200}},
            {"refId": "B", "datasourceUid": "__expr__",
             "model": {"refId": "B", "type": "reduce", "expression": "A", "reducer": "last",
                       "settings": {"mode": "dropNN"}}},
            {"refId": "C", "datasourceUid": "__expr__",
             "model": {"refId": "C", "type": "threshold", "expression": "B",
                       "conditions": [{"evaluator": {"type": a["op"], "params": [a["threshold"]]}}]}},
        ],
        "noDataState": "OK",
        "execErrState": "Error",
        "for": a["for_"],
        "labels": {"severity": a["severity"]},
        "annotations": {"summary": a["summary"]},
    }


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


class Dumper(yaml.SafeDumper):
    pass


def _str(d, s):
    return d.represent_scalar("tag:yaml.org,2002:str", s, style='"' if ("{{" in s or ":" in s) else None)


Dumper.add_representer(str, _str)


# ---- 1. Grafana provisioning (standalone hub, kube-prometheus-stack grafana.alerting)
def helm_escape(rule):
    # The Grafana chart renders grafana.alerting through Helm tpl, so Grafana
    # template expressions must be escaped to survive rendering.
    r = copy.deepcopy(rule)
    r["annotations"]["summary"] = re.sub(r"\{\{(.*?)\}\}", lambda m: '{{ "{{" }}' + m.group(1) + '{{ "}}" }}',
                                         r["annotations"]["summary"])
    return r


prov = {"apiVersion": 1, "groups": [{"orgId": 1, "name": GROUP, "folder": FOLDER_TITLE, "interval": "1m",
                                     "rules": [helm_escape(grafana_rule(a, "prometheus")) for a in ALERTS]}]}
values = {"grafana": {"alerting": {"tpg-alert-rules.yaml": prov}}}
write(os.path.join(MON, "grafana/alerts/grafana-alerting-values.yaml"),
      "# GENERATED by monitoring/grafana/generate.py - do not edit by hand.\n"
      "# Grafana-managed alert rules for the standalone hub (kube-prometheus-stack values).\n"
      + yaml.dump(values, Dumper=Dumper, sort_keys=False, width=1000))

# ---- 2. Grafana provisioning API payloads (Azure Managed Grafana)
for a in ALERTS:
    r = grafana_rule(a, "${DATASOURCE_UID}")
    r.update({"folderUID": FOLDER_UID, "ruleGroup": GROUP, "orgID": 1})
    write(os.path.join(MON, "grafana/alerts/api", a["uid"] + ".json"), json.dumps(r, indent=2) + "\n")

# ---- 3. PrometheusRule (standalone Prometheus -> Alertmanager email)
ops = {"gt": ">", "lt": "<"}
prom_rules = []
for a in ALERTS:
    name = "".join(w.capitalize() for w in a["uid"].replace("tpg-", "").split("-"))
    rule = {"alert": "TanzuPostgres" + name,
            "expr": "(%s) %s %s" % (a["expr"], ops[a["op"]], a["threshold"]),
            "labels": {"severity": a["severity"]},
            "annotations": {"summary": a["summary"]}}
    if a["for_"] != "0m":
        rule["for"] = a["for_"]
    prom_rules.append(rule)
pr = {"apiVersion": "monitoring.coreos.com/v1", "kind": "PrometheusRule",
      "metadata": {"name": "tpg-rules", "namespace": "monitoring", "labels": {"release": "kps"}},
      "spec": {"groups": [{"name": "tanzu-postgres", "rules": prom_rules}]}}
write(os.path.join(MON, "standalone/hub/prometheusrule-tpg.yaml"),
      "# GENERATED by monitoring/grafana/generate.py - do not edit by hand.\n"
      + yaml.dump(pr, Dumper=Dumper, sort_keys=False, width=1000))

# ---- 4. Dashboard
DS = {"type": "prometheus", "uid": "${datasource}"}
panels = []
pid = [0]


def panel(title, ptype, targets, x, y, w, h, extra=None):
    pid[0] += 1
    p = {"id": pid[0], "title": title, "type": ptype, "datasource": DS,
         "gridPos": {"x": x, "y": y, "w": w, "h": h},
         "targets": [dict(refId=chr(65 + i), datasource=DS, expr=e, legendFormat=l,
                          instant=(ptype in ("stat", "table", "bargauge")), range=(ptype in ("timeseries", "barchart")))
                     for i, (e, l) in enumerate(targets)]}
    if extra:
        p.update(extra)
    panels.append(p)


def row(title, y):
    pid[0] += 1
    panels.append({"id": pid[0], "type": "row", "title": title, "collapsed": False,
                   "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []})


C = '{cluster=~"$cluster"}'
thr_red = {"fieldConfig": {"defaults": {"thresholds": {"mode": "absolute", "steps": [
    {"color": "green", "value": None}, {"color": "red", "value": 1}]}}, "overrides": []}}

row("Fleet overview", 0)
panel("Postgres instances per AKS cluster", "bargauge",
      [('count by (cluster) (tanzu_postgres_instance_state{state="Running",cluster=~"$cluster"})', "{{cluster}}")], 0, 1, 8, 7,
      {"options": {"orientation": "horizontal", "displayMode": "gradient", "reduceOptions": {"calcs": ["lastNotNull"]}}})
panel("Healthy instances", "stat",
      [('sum by (cluster) (tanzu_postgres_instance_state{state="Running",cluster=~"$cluster"})', "{{cluster}}")], 8, 1, 8, 7,
      {"fieldConfig": {"defaults": {"color": {"mode": "fixed", "fixedColor": "green"}}, "overrides": []}})
panel("Unhealthy instances", "stat",
      [('count by (cluster) (tanzu_postgres_instance_state{state="Running",cluster=~"$cluster"} == 0) or on (cluster) (count by (cluster) (tanzu_postgres_instance_state{state="Running",cluster=~"$cluster"}) * 0)', "{{cluster}}")],
      16, 1, 8, 7, thr_red)
panel("Instance state", "table",
      [('tanzu_postgres_instance_state{cluster=~"$cluster"} == 1', "")], 0, 8, 24, 8,
      {"transformations": [{"id": "labelsToFields", "options": {"mode": "columns"}},
                           {"id": "organize", "options": {"excludeByName": {"Time": True, "Value": True, "__name__": True, "job": True, "instance": True, "pod": True, "service": True, "endpoint": True, "container": True, "customresource_group": True, "customresource_kind": True, "customresource_version": True}}}]})
row("Replicas", 16)
panel("Pod replicas: ready vs desired", "table",
      [('max by (cluster, namespace, statefulset) (kube_statefulset_status_replicas_ready{namespace=~"pg-.*",cluster=~"$cluster"})', "ready"),
       ('max by (cluster, namespace, statefulset) (kube_statefulset_replicas{namespace=~"pg-.*",cluster=~"$cluster"})', "desired")], 0, 17, 14, 8,
      {"transformations": [{"id": "merge", "options": {}},
                           {"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": {"Value #A": "ready", "Value #B": "desired"}}}]})
panel("Desired read replicas", "table",
      [('max by (cluster, instance_namespace, instance_name) (tanzu_postgres_instance_read_replicas{cluster=~"$cluster"})', "")], 14, 17, 10, 8,
      {"transformations": [{"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": {"Value": "readReplicas"}}}]})
row("Backup and restore", 25)
panel("Backups succeeded", "stat", [('sum by (cluster) (tanzu_postgres_backup_phase{phase="Succeeded",cluster=~"$cluster"})', "{{cluster}}")], 0, 26, 8, 6,
      {"fieldConfig": {"defaults": {"color": {"mode": "fixed", "fixedColor": "green"}}, "overrides": []}})
panel("Backups failed", "stat", [('sum by (cluster) (tanzu_postgres_backup_phase{phase="Failed",cluster=~"$cluster"})', "{{cluster}}")], 8, 26, 8, 6, thr_red)
panel("Backups in progress", "stat", [('sum by (cluster) (tanzu_postgres_backup_phase{phase=~"Pending|Running",cluster=~"$cluster"})', "{{cluster}}")], 16, 26, 8, 6,
      {"fieldConfig": {"defaults": {"color": {"mode": "fixed", "fixedColor": "blue"}}, "overrides": []}})
panel("Restores succeeded", "stat", [('sum by (cluster) (tanzu_postgres_restore_phase{phase="Succeeded",cluster=~"$cluster"})', "{{cluster}}")], 0, 32, 8, 6,
      {"fieldConfig": {"defaults": {"color": {"mode": "fixed", "fixedColor": "green"}}, "overrides": []}})
panel("Restores failed", "stat", [('sum by (cluster) (tanzu_postgres_restore_phase{phase="Failed",cluster=~"$cluster"})', "{{cluster}}")], 8, 32, 8, 6, thr_red)
panel("Restores in progress", "stat", [('sum by (cluster) (tanzu_postgres_restore_phase{phase!~"Succeeded|Failed",cluster=~"$cluster"})', "{{cluster}}")], 16, 32, 8, 6,
      {"fieldConfig": {"defaults": {"color": {"mode": "fixed", "fixedColor": "blue"}}, "overrides": []}})
panel("Backup workflow results (24h)", "table",
      [('sum by (cluster, instance_name, backup_type, result) (increase(argo_workflows_tpg_backup_result_total[24h]))', "")], 0, 38, 12, 8,
      {"transformations": [{"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": {"Value": "runs"}}}]})
panel("Hours since last successful backup", "table",
      [('(time() - max by (cluster, instance_namespace, instance_name) (tanzu_postgres_backup_completed_timestamp{cluster=~"$cluster"} and on (cluster, instance_namespace, backup_name) (tanzu_postgres_backup_phase{phase="Succeeded"} == 1))) / 3600', "")], 12, 38, 12, 8,
      {"fieldConfig": {"defaults": {"decimals": 1, "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "red", "value": 26}]},
                                    "custom": {"cellOptions": {"type": "color-background"}}}, "overrides": []},
       "transformations": [{"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": {"Value": "hours"}}}]})
row("Database", 46)
panel("Replication lag (seconds)", "timeseries", [('max by (cluster, postgres_instance) (pg_replication_lag_seconds{cluster=~"$cluster"})', "{{cluster}}/{{postgres_instance}}")], 0, 47, 12, 8)
panel("WAL archive failures (15m)", "timeseries", [('sum by (cluster, postgres_instance) (increase(pg_stat_archiver_failed_count{cluster=~"$cluster"}[15m]))', "{{cluster}}/{{postgres_instance}}")], 12, 47, 12, 8)
panel("Connections used (%)", "timeseries", [('100 * sum by (cluster, postgres_instance) (pg_stat_activity_count{cluster=~"$cluster"}) / max by (cluster, postgres_instance) (pg_settings_max_connections{cluster=~"$cluster"})', "{{cluster}}/{{postgres_instance}}")], 0, 55, 12, 8)
row("Delete", 63)
panel("Instance deletes (7d)", "table",
      [('sum by (cluster, instance_name, purge_pvcs, result) (increase(argo_workflows_tpg_delete_result_total[7d]))', "")], 0, 64, 12, 8,
      {"transformations": [{"id": "organize", "options": {"excludeByName": {"Time": True}, "renameByName": {"Value": "runs"}}}]})
pid[0] += 1
panels.append({"id": pid[0], "title": "Active alerts", "type": "alertlist", "gridPos": {"x": 12, "y": 55, "w": 12, "h": 8},
               "options": {"viewMode": "list", "groupMode": "default", "maxItems": 50, "sortOrder": 1,
                           "stateFilter": {"firing": True, "pending": True, "noData": False, "normal": False, "error": True},
                           "folder": {"uid": FOLDER_UID, "title": FOLDER_TITLE}, "showInstances": True}})
dashboard = {
    "uid": "tpg-fleet", "title": "Tanzu Postgres Fleet", "tags": ["tanzu-postgres", "tpg"],
    "timezone": "utc", "schemaVersion": 39, "version": 1, "refresh": "1m",
    "time": {"from": "now-24h", "to": "now"},
    "templating": {"list": [
        {"name": "datasource", "type": "datasource", "query": "prometheus", "label": "Data source", "current": {}},
        {"name": "cluster", "type": "query", "label": "Cluster", "datasource": DS,
         "query": {"query": "label_values(tanzu_postgres_instance_state, cluster)", "refId": "cluster"},
         "definition": "label_values(tanzu_postgres_instance_state, cluster)",
         "includeAll": True, "multi": True, "allValue": ".*", "refresh": 2, "current": {}}]},
    "panels": panels,
}
write(os.path.join(MON, "standalone/hub/dashboards/tpg-fleet.json"), json.dumps(dashboard, indent=2) + "\n")


# ---- 5. Component dashboards (instance overview, replication and HA, backup/WAL/restore, alerts)
# Same data source variable as the fleet dashboard, so they work on the hub
# Grafana (standalone) and on Azure Managed Grafana (Managed_Prometheus).
# Metric sources:
#   pg_* and up{postgres_instance}  postgres-exporter sidecar of every data pod (PodMonitor postgres-instances)
#   tanzu_postgres_*                kube-state-metrics custom resource metrics (tpg-ksm, monitoring/ksm/values.yaml)
#   kube_*                          kube-state-metrics
#   container_*, kubelet_volume_*   kubelet / cAdvisor (kube-prometheus-stack, or the Azure managed Prometheus defaults)
#   argo_workflows_tpg_*            Argo Workflows controller on the hub (workflow metrics)
class Board:
    def __init__(self, uid, title, description, variables):
        self.uid, self.title, self.description = uid, title, description
        self.panels, self.pid, self.y = [], 0, 0
        self.variables = variables

    def row(self, title):
        self.pid += 1
        self.panels.append({"id": self.pid, "type": "row", "title": title, "collapsed": False,
                            "gridPos": {"x": 0, "y": self.y, "w": 24, "h": 1}, "panels": []})
        self.y += 1

    def panel(self, title, ptype, targets, x, w, h, extra=None, description=None, newline=False):
        self.pid += 1
        p = {"id": self.pid, "title": title, "type": ptype, "datasource": DS,
             "gridPos": {"x": x, "y": self.y, "w": w, "h": h},
             "targets": [dict(refId=chr(65 + i), datasource=DS, expr=e, legendFormat=l,
                              instant=(ptype in ("stat", "table", "bargauge", "gauge")),
                              range=(ptype in ("timeseries", "barchart", "state-timeline")))
                         for i, (e, l) in enumerate(targets)]}
        if description:
            p["description"] = description
        if extra:
            p.update(copy.deepcopy(extra))
        self.panels.append(p)
        if newline or x + w >= 24:
            self.y += h

    def alertlist(self, title, w, h, state_filter):
        self.pid += 1
        self.panels.append({"id": self.pid, "title": title, "type": "alertlist",
                            "gridPos": {"x": 0, "y": self.y, "w": w, "h": h},
                            "options": {"viewMode": "list", "groupMode": "default", "maxItems": 100, "sortOrder": 1,
                                        "stateFilter": state_filter, "dashboardAlerts": False,
                                        "folder": {"uid": FOLDER_UID, "title": FOLDER_TITLE}, "showInstances": True}})
        if w >= 24:
            self.y += h

    def write(self):
        board = {"uid": self.uid, "title": self.title, "description": self.description,
                 "tags": ["tanzu-postgres", "tpg"], "timezone": "utc", "schemaVersion": 39, "version": 1,
                 "refresh": "30s", "time": {"from": "now-6h", "to": "now"},
                 "links": [{"title": "Tanzu Postgres", "type": "dashboards", "tags": ["tpg"], "asDropdown": True,
                            "includeVars": True, "keepTime": True}],
                 "templating": {"list": self.variables}, "panels": self.panels}
        write(os.path.join(MON, "standalone/hub/dashboards", self.uid + ".json"), json.dumps(board, indent=2) + "\n")
        return len(self.panels)


def var_query(name, label, query, include_all=True, multi=True):
    return {"name": name, "type": "query", "label": label, "datasource": DS,
            "query": {"query": query, "refId": name}, "definition": query,
            "includeAll": include_all, "multi": multi, "allValue": ".*", "refresh": 2, "current": {}, "sort": 1}


V_DS = {"name": "datasource", "type": "datasource", "query": "prometheus", "label": "Data source", "current": {}}
V_CLUSTER = var_query("cluster", "Cluster", "label_values(tanzu_postgres_instance_state, cluster)")
V_INSTANCE = var_query("instance", "Instance",
                       'label_values(tanzu_postgres_instance_state{cluster=~"$cluster"}, instance_name)')
# Selectors: the exporter labels pods with postgres_instance, the custom
# resource metrics carry instance_name, and the pods live in pg-<instance>.
PG = 'cluster=~"$cluster", postgres_instance=~"$instance"'
CR = 'cluster=~"$cluster", instance_name=~"$instance"'
NSX = 'cluster=~"$cluster", namespace=~"pg-($instance)"'


def unit(u, decimals=None, extra=None):
    d = {"fieldConfig": {"defaults": {"unit": u}, "overrides": []}}
    if decimals is not None:
        d["fieldConfig"]["defaults"]["decimals"] = decimals
    if extra:
        d["fieldConfig"]["defaults"].update(extra)
    return d


def thresholds(steps, u=None, background=False):
    d = {"fieldConfig": {"defaults": {"thresholds": {"mode": "absolute", "steps": steps}}, "overrides": []}}
    if u:
        d["fieldConfig"]["defaults"]["unit"] = u
    if background:
        d["fieldConfig"]["defaults"]["custom"] = {"cellOptions": {"type": "color-background"}}
        d["options"] = {"colorMode": "background"}
    return d


def table(rename=None, hide=("Time",)):
    return {"transformations": [{"id": "organize", "options": {
        "excludeByName": {h: True for h in hide}, "renameByName": rename or {}}}]}


GREEN_RED_1 = [{"color": "green", "value": None}, {"color": "red", "value": 1}]
RED_GREEN_1 = [{"color": "red", "value": None}, {"color": "green", "value": 1}]

# ---- 5a. Instance overview
b = Board("tpg-instance", "Tanzu Postgres - Instance overview",
          "Per cluster and instance: availability, connections, throughput, cache, size, locks and the resources of the Postgres pods.",
          [V_DS, V_CLUSTER, V_INSTANCE])
b.row("Availability")
b.panel("Instance state (operator)", "table",
        [('tanzu_postgres_instance_state{%s} == 1' % CR, "")], 0, 12, 7,
        table({"state": "currentState"}, ("Time", "Value", "__name__", "job", "instance", "pod", "service", "endpoint",
                                            "container", "namespace", "customresource_group", "customresource_kind",
                                            "customresource_version")),
        description="status.currentState of every Postgres object (kube-state-metrics custom resource metrics).")
b.panel("Exporter up per pod", "stat", [('max by (cluster, postgres_instance, pod) (up{%s})' % PG, "{{cluster}}/{{pod}}")],
        12, 6, 7, thresholds(RED_GREEN_1, background=True),
        description="1 when the postgres-exporter sidecar of the pod is scraped. The tpg-exporter-down alert fires after 5 minutes at 0.")
b.panel("Postgres reachable (pg_up)", "stat", [('max by (cluster, postgres_instance, pod) (pg_up{%s})' % PG, "{{cluster}}/{{pod}}")],
        18, 6, 7, thresholds(RED_GREEN_1, background=True))
b.row("Connections and throughput")
b.panel("Connections used (% of max_connections)", "timeseries",
        [('100 * sum by (cluster, postgres_instance) (pg_stat_activity_count{%s}) / max by (cluster, postgres_instance) (pg_settings_max_connections{%s})' % (PG, PG),
          "{{cluster}}/{{postgres_instance}}")], 0, 12, 8,
        unit("percent", 1, {"thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "red", "value": 80}]},
                            "custom": {"thresholdsStyle": {"mode": "line"}}}),
        description="The tpg-connections-high alert fires above 80% for 10 minutes.")
b.panel("Connections by state", "timeseries",
        [('sum by (cluster, postgres_instance, state) (pg_stat_activity_count{%s})' % PG, "{{cluster}}/{{postgres_instance}} {{state}}")],
        12, 12, 8, unit("short", 0))
b.panel("Transactions per second", "timeseries",
        [('sum by (cluster, postgres_instance) (rate(pg_stat_database_xact_commit{%s}[5m]))' % PG, "{{cluster}}/{{postgres_instance}} commit"),
         ('sum by (cluster, postgres_instance) (rate(pg_stat_database_xact_rollback{%s}[5m]))' % PG, "{{cluster}}/{{postgres_instance}} rollback")],
        0, 12, 8, unit("ops", 1))
b.panel("Cache hit ratio", "timeseries",
        [('sum by (cluster, postgres_instance) (rate(pg_stat_database_blks_hit{%s}[5m])) / clamp_min(sum by (cluster, postgres_instance) (rate(pg_stat_database_blks_hit{%s}[5m])) + sum by (cluster, postgres_instance) (rate(pg_stat_database_blks_read{%s}[5m])), 1)' % (PG, PG, PG),
          "{{cluster}}/{{postgres_instance}}")], 12, 12, 8, unit("percentunit", 2, {"min": 0, "max": 1}))
b.panel("Rows per second", "timeseries",
        [('sum by (cluster, postgres_instance) (rate(pg_stat_database_tup_fetched{%s}[5m]))' % PG, "{{cluster}}/{{postgres_instance}} fetched"),
         ('sum by (cluster, postgres_instance) (rate(pg_stat_database_tup_inserted{%s}[5m]))' % PG, "{{cluster}}/{{postgres_instance}} inserted"),
         ('sum by (cluster, postgres_instance) (rate(pg_stat_database_tup_updated{%s}[5m]))' % PG, "{{cluster}}/{{postgres_instance}} updated"),
         ('sum by (cluster, postgres_instance) (rate(pg_stat_database_tup_deleted{%s}[5m]))' % PG, "{{cluster}}/{{postgres_instance}} deleted")],
        0, 24, 8, unit("short", 0), description="Rows per second, summed over the databases of the instance.", newline=True)
b.row("Storage, locks and long transactions")
b.panel("Database size", "timeseries",
        [('sum by (cluster, postgres_instance, datname) (pg_database_size_bytes{%s, datname!~"template.*"})' % PG, "{{cluster}}/{{postgres_instance}} {{datname}}")],
        0, 8, 8, unit("bytes"))
b.panel("Locks by mode", "timeseries",
        [('sum by (cluster, postgres_instance, mode) (pg_locks_count{%s})' % PG, "{{cluster}}/{{postgres_instance}} {{mode}}")], 8, 8, 8, unit("short", 0))
b.panel("Deadlocks (15m)", "timeseries",
        [('sum by (cluster, postgres_instance) (increase(pg_stat_database_deadlocks{%s}[15m]))' % PG, "{{cluster}}/{{postgres_instance}}")], 16, 8, 8, unit("short", 0))
b.panel("Longest running transaction", "timeseries",
        [('max by (cluster, postgres_instance) (pg_stat_activity_max_tx_duration{%s})' % PG, "{{cluster}}/{{postgres_instance}}")], 0, 12, 8, unit("s"))
b.panel("Volume usage (data and WAL)", "bargauge",
        [('max by (cluster, namespace, persistentvolumeclaim) (kubelet_volume_stats_used_bytes{%s}) / max by (cluster, namespace, persistentvolumeclaim) (kubelet_volume_stats_capacity_bytes{%s})' % (NSX, NSX),
          "{{cluster}} {{persistentvolumeclaim}}")], 12, 12, 8,
        {"options": {"orientation": "horizontal", "displayMode": "gradient", "reduceOptions": {"calcs": ["lastNotNull"]}},
         "fieldConfig": {"defaults": {"unit": "percentunit", "min": 0, "max": 1, "thresholds": {"mode": "absolute", "steps": [
             {"color": "green", "value": None}, {"color": "orange", "value": 0.75}, {"color": "red", "value": 0.9}]}}, "overrides": []}})
b.row("Postgres pods")
b.panel("CPU per pod", "timeseries",
        [('sum by (cluster, namespace, pod) (rate(container_cpu_usage_seconds_total{%s, container!="", container!="POD"}[5m]))' % NSX, "{{cluster}}/{{pod}}")],
        0, 8, 8, unit("short", 2), description="CPU cores used (rate of container_cpu_usage_seconds_total).")
b.panel("Memory per pod (working set)", "timeseries",
        [('sum by (cluster, namespace, pod) (container_memory_working_set_bytes{%s, container!="", container!="POD"})' % NSX, "{{cluster}}/{{pod}}")],
        8, 8, 8, unit("bytes"))
b.panel("Container restarts (1h)", "timeseries",
        [('sum by (cluster, namespace, pod) (increase(kube_pod_container_status_restarts_total{%s}[1h]))' % NSX, "{{cluster}}/{{pod}}")],
        16, 8, 8, unit("short", 0))
n_instance = b.write()

# ---- 5b. Replication and HA
b = Board("tpg-replication", "Tanzu Postgres - Replication and HA",
          "Primary and standby roles, replication lag, replicas ready against desired, and WAL archiving.",
          [V_DS, V_CLUSTER, V_INSTANCE])
b.row("Roles and replicas")
b.panel("Role per pod (1 = replica, 0 = primary)", "table",
        [('max by (cluster, postgres_instance, pod) (pg_replication_is_replica{%s})' % PG, "")], 0, 12, 8,
        table({"Value": "is_replica"}),
        description="pg_replication_is_replica from the exporter: 0 on the primary, 1 on a standby or read replica.")
b.panel("Pods ready vs desired", "table",
        [('max by (cluster, namespace, statefulset) (kube_statefulset_status_replicas_ready{%s})' % NSX, "ready"),
         ('max by (cluster, namespace, statefulset) (kube_statefulset_replicas{%s})' % NSX, "desired")], 12, 12, 8,
        {"transformations": [{"id": "merge", "options": {}},
                             {"id": "organize", "options": {"excludeByName": {"Time": True},
                                                            "renameByName": {"Value #A": "ready", "Value #B": "desired"}}}]},
        description="The tpg-replicas-below-desired alert fires when ready stays below desired for 10 minutes.")
b.panel("Desired read replicas (spec)", "stat",
        [('max by (cluster, instance_name) (tanzu_postgres_instance_read_replicas{%s})' % CR, "{{cluster}}/{{instance_name}}")], 0, 24, 5,
        unit("short", 0), newline=True)
b.row("Replication lag")
b.panel("Replication lag (seconds)", "timeseries",
        [('max by (cluster, postgres_instance, pod) (pg_replication_lag_seconds{%s})' % PG, "{{cluster}}/{{pod}}")], 0, 24, 9,
        unit("s", 1, {"thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "red", "value": 30}]},
                      "custom": {"thresholdsStyle": {"mode": "line"}}}),
        description="The tpg-replication-lag alert fires above 30 seconds for 5 minutes.", newline=True)
b.row("WAL archiving")
b.panel("WAL segments archived (1h)", "timeseries",
        [('sum by (cluster, postgres_instance) (increase(pg_stat_archiver_archived_count{%s}[1h]))' % PG, "{{cluster}}/{{postgres_instance}}")],
        0, 12, 8, unit("short", 0))
b.panel("WAL archive failures (15m)", "timeseries",
        [('sum by (cluster, postgres_instance) (increase(pg_stat_archiver_failed_count{%s}[15m]))' % PG, "{{cluster}}/{{postgres_instance}}")],
        12, 12, 8, unit("short", 0, {"thresholds": {"mode": "absolute", "steps": GREEN_RED_1}, "custom": {"thresholdsStyle": {"mode": "line"}}}),
        description="The tpg-wal-archiving-failing alert fires on any failure: point-in-time recovery is at risk.")
b.panel("Pod restarts (24h)", "bargauge",
        [('sum by (cluster, pod) (increase(kube_pod_container_status_restarts_total{%s}[24h]))' % NSX, "{{cluster}}/{{pod}}")], 0, 24, 7,
        {"options": {"orientation": "horizontal", "displayMode": "basic", "reduceOptions": {"calcs": ["lastNotNull"]}},
         "fieldConfig": {"defaults": {"unit": "short", "decimals": 0, "thresholds": {"mode": "absolute", "steps": GREEN_RED_1}}, "overrides": []}},
        description="A failover restarts or replaces pods; a count that keeps growing points at a crash loop.")
n_repl = b.write()

# ---- 5c. Backup, WAL and restore
b = Board("tpg-backup", "Tanzu Postgres - Backup, WAL and restore",
          "Backups by phase and type, age of the newest full and incremental backup, WAL archiving, retention and restores.",
          [V_DS, V_CLUSTER, V_INSTANCE])
b.row("Backups")
b.panel("Hours since the newest successful full backup", "table",
        [('(time() - max by (cluster, instance_namespace, instance_name) (tanzu_postgres_backup_completed_timestamp{%s, backup_type="full"} and on (cluster, instance_namespace, backup_name) (tanzu_postgres_backup_phase{phase="Succeeded"} == 1))) / 3600' % CR, "")],
        0, 12, 8, dict(thresholds([{"color": "green", "value": None}, {"color": "orange", "value": 168}, {"color": "red", "value": 192}], None, True),
                       **table({"Value": "hours"})),
        description="The fleet schedule takes a full backup every Sunday (tpg-backup-full): more than 7 days (168 h) means a weekly full was missed.")
b.panel("Hours since the newest successful backup (any type)", "table",
        [('(time() - max by (cluster, instance_namespace, instance_name) (tanzu_postgres_backup_completed_timestamp{%s} and on (cluster, instance_namespace, backup_name) (tanzu_postgres_backup_phase{phase="Succeeded"} == 1))) / 3600' % CR, "")],
        12, 12, 8, dict(thresholds([{"color": "green", "value": None}, {"color": "red", "value": 26}], None, True),
                        **table({"Value": "hours"})),
        description="The tpg-no-recent-backup alert fires above 26 hours.")
b.panel("Backups by phase and type", "table",
        [('sum by (cluster, instance_name, backup_type, phase) (tanzu_postgres_backup_phase{%s} == 1)' % CR, "")], 0, 12, 8,
        table({"Value": "backups"}))
b.panel("Backups completed in the last 24 hours", "timeseries",
        [('count by (cluster, instance_name, backup_type) ((time() - tanzu_postgres_backup_completed_timestamp{%s}) < 86400)' % CR,
          "{{cluster}}/{{instance_name}} {{backup_type}}")], 12, 12, 8, unit("short", 0),
        description="One full backup on Sunday and one incremental on the other days is the fleet schedule.")
b.panel("Backup workflow results (24h)", "table",
        [('sum by (cluster, instance_name, backup_type, result) (increase(argo_workflows_tpg_backup_result_total{cluster=~"$cluster", instance_name=~"$instance"}[24h]))', "")],
        0, 12, 8, table({"Value": "runs"}),
        description="Results of the tpg-backup runs (CronWorkflows tpg-backup-full and tpg-backup-incr, and manual runs).")
b.panel("Retention workflow results (7d)", "table",
        [('sum by (cluster, instance_name, result) (increase(argo_workflows_tpg_backup_retention_result_total{cluster=~"$cluster", instance_name=~"$instance"}[7d]))', "")],
        12, 12, 8, table({"Value": "runs"}),
        description="tpg-backup-retention expires whole chains older than retentionDays: EXPIRED, NOTHING_TO_EXPIRE, DRY_RUN.")
b.row("WAL archiving")
b.panel("WAL archive failures (15m)", "timeseries",
        [('sum by (cluster, postgres_instance) (increase(pg_stat_archiver_failed_count{%s}[15m]))' % PG, "{{cluster}}/{{postgres_instance}}")],
        0, 12, 8, unit("short", 0, {"thresholds": {"mode": "absolute", "steps": GREEN_RED_1}, "custom": {"thresholdsStyle": {"mode": "line"}}}))
b.panel("WAL segments archived (1h)", "timeseries",
        [('sum by (cluster, postgres_instance) (increase(pg_stat_archiver_archived_count{%s}[1h]))' % PG, "{{cluster}}/{{postgres_instance}}")],
        12, 12, 8, unit("short", 0))
b.row("Restores")
b.panel("Restores by phase", "table",
        [('sum by (cluster, instance_namespace, target_instance, phase) (tanzu_postgres_restore_phase{cluster=~"$cluster"} == 1)', "")],
        0, 12, 8, table({"Value": "restores"}))
b.panel("Restore workflow results (7d)", "table",
        [('sum by (cluster, instance_name, mode, result) (increase(argo_workflows_tpg_restore_result_total{cluster=~"$cluster", instance_name=~"$instance"}[7d]))', "")],
        12, 12, 8, table({"Value": "runs"}))
n_backup = b.write()

# ---- 5d. Alerts: the configured rules, their state and the value behind each one
b = Board("tpg-alerts", "Tanzu Postgres - Alerts",
          "The %d configured alert rules (monitoring/grafana/generate.py): current state, and each rule's expression over time with its threshold." % len(ALERTS),
          [V_DS])
b.row("State")
b.alertlist("Firing and pending", 24, 8, {"firing": True, "pending": True, "noData": False, "normal": False, "error": True})
b.panel("Rules firing in Prometheus (standalone PrometheusRule)", "timeseries",
        [('count by (alertname, cluster) (ALERTS{alertname=~"TanzuPostgres.*", alertstate="firing"})', "{{alertname}} {{cluster}}")],
        0, 24, 8, unit("short", 0),
        description="ALERTS series of the PrometheusRule tpg-rules (hub Prometheus, standalone option). Empty on Azure Managed Grafana, whose rules are Grafana-managed: see the list above.",
        newline=True)
b.row("Rule values (threshold shown as a line)")
col = 0
for a in ALERTS:
    steps = [{"color": "green", "value": None}, {"color": "red", "value": a["threshold"] if a["op"] == "gt" else a["threshold"]}]
    b.panel("%s (%s %s, for %s, %s)" % (a["title"], ">" if a["op"] == "gt" else "<", a["threshold"], a["for_"], a["severity"]),
            "timeseries", [(a["expr"], "")], col, 12, 7,
            unit("short", 2, {"thresholds": {"mode": "absolute", "steps": steps},
                              "custom": {"thresholdsStyle": {"mode": "line"}}}),
            description=a["summary"].replace("{{ $labels.", "<").replace(" }}", ">"))
    col = 12 if col == 0 else 0
if col == 12:
    b.y += 7
n_alerts = b.write()

print("generated %d alert rules, the fleet dashboard (%d panels) and dashboards tpg-instance (%d), tpg-replication (%d), tpg-backup (%d), tpg-alerts (%d)"
      % (len(ALERTS), len(panels), n_instance, n_repl, n_backup, n_alerts))
