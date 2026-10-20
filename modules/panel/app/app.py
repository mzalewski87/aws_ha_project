"""Lab admin panel — AD login, read-only view of the firewall pair, policy simulation.

Deliberately small and read-only:
  * login against Active Directory (NTLM bind, so the password is never sent in clear) and a
    required group (PANEL_ADMIN_GROUP);
  * status of each firewall (HA state, version) through the PAN-OS XML API with a READ-ONLY admin;
  * `test security-policy-match`: ask the firewall which rule a session WOULD hit. This checks
    Advanced IP Defense / policy without sending a single packet to a real malicious address;
  * a sample from one of PANW's predefined IP lists, so a test can use an address that really is
    on the list.
Nothing here changes configuration or touches AWS. Every action is written to the audit log
(one JSON line per event on stdout).
"""
import base64
import json
import os
import secrets
import sys
import threading
import time

import requests
from flask import Flask, Response, abort, jsonify, redirect, render_template_string, request, session, url_for
from ldap3 import NTLM, Connection, Server
from ldap3.core.exceptions import LDAPException
from ldap3.utils.conv import escape_filter_chars

import failover_core as fo
import panel_core as core

CFG = {
    # Failover tests (operators only): {"fw1": {"ip": "...", "id": "i-..."}, ...}. Empty = disabled.
    "fw_map": json.loads(base64.b64decode(os.environ.get("PANEL_FW_MAP_B64", "") or "e30=").decode()),
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
    resp.headers["Content-Security-Policy"] = "default-src 'self'; style-src 'unsafe-inline'; form-action 'self'"
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


def fw_op(ip, cmd, vsys=None):
    params = {"type": "op", "cmd": cmd}
    if vsys:
        params["vsys"] = vsys
    text = fw_call(ip, params)
    err = core.api_error(text)
    if err:
        raise core.ValidationError(err)
    return text


PAGE = """<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>Lab admin panel</title>
<style>body{font:15px system-ui;max-width:880px;margin:2rem auto;padding:0 1rem;color:#1b1f24;background:#fff}
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


@app.route("/simulate", methods=["GET", "POST"])
def simulate():
    gate = need_login()
    if gate:
        return gate
    ctx = {"result": None, "error": None, "edl": None, "lists": core.EDL_LISTS, "zones": core.ZONES,
           "form": {"src": CFG["spoke_host"], "dst": "93.184.216.34", "port": "443", "proto": "tcp",
                    "zfrom": "trust", "zto": "untrust"}}
    if request.method == "POST":
        check_csrf()
        action = request.form.get("action", "match")
        ctx["form"].update({k: request.form.get(k, v) for k, v in ctx["form"].items()})
        try:
            ip = CFG["fw_ips"][0] if CFG["fw_ips"] else None
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
                rules = core.parse_policy_match(fw_op(ip, core.policy_match_cmd(*args)))
                ctx["result"] = {"rules": rules, "firewall": ip}
                audit("policy_match", src=args[0], dst=args[1], port=args[2], rules=rules)
        except (core.ValidationError, requests.RequestException) as exc:
            ctx["error"] = str(exc)[:200]
    return page("""<div class=card><h2>Which rule would this session hit?</h2>
<p>Asks the firewall to <em>simulate</em> a session. <b>No traffic is sent</b>, so it is safe to use a known-bad address.</p>
<form method=post><input type=hidden name=csrf value="{{ csrf }}">
<label>Source <input name=src value="{{ form.src }}"></label>
<label>Destination <input name=dst value="{{ form.dst }}"></label><br>
<label>Port <input name=port value="{{ form.port }}" size=6></label>
<label>Protocol <select name=proto>{% for p in ('tcp','udp','icmp') %}<option {{ 'selected' if p==form.proto }}>{{ p }}</option>{% endfor %}</select></label>
<label>From <select name=zfrom>{% for z in zones %}<option {{ 'selected' if z==form.zfrom }}>{{ z }}</option>{% endfor %}</select></label>
<label>To <select name=zto>{% for z in zones %}<option {{ 'selected' if z==form.zto }}>{{ z }}</option>{% endfor %}</select></label><br>
<button name=action value=match>Simulate</button></form>
{% if error %}<p class=err>{{ error }}</p>{% endif %}
{% if result %}<p>Matched rule: {% for r in result.rules %}<code>{{ r }}</code> {% else %}<span class=err>none found</span>{% endfor %}
<small>(answered by {{ result.firewall }})</small></p>{% endif %}</div>
<div class=card><h2>Take a destination from an IP Defense list</h2>
<form method=post><input type=hidden name=csrf value="{{ csrf }}">
<select name=edl>{% for l in lists %}<option>{{ l }}</option>{% endfor %}</select>
<select name=use><option value=dst>use as destination (outbound, trust to untrust)</option><option value=src>use as source (inbound, untrust to trust)</option></select>
<input type=hidden name=src value="{{ form.src }}"><input type=hidden name=port value="{{ form.port }}">
<input type=hidden name=proto value="{{ form.proto }}"><input type=hidden name=zfrom value="{{ form.zfrom }}"><input type=hidden name=zto value="{{ form.zto }}">
<button name=action value=sample>Load sample</button></form>
{% if edl %}<p><code>{{ edl.name }}</code>: {{ edl.total }} entries. Sample: {{ edl.sample|join(', ') }}.<br>
The first one is now in the form above (zones set to match); press Simulate.</p>{% endif %}</div>""", **ctx)


# ---- failover tests (operators only) ----------------------------------------------------
# One test at a time per host. The scenarios refuse to start unless the pair is a clean,
# synchronized active/passive pair, so a second host cannot start a conflicting run either.
RUN = {"job": None, "probe": None}
RUN_LOCK = threading.Lock()
JS = r"""(function () {
  var box = document.getElementById('progress');
  function el(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; e.textContent = text; return e; }
  function render(d) {
    box.textContent = '';
    if (!d.job) { box.appendChild(el('p', '', 'No test has been run on this host yet.')); return; }
    var j = d.job, p = d.probe;
    box.appendChild(el('h3', j.status === 'failed' ? 'err' : (j.status === 'done' ? 'ok' : ''),
      j.scenario + ' — ' + j.status + ' (' + j.elapsed + 's, started by ' + j.user + ')'));
    if (p) {
      box.appendChild(el('p', p.down_now ? 'err' : '',
        'GlobalProtect portal: ' + p.checks + ' checks, ' + p.failed + ' failed, longest outage ' +
        p.longest_outage_s + 's, total ' + p.total_outage_s + 's, now ' + (p.down_now ? 'DOWN' : 'UP')));
    }
    if (j.result && j.result.takeover_s !== undefined) {
      box.appendChild(el('p', '', 'Takeover time (peer became active): ' + j.result.takeover_s + 's'));
    }
    var ul = document.createElement('ul');
    j.steps.forEach(function (s) { ul.appendChild(el('li', s.level === 'error' ? 'err' : (s.level === 'warn' ? 'err' : ''), '+' + s.t + 's  ' + s.msg)); });
    box.appendChild(ul);
  }
  function poll() {
    var delay = 2000;
    fetch('/failover/status', {credentials: 'same-origin'}).then(function (r) { return r.json(); })
      .then(function (d) { render(d); if (!d.job || d.job.status !== 'running') delay = 8000; })
      .catch(function () {}).then(function () { setTimeout(poll, delay); });
  }
  poll();
})();
"""


class HttpApi:
    """Firewall HA operations over the XML API, addressed by unit name (fw1/fw2)."""

    def _ip(self, unit):
        return CFG["fw_map"][unit]["ip"]

    def ha(self, unit):
        return core.parse_ha(fw_op(self._ip(unit), core.HA_CMD))

    def suspend(self, unit):
        fw_op(self._ip(unit), core.HA_SUSPEND_CMD)

    def functional(self, unit):
        fw_op(self._ip(unit), core.HA_FUNCTIONAL_CMD)


class Ec2Api:
    """Start/stop of the two firewall instances only (the IAM role allows nothing else)."""

    def __init__(self):
        import boto3
        self.client = boto3.client("ec2", region_name=CFG["region"] or None)

    def _id(self, unit):
        return CFG["fw_map"][unit]["id"]

    def state(self, unit):
        r = self.client.describe_instances(InstanceIds=[self._id(unit)])
        return r["Reservations"][0]["Instances"][0]["State"]["Name"]

    def stop(self, unit):
        self.client.stop_instances(InstanceIds=[self._id(unit)])

    def start(self, unit):
        self.client.start_instances(InstanceIds=[self._id(unit)])


def gp_check():
    try:
        r = requests.get(f"https://{CFG['gp_fqdn']}/global-protect/prelogin.esp", timeout=3)
        return r.status_code == 200 and "Success" in r.text
    except requests.RequestException:
        return False


def start_job(scenario, user, ip):
    job = fo.Job(scenario, user)
    probe = fo.ProbeStats()
    stop = threading.Event()
    ctx = fo.Ctx(HttpApi(), Ec2Api(), job, sorted(CFG["fw_map"]))

    def prober():
        while not stop.is_set():
            probe.record(gp_check())
            stop.wait(1)

    def runner():
        try:
            fo.run_job(ctx, fo.SCENARIOS[scenario][1])
        finally:
            stop.set()
            job.result["probe"] = probe.summary()
            print(json.dumps({"event": "failover_finished", "user": user, "ip": ip, "scenario": scenario,
                              "status": job.status, "result": job.result}), flush=True)

    RUN["job"], RUN["probe"] = job, probe
    if CFG["gp_fqdn"]:
        threading.Thread(target=prober, daemon=True).start()
    threading.Thread(target=runner, daemon=True).start()


@app.get("/failover.js")
def failover_js():
    return Response(JS, mimetype="application/javascript")


@app.get("/failover/status")
def failover_status():
    if not session.get("user"):
        abort(401)
    job = RUN["job"]
    return jsonify({"job": job.to_dict() if job else None,
                    "probe": RUN["probe"].summary() if RUN["probe"] else None})


@app.route("/failover", methods=["GET", "POST"])
def failover():
    gate = need_login()
    if gate:
        return gate
    enabled = bool(CFG["fw_map"])
    operator = session.get("role") == "operator"
    message = None
    if request.method == "POST":
        check_csrf()
        scenario = request.form.get("scenario", "")
        if not (enabled and operator):
            audit("failover_denied", scenario=scenario)
            abort(403)
        if scenario not in fo.SCENARIOS:
            message = "Unknown test."
        elif request.form.get("confirm", "") != "FAILOVER":
            message = "Type FAILOVER in the confirmation box to start."
        else:
            with RUN_LOCK:
                running = RUN["job"] is not None and RUN["job"].status == "running"
                if running:
                    message = "A test is already running on this host."
                else:
                    audit("failover_start", scenario=scenario)
                    start_job(scenario, session["user"],
                              request.headers.get("X-Forwarded-For", request.remote_addr))
                    message = "Started. Progress appears below."
    return page("""<div class=card><h2>Failover tests</h2>
<p>Runs a real failover of the firewall pair and shows, live, how long the GlobalProtect portal was
unreachable. The panel stays up (it runs outside the firewall path, in two AZs).</p>
{% if not enabled %}<p class=err>Failover tests are not enabled in this deployment.</p>
{% elif not operator %}<p class=err>Your account is not an operator, so these tests are disabled for you.</p>
{% else %}<form method=post><input type=hidden name=csrf value="{{ csrf }}">
<p>{% for key, item in scenarios.items() %}<label><input type=radio name=scenario value="{{ key }}" {{ 'checked' if loop.first }}> {{ item[0] }}</label><br>{% endfor %}</p>
<p><label>Type <code>FAILOVER</code> to confirm <input name=confirm autocomplete=off size=12></label>
<button>Start</button></p>
<p><small>The test refuses to start unless one firewall is active, the other passive and config-synchronized.
If a run is interrupted, use the recover option.</small></p></form>{% endif %}
{% if message %}<p><b>{{ message }}</b></p>{% endif %}</div>
<div class=card id=progress><p>Loading</p></div>
<script src="{{ url_for('failover_js') }}"></script>""", enabled=enabled, operator=operator,
                scenarios=fo.SCENARIOS, message=message)


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8080)
