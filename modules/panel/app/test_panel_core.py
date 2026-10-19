"""Unit tests for panel_core (no Flask / LDAP / firewall needed).

Run:  python3 -m unittest -v modules/panel/app/test_panel_core.py
"""
import os
import sys
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(__file__))
import panel_core as m  # noqa: E402


class Validation(unittest.TestCase):
    def test_ip_refuses_injection_and_names(self):
        for bad in ("1.1.1.1</source><x/>", "evil.example.com", "127.0.0.1", "224.0.0.1", "0.0.0.0", ""):
            with self.assertRaises(m.ValidationError):
                m.valid_ipv4(bad)

    def test_ip_accepts_normal(self):
        self.assertEqual(m.valid_ipv4(" 72.255.3.18 "), "72.255.3.18")

    def test_port(self):
        for bad in ("0", "65536", "80;ls", "", "-1"):
            with self.assertRaises(m.ValidationError):
                m.valid_port(bad)
        self.assertEqual(m.valid_port("443"), "443")

    def test_protocol_zone_edl_user(self):
        self.assertEqual(m.valid_protocol("TCP"), "6")
        for f, bad in ((m.valid_protocol, "gre"), (m.valid_zone, "any"),
                       (m.valid_edl, "x</name><y/>"), (m.valid_username, "a)(uid=*"),
                       (m.valid_username, "a b")):
            with self.assertRaises(m.ValidationError):
                f(bad)
        self.assertEqual(m.valid_zone("trust"), "trust")
        self.assertEqual(m.valid_username("admin"), "admin")


class Commands(unittest.TestCase):
    def test_policy_match_is_well_formed(self):
        x = m.policy_match_cmd("10.12.0.10", "72.255.3.18", "443", "6", "trust", "untrust")
        ET.fromstring(x)
        self.assertIn("<source>10.12.0.10</source>", x)

    def test_edl_cmd_is_well_formed(self):
        ET.fromstring(m.edl_show_cmd("panw-torexit-ip-list"))


class Parsers(unittest.TestCase):
    def test_ha(self):
        xml = ('<response status="success"><result><enabled>yes</enabled><group><local-info>'
               '<state>active</state></local-info><peer-info><state>passive</state></peer-info>'
               '<running-sync>synchronized</running-sync></group></result></response>')
        self.assertEqual(m.parse_ha(xml), {"enabled": "yes", "state": "active",
                                           "peer_state": "passive", "config_sync": "synchronized"})

    def test_policy_match_both_forms(self):
        text = '<response status="success"><result>"ipdef-outbound-alert; index: 2" {\n x;\n}</result></response>'
        self.assertEqual(m.parse_policy_match(text), ["ipdef-outbound-alert"])
        entry = '<response status="success"><result><rules><entry name="spokes-outbound"/></rules></result></response>'
        self.assertEqual(m.parse_policy_match(entry), ["spokes-outbound"])

    def test_edl_sample(self):
        text = ('<response status="success"><result>x\n\tTotal valid entries\t: 5500\n'
                '\t\t72.255.3.18\n\t\t147.1.17.88\n</result></response>')
        self.assertEqual(m.parse_edl_sample(text), {"total": 5500, "sample": ["72.255.3.18", "147.1.17.88"]})

    def test_errors(self):
        self.assertIsNone(m.api_error('<response status="success"/>'))
        self.assertIn("bad", m.api_error('<response status="error"><msg>bad</msg></response>'))
        with self.assertRaises(m.ValidationError):
            m.parse_ha("<<<not xml")


class Limiter(unittest.TestCase):
    def test_blocks_forgets_resets(self):
        now = [0.0]
        rl = m.RateLimiter(limit=3, window=100, clock=lambda: now[0])
        for _ in range(3):
            rl.fail("k")
        self.assertTrue(rl.blocked("k"))
        now[0] = 101
        self.assertFalse(rl.blocked("k"))
        rl.fail("k")
        rl.reset("k")
        self.assertFalse(rl.blocked("k"))


if __name__ == "__main__":
    unittest.main()
