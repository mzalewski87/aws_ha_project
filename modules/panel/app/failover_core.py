"""failover_core — failover test scenarios as a small state machine, no third-party imports.

The scenarios talk to the world only through injected objects, so the whole flow can be
unit-tested with a fake cluster:

  api  : ha(unit) -> {"state","peer_state","config_sync","priority"}   (raises when unreachable)
         suspend(unit) / functional(unit)            (PAN-OS HA suspend / restore)
         sync(unit)                                  (sync-to-remote of the running config)
  ec2  : state(unit) -> "running"|"stopped"|...  stop(unit)  start(unit)
  probe: ProbeStats fed by a background GlobalProtect portal check

Every wait has a timeout; a failed or timed-out step marks the job failed and leaves the pair
for the "recover" scenario instead of guessing. Preemption is off on the pair (PANW guidance for
AWS), so after a test the roles stay swapped; "failback" (also run at the end of a test when
restore is on) makes the preferred unit (lowest HA device priority) active again.
"""
import threading
import time

MAX_OUTAGES = 200


class Aborted(Exception):
    """A scenario step failed or timed out; the message is safe to show."""


class ProbeStats:
    """Counts portal checks and records outages (consecutive failures) as time intervals."""

    def __init__(self, clock=time.time, base=None):
        self.clock = clock
        self.base = clock() if base is None else base
        self.total = 0
        self.failed = 0
        self.outages = []  # [start, end] in seconds from base; end None while ongoing
        self._lock = threading.Lock()

    def record(self, ok: bool) -> None:
        rel = round(self.clock() - self.base, 1)
        with self._lock:
            self.total += 1
            ongoing = bool(self.outages) and self.outages[-1][1] is None
            if ok and ongoing:
                self.outages[-1][1] = rel
            elif not ok:
                self.failed += 1
                if not ongoing and len(self.outages) < MAX_OUTAGES:
                    self.outages.append([rel, None])

    def summary(self) -> dict:
        now = round(self.clock() - self.base, 1)
        with self._lock:
            spans = [[s, e if e is not None else now] for s, e in self.outages]
            down = bool(self.outages) and self.outages[-1][1] is None
            lengths = [round(e - s, 1) for s, e in spans]
            return {"checks": self.total, "failed": self.failed,
                    "longest_outage_s": max(lengths, default=0.0),
                    "total_outage_s": round(sum(lengths), 1),
                    "down_now": down, "outages": spans}


class Job:
    def __init__(self, scenario, user, phases=(), clock=time.time, options=None, run_id=None):
        self.clock = clock
        self.started = clock()
        self.id = run_id or f"{int(self.started)}-{scenario}"
        self.scenario = scenario
        self.user = user
        self.options = dict(options or {})
        self.finished = None
        self.status = "running"  # running | done | failed
        self.phases = list(phases)
        self.phase = 0
        self.steps = []
        self.marks = []
        self.result = {}
        self.listeners = []  # called (job) after every change, e.g. to persist it
        self._lock = threading.Lock()

    def _t(self):
        return round(self.clock() - self.started, 1)

    def _changed(self):
        for fn in self.listeners:
            try:
                fn(self)
            except Exception:  # persistence must never break a running test
                pass

    def log(self, msg, level="info"):
        with self._lock:
            self.steps.append({"t": self._t(), "level": level, "msg": msg})
        self._changed()

    def mark(self, label):
        """A key moment for the timeline (failover triggered, peer active, roles restored...)."""
        with self._lock:
            self.marks.append({"t": self._t(), "label": label})
        self._changed()

    def enter(self, name):
        with self._lock:
            if name in self.phases:
                self.phase = self.phases.index(name)
        self.log(f"-- {name}")

    def to_dict(self):
        with self._lock:
            return {"id": self.id, "scenario": self.scenario, "user": self.user, "status": self.status,
                    "started": self.started, "options": dict(self.options),
                    "elapsed": round((self.finished or self.clock()) - self.started, 1),
                    "phases": list(self.phases), "phase": self.phase,
                    "steps": list(self.steps), "marks": list(self.marks), "result": dict(self.result)}


class Ctx:
    """units: the pair under test. others: units of the OTHER region(s), only read (the region
    outage test refuses to start unless another region has an active unit to take the traffic)."""

    def __init__(self, api, ec2, job, units, sleep=time.sleep, clock=time.monotonic, others=()):
        self.api, self.ec2, self.job, self.units = api, ec2, job, list(units)
        self.others = list(others)
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
                      ", ".join(f"{u}={(h or {}).get('state', 'unreachable')}" for u, h in states.items()) +
                      ". Use 'Recover' first.")
    return active[0], passive[0]


def preferred(ctx):
    """The unit that should normally be active: lowest HA device priority (PAN-OS: lower wins)."""
    prios = {}
    for u in ctx.units:
        raw = (ctx.ha(u) or {}).get("priority")
        try:
            prios[u] = int(raw) if raw not in (None, "") else 10**6  # 0 is valid (and the strongest)
        except ValueError:
            prios[u] = 10**6
    return sorted(ctx.units, key=lambda u: (prios[u], u))[0]


def ensure_synced(ctx, active, passive, timeout=240):
    """Check running-config sync of the pair; when it is off, ask the active unit to push it.

    Live-seen: the pair can report 'not synchronized' for a while after a commit (for example a
    push from SCM) and then recover by itself. So wait briefly, then force a sync from the active
    unit, then wait again. Abort only if it still has not converged. (Forcing is the last resort:
    on SCM-managed pairs it was checked live that sync-to-remote did not overwrite the peer's own
    interface addresses, which come from SCM per-device variables.)
    """
    def synced():
        a, p = ctx.ha(active), ctx.ha(passive)
        return bool(a and p and a.get("config_sync") == "synchronized" and p.get("config_sync") == "synchronized")

    if synced():
        ctx.job.log("running configuration is synchronized on both units")
        return
    ctx.job.log("running configuration is NOT synchronized: giving it 90s, then forcing a sync", "warn")
    try:
        ctx.wait(synced, "configuration synchronized on its own", 90, 5)
        return
    except Aborted:
        pass
    ctx.job.log(f"asking {active} to sync its running configuration to {passive} (sync-to-remote)")
    ctx.job.mark("forced config sync")
    ctx.api.sync(active)
    try:
        ctx.wait(synced, "configuration synchronized after the forced sync", timeout, 5)
    except Aborted:
        a, p = ctx.ha(active) or {}, ctx.ha(passive) or {}
        raise Aborted("the pair stays out of sync after a forced sync "
                      f"({active}: {a.get('config_sync')}, {passive}: {p.get('config_sync')}). "
                      "The two units have diverging local configuration: compare them and commit on the active unit.")


def _undo_on_abort(ctx, step, undo):
    """Run step(); if it (or the wait inside it) fails, run undo() before re-raising, so an
    aborted test never leaves a unit suspended or stopped with nobody to bring it back."""
    try:
        return step()
    except Exception as exc:
        ctx.job.log(f"step failed ({exc}); undoing it", "error")
        try:
            undo()
            ctx.job.log("undo sent")
        except Exception as undo_exc:  # report, keep the original error
            ctx.job.log(f"undo failed too: {undo_exc}", "error")
        raise


def failback(ctx):
    """Make the preferred unit active again by suspending the current active one, then restore it."""
    pref = preferred(ctx)
    if ctx.is_active(pref):
        ctx.job.log(f"{pref} (preferred primary) is already active: nothing to do")
        return
    cur, other = find_roles(ctx)
    ensure_synced(ctx, cur, other)
    ctx.job.log(f"failing back: suspending {cur} so that {pref} becomes active")
    ctx.job.mark(f"failback: suspend {cur}")

    def go():
        ctx.api.suspend(cur)
        return ctx.wait(lambda: ctx.is_active(pref), f"{pref} becomes active", 180, 2)
    t = _undo_on_abort(ctx, go, lambda: ctx.api.functional(cur))
    ctx.job.result["failback_s"] = round(t, 1)
    ctx.job.mark(f"{pref} active")
    ctx.api.functional(cur)
    ctx.wait(lambda: ctx.is_passive_synced(cur), f"{cur} rejoins as passive and synchronized", 600)
    ctx.job.mark("original roles restored")


def _restore(ctx):
    if ctx.job.options.get("restore", True):
        ctx.job.enter("failback to preferred primary")
        failback(ctx)
    else:
        ctx.job.log("restore of the original roles is off for this run: roles stay swapped")


def sync_check(ctx):
    """Check config sync of the pair and repair it from the active unit when needed."""
    ctx.job.enter("pre-checks")
    x, y = find_roles(ctx)
    ctx.job.log(f"pair roles: {x} active, {y} passive")
    ctx.job.enter("check and repair sync")
    ensure_synced(ctx, x, y)


def soft_failover(ctx):
    """Suspend the active unit (the PAN-OS HA way), watch the peer take over, then restore."""
    ctx.job.enter("pre-checks")
    x, y = find_roles(ctx)
    ensure_synced(ctx, x, y)
    ctx.job.log(f"pair is healthy: {x} active, {y} passive, synchronized")
    ctx.job.enter("trigger failover")
    ctx.job.log(f"suspending {x} (request high-availability state suspend)")
    ctx.job.mark(f"suspend {x}")

    def go():
        ctx.api.suspend(x)
        ctx.job.enter("takeover")
        return ctx.wait(lambda: ctx.is_active(y), f"{y} becomes active", 180, 2)
    takeover = _undo_on_abort(ctx, go, lambda: ctx.api.functional(x))
    ctx.job.result["takeover_s"] = round(takeover, 1)
    ctx.job.mark(f"{y} active")
    ctx.job.enter("observe")
    ctx.job.log("observing the GlobalProtect portal for 20s on the new active unit")
    ctx.sleep(20)
    ctx.job.enter("restore failed unit")
    ctx.job.log(f"restoring {x} (request high-availability state functional)")
    ctx.api.functional(x)
    ctx.wait(lambda: ctx.is_passive_synced(x), f"{x} rejoins as passive and synchronized", 600)
    ctx.job.mark(f"{x} passive")
    _restore(ctx)


def hard_failover(ctx):
    """Power the active unit off at the EC2 level, watch the takeover, then bring it back."""
    ctx.job.enter("pre-checks")
    x, y = find_roles(ctx)
    ensure_synced(ctx, x, y)
    for u in (x, y):
        st = ctx.ec2.state(u)
        if st != "running":
            raise Aborted(f"{u} EC2 instance is '{st}', not running")
    ctx.job.log(f"pair is healthy: {x} active, {y} passive")
    ctx.job.enter("stop active instance")
    ctx.job.log(f"stopping the EC2 instance of {x}")
    ctx.job.mark(f"EC2 stop {x}")

    def go():
        ctx.ec2.stop(x)
        ctx.job.enter("takeover")
        return ctx.wait(lambda: ctx.is_active(y), f"{y} becomes active", 300, 2)
    takeover = _undo_on_abort(ctx, go, lambda: ctx.ec2.start(x))
    ctx.job.result["takeover_s"] = round(takeover, 1)
    ctx.job.mark(f"{y} active")
    ctx.job.enter("observe")
    ctx.wait(lambda: ctx.ec2.state(x) == "stopped", f"{x} fully stopped", 300)
    ctx.job.log("observing the GlobalProtect portal for 20s with one firewall down")
    ctx.sleep(20)
    ctx.job.enter("start instance")
    ctx.job.log(f"starting {x} again")
    ctx.job.mark(f"EC2 start {x}")
    ctx.ec2.start(x)
    ctx.wait(lambda: ctx.ec2.state(x) == "running", f"{x} running", 180)
    ctx.job.enter("boot and rejoin HA")
    ctx.job.log("PAN-OS boots and rejoins HA (typically 4-8 minutes)")
    ctx.wait(lambda: ctx.is_passive_synced(x), f"{x} boots, rejoins as passive and synchronized", 1200, 10)
    ctx.job.mark(f"{x} passive")
    _restore(ctx)


def region_outage(ctx):
    """Take a whole region's pair down (both EC2 instances), watch the portal move to the other
    region (Global Accelerator health checks), then bring the region back and fail back."""
    ctx.job.enter("pre-checks")
    if not ctx.others:
        raise Aborted("no other region is configured: a region outage would just be an outage")
    alive = [u for u in ctx.others if ctx.is_active(u)]
    if not alive:
        raise Aborted("the other region has no active firewall to take over; refusing to start")
    x, y = find_roles(ctx)
    ensure_synced(ctx, x, y)
    for u in ctx.units:
        st = ctx.ec2.state(u)
        if st != "running":
            raise Aborted(f"{u} EC2 instance is '{st}', not running")
    ctx.job.log(f"this region: {x} active, {y} passive; other region active unit: {', '.join(alive)}")
    ctx.job.enter("stop the region")
    ctx.job.mark("EC2 stop " + " + ".join(ctx.units))

    def go():
        for u in ctx.units:
            ctx.ec2.stop(u)
        return ctx.wait(lambda: all(ctx.ec2.state(u) == "stopped" for u in ctx.units),
                        "both firewalls of this region stopped", 420, 5)
    _undo_on_abort(ctx, go, lambda: [ctx.ec2.start(u) for u in ctx.units])
    ctx.job.mark("region down")
    ctx.job.enter("observe")
    ctx.job.log("observing the portal for 30s: it should now be answered by the other region")
    ctx.sleep(30)
    ctx.job.enter("start the region")
    ctx.job.mark("EC2 start " + " + ".join(ctx.units))
    for u in ctx.units:
        ctx.ec2.start(u)
    ctx.wait(lambda: all(ctx.ec2.state(u) == "running" for u in ctx.units), "both firewalls running", 240)
    ctx.job.enter("boot and rejoin HA")
    ctx.job.log("PAN-OS boots on both units and they elect an active one (typically 6-10 minutes)")
    ctx.wait(lambda: sum(1 for u in ctx.units if ctx.is_active(u)) == 1 and
             sum(1 for u in ctx.units if ctx.is_passive_synced(u)) == 1,
             "one active and one passive, synchronized", 1500, 10)
    ctx.job.mark("region back")
    _restore(ctx)


def rebalance(ctx):
    """Make the preferred primary active again (no other changes)."""
    ctx.job.enter("pre-checks")
    find_roles(ctx)
    ctx.job.enter("failback to preferred primary")
    failback(ctx)


def recover(ctx):
    """Put the pair back to a normal state after an aborted run."""
    ctx.job.enter("start stopped units")
    for u in ctx.units:
        st = ctx.ec2.state(u)
        if st == "stopped":
            ctx.job.log(f"{u} is stopped: starting it")
            ctx.job.mark(f"EC2 start {u}")
            ctx.ec2.start(u)
            ctx.wait(lambda u=u: ctx.ec2.state(u) == "running", f"{u} running", 180)
        elif st not in ("running", "pending"):
            ctx.job.log(f"{u} EC2 state is '{st}': leaving it", "warn")
    ctx.job.enter("wait for the API")
    for u in ctx.units:
        ctx.wait(lambda u=u: ctx.ha(u) is not None, f"{u} API reachable", 900, 10)
    ctx.job.enter("clear suspended state")
    for u in ctx.units:
        h = ctx.ha(u) or {}
        if h.get("state") == "suspended":
            ctx.job.log(f"{u} is suspended: setting it functional")
            ctx.api.functional(u)
    ctx.job.enter("pair healthy")
    ctx.wait(lambda: sum(1 for u in ctx.units if ctx.is_active(u)) == 1 and
             sum(1 for u in ctx.units if ctx.is_passive_synced(u)) == 1,
             "one active and one passive, synchronized", 900, 10)


RESTORE = "failback to preferred primary"
# key -> (label, function, phases, typical duration in seconds, takes the restore option)
# Typical durations = measured live + 30 %, shown rounded DOWN to whole minutes:
#   soft 47 s -> 1 min; hard 426 s + ~30 s failback = 456 s -> 593 s -> 9 min;
#   region 510 s with a 60 s observation, i.e. 480 s with 30 s -> 624 s -> 10 min.
SCENARIOS = {
    "sync": ("Check and repair configuration sync", sync_check,
             ["pre-checks", "check and repair sync"], 60, False),
    "soft": ("HA failover: suspend the active firewall, then restore it", soft_failover,
             ["pre-checks", "trigger failover", "takeover", "observe", "restore failed unit", RESTORE], 61, True),
    "hard": ("Hard failover: stop the active firewall's EC2 instance, then start it", hard_failover,
             ["pre-checks", "stop active instance", "takeover", "observe", "start instance",
              "boot and rejoin HA", RESTORE], 593, True),
    "region": ("Region outage: stop BOTH firewalls of the region, then bring them back", region_outage,
               ["pre-checks", "stop the region", "observe", "start the region", "boot and rejoin HA", RESTORE],
               624, True),
    "rebalance": ("Align the pair: make the preferred primary active again", rebalance,
                  ["pre-checks", RESTORE], 60, False),
    "recover": ("Recover: start stopped firewalls, clear suspended state", recover,
                ["start stopped units", "wait for the API", "clear suspended state", "pair healthy"], 60, False),
}


def phases_for(scenario, restore=True):
    phases = list(SCENARIOS[scenario][2])
    if SCENARIOS[scenario][4] and not restore:
        phases = [p for p in phases if p != RESTORE]
    return phases


def run_job(ctx, fn):
    """Run one scenario to completion; never raises, always records the outcome on the job."""
    job = ctx.job
    try:
        fn(ctx)
        job.status = "done"
        job.phase = len(job.phases)
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
        job._changed()
