# ClickHouse Federation Designs

Two runnable kind-based demos for federating independent ClickHouse
clusters via query-level federation (no replication or Raft ever crosses a
cluster boundary):

| Design | Topology | Use case |
|--------|----------|----------|
| [design-a](design-a/README.md) | **Flat**: 3 regional clusters (FRA/MUC/HAM), every region can query all others via a `global` Distributed table | Few, known regions; any region is a query entry point; includes full TLS + cross-region RBAC |
| [design-b](design-b/README.md) | **Hierarchical**: customer clusters → stateless federal router per T-CaaS cluster → stateless global router (single Grafana endpoint) | Many customer clusters across many Kubernetes clusters; adding a customer only touches its own T-CaaS cluster |

Each design is self-contained:

```bash
cd design-a   # or design-b
bash setup.sh
bash scripts/verify.sh
bash teardown.sh
```

Both demos can run side by side (distinct kind cluster names and host
ports).
