"""Unit tests for failover_core with a fake two-firewall cluster on a virtual clock.

Run:  python3 -I modules/panel/app/test_failover_core.py
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import failover_core as fc  # noqa: E402


class Fake:
    """Virtual clock + cluster. Transitions are scheduled and applied as time advances."""

    def __init__(self):
        self.t = 0.0
        self.ha_state = {"fw1": "active", "fw2": "passive"}
        self.sync = {"fw1": "synchronized", "fw2": "synchronized"}
        self.reachable = {"fw1": True, "fw2": True}
        self.ec2_state = {"fw1": "running", "fw2": "running"}
        self.pending = []
        self.calls = []

    def at(self, delay, fn):
        self.pending.append((self.t + delay, fn))

    def clock(self):
        due = [p for p in self.pending if p[0] <= self.t]
        self.pending = [p for p in self.pending if p[0] > self.t]
        for _, fn in sorted(due, key=lambda p: p[0]):
            fn()
        return self.t

    def sleep(self, s):
        self.t += s

    # api
    def ha(self, u):
        self.clock()
        if not self.reachable[u]:
            raise OSError("unreachable")
        return {"state": self.ha_state[u], "config_sync": self.sync[u], "peer_state": "x"}

    def suspend(self, u):
        self.calls.append(("suspend", u))
        other = "fw2" if u == "fw1" else "fw1"
        self.ha_state[u] = "suspended"
        self.at(15, lambda: self.ha_state.__setitem__(other, "active"))

    def functional(self, u):
        self.calls.append(("functional", u))
        self.at(40, lambda: self.ha_state.__setitem__(u, "passive"))

    # ec2
    def state(self, u):
        self.clock()
        return self.ec2_state[u]

    def stop(self, u):
        self.calls.append(("stop", u))
        other = "fw2" if u == "fw1" else "fw1"
        self.ec2_state[u] = "stopping"
        self.reachable[u] = False
        self.at(30, lambda: self.ha_state.__setitem__(other, "active"))
        self.at(45, lambda: self.ec2_state.__setitem__(u, "stopped"))

    def start(self, u):
        self.calls.append(("start", u))
        self.ec2_state[u] = "pending"
        self.at(20, lambda: self.ec2_state.__setitem__(u, "running"))
        self.at(200, lambda: (self.reachable.__setitem__(u, True), self.ha_state.__setitem__(u, "passive")))


def make(fake):
    job = fc.Job("t", "tester", clock=fake.clock)
    return fc.Ctx(fake, fake, job, ["fw1", "fw2"], sleep=fake.sleep, clock=fake.clock)


class Scenarios(unittest.TestCase):
    def test_soft_failover_swaps_roles_and_restores(self):
        f = Fake()
        ctx = make(f)
        fc.run_job(ctx, fc.soft_failover)
        self.assertEqual(ctx.job.status, "done", ctx.job.steps)
        self.assertEqual(f.calls, [("suspend", "fw1"), ("functional", "fw1")])
        self.assertEqual((f.ha_state["fw1"], f.ha_state["fw2"]), ("passive", "active"))
        self.assertAlmostEqual(ctx.job.result["takeover_s"], 16, delta=3)

    def test_hard_failover_stops_then_starts_the_active_unit_only(self):
        f = Fake()
        ctx = make(f)
        fc.run_job(ctx, fc.hard_failover)
        self.assertEqual(ctx.job.status, "done", ctx.job.steps)
        self.assertEqual(f.calls, [("stop", "fw1"), ("start", "fw1")])
        self.assertEqual(f.ec2_state, {"fw1": "running", "fw2": "running"})

    def test_refuses_to_start_when_pair_is_not_clean(self):
        f = Fake()
        f.ha_state["fw2"] = "suspended"
        ctx = make(f)
        fc.run_job(ctx, fc.soft_failover)
        self.assertEqual(ctx.job.status, "failed")
        self.assertEqual(f.calls, [])  # nothing was touched

    def test_refuses_when_passive_not_synchronized(self):
        f = Fake()
        f.sync["fw2"] = "out of sync"
        ctx = make(f)
        fc.run_job(ctx, fc.hard_failover)
        self.assertEqual(ctx.job.status, "failed")
        self.assertEqual(f.calls, [])

    def test_timeout_fails_the_job_instead_of_hanging(self):
        f = Fake()
        f.suspend = lambda u: f.calls.append(("suspend", u))  # peer never takes over
        ctx = make(f)
        fc.run_job(ctx, fc.soft_failover)
        self.assertEqual(ctx.job.status, "failed")
        self.assertIn("timed out", ctx.job.steps[-2]["msg"])

    def test_recover_starts_stopped_unit_and_clears_suspend(self):
        f = Fake()
        f.ec2_state["fw1"] = "stopped"
        f.reachable["fw1"] = False
        f.ha_state["fw1"] = "initial"
        f.ha_state["fw2"] = "active"
        ctx = make(f)
        fc.run_job(ctx, fc.recover)
        self.assertEqual(ctx.job.status, "done", ctx.job.steps)
        self.assertIn(("start", "fw1"), f.calls)

    def test_recover_sets_suspended_unit_functional(self):
        f = Fake()
        f.ha_state = {"fw1": "suspended", "fw2": "active"}
        ctx = make(f)
        fc.run_job(ctx, fc.recover)
        self.assertEqual(ctx.job.status, "done", ctx.job.steps)
        self.assertIn(("functional", "fw1"), f.calls)


class Probe(unittest.TestCase):
    def test_measures_outage(self):
        now = [0.0]
        p = fc.ProbeStats(clock=lambda: now[0])
        for ok, t in [(True, 0), (True, 1), (False, 2), (False, 3), (False, 4), (True, 9), (True, 10)]:
            now[0] = t
            p.record(ok)
        s = p.summary()
        self.assertEqual((s["checks"], s["failed"], s["longest_outage_s"], s["down_now"]), (7, 3, 7.0, False))

    def test_ongoing_outage_is_visible(self):
        now = [0.0]
        p = fc.ProbeStats(clock=lambda: now[0])
        p.record(True)
        now[0] = 5
        p.record(False)
        now[0] = 9
        self.assertTrue(p.summary()["down_now"])
        self.assertEqual(p.summary()["longest_outage_s"], 4.0)


if __name__ == "__main__":
    unittest.main()
