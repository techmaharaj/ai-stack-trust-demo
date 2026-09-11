# Source snippets for Gate 2 (context & retrieval). Plain strings, seeded
# into Milvus Lite via seed_runbooks.py. Deliberately mixed: some match the
# checkout-service scenario closely, some don't -- so retrieval actually
# has to pick, not just return snippet #1 every time.

RUNBOOKS = [
    "Runbook: CrashLoopBackOff on a stateless service. First check "
    "`kubectl logs <pod> --previous` for the exit reason before restarting "
    "anything -- a restart without reading the prior crash's logs destroys "
    "the evidence.",

    "Runbook: DB connection timeout errors ('context deadline exceeded' "
    "connecting to postgres). Usually one of: (1) DB is actually down, "
    "(2) a NetworkPolicy or security group changed, (3) connection pool "
    "exhausted upstream. Check DB reachability from a debug pod in the "
    "same namespace before assuming app-side code is at fault.",

    "Runbook: connection pool exhausted after N retries. If the pool size "
    "is unchanged and this just started, look for a recent traffic spike "
    "or a leaked connection (a code path that opens a connection but "
    "doesn't close it on error). Restarting the pod resets the pool but "
    "does not fix a leak -- it will recur.",

    "Runbook: OOMKilled pods. Check `kubectl describe pod` for "
    "'OOMKilled' under Last State. Compare memory usage against the "
    "container's configured limit. Raising the limit is a mitigation, "
    "not a root cause fix -- find what changed in memory usage first.",

    "Runbook: ImagePullBackOff. Almost always a registry auth problem or "
    "a typo'd image tag. Check `kubectl describe pod` events for the "
    "exact pull error before touching the deployment spec.",

    "Runbook: readiness probe failing but the process is running. Check "
    "whether the probe's port/path actually matches what the app listens "
    "on -- this is the single most common cause, more common than the "
    "app actually being unhealthy.",

    "Runbook: prod database credential rotation. Any credential rotation "
    "for a prod-labeled resource requires a change ticket and the "
    "`demo.io/approved-by` annotation before the platform will accept it. "
    "This is enforced by policy, not convention -- an unapproved attempt "
    "is denied at the API server, not just discouraged.",

    "Runbook: service down after a recent deploy. Check the rollout "
    "history first (`kubectl rollout history`) -- a bad deploy is a more "
    "common cause than infrastructure drift, and rolling back is often "
    "faster than root-causing forward.",

    "Runbook: intermittent 5xx from a service behind an ingress. Check "
    "ingress controller logs and upstream health checks before assuming "
    "the backend pod itself is unhealthy -- the pod may be fine and the "
    "routing layer is the actual fault.",

    "Runbook: PersistentVolumeClaim stuck Pending. Check the "
    "StorageClass exists and has a provisioner; on a local/dev cluster "
    "this is very often a missing default StorageClass, not a quota or "
    "capacity issue.",

    "Runbook: node under memory pressure evicting pods. Check "
    "`kubectl describe node` for MemoryPressure conditions before "
    "chasing an individual pod's logs -- the eviction may not be that "
    "pod's fault at all.",

    "Runbook: DNS resolution failures inside the cluster (service name "
    "not resolving). Check CoreDNS pod health and logs first -- a "
    "cluster-wide DNS problem looks identical to an app-level bug from "
    "inside a single failing pod.",
]
