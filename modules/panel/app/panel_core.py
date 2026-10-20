"""panel_core — the parts of the admin panel that must be right, with no third-party imports.

Everything that touches untrusted input (a form field) or builds a request for the firewall
lives here so it can be unit-tested without Flask, LDAP or a firewall:

  * strict validation of every value that ends up inside an XML-API command,
  * building those commands from validated values only (never string-pasting user text),
  * parsing the firewall's answers,
  * a small in-memory login rate limiter.
"""
import ipaddress
import re
import time
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

ZONES = ("trust", "untrust", "vpn")
PROTOCOLS = {"tcp": "6", "udp": "17", "icmp": "1"}
# Predefined PANW lists the panel is allowed to sample from. A fixed allow-list: the list name
# is part of an XML command, so it is never taken from the request.
EDL_LISTS = (
    "panw-aipd-c2-infra-ip-list",
    "panw-aipd-in-malware-ip-list",
    "panw-aipd-scanning-ip-list",
    "panw-aipd-vuln-svcs-ip-list",
    "panw-torexit-ip-list",
    "panw-bulletproof-ip-list",
    "panw-highrisk-ip-list",
)
_USER_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")


class ValidationError(ValueError):
    """A form value was not acceptable. The message is safe to show to the user."""


def valid_ipv4(value: str) -> str:
    try:
        ip = ipaddress.IPv4Address((value or "").strip())
    except ipaddress.AddressValueError as exc:
        raise ValidationError("not a valid IPv4 address") from exc
    if ip.is_multicast or ip.is_unspecified or ip.is_loopback:
        raise ValidationError("multicast, loopback and 0.0.0.0 are not allowed")
    return str(ip)


def valid_port(value: str) -> str:
    try:
        port = int((value or "").strip())
    except ValueError as exc:
        raise ValidationError("port must be a number") from exc
    if not 1 <= port <= 65535:
        raise ValidationError("port must be 1-65535")
    return str(port)


def valid_protocol(value: str) -> str:
    key = (value or "").strip().lower()
    if key not in PROTOCOLS:
        raise ValidationError("protocol must be tcp, udp or icmp")
    return PROTOCOLS[key]


def valid_zone(value: str) -> str:
    key = (value or "").strip().lower()
    if key not in ZONES:
        raise ValidationError("zone must be one of: " + ", ".join(ZONES))
    return key


def valid_edl(value: str) -> str:
    if value not in EDL_LISTS:
        raise ValidationError("unknown list")
    return value


def valid_username(value: str) -> str:
    value = (value or "").strip()
    if not _USER_RE.match(value):
        raise ValidationError("invalid user name")
    return value


def policy_match_cmd(src: str, dst: str, port: str, proto: str, zfrom: str, zto: str) -> str:
    """XML for `test security-policy-match`; every argument must already be validated."""
    return (
        "<test><security-policy-match>"
        f"<source>{escape(src)}</source><destination>{escape(dst)}</destination>"
        f"<destination-port>{escape(port)}</destination-port><protocol>{escape(proto)}</protocol>"
        f"<from>{escape(zfrom)}</from><to>{escape(zto)}</to>"
        "</security-policy-match></test>"
    )


def edl_show_cmd(name: str) -> str:
    return (
        "<request><system><external-list><show><type><predefined-ip>"
        f"<name>{escape(name)}</name></predefined-ip></type></show></external-list></system></request>"
    )


HA_CMD = "<show><high-availability><state/></high-availability></show>"
# Failover tests (operators only). Fixed strings: nothing from a form ever reaches them.
HA_SUSPEND_CMD = "<request><high-availability><state><suspend/></state></high-availability></request>"
HA_SYNC_CMD = "<request><high-availability><sync-to-remote><running-config/></sync-to-remote></high-availability></request>"
HA_FUNCTIONAL_CMD = "<request><high-availability><state><functional/></state></high-availability></request>"
INFO_CMD = "<show><system><info/></system></show>"


def _root(text: str):
    try:
        return ET.fromstring(text)
    except ET.ParseError as exc:
        raise ValidationError("the firewall returned an unreadable answer") from exc


def api_error(text: str):
    """Return the firewall's error message, or None when the call succeeded."""
    root = _root(text)
    if root.get("status") == "success":
        return None
    msg = " ".join(t.strip() for t in root.itertext() if t.strip())
    return msg or "the firewall rejected the request"


def parse_key(text: str) -> str:
    key = _root(text).findtext(".//key")
    if not key:
        raise ValidationError("the firewall did not return an API key (wrong credentials?)")
    return key


def parse_ha(text: str) -> dict:
    root = _root(text)
    return {
        "enabled": root.findtext(".//enabled"),
        "state": root.findtext(".//group/local-info/state"),
        "peer_state": root.findtext(".//group/peer-info/state"),
        "config_sync": root.findtext(".//group/running-sync"),
    }


def parse_info(text: str) -> dict:
    root = _root(text)
    return {k: root.findtext(f".//{k}") for k in ("hostname", "serial", "sw-version", "model")}


def parse_policy_match(text: str) -> list:
    """Names of the rules the simulated session matched (normally one)."""
    root = _root(text)
    rules = [e.get("name") for e in root.iter("entry") if e.get("name")]
    if rules:
        return rules
    # Some releases answer with the rule block as text: `"rule-name; index: 2" { ... }`.
    body = "".join(root.itertext())
    return re.findall(r'"([^"]+?);\s*index:\s*\d+"', body)


def parse_edl_sample(text: str, limit: int = 5) -> dict:
    """Entry count and a few sample addresses of a predefined list.

    The XML API answers with <total-valid> and <member> elements (live-verified on 12.2.4);
    the CLI-style text form ("Total valid entries : N", one address per line) is the fallback.
    """
    root = _root(text)
    ips = []
    for member in root.iter("member"):
        try:
            ips.append(str(ipaddress.IPv4Address((member.text or "").strip())))
        except ipaddress.AddressValueError:
            continue
    total = (root.findtext(".//total-valid") or "").strip()
    if total.isdigit():
        return {"total": int(total), "sample": ips[:limit]}
    body = "".join(root.itertext())
    legacy = re.search(r"Total valid entries\s*:\s*(\d+)", body)
    if not ips:
        for line in body.splitlines():
            try:
                ips.append(str(ipaddress.IPv4Address(line.strip())))
            except ipaddress.AddressValueError:
                continue
    return {"total": int(legacy.group(1)) if legacy else None, "sample": ips[:limit]}


class RateLimiter:
    """At most `limit` failed attempts per key inside `window` seconds."""

    def __init__(self, limit: int = 5, window: int = 600, clock=time.monotonic):
        self.limit, self.window, self.clock = limit, window, clock
        self._fails = {}

    def _recent(self, key):
        now = self.clock()
        recent = [t for t in self._fails.get(key, []) if now - t < self.window]
        self._fails[key] = recent
        return recent

    def blocked(self, key) -> bool:
        return len(self._recent(key)) >= self.limit

    def fail(self, key) -> None:
        self._recent(key).append(self.clock())

    def reset(self, key) -> None:
        self._fails.pop(key, None)
