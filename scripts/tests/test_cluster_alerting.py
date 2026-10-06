#!/usr/bin/env python3
"""Offline alerting checks. Requires PyYAML, Go, amtool 0.30.1, and Kustomize.

Optionally set HELM_CHART_ARCHIVE to the kube-prometheus-stack 80.14.4 archive.
Only dummy data is used. No cluster, Vault, or SMTP connection is made.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
MONITORING = ROOT / "cluster/platform/observability/monitoring"
SECRET_NAME = "alertmanager-runtime-config"

# Render the exact standard Go template syntax used in this ExternalSecret.
# ESO supplies toJson through Sprig; this equivalent uses encoding/json.
# An in-cluster ESO Ready check is still required before activation.
RENDERER = r'''
package main
import ("encoding/json"; "os"; "text/template")
func main() {
 var input struct { Template string; Values map[string]string }
 if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil { panic(err) }
 funcs := template.FuncMap{"toJson": func(v any) (string, error) {
   b, err := json.Marshal(v); return string(b), err
 }}
 t, err := template.New("eso").Option("missingkey=error").Funcs(funcs).Parse(input.Template)
 if err != nil { panic(err) }
 if err := t.Execute(os.Stdout, input.Values); err != nil { panic(err) }
}
'''


def run(*args, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, **kwargs)
    if result.returncode:
        # This test only ever handles dummy values, never live config or credentials.
        raise subprocess.CalledProcessError(result.returncode, args, output=result.stdout,
                                            stderr=result.stderr)
    return result.stdout


class ClusterAlertingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="cluster-alerting-test-")
        cls.tmp = Path(cls.temp.name)
        cls.addClassCleanup(cls.temp.cleanup)
        helper = cls.tmp / "render.go"
        helper.write_text(RENDERER)
        cls.renderer = cls.tmp / "render-eso"
        run("go", "build", "-o", str(cls.renderer), str(helper))
        cls.es = yaml.safe_load((MONITORING / "shared/alertmanager-config.yaml").read_text())
        cls.data = cls.es["spec"]["target"]["template"]["data"]
        cls.values = {
            "smtpFrom": 'Cluster alerts <alerts@example.org>',
            "smtpTo": 'operator@example.net',
            "smtpUsername": 'alertmanager@example.org',
            "smtpPassword": 'dummy:"quoted"\\slash\n$(SHOULD_NOT_EXPAND)',
        }
        cls.rendered = {key: cls.render(value, cls.values) for key, value in cls.data.items()}
        for name, content in cls.rendered.items():
            (cls.tmp / name).write_text(content)
        cls.config = yaml.safe_load(cls.rendered["alertmanager.yaml"])
        # Replace only container mount paths in this disposable test fixture.
        fixture = cls.rendered["alertmanager.yaml"].replace(
            "/etc/alertmanager/config/", str(cls.tmp) + "/")
        cls.config_file = cls.tmp / "fixture.yaml"
        cls.config_file.write_text(fixture)

    @classmethod
    def render(cls, template, values):
        return run(str(cls.renderer), input=json.dumps({"Template": template, "Values": values}))

    def test_secret_values_and_missing_keys(self):
        self.assertEqual(self.rendered["smtp-password"], self.values["smtpPassword"])
        self.assertNotIn(self.values["smtpPassword"], self.rendered["alertmanager.yaml"])
        self.assertEqual(self.config["global"]["smtp_auth_username"], self.values["smtpUsername"])
        self.assertTrue(self.config["global"]["smtp_require_tls"])
        self.assertEqual(self.config["global"]["smtp_from"], self.values["smtpFrom"])
        self.assertEqual(self.config["receivers"][1]["email_configs"][0]["to"], self.values["smtpTo"])
        for key in self.values:
            incomplete = {k: v for k, v in self.values.items() if k != key}
            target = "smtp-password" if key == "smtpPassword" else "alertmanager.yaml"
            with self.subTest(key=key), self.assertRaises(subprocess.CalledProcessError):
                self.render(self.data[target], incomplete)

    def test_pinned_alertmanager_and_config(self):
        self.assertIn("version 0.30.1", run("amtool", "--version"))
        run("amtool", "check-config", str(self.config_file))
        self.assertEqual(self.config["inhibit_rules"], [
            {"source_matchers": ['severity="critical"'], "target_matchers": ['severity=~"warning|info"'], "equal": ["namespace", "alertname"]},
            {"source_matchers": ['severity="warning"'], "target_matchers": ['severity="info"'], "equal": ["namespace", "alertname"]},
            {"source_matchers": ['alertname="InfoInhibitor"'], "target_matchers": ['severity="info"'], "equal": ["namespace"]},
            {"target_matchers": ['alertname="InfoInhibitor"']},
        ])
        self.assertEqual(self.config["route"]["group_by"], ["namespace", "alertname"])

    def test_routing(self):
        cases = [
            ("homelab-email", "alertname=KubeNodeNotReady", "severity=critical"),
            ("homelab-email", "alertname=KubeNodeNotReady", "severity=warning"),
            ("homelab-email", "alertname=KubeNodeUnreachable", "severity=warning"),
            ("homelab-email", "alertname=KubeStatefulSetReplicasMismatch", "severity=warning", "namespace=databases"),
            ("blackhole", "alertname=KubeDeploymentReplicasMismatch", "severity=warning", "namespace=media"),
            ("homelab-email", "alertname=CephMgrPrometheusCollectorStalled", "severity=warning", "namespace=rook-ceph"),
            ("homelab-email", "alertname=KubePersistentVolumeFillingUp", "severity=warning", "namespace=media"),
            ("homelab-email", "alertname=KubePodCrashLooping", "severity=warning", "namespace=identity"),
            ("blackhole", "alertname=KubePodCrashLooping", "severity=warning", "namespace=media"),
            ("blackhole", "alertname=UnselectedWarning", "severity=warning", "namespace=identity"),
            ("blackhole", "alertname=CephHealthWarning", "severity=info"),
            ("blackhole", "alertname=CephNewUnreviewedWarning", "severity=warning"),
            ("blackhole", "alertname=Watchdog", "severity=critical"),
            ("blackhole", "alertname=InfoInhibitor", "severity=critical"),
            ("blackhole", "alertname=UnlabelledAlert"),
        ]
        for receiver, *labels in cases:
            with self.subTest(labels=labels):
                run("amtool", "config", "routes", "test", "--config.file=" + str(self.config_file),
                    "--verify.receivers=" + receiver, *labels)

    def test_notification_privacy_and_resolution(self):
        email = self.config["receivers"][1]["email_configs"][0]
        self.assertEqual(email["html"], "")
        self.assertTrue(email["send_resolved"])
        for state in ("firing", "resolved"):
            labels = {"alertname": "KubeNodeNotReady", "severity": "critical", "node": "test-node", "private": "DO_NOT_EMAIL"}
            data = {"Status": state, "Receiver": "homelab-email", "CommonLabels": labels,
                    "ExternalURL": "https://DO_NOT_EMAIL/", "CommonAnnotations": {"summary": "DO_NOT_EMAIL"},
                    "Alerts": [{"Status": state, "Labels": labels, "Annotations": {"description": "DO_NOT_EMAIL"},
                                "StartsAt": "2026-01-01T00:00:00Z", "EndsAt": "2026-01-01T00:05:00Z",
                                "GeneratorURL": "https://DO_NOT_EMAIL/"}]}
            datafile = self.tmp / "notification.json"
            datafile.write_text(json.dumps(data))
            for name, template in (("body", email["text"]), ("subject", email["headers"]["Subject"])):
                output = run("amtool", "template", "render", "--template.glob=" + str(self.tmp / "notifications.tmpl"),
                             "--template.text=" + template, "--template.data=" + str(datafile))
                self.assertNotIn("DO_NOT_EMAIL", output)
                self.assertIn(state.upper() if name == "subject" else state, output)
                if name == "body":
                    self.assertIn("test-node", output)
                    if state == "resolved":
                        self.assertIn("Resolved:", output)

    def test_kustomize_wiring(self):
        docs = list(yaml.safe_load_all(run("kustomize", "build", str(MONITORING / "shared"))))
        selected = [d for d in docs if d.get("kind") == "ExternalSecret" and d["metadata"]["name"] == SECRET_NAME]
        self.assertEqual(len(selected), 1)
        self.assertEqual(selected[0]["metadata"]["namespace"], "monitoring")
        self.assertEqual(selected[0]["spec"]["target"]["template"]["data"], self.data)

    @unittest.skipUnless(os.environ.get("HELM_CHART_ARCHIVE"), "set HELM_CHART_ARCHIVE for complete pinned-chart render")
    def test_helm_existing_secret(self):
        archive = os.environ["HELM_CHART_ARCHIVE"]
        chart = yaml.safe_load(run("helm", "show", "chart", archive))
        self.assertEqual(chart["version"], "80.14.4")
        docs = list(yaml.safe_load_all(run("helm", "template", "kube-prometheus-stack", archive,
                    "--namespace", "monitoring", "--kube-version", "1.36.2", "-f", str(MONITORING / "values.yaml"))))
        am = next(d for d in docs if d and d.get("kind") == "Alertmanager")
        self.assertEqual(am["spec"]["configSecret"], SECRET_NAME)
        self.assertIn("v0.30.1", am["spec"]["image"])
        configs = [d for d in docs if d and d.get("kind") == "Secret" and "alertmanager.yaml" in d.get("data", {})]
        self.assertEqual(configs, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
