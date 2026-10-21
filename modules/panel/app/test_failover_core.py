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
        self.cfg_sync = {"fw1": "synchronized", "fw2": "synchronized"}
        self.reachable = {"fw1": True, "fw2": True}
        self.ec2_state = {"fw1": "running", "fw2": "running"}
        self.pending = []
        self.calls = []
        self.repairable = True

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
        if u.startswith("b"):  # a unit of the other region: always healthy here
            return {"state": "active" if u == "b1" else "passive", "config_sync": "synchronized",
                    "peer_state": "x", "priority": "100"}
        if not self.reachable[u]:
            raise OSError("unreachable")
        return {"state": self.ha_state[u], "config_sync": self.cfg_sync[u], "peer_state": "x",
                "priority": {"fw1": "100", "fw2": "110"}[u]}

    def suspend(self, u):
        self.calls.append(("suspend", u))
        other = "fw2" if u == "fw1" else "fw1"
        self.ha_state[u] = "suspended"
        self.at(15, lambda: self.ha_state.__setitem__(other, "active"))

    def sync(self, u):
        self.calls.append(("sync", u))
        if self.repairable:
            self.at(25, lambda: self.cfg_sync.update({"fw1": "synchronized", "fw2": "synchronized"}))

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


def make(fake, others=(), **options):
    job = fc.Job("t", "tester", clock=fake.clock, options=options)
    return fc.Ctx(fake, fake, job, ["fw1", "fw2"], sleep=fake.sleep, clock=fake.clock, others=others)


class Scenarios(unittest.TestCase):
    def test_soft_failover_measures_and_fails_back_to_the_preferred_unit(self):
        f = Fake()
        ctx = make(f)
        fc.run_job(ctx, fc.soft_failover)
        self.assertEqual(ctx.job.status, "done", ctx.job.steps)
        self.assertEqual(f.calls, [("suspend", "fw1"), ("functional", "fw1"),
                                   ("suspend", "fw2"), ("functional", "fw2")])
        self.assertEqual((f.ha_state["fw1"], f.ha_state["fw2"]), ("active", "passive"))
        self.assertAlmostEqual(ctx.job.result["takeover_s"], 16, delta=3)
        self.assertIn("failback_s", ctx.job.result)
        self.assertEqual(ctx.job.marks[-1]["label"], "original roles restored")

    def test_soft_failover_without_restore_leaves_roles_swapped(self):
        f = Fake()
        ctx = make(f, restore=False)
        fc.run_job(ctx, fc.soft_failover)
        self.assertEqual(ctx.job.status, "done", ctx.job.steps)
        self.assertEqual(f.calls, [("suspend", "fw1"), ("functional", "fw1")])
        self.assertEqual((f.ha_state["fw1"], f.ha_state["fw2"]), ("passive", "active"))

    def test_rebalance_makes_the_preferred_unit_active(self):
        f = Fake()
        f.ha_state = {"fw1": "passive", "fw2": "active"}
        ctx = make(f)
        fc.run_job(ctx, fc.rebalance)
        self.assertEqual(ctx.job.status, "done", ctx.job.steps)
        self.assertEqual(f.calls, [("suspend", "fw2"), ("functional", "fw2")])
        self.assertEqual(f.ha_state, {"fw1": "active", "fw2": "passive"})

    def test_rebalance_is_a_no_op_when_already_aligned(self):
        f = Fake()
        ctx = make(f)
        fc.run_job(ctx, fc.rebalance)
        self.assertEqual(ctx.job.status, "done", ctx.job.steps)
        self.assertEqual(f.calls, [])

    def test_region_outage_stops_both_units_and_brings_them_back(self):
        f = Fake()
        orig_stop = f.stop
        def stop_both(u):  # in a region outage nobody takes over inside the region
            f.calls.append(("stop", u))
            f.ec2_state[u] = "stopping"
            f.reachable[u] = False
            f.at(45, lambda: f.ec2_state.__setitem__(u, "stopped"))
        f.stop = stop_both
        def start(u):
            f.calls.append(("start", u))
            f.ec2_state[u] = "pending"
            f.at(20, lambda: f.ec2_state.__setitem__(u, "running"))
            state = "active" if u == "fw2" else "passive"  # the other unit may win the election
            f.at(300, lambda: (f.reachable.__setitem__(u, True), f.ha_state.__setitem__(u, state)))
        f.start = start
        ctx = make(f, others=["b1", "b2"])
        fc.run_job(ctx, fc.region_outage)
        self.assertEqual(ctx.job.status, "done", ctx.job.steps)
        self.assertEqual(f.calls[:4], [("stop", "fw1"), ("stop", "fw2"), ("start", "fw1"), ("start", "fw2")])
        self.assertEqual(f.calls[4:], [("suspend", "fw2"), ("functional", "fw2")])  # failback to fw1
        self.assertEqual(f.ha_state, {"fw1": "active", "fw2": "passive"})

    def test_region_outage_refuses_when_global_accelerator_says_the_other_region_is_unhealthy(self):
        f = Fake()
        ctx = make(f, others=["b1", "b2"])
        ctx.others_ready = lambda: (False, "Global Accelerator: eu-west-1 is UNHEALTHY")
        fc.run_job(ctx, fc.region_outage)
        self.assertEqual(ctx.job.status, "failed")
        self.assertEqual(f.calls, [])

    def test_start_all_keeps_going_after_one_failure(self):
        f = Fake()
        f.ec2_state = {"fw1": "stopped", "fw2": "stopped"}
        real = f.start
        def start(u):
            if u == "fw1":
                raise RuntimeError("throttled")
            real(u)
        f.start = start
        ctx = make(f)
        with self.assertRaises(fc.Aborted):
            fc._start_all(ctx, ["fw1", "fw2"])
        self.assertIn(("start", "fw2"), f.calls)  # fw2 still started

    def test_region_outage_refuses_without_a_live_other_region(self):
        f = Fake()
        ctx = make(f)
        fc.run_job(ctx, fc.region_outage)
        self.assertEqual(ctx.job.status, "failed")
        self.assertEqual(f.calls, [])

    def test_phases_advance_to_the_end(self):
        f = Fake()
        ctx = make(f)
        ctx.job.phases = fc.phases_for("soft")
        fc.run_job(ctx, fc.soft_failover)
        self.assertEqual(ctx.job.to_dict()["phase"], len(ctx.job.phases))

    def test_hard_failover_stops_then_starts_the_active_unit_only(self):
        f = Fake()
        ctx = make(f)
        fc.run_job(ctx, fc.hard_failover)
        self.assertEqual(ctx.job.status, "done", ctx.job.steps)
        self.assertEqual(f.calls[:2], [("stop", "fw1"), ("start", "fw1")])
        self.assertEqual(f.ec2_state, {"fw1": "running", "fw2": "running"})
        self.assertEqual(f.calls[2:], [("suspend", "fw2"), ("functional", "fw2")])  # failback
        self.assertEqual(f.ha_state, {"fw1": "active", "fw2": "passive"})

    def test_refuses_to_start_when_pair_is_not_clean(self):
        f = Fake()
        f.ha_state["fw2"] = "suspended"
        ctx = make(f)
        fc.run_job(ctx, fc.soft_failover)
        self.assertEqual(ctx.job.status, "failed")
        self.assertEqual(f.calls, [])  # nothing was touched

    def test_out_of_sync_pair_is_repaired_before_the_test(self):
        f = Fake()
        f.cfg_sync["fw2"] = "not synchronized"
        ctx = make(f)
        fc.run_job(ctx, fc.hard_failover)
        self.assertEqual(ctx.job.status, "done", ctx.job.steps)
        self.assertEqual(f.calls[0], ("sync", "fw1"))  # the ACTIVE unit pushes its config first
        self.assertIn("forced config sync", [m["label"] for m in ctx.job.marks])

    def test_stays_out_of_sync_means_abort_before_touching_anything(self):
        f = Fake()
        f.cfg_sync["fw2"] = "not synchronized"
        f.repairable = False
        ctx = make(f)
        fc.run_job(ctx, fc.soft_failover)
        self.assertEqual(ctx.job.status, "failed")
        self.assertEqual(f.calls, [("sync", "fw1")])  # no suspend/stop happened
        self.assertIn("diverging", ctx.job.steps[-2]["msg"])

    def test_sync_scenario_repairs_on_demand(self):
        f = Fake()
        f.cfg_sync["fw1"] = "not synchronized"
        ctx = make(f)
        fc.run_job(ctx, fc.sync_check)
        self.assertEqual(ctx.job.status, "done", ctx.job.steps)
        self.assertEqual(f.cfg_sync, {"fw1": "synchronized", "fw2": "synchronized"})

    def test_sync_that_heals_by_itself_is_not_forced(self):
        f = Fake()
        f.cfg_sync["fw2"] = "not synchronized"
        f.at(10, lambda: f.cfg_sync.update({"fw1": "synchronized", "fw2": "synchronized"}))
        ctx = make(f)
        fc.run_job(ctx, fc.sync_check)
        self.assertEqual(ctx.job.status, "done", ctx.job.steps)
        self.assertEqual(f.calls, [])

    def test_timeout_fails_the_job_and_undoes_the_suspend(self):
        f = Fake()
        f.suspend = lambda u: f.calls.append(("suspend", u))  # peer never takes over
        ctx = make(f)
        fc.run_job(ctx, fc.soft_failover)
        self.assertEqual(ctx.job.status, "failed")
        self.assertIn("timed out", ctx.job.steps[-2]["msg"])
        self.assertEqual(f.calls, [("suspend", "fw1"), ("functional", "fw1")])  # undone

    def test_hard_failover_starts_the_unit_again_if_the_peer_never_takes_over(self):
        f = Fake()
        real_stop = f.stop
        def stop_no_takeover(u):
            real_stop(u)
            f.pending = [p for p in f.pending if "ha_state" not in repr(p[1].__code__.co_names)]
        f.stop = stop_no_takeover
        ctx = make(f)
        fc.run_job(ctx, fc.hard_failover)
        self.assertEqual(ctx.job.status, "failed")
        self.assertEqual(f.calls, [("stop", "fw1"), ("start", "fw1")])

    def test_priority_zero_is_the_strongest(self):
        f = Fake()
        orig = f.ha
        f.ha = lambda u: {**orig(u), "priority": {"fw1": "100", "fw2": "0"}[u]}
        ctx = make(f)
        self.assertEqual(fc.preferred(ctx), "fw2")

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
        self.assertEqual(s["outages"], [[2.0, 9.0]])

    def test_two_outages_are_two_intervals(self):
        now = [0.0]
        p = fc.ProbeStats(clock=lambda: now[0])
        for ok, t in [(False, 1), (True, 3), (True, 50), (False, 60), (False, 61), (True, 65)]:
            now[0] = t
            p.record(ok)
        s = p.summary()
        self.assertEqual((s["outages"], s["total_outage_s"], s["longest_outage_s"]), ([[1.0, 3.0], [60.0, 65.0]], 7.0, 5.0))

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
