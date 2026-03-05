# Day 6 — Failure Simulation

## What We Did

Deliberately broke things in `dotnet-demo` to understand how OpenShift detects,
responds to, and recovers from common failure modes.

---

## Scenario 1 — CrashLoopBackOff

**What:** A pod whose container exits immediately with a non-zero exit code.

**How we triggered it:**
```yaml
containers:
- name: crasher
  image: busybox
  command: ["sh", "-c", "echo 'I am about to crash'; exit 1"]
```

**What OpenShift does:**
1. Container exits → kubelet sees non-zero exit code
2. `restartPolicy: Always` → kubelet restarts the container
3. Each restart backs off exponentially: 10s → 20s → 40s → 80s → 5min cap
4. After 3+ restarts → status shows `CrashLoopBackOff`

**Evidence observed:**
```
NAME         READY   STATUS             RESTARTS   AGE
crash-demo   0/1     CrashLoopBackOff   1          33s

Phase: Running  Restarts: 1  Reason: CrashLoopBackOff
Last log: "I am about to crash"
```

**Diagnosis commands:**
```bash
oc get pod crash-demo -n dotnet-demo
oc describe pod crash-demo -n dotnet-demo   # shows Last State + exit code
oc logs crash-demo -n dotnet-demo           # current attempt
oc logs crash-demo -n dotnet-demo --previous  # logs from crashed container
```

**Common real-world causes:**
- App fails to connect to DB at startup (missing secret/wrong connstr)
- Missing required environment variable
- App binary crash / unhandled exception on startup
- Wrong entrypoint / command in image

---

## Scenario 2 — OOMKill

**What:** Container exceeds its memory limit — kernel sends SIGKILL (signal 9).

**Expected evidence in production:**
```
Status:    OOMKilled
Reason:    OOMKilled
ExitCode:  137  (128 + SIGKILL)
```

**Note:** In CRC on nested Hyper-V, the kernel's memory overcommit and zero-page
deduplication make it difficult to force OOMKill reliably with simple shell commands.
In production Kubernetes/OpenShift clusters, OOMKill is enforced by cgroups v2.

**How LimitRange prevents surprise OOMKills (Day 3):**
The `LimitRange` we applied ensures every container has explicit memory limits,
so the scheduler can place pods on nodes with sufficient memory. Without limits,
a pod can grow unbounded until the node runs out of RAM → all pods on that node
can be OOMKilled (noisy-neighbour problem).

**Diagnosis commands:**
```bash
oc describe pod <name> -n dotnet-demo | grep -A3 "Last State"
# Look for: Reason: OOMKilled, Exit Code: 137
oc adm top pods -n dotnet-demo   # live memory usage
```

---

## Scenario 3 — Bad Deployment (ImagePullBackOff) + Rollback

**What:** Deployment updated to a non-existent image tag — simulates pushing bad config.

**How we triggered it:**
```bash
oc set image deployment/aspnetapp \
  aspnetapp=mcr.microsoft.com/dotnet/samples:does-not-exist-v999 -n dotnet-demo
```

**Timeline observed:**
```
t=0s:   oc set image → new ReplicaSet created, new pod scheduled
t=10s:  new pod → ErrImagePull (can't pull image)
t=22s:  new pod → ImagePullBackOff (backing off retries)
        OLD pod remains Running throughout — ZERO DOWNTIME
t=100s: old pod still serving HTTP 200 via Route
```

**Key insight: Rolling update strategy protects production traffic**
OpenShift's default `RollingUpdate` strategy (`maxUnavailable: 25%, maxSurge: 25%`)
means the old pod is only terminated AFTER the new pod passes readiness checks.
Since the new pod never becomes Ready, the old pod is never terminated.

**Rollback:**
```bash
oc rollout undo deployment/aspnetapp -n dotnet-demo
```

```
deployment.apps/aspnetapp rolled back
deployment "aspnetapp" successfully rolled out

Image restored: mcr.microsoft.com/dotnet/samples:aspnetapp
Route after rollback: HTTP 200  ✅
```

**Rollout history after the incident:**
```
REVISION  CHANGE-CAUSE
1         <none>   ← original deploy (Day 2)
3         <none>   ← bad image (automatically removed on rollback)
4         <none>   ← rollback (points to revision 1's image)
```

**Rollback to a specific revision:**
```bash
oc rollout undo deployment/aspnetapp --to-revision=1 -n dotnet-demo
```

---

## Scenario 4 — Manual Pod Kill (Self-Healing)

**What:** Simulate a pod being killed (node failure, OOM eviction, operator eviction).

**How we triggered it:**
```bash
oc delete pod aspnetapp-6c959d7cf8-4bbtk -n dotnet-demo
```

**What OpenShift does:**
- ReplicaSet controller detects `actual replicas (0) < desired replicas (1)`
- Immediately schedules a new pod
- New pod starts, passes probes → becomes Ready

**Recovery time:** < 30s (time to pull image from cache + startup)
App was still serving HTTP 200 within seconds because the pod was already in cache.

---

## Summary — Failure Modes and Responses

| Failure | OpenShift Response | User Action Needed |
|---------|-------------------|-------------------|
| Container crash (exit ≠ 0) | Restart with exponential backoff → CrashLoopBackOff | `oc logs --previous` to diagnose, fix image/config |
| OOMKill | Restart (if restartPolicy allows) | Increase memory limit or fix memory leak |
| ImagePullBackOff | New pod stalls, old pod stays Running | `oc rollout undo` to rollback |
| Pod deleted | ReplicaSet immediately reschedules | None — automatic |
| Node failure | Pods evicted → rescheduled on healthy nodes | None — automatic (with multi-replica) |

## Key Lesson — Why Probes + Rolling Updates Matter

Without readiness probes: OpenShift would mark the bad new pod Ready as soon as
it *starts*, then kill the old pod → brief downtime.

With readiness probes (set up Day 2): the new pod never passes readiness → old
pod is never terminated → zero downtime. **Probes are your blast shield.**

---

## Diagnostic Cheat Sheet

```bash
# See why a pod isn't running
oc describe pod <name> -n <ns>
oc logs <name> -n <ns>
oc logs <name> -n <ns> --previous   # logs from the last crash

# Watch rollout live
oc rollout status deployment/<name> -n <ns>

# See all revisions
oc rollout history deployment/<name> -n <ns>

# Rollback
oc rollout undo deployment/<name> -n <ns>
oc rollout undo deployment/<name> --to-revision=<N> -n <ns>

# Events (most useful for ImagePullBackOff, SCC failures, etc.)
oc get events -n <ns> --sort-by=.lastTimestamp | tail -20

# Resource usage
oc adm top pods -n <ns>
oc adm top nodes
```
