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
    "operator_group": os.environ.get("PANEL_OPERATOR_GROUP", "panel-operators"),
    "gp_fqdn": os.environ.get("PANEL_GP_FQDN", ""),
    "region": os.environ.get("AWS_DEFAULT_REGION", ""),
    "ldap_host": os.environ["PANEL_LDAP_HOST"],
    "domain": os.environ["PANEL_DOMAIN"],  # e.g. panw.labs
    "netbios": os.environ.get("PANEL_NETBIOS", os.environ["PANEL_DOMAIN"].split(".")[0].upper()),
    "base_dn": os.environ["PANEL_BASE_DN"],
    "group": os.environ.get("PANEL_ADMIN_GROUP", "panel-admins"),
    "fw_ips": [x for x in os.environ.get("PANEL_FW_IPS", "").split(",") if x],
    "fw_user": os.environ.get("PANEL_FW_USER", ""),
    "fw_password": os.environ.get("PANEL_FW_PASSWORD", ""),
    "spoke_host": os.environ.get("PANEL_SPOKE_HOST", "10.12.0.10"),
}

app = Flask(__name__)
app.secret_key = os.environ["PANEL_SESSION_SECRET"]
app.config.update(SESSION_COOKIE_SECURE=True, SESSION_COOKIE_HTTPONLY=True,
                  SESSION_COOKIE_SAMESITE="Strict", PERMANENT_SESSION_LIFETIME=1800)
limiter = core.RateLimiter(limit=5, window=600)
_keys = {}  # firewall ip -> (api key, time obtained)


def audit(event, **fields):
    rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "event": event,
           "user": session.get("user"), "ip": request.headers.get("X-Forwarded-For", request.remote_addr)}
    rec.update(fields)
    print(json.dumps(rec), file=sys.stdout, flush=True)


@app.after_request
def headers(resp):
    resp.headers["X-Frame-Options"] = "DENY"
    resp.headers["X-Content-Type-Options"] = "nosniff"
    resp.headers["Referrer-Policy"] = "no-referrer"
    resp.headers["Content-Security-Policy"] = "default-src 'self'; style-src 'self' 'unsafe-inline'; form-action 'self'"
    resp.headers["Cache-Control"] = "no-store"
    return resp


def csrf_token():
    if "csrf" not in session:
        session["csrf"] = secrets.token_urlsafe(24)
    return session["csrf"]


def need_login():
    if not session.get("user"):
        return redirect(url_for("login"))
    return None


def check_csrf():
    if not secrets.compare_digest(request.form.get("csrf", ""), session.get("csrf", "x")):
        abort(400, "bad CSRF token")


def ad_authenticate(username, password):
    """None unless a valid AD account in the admin group; then "operator" or "viewer".

    "operator" (extra group) may also run the failover tests; "viewer" is read-only.
    """
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

        def member(name):
            return any(g.startswith(f"cn={name.lower()},") for g in groups)

        if not member(CFG["group"]):
            return None
        return "operator" if member(CFG["operator_group"]) else "viewer"
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
        r = requests.get(f"https://{ip}/api/", timeout=10, verify=False,  # self-signed mgmt cert, private network
                         params={"type": "keygen", "user": CFG["fw_user"], "password": CFG["fw_password"]})
        key = (core.parse_key(r.text), time.time())
        _keys[ip] = key
    r = requests.post(f"https://{ip}/api/", timeout=timeout, verify=False,
                      data={**params, "key": key[0]})
    return r.text


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
        ip = request.headers.get("X-Forwarded-For", request.remote_addr).split(",")[0].strip()
        try:
            user = core.valid_username(request.form.get("username", ""))
        except core.ValidationError:
            user = ""
        key = f"{ip}|{user}"
        if limiter.blocked(key) or limiter.blocked(f"{ip}|*"):
            audit("login_blocked", target=user)
            return page("<p class=err>Too many failed attempts. Try again in a few minutes.</p>"), 429
        role = ad_authenticate(user, request.form.get("password", "")) if user else None
        if role:
            limiter.reset(key)
            session.clear()
            session.permanent = True
            session["user"] = user
            session["role"] = role
            audit("login_ok", role=role)
            return redirect(url_for("home"))
        limiter.fail(key)
        limiter.fail(f"{ip}|*")
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
            row["error"] = str(exc)[:160]
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
    for u in CFG["topo"].get("units", {}).values():
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
        upto = matched["index"] if matched and matched["index"] else len(allrules)
        before = [r for r in allrules if r["index"] < upto]
        for r in before[-30:]:
            rules.append({**r, "verdict": "skip", "reason": core.skip_reason(r, zfrom, zto)})
        hidden = max(0, len(before) - 30)
        if matched:
            m = next((r for r in allrules if r["name"] == matched["name"]), None)
            rules.append({**(m or matched), "verdict": "match", "reason": "first rule whose criteria all match"})
            if not matched["action"] and m:
                matched["action"] = m["action"]
        after = [r for r in allrules if r["index"] > upto][:2]
        rules += [{**r, "verdict": "unused", "reason": "not evaluated (a rule above already matched)"} for r in after]
    except (core.ValidationError, requests.RequestException) as exc:
        hidden, rules_error = 0, str(exc)[:160]
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
            ctx["error"] = str(exc)[:200]
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


def ec2_client():
    if "ec2" not in _boto:
        import boto3
        _boto["ec2"] = boto3.client("ec2", region_name=CFG["region"] or None)
    return _boto["ec2"]


def units():
    return CFG["topo"].get("units", {})


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
        r = ec2_client().describe_instances(InstanceIds=[units()[unit]["id"]])
        return r["Reservations"][0]["Instances"][0]["State"]["Name"]

    def stop(self, unit):
        ec2_client().stop_instances(InstanceIds=[units()[unit]["id"]])

    def start(self, unit):
        ec2_client().start_instances(InstanceIds=[units()[unit]["id"]])


class RunStore:
    """Runs in DynamoDB, so both hosts show the same progress and the history survives host swaps."""

    STALE = 90  # a 'running' record not updated for this long belongs to a host that went away

    def __init__(self, table):
        self.table = table
        self._client = None
        self._last = {}

    def client(self):
        if self._client is None:
            import boto3
            self._client = boto3.client("dynamodb", region_name=CFG["region"] or None)
        return self._client

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

    def recent(self, limit=20):
        if not self.table:
            return []
        try:
            items, kwargs = [], {"TableName": self.table}
            while True:
                r = self.client().scan(**kwargs)
                items += r.get("Items", [])
                if "LastEvaluatedKey" not in r or len(items) > 500:
                    break
                kwargs["ExclusiveStartKey"] = r["LastEvaluatedKey"]
        except Exception as exc:
            print(json.dumps({"event": "store_error", "error": str(exc)[:200]}), flush=True)
            return []
        docs = []
        for it in items:
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
        r = requests.get(f"https://{CFG['gp_fqdn']}/global-protect/prelogin.esp", timeout=3)
        return r.status_code == 200 and "Success" in r.text
    except requests.RequestException:
        return False


def job_doc(job, probe):
    doc = job.to_dict()
    if probe is not None:
        doc["probe"] = probe.summary()
    return doc


def start_job(scenario, user, ip, restore):
    job = fo.Job(scenario, user, phases=fo.phases_for(scenario, restore), options={"restore": restore})
    probe = fo.ProbeStats(base=job.started)
    stop = threading.Event()
    ctx = fo.Ctx(HttpApi(), Ec2Api(), job, sorted(units()))
    job.listeners.append(lambda j: STORE.put(job_doc(j, probe)))

    def prober():
        while not stop.is_set():
            probe.record(gp_check())
            stop.wait(1)

    def runner():
        try:
            fo.run_job(ctx, fo.SCENARIOS[scenario][1])
        finally:
            stop.set()
            job.result["probe"] = {k: v for k, v in probe.summary().items() if k != "outages"}
            STORE.put(job_doc(job, probe), force=True)
            print(json.dumps({"event": "failover_finished", "user": user, "ip": ip, "scenario": scenario,
                              "status": job.status, "result": job.result}), flush=True)

    RUN["job"], RUN["probe"] = job, probe
    STORE.put(job_doc(job, probe), force=True)
    if CFG["gp_fqdn"]:
        threading.Thread(target=prober, daemon=True).start()
    threading.Thread(target=runner, daemon=True).start()


def running_elsewhere():
    latest = STORE.recent(1)
    return latest[0] if latest and latest[0]["status"] == "running" else None


class Topology:
    """Live picture of the pair: HA roles, EC2 state, who holds the public EIP, who gets the routes."""

    def __init__(self):
        self._lock = threading.Lock()
        self._cache = (0.0, None)

    def get(self):
        with self._lock:
            if time.time() - self._cache[0] < 2 and self._cache[1] is not None:
                return self._cache[1]
        data = self._build()
        with self._lock:
            self._cache = (time.time(), data)
        return data

    def _build(self):
        topo, errors = CFG["topo"], []
        out = {"units": {}, "public_ip": topo.get("public_ip", ""), "eip_holder": None, "eip_private_ip": None,
               "routes": [], "gp_fqdn": CFG["gp_fqdn"], "gp_up": None, "ts": time.time()}
        for name, u in sorted(units().items()):
            d = {"name": name, "ip": u["ip"]}
            try:
                d.update(HttpApi().ha(name))
            except Exception:
                d["state"] = "unreachable"
            out["units"][name] = d
        try:
            ids = {u["id"]: n for n, u in units().items()}
            r = ec2_client().describe_instances(InstanceIds=list(ids))
            for res in r["Reservations"]:
                for inst in res["Instances"]:
                    out["units"][ids[inst["InstanceId"]]]["ec2"] = inst["State"]["Name"]
            if topo.get("eip_allocation_id"):
                a = ec2_client().describe_addresses(AllocationIds=[topo["eip_allocation_id"]])["Addresses"][0]
                eni = a.get("NetworkInterfaceId")
                out["eip_holder"] = next((n for n, u in units().items() if u.get("untrust_eni") == eni), None)
                out["eip_private_ip"] = a.get("PrivateIpAddress")
            trust = {u["trust_eni"]: n for n, u in units().items() if u.get("trust_eni")}
            if trust:
                rts = ec2_client().describe_route_tables(
                    Filters=[{"Name": "route.network-interface-id", "Values": list(trust)}])["RouteTables"]
                for rt in rts:
                    name = next((t["Value"] for t in rt.get("Tags", []) if t["Key"] == "Name"), rt["RouteTableId"])
                    for route in rt["Routes"]:
                        if route.get("NetworkInterfaceId") in trust:
                            out["routes"].append({"table": name, "dest": route.get("DestinationCidrBlock", ""),
                                                  "unit": trust[route["NetworkInterfaceId"]]})
        except Exception as exc:
            errors.append(f"AWS: {type(exc).__name__}: {exc}"[:200])
        job = RUN["job"]
        if job is not None and job.status == "running" and RUN["probe"] is not None:
            out["gp_up"] = not RUN["probe"].summary()["down_now"]
        elif CFG["gp_fqdn"]:
            out["gp_up"] = gp_check()
        out["errors"] = errors
        return out


TOPOLOGY = Topology()


@app.get("/failover/topology")
def failover_topology():
    if not session.get("user"):
        abort(401)
    return jsonify(TOPOLOGY.get())


@app.get("/failover/status")
def failover_status():
    if not session.get("user"):
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
    if not session.get("user"):
        abort(401)
    rows = []
    for d in STORE.recent(25):
        r, p = d.get("result", {}), d.get("probe") or d.get("result", {}).get("probe") or {}
        rows.append({"id": d["id"], "started": d["started"], "scenario": d["scenario"], "user": d["user"],
                     "status": d["status"], "elapsed": d["elapsed"], "takeover_s": r.get("takeover_s"),
                     "failback_s": r.get("failback_s"), "outage_total_s": p.get("total_outage_s"),
                     "outage_longest_s": p.get("longest_outage_s"), "restore": d.get("options", {}).get("restore")})
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
        if not (enabled and operator):
            audit("failover_denied", scenario=scenario)
            abort(403)
        restore = request.form.get("restore") == "1"
        if scenario not in fo.SCENARIOS:
            message = "Unknown test."
        elif request.form.get("confirm", "") != "FAILOVER":
            message = "Type FAILOVER in the confirmation box to start."
        else:
            with RUN_LOCK:
                local = RUN["job"] is not None and RUN["job"].status == "running"
                other = None if local else running_elsewhere()
                if local or other:
                    message = "A test is already running" + ("" if local else f" (started by {other['user']})") + "."
                else:
                    audit("failover_start", scenario=scenario, restore=restore)
                    start_job(scenario, session["user"],
                              request.headers.get("X-Forwarded-For", request.remote_addr), restore)
                    message = "Started. Progress appears below."
    meta = {"enabled": enabled, "operator": operator, "public_ip": CFG["topo"].get("public_ip", ""),
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
<p>{% for key, item in meta.scenarios.items() %}<label class=scen><input type=radio name=scenario value="{{ key }}" {{ 'checked' if loop.first }}>
{{ item.label }} <span class=muted>(about {{ (item.typical/60)|round(0, 'ceil')|int }} min)</span></label>{% endfor %}</p>
<p><label><input type=checkbox name=restore value=1 checked id=restore> After the test, fail back so the preferred
primary is active again (one more short switchover, measured too)</label></p>
<p><label>Type <code>FAILOVER</code> to confirm <input name=confirm autocomplete=off size=12></label>
<button>Start</button></p>
<p class=muted>Tests refuse to start unless one firewall is active and the other passive; configuration sync is
checked and repaired first. Region failure needs a second region (not deployed here).</p></form>{% endif %}
{% if message %}<p><b>{{ message }}</b></p>{% endif %}</div>
<div class=card><h2>Current / last run</h2><div id=run><p class=muted>Loading</p></div></div>
<div class=card><h2>History</h2><div id=history><p class=muted>Loading</p></div></div>
<script type=application/json id=fo-data>{{ meta|tojson }}</script>
<script src="{{ url_for('static', filename='failover.js') }}"></script>""", meta=meta, message=message)


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8080)
