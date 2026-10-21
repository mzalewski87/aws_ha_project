"""Lab admin panel — AD login, firewall pair status, policy simulation, failover tests.

Viewers (AD group PANEL_ADMIN_GROUP) only read:
  * login against Active Directory (NTLM bind, so the password is never sent in clear) and a
    required group (PANEL_ADMIN_GROUP);
  * status of each firewall (HA state, version) through the PAN-OS XML API with a READ-ONLY admin;
  * `test security-policy-match`: ask the firewall which rule a session WOULD hit. This checks
    Advanced IP Defense / policy without sending a single packet to a real malicious address;
  * a sample from one of PANW's predefined IP lists, so a test can use an address that really is
    on the list.
Operators (additionally PANEL_OPERATOR_GROUP) may run failover tests: HA suspend/restore and
EC2 stop/start of the two firewall instances only (that is all the hosts' IAM role allows).
Runs are stored in DynamoDB so both panel hosts show the same progress and history. Every action
is written to the audit log (one JSON line per event on stdout).
"""
import base64
import json
import os
import secrets
import sys
import threading
import time

import requests
from flask import Flask, abort, jsonify, redirect, render_template_string, request, session, url_for
from ldap3 import NTLM, Connection, Server
from ldap3.core.exceptions import LDAPException
from ldap3.utils.conv import escape_filter_chars

import failover_core as fo
import panel_core as core

CFG = {
    # {"units": {"fw1": {"ip", "id", "untrust_eni", "trust_eni"}, ...}, "eip_allocation_id", "public_ip"}
    "topo": json.loads(base64.b64decode(os.environ.get("PANEL_TOPO_B64", "") or "e30=").decode()),
    "failover_enabled": os.environ.get("PANEL_FAILOVER_ENABLED", "0") == "1",
    "runs_table": os.environ.get("PANEL_RUNS_TABLE", ""),
    "ga_arn": os.environ.get("PANEL_GA_ARN", ""),   # Global Accelerator in front of the portal
    "operator_group": os.environ.get("PANEL_OPERATOR_GROUP", "panel-operators"),
    "gp_fqdn": os.environ.get("PANEL_GP_FQDN", ""),
    "region": os.environ.get("AWS_DEFAULT_REGION", ""),
    "ldap_host": os.environ["PANEL_LDAP_HOST"],
    "domain": os.environ["PANEL_DOMAIN"],  # e.g. panw.labs
    "netbios": os.environ.get("PANEL_NETBIOS", os.environ["PANEL_DOMAIN"].split(".")[0].upper()),
    "base_dn": os.environ["PANEL_BASE_DN"],
    "group": os.environ.get("PANEL_ADMIN_GROUP", "panel-admins"),
    # Membership is checked by full DN, not by CN alone: a same-named group in another OU must
    # not grant access. scripts/panel-setup.sh creates both groups in CN=Users.
    "fw_ips": [x for x in os.environ.get("PANEL_FW_IPS", "").split(",") if x],
    "fw_user": os.environ.get("PANEL_FW_USER", ""),
    "fw_password": os.environ.get("PANEL_FW_PASSWORD", ""),
    "spoke_host": os.environ.get("PANEL_SPOKE_HOST", "10.12.0.10"),
}

# Pairs: {"a": {"label", "region", "eip_allocation_id", "public_ip", "units": {name: {ip, id,
# untrust_eni, trust_eni}}}, "b": {...}}. Unit names are unique across pairs (e.g. a-fw1).
if "pairs" not in CFG["topo"] and CFG["topo"].get("units"):
    CFG["topo"] = {"pairs": {"a": {"label": "Region A", "region": CFG["region"],
                                   **{k: v for k, v in CFG["topo"].items() if k != "pairs"}}}}
for _p in CFG["topo"].get("pairs", {}).values():
    _p.setdefault("region", CFG["region"])
    for _u in _p.get("units", {}).values():
        _u["region"] = _p["region"]

for _k, _cn in (("group_dn", "group"), ("operator_group_dn", "operator_group")):
    CFG[_k] = os.environ.get("PANEL_" + _k.upper(), f"CN={CFG[_cn]},CN=Users,{CFG['base_dn']}").lower()

SESSION_MAX_AGE = 8 * 3600      # absolute lifetime: polling must not keep a session alive forever
OPERATOR_FRESH_LOGIN = 3600     # disruptive actions need a sign-in within the last hour
TIMEOUT_CONNECT = 3             # fail fast on an unreachable firewall (a stopped unit during a test)

app = Flask(__name__)
app.secret_key = os.environ["PANEL_SESSION_SECRET"]
app.config.update(SESSION_COOKIE_SECURE=True, SESSION_COOKIE_HTTPONLY=True,
                  SESSION_COOKIE_SAMESITE="Strict", PERMANENT_SESSION_LIFETIME=1800)
limiter = core.RateLimiter(limit=5, window=600)
_keys = {}  # firewall ip -> (api key, time obtained)


def client_ip():
    """The address the ALB saw. It APPENDS the peer to X-Forwarded-For, so the last entry is the
    trustworthy one; the first entries are whatever the client sent."""
    xff = [p.strip() for p in request.headers.get("X-Forwarded-For", "").split(",") if p.strip()]
    return xff[-1] if xff else (request.remote_addr or "?")


def audit(event, **fields):
    rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "event": event,
           "user": session.get("user"), "ip": client_ip()}
    rec.update(fields)
    print(json.dumps(rec), file=sys.stdout, flush=True)


@app.after_request
def headers(resp):
    resp.headers["X-Frame-Options"] = "DENY"
    resp.headers["X-Content-Type-Options"] = "nosniff"
    resp.headers["Referrer-Policy"] = "no-referrer"
    resp.headers["Content-Security-Policy"] = "default-src 'self'; style-src 'self' 'unsafe-inline'; form-action 'self'"
    resp.headers["Cache-Control"] = "no-store"
    resp.headers["Strict-Transport-Security"] = "max-age=31536000"
    return resp


def csrf_token():
    if "csrf" not in session:
        session["csrf"] = secrets.token_urlsafe(24)
    return session["csrf"]


def logged_in():
    """A valid session: signed in, and inside the absolute lifetime."""
    if not session.get("user"):
        return False
    if time.time() - session.get("login_at", 0) > SESSION_MAX_AGE:
        session.clear()
        return False
    return True


def need_login():
    if not logged_in():
        return redirect(url_for("login"))
    return None


def check_csrf():
    if not secrets.compare_digest(request.form.get("csrf", ""), session.get("csrf", "x")):
        abort(400, "bad CSRF token")


def ad_authenticate(username, password):
    """None unless a valid AD account in the admin group; then "operator" or "viewer".

    "operator" (extra group) may also run the failover tests; "viewer" is read-only.
    """
    if not password:  # an empty password would be an unauthenticated bind on some servers
        return None
    server = Server(CFG["ldap_host"], port=389, connect_timeout=5)
    conn = Connection(server, user=f'{CFG["netbios"]}\\{username}', password=password,
                      authentication=NTLM, receive_timeout=8)
    try:
        if not conn.bind():
            return None
        conn.search(CFG["base_dn"], f"(sAMAccountName={escape_filter_chars(username)})", attributes=["memberOf"])
        if not conn.entries:
            return None
        groups = [str(g).lower() for g in conn.entries[0].memberOf.values]

        if CFG["group_dn"] not in groups:
            return None
        return "operator" if CFG["operator_group_dn"] in groups else "viewer"
    except LDAPException:
        return None
    except Exception as exc:  # fail closed: any other bind problem is a failed sign-in, not a 500
        print(json.dumps({"event": "ldap_error", "error": f"{type(exc).__name__}: {exc}"[:200]}), flush=True)
        return None
    finally:
        conn.unbind()


def fw_call(ip, params, timeout=25):
    """One XML-API request to a firewall with a cached key; returns the answer text."""
    key = _keys.get(ip)
    if not key or time.time() - key[1] > 3000:
        # POST, never GET: a query string ends up in exception texts and in the firewall's access log.
        r = requests.post(f"https://{ip}/api/", timeout=(TIMEOUT_CONNECT, 10), verify=False,  # self-signed mgmt cert, private network
                          data={"type": "keygen", "user": CFG["fw_user"], "password": CFG["fw_password"]})
        key = (core.parse_key(r.text), time.time())
        _keys[ip] = key
    r = requests.post(f"https://{ip}/api/", timeout=(TIMEOUT_CONNECT, timeout), verify=False,
                      data={**params, "key": key[0]})
    return r.text


def safe_error(exc):
    """Text for the page. Network errors are summarised (their text can carry URLs and hosts);
    the details go to the journal only."""
    if isinstance(exc, requests.RequestException):
        print(json.dumps({"event": "firewall_error", "error": f"{type(exc).__name__}: {exc}"[:300]}), flush=True)
        return "firewall unreachable (timeout or connection refused)"
    return str(exc)[:200]


def fw_op(ip, cmd, vsys=None, timeout=25):
    params = {"type": "op", "cmd": cmd}
    if vsys:
        params["vsys"] = vsys
    text = fw_call(ip, params, timeout=timeout)
    err = core.api_error(text)
    if err:
        raise core.ValidationError(err)
    return text


PAGE = """<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>Lab admin panel</title>
<link rel=stylesheet href="{{ url_for('static', filename='panel.css') }}">
<style>body{font:15px system-ui;max-width:1000px;margin:2rem auto;padding:0 1rem;color:#1b1f24;background:#fff}
@media(prefers-color-scheme:dark){body{background:#0f1318;color:#e6e9ee}input,select,button{background:#1b222b;color:#e6e9ee;border:1px solid #3a4452}}
nav a{margin-right:1rem}.card{border:1px solid #8884;border-radius:8px;padding:1rem;margin:1rem 0}
input,select,button{padding:.4rem .6rem;margin:.2rem 0;font:inherit}.err{color:#c0392b}.ok{color:#1e8e3e}
code{background:#8882;padding:.1rem .3rem;border-radius:4px}table{border-collapse:collapse}td,th{padding:.3rem .8rem;border-bottom:1px solid #8884;text-align:left}</style>
<h1>Lab admin panel</h1>
{% if session.user %}<nav><a href="{{ url_for('home') }}">Status</a><a href="{{ url_for('simulate') }}">Policy simulation</a><a href="{{ url_for('failover') }}">Failover tests</a>
<span style="float:right">{{ session.user }} · <a href="{{ url_for('logout') }}">log out</a></span></nav>{% endif %}
{{ body|safe }}"""


def page(body_template, **ctx):
    from flask import render_template_string as rts
    body = rts(body_template, csrf=csrf_token(), **ctx)
    return rts(PAGE, body=body)


@app.get("/health")
def health():
    return "ok", 200


@app.route("/login", methods=["GET", "POST"])
def login():
    error = None
    if request.method == "POST":
        check_csrf()
        ip = client_ip()
        try:
            user = core.valid_username(request.form.get("username", ""))
        except core.ValidationError:
            user = ""
        key = f"{ip}|{user}"
        if limiter.blocked(key) or limiter.blocked(f"{ip}|*") or limiter.blocked(f"*|{user}"):
            audit("login_blocked", target=user)
            return page("<p class=err>Too many failed attempts. Try again in a few minutes.</p>"), 429
        role = ad_authenticate(user, request.form.get("password", "")) if user else None
        if role:
            limiter.reset(key)
            session.clear()
            session.permanent = True
            session["user"] = user
            session["role"] = role
            session["login_at"] = time.time()
            audit("login_ok", role=role)
            return redirect(url_for("home"))
        limiter.fail(key)
        limiter.fail(f"{ip}|*")
        if user:
            limiter.fail(f"*|{user}")
        audit("login_failed", target=user)
        error = "Sign-in failed."
    return page("""<form method=post class=card><input type=hidden name=csrf value="{{ csrf }}">
<p>Sign in</p>
<label>User<br><input name=username autocomplete=username required></label><br>
<label>Password<br><input name=password type=password autocomplete=current-password required></label><br>
{% if error %}<p class=err>{{ error }}</p>{% endif %}<button>Sign in</button></form>""", error=error)


@app.get("/logout")
def logout():
    audit("logout")
    session.clear()
    return redirect(url_for("login"))


@app.get("/")
def home():
    gate = need_login()
    if gate:
        return gate
    rows = []
    for ip in CFG["fw_ips"]:
        row = {"ip": ip}
        try:
            row.update(core.parse_info(fw_op(ip, core.INFO_CMD)))
            row.update(core.parse_ha(fw_op(ip, core.HA_CMD)))
        except (core.ValidationError, requests.RequestException) as exc:
            row["error"] = safe_error(exc)
        rows.append(row)
    audit("view_status")
    return page("""<div class=card><h2>Firewalls</h2><table>
<tr><th>Mgmt IP<th>Serial<th>PAN-OS<th>HA state<th>Peer<th>Config sync</tr>
{% for r in rows %}<tr><td>{{ r.ip }}
{% if r.error %}<td colspan=5 class=err>{{ r.error }}
{% else %}<td>{{ r.get('serial') }}<td>{{ r.get('sw-version') }}<td><b>{{ r.get('state') }}</b><td>{{ r.get('peer_state') }}<td>{{ r.get('config_sync') }}{% endif %}</tr>
{% endfor %}</table></div>""", rows=rows)



# ---- policy simulation ------------------------------------------------------------------
_rulebase_cache = {}  # firewall ip -> (time, rules)


def rulebase(ip):
    """Ordered rules of the firewall (cached for a minute; the panel never changes them)."""
    hit = _rulebase_cache.get(ip)
    if hit and time.time() - hit[0] < 60:
        return hit[1]
    rules = core.parse_rulebase(fw_op(ip, core.RULEBASE_CMD, timeout=40))
    _rulebase_cache[ip] = (time.time(), rules)
    return rules


def active_ip():
    """Mgmt IP of the active unit (it is the one that really decides); first unit as a fallback."""
    for u in units().values():
        try:
            if (core.parse_ha(fw_op(u["ip"], core.HA_CMD, timeout=5)).get("state") or "").startswith("active"):
                return u["ip"]
        except (core.ValidationError, requests.RequestException):
            continue
    return CFG["fw_ips"][0] if CFG["fw_ips"] else None


def build_simulation(ip, args):
    src, dst, port, proto, zfrom, zto = args
    text = fw_op(ip, core.policy_match_cmd(*args))
    matched = core.parse_policy_match_detail(text)
    names = core.parse_policy_match(text)
    if not matched and names:
        matched = {"name": names[0], "index": 0, "from": [], "to": [], "source": {}, "destination": {},
                   "application": "", "action": ""}
    rules, rules_error = [], None
    try:
        allrules = rulebase(ip)
        m = next((r for r in allrules if matched and r["name"] == matched["name"]), None)
        upto = m["index"] if m else float("inf")
        before = [r for r in allrules if r["index"] < upto]
        for r in before[-30:]:
            rules.append({**r, "verdict": "skip", "reason": core.skip_reason(r, zfrom, zto)})
        hidden = max(0, len(before) - 30)
        if matched:
            rules.append({**(m or matched), "verdict": "match", "reason": "first rule whose criteria all match"})
            if not matched["action"] and m:
                matched["action"] = m["action"]
        after = [r for r in allrules if r["index"] > upto][:2]
        rules += [{**r, "verdict": "unused", "reason": "not evaluated (a rule above already matched)"} for r in after]
    except (core.ValidationError, requests.RequestException) as exc:
        hidden, rules_error = 0, safe_error(exc)
    proto_name = {v: k for k, v in core.PROTOCOLS.items()}.get(proto, proto)
    return {"src": src, "dst": dst, "port": port, "proto": proto_name, "zfrom": zfrom, "zto": zto,
            "firewall": ip, "matched": matched, "rules": rules, "hidden_before": hidden,
            "rules_error": rules_error}


@app.route("/simulate", methods=["GET", "POST"])
def simulate():
    gate = need_login()
    if gate:
        return gate
    ctx = {"sim": None, "error": None, "edl": None, "lists": core.EDL_LISTS, "zones": core.ZONES,
           "form": {"src": CFG["spoke_host"], "dst": "93.184.216.34", "port": "443", "proto": "tcp",
                    "zfrom": "trust", "zto": "untrust"}}
    if request.method == "POST":
        check_csrf()
        action = request.form.get("action", "match")
        ctx["form"].update({k: request.form.get(k, v) for k, v in ctx["form"].items()})
        try:
            ip = active_ip()
            if not ip:
                raise core.ValidationError("no firewall configured")
            if action == "sample":
                name = core.valid_edl(request.form.get("edl", ""))
                ctx["edl"] = {"name": name, **core.parse_edl_sample(fw_op(ip, core.edl_show_cmd(name), vsys="vsys1"))}
                if ctx["edl"]["sample"]:
                    # Outbound lists are matched on the destination, inbound ones (scanners, Tor exits,
                    # vulnerable services) on the source of a session arriving from the internet.
                    use = request.form.get("use", "dst")
                    if use == "src":
                        ctx["form"].update({"src": ctx["edl"]["sample"][0], "dst": CFG["spoke_host"],
                                            "zfrom": "untrust", "zto": "trust"})
                    else:
                        ctx["form"].update({"dst": ctx["edl"]["sample"][0], "src": CFG["spoke_host"],
                                            "zfrom": "trust", "zto": "untrust"})
                audit("edl_sample", list=name)
            else:
                f = ctx["form"]
                args = (core.valid_ipv4(f["src"]), core.valid_ipv4(f["dst"]), core.valid_port(f["port"]),
                        core.valid_protocol(f["proto"]), core.valid_zone(f["zfrom"]), core.valid_zone(f["zto"]))
                ctx["sim"] = build_simulation(ip, args)
                m = ctx["sim"]["matched"] or {}
                audit("policy_match", src=args[0], dst=args[1], port=args[2], rule=m.get("name"), action=m.get("action"))
        except (core.ValidationError, requests.RequestException) as exc:
            ctx["error"] = safe_error(exc)
    return page("""<div class=card><h2>Which rule would this session hit?</h2>
<p>Asks the active firewall to <em>simulate</em> a session. <b>No traffic is sent</b>, so it is safe to use a known-bad address.</p>
<form method=post><input type=hidden name=csrf value="{{ csrf }}">
<label>Source <input name=src value="{{ form.src }}"></label>
<label>Destination <input name=dst value="{{ form.dst }}"></label><br>
<label>Port <input name=port value="{{ form.port }}" size=6></label>
<label>Protocol <select name=proto>{% for p in ('tcp','udp','icmp') %}<option {{ 'selected' if p==form.proto }}>{{ p }}</option>{% endfor %}</select></label>
<label>From <select name=zfrom>{% for z in zones %}<option {{ 'selected' if z==form.zfrom }}>{{ z }}</option>{% endfor %}</select></label>
<label>To <select name=zto>{% for z in zones %}<option {{ 'selected' if z==form.zto }}>{{ z }}</option>{% endfor %}</select></label><br>
<button name=action value=match>Simulate</button></form>
{% if error %}<p class=err>{{ error }}</p>{% endif %}</div>
{% if sim %}<div class=card><div class=row><h2>How the firewall decides</h2><button type=button id=replay>Replay</button></div>
<svg id=flow class=diagram role=img aria-label="Packet path through the firewall"></svg>
<div id=verdict class=verdict></div>
<div class=cols><div><h3>Rules, top to bottom</h3><ol id=rules class=rules></ol></div>
<div><h3>Why</h3><ul id=why class=why></ul></div></div>
<script type=application/json id=sim-data>{{ sim|tojson }}</script>
<script src="{{ url_for('static', filename='simulate.js') }}"></script></div>{% endif %}
<div class=card><h2>Take an address from an IP Defense list</h2>
<form method=post><input type=hidden name=csrf value="{{ csrf }}">
<select name=edl>{% for l in lists %}<option>{{ l }}</option>{% endfor %}</select>
<select name=use><option value=dst>use as destination (outbound, trust to untrust)</option><option value=src>use as source (inbound, untrust to trust)</option></select>
<input type=hidden name=src value="{{ form.src }}"><input type=hidden name=port value="{{ form.port }}">
<input type=hidden name=proto value="{{ form.proto }}"><input type=hidden name=zfrom value="{{ form.zfrom }}"><input type=hidden name=zto value="{{ form.zto }}">
<button name=action value=sample>Load sample</button></form>
{% if edl %}<p><code>{{ edl.name }}</code>: {{ edl.total }} entries. Sample: {{ edl.sample|join(', ') }}.<br>
The first one is now in the form above (zones set to match); press Simulate.</p>{% endif %}</div>""", **ctx)


# ---- failover tests ------------------------------------------------------------------------
_boto = {}
_boto_lock = threading.Lock()  # creating boto3 clients from several threads at once is not safe


def aws_client(service, region=None):
    region = region or CFG["region"] or None
    with _boto_lock:
        if (service, region) not in _boto:
            import boto3
            _boto[(service, region)] = boto3.client(service, region_name=region)
        return _boto[(service, region)]


def ec2_client(region=None):
    return aws_client("ec2", region)


def pairs():
    return CFG["topo"].get("pairs", {})


def units():
    """All firewall units of all pairs, by name."""
    return {n: {**u, "pair": k} for k, p in pairs().items() for n, u in p.get("units", {}).items()}


class HttpApi:
    """Firewall HA operations over the XML API, addressed by unit name (fw1/fw2)."""

    def ha(self, unit):
        return core.parse_ha(fw_op(units()[unit]["ip"], core.HA_CMD, timeout=8))

    def suspend(self, unit):
        fw_op(units()[unit]["ip"], core.HA_SUSPEND_CMD)

    def functional(self, unit):
        fw_op(units()[unit]["ip"], core.HA_FUNCTIONAL_CMD)

    def sync(self, unit):
        fw_op(units()[unit]["ip"], core.HA_SYNC_CMD)


class Ec2Api:
    """Start/stop of the two firewall instances only (the IAM role allows nothing else)."""

    def state(self, unit):
        u = units()[unit]
        r = ec2_client(u["region"]).describe_instances(InstanceIds=[u["id"]])
        return r["Reservations"][0]["Instances"][0]["State"]["Name"]

    def stop(self, unit):
        u = units()[unit]
        ec2_client(u["region"]).stop_instances(InstanceIds=[u["id"]])

    def start(self, unit):
        u = units()[unit]
        ec2_client(u["region"]).start_instances(InstanceIds=[u["id"]])


class StoreError(Exception):
    """The run store could not be read or written; disruptive tests must not start."""


class RunStore:
    """Runs in DynamoDB, so both hosts show the same progress and the history survives host swaps.

    One item per run, plus a LEASE item ("lease") taken with a conditional write: it is what
    really enforces "one test at a time" across both hosts. The running host renews it (and the
    run's `updated` time) every HEARTBEAT seconds; a lease or run not renewed for STALE seconds
    belongs to a host that went away.
    """

    HEARTBEAT = 15
    STALE = 90
    LEASE = "lease"

    def __init__(self, table):
        self.table = table
        self._last = {}

    def client(self):
        return aws_client("dynamodb")

    def put(self, doc, force=False):
        if not self.table:
            return
        now = time.time()
        if not force and doc["status"] == "running" and now - self._last.get(doc["id"], 0) < 2:
            return
        self._last[doc["id"]] = now
        try:
            self.client().put_item(TableName=self.table, Item={
                "id": {"S": doc["id"]}, "started": {"N": str(doc["started"])},
                "updated": {"N": str(now)}, "doc": {"S": json.dumps(doc)}})
        except Exception as exc:  # never break a running test because of the history
            print(json.dumps({"event": "store_error", "error": str(exc)[:200]}), flush=True)

    def take_lease(self, run_id, user):
        """True if this run got the lease; False if another fresh run holds it. Raises StoreError."""
        if not self.table:
            return True
        now = time.time()
        try:
            self.client().put_item(
                TableName=self.table,
                Item={"id": {"S": self.LEASE}, "run": {"S": run_id}, "user": {"S": user},
                      "expires": {"N": str(now + self.STALE)}},
                ConditionExpression="attribute_not_exists(id) OR expires < :now",
                ExpressionAttributeValues={":now": {"N": str(now)}})
            return True
        except Exception as exc:
            if type(exc).__name__ == "ConditionalCheckFailedException":
                return False
            raise StoreError(str(exc)[:200])

    def renew_lease(self, run_id):
        if not self.table:
            return
        try:
            self.client().update_item(
                TableName=self.table, Key={"id": {"S": self.LEASE}},
                UpdateExpression="SET expires = :e", ConditionExpression="run = :r",
                ExpressionAttributeValues={":e": {"N": str(time.time() + self.STALE)}, ":r": {"S": run_id}})
        except Exception as exc:
            print(json.dumps({"event": "store_error", "error": str(exc)[:200]}), flush=True)

    def release_lease(self, run_id):
        if not self.table:
            return
        try:
            self.client().delete_item(
                TableName=self.table, Key={"id": {"S": self.LEASE}}, ConditionExpression="run = :r",
                ExpressionAttributeValues={":r": {"S": run_id}})
        except Exception as exc:
            print(json.dumps({"event": "store_error", "error": str(exc)[:200]}), flush=True)

    def lease_holder(self):
        if not self.table:
            return None
        try:
            it = self.client().get_item(TableName=self.table, Key={"id": {"S": self.LEASE}}).get("Item")
        except Exception as exc:
            raise StoreError(str(exc)[:200])
        if it and float(it["expires"]["N"]) > time.time():
            return it["user"]["S"]
        return None

    def recent(self, limit=20):
        if not self.table:
            return []
        try:
            items, kwargs = [], {"TableName": self.table}
            while True:
                r = self.client().scan(**kwargs)
                items += r.get("Items", [])
                if "LastEvaluatedKey" not in r:
                    break
                kwargs["ExclusiveStartKey"] = r["LastEvaluatedKey"]
        except Exception as exc:
            print(json.dumps({"event": "store_error", "error": str(exc)[:200]}), flush=True)
            return []
        docs = []
        for it in items:
            if it["id"]["S"] == self.LEASE or "doc" not in it:
                continue
            doc = json.loads(it["doc"]["S"])
            if doc["status"] == "running" and time.time() - float(it["updated"]["N"]) > self.STALE:
                doc["status"] = "interrupted"
            docs.append(doc)
        return sorted(docs, key=lambda d: d["started"], reverse=True)[:limit]


STORE = RunStore(CFG["runs_table"])
RUN = {"job": None, "probe": None}
RUN_LOCK = threading.Lock()


def gp_check():
    try:
        r = requests.get(f"https://{CFG['gp_fqdn']}/global-protect/prelogin.esp", timeout=(3, 3))
        return r.status_code == 200 and "Success" in r.text
    except requests.RequestException:
        return False


def job_doc(job, probe):
    doc = job.to_dict()
    if probe is not None:
        doc["probe"] = probe.summary()
    return doc


def start_job(scenario, user, ip, restore, run_id=None, pair=None):
    """Start a run in background threads. The caller must already hold the store lease for run_id."""
    pair = pair or next(iter(pairs()), "a")
    job = fo.Job(scenario, user, phases=fo.phases_for(scenario, restore),
                 options={"restore": restore, "pair": pair, "pair_label": pairs().get(pair, {}).get("label", pair)},
                 run_id=run_id)
    probe = fo.ProbeStats(base=job.started)
    stop = threading.Event()
    mine = sorted(pairs()[pair]["units"])
    others = sorted(n for k, p in pairs().items() if k != pair for n in p.get("units", {}))
    ctx = fo.Ctx(HttpApi(), Ec2Api(), job, mine, others=others)
    job.listeners.append(lambda j: STORE.put(job_doc(j, probe)))

    def prober():
        while not stop.is_set():
            probe.record(gp_check())
            stop.wait(1)

    def heartbeat():
        # Long waits (a firewall booting: up to 20 min) log nothing; without this the run would
        # look stale to the other host and a second test could start in the middle of it.
        while not stop.wait(STORE.HEARTBEAT):
            STORE.renew_lease(job.id)
            STORE.put(job_doc(job, probe), force=True)

    def runner():
        try:
            fo.run_job(ctx, fo.SCENARIOS[scenario][1])
            # The HA roles can settle before the portal answers again (seen live: a failback
            # finished while the portal was still down). Keep probing until it is back, at most
            # 120 s, so the measured outage is the real one.
            if CFG["gp_fqdn"]:
                deadline = time.time() + 120
                while probe.summary()["down_now"] and time.time() < deadline:
                    time.sleep(1)
                if not probe.summary()["down_now"] and probe.outages:
                    job.mark("portal reachable again")
        finally:
            job.finished = job.clock()  # after the probe wait, so the timeline covers it
            stop.set()
            job.result["probe"] = {k: v for k, v in probe.summary().items() if k != "outages"}
            STORE.put(job_doc(job, probe), force=True)
            STORE.release_lease(job.id)
            print(json.dumps({"event": "failover_finished", "user": user, "ip": ip, "scenario": scenario,
                              "status": job.status, "result": job.result}), flush=True)

    RUN["job"], RUN["probe"] = job, probe
    STORE.put(job_doc(job, probe), force=True)
    if CFG["gp_fqdn"]:
        threading.Thread(target=prober, daemon=True).start()
    threading.Thread(target=heartbeat, daemon=True).start()
    threading.Thread(target=runner, daemon=True).start()
    return job


_ga_cache = {"ts": 0.0, "data": None}


def ga_state():
    """Endpoint health per region of the portal's TCP 443 listener (cached 15 s; the GA API
    lives in us-west-2 and needs no polling every 2 s)."""
    if not CFG["ga_arn"]:
        return None
    if time.time() - _ga_cache["ts"] < 15 and _ga_cache["data"] is not None:
        return _ga_cache["data"]
    data = {"home": CFG["region"], "groups": {}, "error": None}
    try:
        ga = aws_client("globalaccelerator", "us-west-2")
        listeners = ga.list_listeners(AcceleratorArn=CFG["ga_arn"])["Listeners"]
        for lst in listeners:
            if not any(r["FromPort"] <= 443 <= r["ToPort"] for r in lst["PortRanges"]):
                continue
            for g in ga.list_endpoint_groups(ListenerArn=lst["ListenerArn"])["EndpointGroups"]:
                health = [e.get("HealthState", "UNKNOWN") for e in g.get("EndpointDescriptions", [])]
                data["groups"][g["EndpointGroupRegion"]] = {
                    "health": "HEALTHY" if health and all(h == "HEALTHY" for h in health) else (health[0] if health else "UNKNOWN"),
                    "dial": g.get("TrafficDialPercentage", 100)}
    except Exception as exc:
        print(json.dumps({"event": "ga_error", "error": f"{type(exc).__name__}: {exc}"[:300]}), flush=True)
        data["error"] = f"Global Accelerator lookup failed ({type(exc).__name__})."
    _ga_cache.update(ts=time.time(), data=data)
    return data


class Topology:
    """Live picture of the pair: HA roles, EC2 state, who holds the public EIP, who gets the routes.

    Single-flight: one build at a time, everyone else gets the cached picture. Without it every
    poll from every open tab started its own build, and during a hard failover (a unit timing
    out) the 8 worker threads all hung on firewall calls.
    """

    def __init__(self):
        self._build_lock = threading.Lock()
        self._cache = (0.0, None)

    def get(self):
        ts, data = self._cache
        if data is not None and time.time() - ts < 2:
            return data
        if not self._build_lock.acquire(blocking=data is None):
            return data  # another thread is refreshing: serve the previous picture
        try:
            ts, data = self._cache
            if data is None or time.time() - ts >= 2:
                data = self._build()
                self._cache = (time.time(), data)
            return data
        finally:
            self._build_lock.release()

    def _build(self):
        errors, out = [], {"pairs": {}, "gp_fqdn": CFG["gp_fqdn"], "gp_up": None, "ts": time.time()}
        for key, p in pairs().items():
            pic = {"label": p.get("label", key), "region": p["region"], "public_ip": p.get("public_ip", ""),
                   "eip_holder": None, "eip_private_ip": None, "routes": [], "units": {}}
            for name, u in sorted(p.get("units", {}).items()):
                d = {"name": name, "ip": u["ip"]}
                try:
                    d.update(HttpApi().ha(name))
                except Exception:
                    d["state"] = "unreachable"
                pic["units"][name] = d
            try:
                ec2 = ec2_client(p["region"])
                ids = {u["id"]: n for n, u in p["units"].items()}
                r = ec2.describe_instances(InstanceIds=list(ids))
                for res in r["Reservations"]:
                    for inst in res["Instances"]:
                        pic["units"][ids[inst["InstanceId"]]]["ec2"] = inst["State"]["Name"]
                if p.get("eip_allocation_id"):
                    a_ = ec2.describe_addresses(AllocationIds=[p["eip_allocation_id"]])["Addresses"][0]
                    eni = a_.get("NetworkInterfaceId")
                    pic["eip_holder"] = next((n for n, u in p["units"].items() if u.get("untrust_eni") == eni), None)
                    pic["eip_private_ip"] = a_.get("PrivateIpAddress")
                trust = {u["trust_eni"]: n for n, u in p["units"].items() if u.get("trust_eni")}
                if trust:
                    rts = ec2.describe_route_tables(
                        Filters=[{"Name": "route.network-interface-id", "Values": list(trust)}])["RouteTables"]
                    for rt in rts:
                        rname = next((t["Value"] for t in rt.get("Tags", []) if t["Key"] == "Name"), rt["RouteTableId"])
                        for route in rt["Routes"]:
                            if route.get("NetworkInterfaceId") in trust:
                                pic["routes"].append({"table": rname, "dest": route.get("DestinationCidrBlock", ""),
                                                      "unit": trust[route["NetworkInterfaceId"]]})
            except Exception as exc:
                # Details (account id, role ARN in an AccessDenied) go to the journal, not to viewers.
                print(json.dumps({"event": "topology_error", "pair": key,
                                  "error": f"{type(exc).__name__}: {exc}"[:300]}), flush=True)
                errors.append(f"{pic['label']}: AWS lookup failed ({type(exc).__name__}).")
            out["pairs"][key] = pic
        job = RUN["job"]
        if job is not None and job.status == "running" and RUN["probe"] is not None:
            out["gp_up"] = not RUN["probe"].summary()["down_now"]
        elif CFG["gp_fqdn"]:
            out["gp_up"] = gp_check()
        out["ga"] = ga_state()
        if out["ga"] and out["ga"].get("error"):
            errors.append(out["ga"]["error"])
        out["errors"] = errors
        return out


TOPOLOGY = Topology()


@app.get("/failover/topology")
def failover_topology():
    if not logged_in():
        abort(401)
    return jsonify(TOPOLOGY.get())


@app.get("/failover/status")
def failover_status():
    if not logged_in():
        abort(401)
    job = RUN["job"]
    if job is not None and (job.status == "running" or not CFG["runs_table"]):
        return jsonify({"job": job_doc(job, RUN["probe"]), "source": "this host"})
    latest = STORE.recent(1)
    if latest:
        return jsonify({"job": latest[0], "source": "store"})
    return jsonify({"job": job_doc(job, RUN["probe"]) if job else None, "source": "this host"})


@app.get("/failover/history")
def failover_history():
    if not logged_in():
        abort(401)
    rows = []
    for d in STORE.recent(25):
        r, p = d.get("result", {}), d.get("probe") or d.get("result", {}).get("probe") or {}
        rows.append({"id": d["id"], "started": d["started"], "scenario": d["scenario"], "user": d["user"],
                     "status": d["status"], "elapsed": d["elapsed"], "takeover_s": r.get("takeover_s"),
                     "failback_s": r.get("failback_s"), "outage_total_s": p.get("total_outage_s"),
                     "outage_longest_s": p.get("longest_outage_s"), "restore": d.get("options", {}).get("restore"),
                     "pair": d.get("options", {}).get("pair_label", "")})
    return jsonify({"runs": rows})


@app.route("/failover", methods=["GET", "POST"])
def failover():
    gate = need_login()
    if gate:
        return gate
    enabled = bool(units()) and CFG["failover_enabled"]
    operator = session.get("role") == "operator"
    message = None
    if request.method == "POST":
        check_csrf()
        scenario = request.form.get("scenario", "")
        pair = request.form.get("pair", "")
        if not (enabled and operator):
            audit("failover_denied", scenario=scenario)
            abort(403)
        restore = request.form.get("restore") == "1"
        if scenario not in fo.SCENARIOS:
            message = "Unknown test."
        elif pair not in pairs():
            message = "Unknown region / pair."
        elif scenario == "region" and len(pairs()) < 2:
            message = "A region outage test needs a second region."
        elif request.form.get("confirm", "") != "FAILOVER":
            message = "Type FAILOVER in the confirmation box to start."
        elif time.time() - session.get("login_at", 0) > OPERATOR_FRESH_LOGIN:
            # Group membership is read at sign-in; a fresh sign-in picks up AD changes.
            message = "For disruptive tests please sign out and sign in again (last sign-in is over an hour old)."
        else:
            with RUN_LOCK:
                try:
                    local = RUN["job"] is not None and RUN["job"].status == "running"
                    run_id = f"{int(time.time())}-{scenario}"
                    if local or not STORE.take_lease(run_id, session["user"]):
                        holder = None if local else STORE.lease_holder()
                        message = "A test is already running" + (f" (started by {holder})" if holder else "") + "."
                    else:
                        audit("failover_start", scenario=scenario, restore=restore, pair=pair)
                        start_job(scenario, session["user"], client_ip(), restore, run_id, pair)
                        message = "Started. Progress appears below."
                except StoreError as exc:
                    print(json.dumps({"event": "store_error", "error": str(exc)}), flush=True)
                    message = "The run store is unavailable, so a test cannot be started safely. Try again later."
    meta = {"enabled": enabled, "operator": operator,
            "pairs": [{"key": k, "label": p.get("label", k), "region": p["region"]} for k, p in pairs().items()],
            "scenarios": {k: {"label": v[0], "typical": v[3], "restore": v[4], "phases": v[2]}
                          for k, v in fo.SCENARIOS.items()}}
    return page("""<div class=card><h2>Live topology</h2>
<p class=muted>Refreshed every few seconds from the firewalls' HA state and from AWS (where the public EIP
and the inspection routes point). Green = carries traffic.</p>
<svg id=topo class=diagram role=img aria-label="Firewall pair topology"></svg><p id=topo-note class=muted></p></div>
<div class=card><h2>Run a test</h2>
{% if not meta.enabled %}<p class=err>Failover tests are not enabled in this deployment.</p>
{% elif not meta.operator %}<p class=err>Your account is not an operator, so these tests are disabled for you.</p>
{% else %}<form method=post id=run-form><input type=hidden name=csrf value="{{ csrf }}">
<p><b>Region / pair:</b> {% for p in meta.pairs %}<label class=scen-inline><input type=radio name=pair value="{{ p.key }}" {{ 'checked' if loop.first }}>
{{ p.label }} <span class=muted>({{ p.region }})</span></label> {% endfor %}</p>
<p>{% for key, item in meta.scenarios.items() %}{% if key != 'region' or meta.pairs|length > 1 %}<label class=scen><input type=radio name=scenario value="{{ key }}" {{ 'checked' if loop.first }}>
{{ item.label }} <span class=muted>(about {{ [item.typical // 60, 1]|max|int }} min)</span></label>{% endif %}{% endfor %}</p>
<p><label><input type=checkbox name=restore value=1 checked id=restore> After the test, fail back so the preferred
primary is active again (one more short switchover, measured too)</label></p>
<p><label>Type <code>FAILOVER</code> to confirm <input name=confirm autocomplete=off size=12></label>
<button>Start</button></p>
<p class=muted>Tests refuse to start unless one firewall is active and the other passive; configuration sync is
checked and repaired first. The region outage test stops both firewalls of the chosen region; the portal
should then be answered by the other region through Global Accelerator.</p></form>{% endif %}
{% if message %}<p><b>{{ message }}</b></p>{% endif %}</div>
<div class=card><h2>Current / last run</h2><div id=run><p class=muted>Loading</p></div></div>
<div class=card><h2>History</h2><div id=history><p class=muted>Loading</p></div></div>
<script type=application/json id=fo-data>{{ meta|tojson }}</script>
<script src="{{ url_for('static', filename='failover.js') }}"></script>""", meta=meta, message=message)


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8080)
