#!/usr/bin/env python3
"""
Generate EKS egress External Dynamic Lists for PAN-OS / Panorama (AWS).

Writes (atomically):
  - /var/www/html/edl/eks-egress-fqdn.txt  (URL list — wildcards, trailing slash)
  - /var/www/html/edl/eks-egress-ips.txt   (IP list — AWS ip-ranges.json for the
                                             region's AMAZON service, IPv4)

PAN-OS quirks honoured:
  - URL entries get a trailing slash so wildcards match (`*.foo/`).
  - # / ; comment lines are preserved.
If the AWS ip-ranges.json fetch fails, the previous IP list is kept (stale beats
empty — empty would block legitimate egress).

Reads /opt/eks-edl/settings.json for {"region": "..."}. Run by the systemd timer.
"""
import datetime, json, os, sys, tempfile, urllib.request, logging

BASE = "/opt/eks-edl/fqdn_base_list.txt"
SETTINGS = "/opt/eks-edl/settings.json"
OUTDIR = "/var/www/html/edl"
FQDN_OUT = os.path.join(OUTDIR, "eks-egress-fqdn.txt")
IPS_OUT = os.path.join(OUTDIR, "eks-egress-ips.txt")
IP_RANGES_URL = "https://ip-ranges.amazonaws.com/ip-ranges.json"

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s",
                    handlers=[logging.FileHandler("/var/log/eks-edl-update.log"),
                              logging.StreamHandler(sys.stdout)])
log = logging.getLogger("eks-edl")


def settings():
    with open(SETTINGS, encoding="utf-8") as f:
        s = json.load(f)
    if not s.get("region"):
        raise RuntimeError("settings.json missing 'region'")
    return s


def render_fqdn(region):
    out = ["# EKS Egress FQDN List",
           f"# Generated: {datetime.datetime.utcnow().isoformat()}Z",
           f"# Region: {region}", ""]
    with open(BASE, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            s = line.strip()
            if not s or s.startswith(("#", ";")):
                out.append(line)
            else:
                out.append(s.replace("${REGION}", region) + "/")
    return "\n".join(out) + "\n"


def fetch_ip_cidrs(region):
    req = urllib.request.Request(IP_RANGES_URL, headers={"User-Agent": "eks-edl/1.0"})
    with urllib.request.urlopen(req, timeout=60) as r:
        doc = json.loads(r.read())
    cidrs = sorted({p["ip_prefix"] for p in doc.get("prefixes", [])
                    if p.get("region") == region and p.get("service") == "AMAZON"})
    if not cidrs:
        raise RuntimeError(f"no AMAZON prefixes for region {region}")
    return cidrs


def render_ips(region, cidrs):
    out = [f"# EKS Egress IP List (AMAZON, {region})",
           f"# Generated: {datetime.datetime.utcnow().isoformat()}Z",
           f"# Count: {len(cidrs)}", ""]
    out.extend(cidrs)
    return "\n".join(out) + "\n"


def write_atomic(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-", suffix=".txt")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def main():
    s = settings()
    region = s["region"]
    write_atomic(FQDN_OUT, render_fqdn(region))
    log.info("wrote FQDN list")
    try:
        cidrs = fetch_ip_cidrs(region)
        write_atomic(IPS_OUT, render_ips(region, cidrs))
        log.info("wrote IP list (%d CIDRs)", len(cidrs))
    except Exception as e:
        log.warning("IP list fetch failed: %s", e)
        if not os.path.exists(IPS_OUT):
            write_atomic(IPS_OUT, f"# fetch failed {datetime.datetime.utcnow().isoformat()}Z\n")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log.exception("crashed: %s", e)
        sys.exit(1)
