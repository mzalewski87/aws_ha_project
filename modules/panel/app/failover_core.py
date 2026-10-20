"""failover_core — failover test scenarios as a small state machine, no third-party imports.

The scenarios talk to the world only through three injected objects, so the whole flow can be
unit-tested with a fake cluster:

  api  : ha(unit) -> {"state","peer_state","config_sync"}   (raises when unreachable)
         suspend(unit) / functional(unit)                    (PAN-OS HA suspend / restore)
         sync(unit)                                          (sync-to-remote of the running config)
  ec2  : state(unit) -> "running"|"stopped"|...  stop(unit)  start(unit)
  probe: ProbeStats fed by a background GlobalProtect portal check

Every wait has a timeout; a failed or timed-out step marks the job failed and leaves the cluster
for the "recover" scenario instead of guessing.
"""
import threading
import time

UNITS_REQUIRED = 2


class Aborted(Exception):
    """A scenario step failed or timed out; the message is safe to show."""


class ProbeStats:
    """Counts portal checks and measures outages (consecutive failures) in seconds."""

    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.total = 0
        self.failed = 0
        self.longest = 0.0
        self.outage_total = 0.0
        self._down_since = None
        self._lock = threading.Lock()

    def record(self, ok: bool) -> None:
        now = self.clock()
        with self._lock:
            self.total += 1
            if ok:
                if self._down_since is not None:
                    gap = now - self._down_since
                    self.outage_total += gap
                    self.longest = max(self.longest, gap)
                    self._down_since = None
            else:
                self.failed += 1
                if self._down_since is None:
                    self._down_since = now

    def summary(self) -> dict:
        now = self.clock()
        with self._lock:
            ongoing = (now - self._down_since) if self._down_since is not None else 0.0
            return {"checks": self.total, "failed": self.failed,
                    "longest_outage_s": round(max(self.longest, ongoing), 1),
                    "total_outage_s": round(self.outage_total + ongoing, 1),
                    "down_now": self._down_since is not None}


class Job:
    def __init__(self, scenario, user, clock=time.time):
        self.clock = clock
        self.id = f"{int(clock())}-{scenario}"
        self.scenario = scenario
        self.user = user
        self.started = clock()
        self.finished = None
        self.status = "running"  # running | done | failed
        self.steps = []
        self.result = {}
        self._lock = threading.Lock()

    def log(self, msg, level="info"):
        with self._lock:
            self.steps.append({"t": round(self.clock() - self.started, 1), "level": level, "msg": msg})

    def to_dict(self, probe=None):
        with self._lock:
            d = {"id": self.id, "scenario": self.scenario, "user": self.user, "status": self.status,
                 "elapsed": round((self.finished or self.clock()) - self.started, 1),
                 "steps": list(self.steps), "result": dict(self.result)}
        if probe is not None:
            d["probe"] = probe.summary()
        return d


class Ctx:
    def __init__(self, api, ec2, job, units, sleep=time.sleep, clock=time.monotonic):
        self.api, self.ec2, self.job, self.units = api, ec2, job, list(units)
        self.sleep, self.clock = sleep, clock

    def ha(self, unit):
        try:
            return self.api.ha(unit)
        except Exception:  # unreachable while rebooting / stopped
            return None

    def wait(self, pred, what, timeout, interval=5):
        start = self.clock()
        while True:
            try:
                if pred():
                    elapsed = self.clock() - start
                    self.job.log(f"{what}: done after {elapsed:.0f}s")
                    return elapsed
            except Exception:
                pass
            if self.clock() - start > timeout:
                raise Aborted(f"timed out after {timeout}s waiting for: {what}")
            self.sleep(interval)

    def is_active(self, unit):
        h = self.ha(unit)
        return bool(h and (h.get("state") or "").startswith("active"))

    def is_passive_synced(self, unit):
        h = self.ha(unit)
        return bool(h and h.get("state") == "passive" and h.get("config_sync") == "synchronized")


def find_roles(ctx):
    """Return (active_unit, passive_unit) or abort when the pair is not in a clean A/P state."""
    states = {u: ctx.ha(u) for u in ctx.units}
    active = [u for u, h in states.items() if h and (h.get("state") or "").startswith("active")]
    passive = [u for u, h in states.items() if h and h.get("state") == "passive"]
    if len(active) != 1 or len(passive) != 1:
        raise Aborted("the pair is not in a clean active/passive state: " +
                      ", ".join(f"{u}={(h or {}).get('state', 'unreachable')}" for u, h in states.items()))
    return active[0], passive[0]


def ensure_synced(ctx, active, passive, timeout=240):
    """Check running-config sync of the pair; when it is off, ask the active unit to push it.

    Live-seen: the pair can report 'not synchronized' for a while after a commit (for example a
    push from SCM) and then recover by itself. So wait briefly, then force a sync from the active
    unit, then wait again. Abort only if it still has not converged.
    """
    def synced():
        a, p = ctx.ha(active), ctx.ha(passive)
        return bool(a and p and a.get("config_sync") == "synchronized" and p.get("config_sync") == "synchronized")

    if synced():
        ctx.job.log("running configuration is synchronized on both units")
        return
    ctx.job.log("running configuration is NOT synchronized: giving it 20s, then forcing a sync", "warn")
    try:
        ctx.wait(synced, "configuration synchronized on its own", 20, 5)
        return
    except Aborted:
        pass
    ctx.job.log(f"asking {active} to sync its running configuration to {passive} (sync-to-remote)")
    ctx.api.sync(active)
    try:
        ctx.wait(synced, "configuration synchronized after the forced sync", timeout, 5)
    except Aborted:
        a, p = ctx.ha(active) or {}, ctx.ha(passive) or {}
        raise Aborted("the pair stays out of sync after a forced sync "
                      f"({active}: {a.get('config_sync')}, {passive}: {p.get('config_sync')}). "
                      "The two units have diverging local configuration: compare them and commit on the active unit.")


def sync_check(ctx):
    """Check config sync of the pair and repair it from the active unit when needed."""
    x, y = find_roles(ctx)
    ctx.job.log(f"pair roles: {x} active, {y} passive")
    ensure_synced(ctx, x, y)


def soft_failover(ctx):
    """Suspend the active unit (the PAN-OS HA way), watch the peer take over, then restore."""
    x, y = find_roles(ctx)
    ensure_synced(ctx, x, y)
    ctx.job.log(f"pair is healthy: {x} active, {y} passive, synchronized")
    ctx.job.log(f"suspending {x} (request high-availability state suspend)")
    ctx.api.suspend(x)
    takeover = ctx.wait(lambda: ctx.is_active(y), f"{y} becomes active", 180, 2)
    ctx.job.result["takeover_s"] = round(takeover, 1)
    ctx.job.log("observing the GlobalProtect portal for 20s on the new active unit")
    ctx.sleep(20)
    ctx.job.log(f"restoring {x} (request high-availability state functional)")
    ctx.api.functional(x)
    ctx.wait(lambda: ctx.is_passive_synced(x), f"{x} rejoins as passive and synchronized", 600)
    ctx.job.log(f"final roles: {y} active, {x} passive (preemption is off, so no second failover)")


def hard_failover(ctx):
    """Power the active unit off at the EC2 level, watch the takeover, then bring it back."""
    x, y = find_roles(ctx)
    ensure_synced(ctx, x, y)
    for u in (x, y):
        st = ctx.ec2.state(u)
        if st != "running":
            raise Aborted(f"{u} EC2 instance is '{st}', not running")
    ctx.job.log(f"pair is healthy: {x} active, {y} passive; stopping the EC2 instance of {x}")
    ctx.ec2.stop(x)
    takeover = ctx.wait(lambda: ctx.is_active(y), f"{y} becomes active", 300, 3)
    ctx.job.result["takeover_s"] = round(takeover, 1)
    ctx.wait(lambda: ctx.ec2.state(x) == "stopped", f"{x} fully stopped", 300)
    ctx.job.log("observing the GlobalProtect portal for 20s with one firewall down")
    ctx.sleep(20)
    ctx.job.log(f"starting {x} again")
    ctx.ec2.start(x)
    ctx.wait(lambda: ctx.ec2.state(x) == "running", f"{x} running", 180)
    ctx.wait(lambda: ctx.is_passive_synced(x), f"{x} boots, rejoins as passive and synchronized", 1200, 10)
    ctx.job.log(f"final roles: {y} active, {x} passive")


def recover(ctx):
    """Put the pair back to a normal state after an aborted run."""
    for u in ctx.units:
        st = ctx.ec2.state(u)
        if st == "stopped":
            ctx.job.log(f"{u} is stopped: starting it")
            ctx.ec2.start(u)
            ctx.wait(lambda u=u: ctx.ec2.state(u) == "running", f"{u} running", 180)
        elif st not in ("running", "pending"):
            ctx.job.log(f"{u} EC2 state is '{st}': leaving it", "warn")
    for u in ctx.units:
        ctx.wait(lambda u=u: ctx.ha(u) is not None, f"{u} API reachable", 900, 10)
    for u in ctx.units:
        h = ctx.ha(u) or {}
        if h.get("state") == "suspended":
            ctx.job.log(f"{u} is suspended: setting it functional")
            ctx.api.functional(u)
    ctx.wait(lambda: sum(1 for u in ctx.units if ctx.is_active(u)) == 1 and
             sum(1 for u in ctx.units if ctx.is_passive_synced(u)) == 1,
             "one active and one passive, synchronized", 900, 10)


SCENARIOS = {
    "sync": ("Check and repair configuration sync (forces a sync from the active unit if needed)", sync_check),
    "soft": ("HA failover (suspend the active firewall, then restore)", soft_failover),
    "hard": ("Hard failover (stop the active firewall's EC2 instance, then start it)", hard_failover),
    "recover": ("Recover the pair (start stopped firewalls, clear suspended state)", recover),
}


def run_job(ctx, fn):
    """Run one scenario to completion; never raises, always records the outcome on the job."""
    job = ctx.job
    try:
        fn(ctx)
        job.status = "done"
        job.log("finished OK")
    except Aborted as exc:
        job.status = "failed"
        job.log(str(exc), "error")
        job.log("the pair may be in an unusual state: use 'Recover' to restore it", "warn")
    except Exception as exc:  # unexpected: still fail visibly, not silently
        job.status = "failed"
        job.log(f"unexpected error: {type(exc).__name__}: {exc}"[:300], "error")
        job.log("the pair may be in an unusual state: use 'Recover' to restore it", "warn")
    finally:
        job.finished = job.clock()
