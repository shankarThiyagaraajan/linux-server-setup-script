# shellcheck shell=bash
# watch.sh: the security watch. A systemd service follows the system journal
# live and records security events; the dashboard shows them and offers
# actions without leaving it.
#
#   critical   act now: root login, login right after a brute-force run,
#              a new UID 0 account, /etc/ld.so.preload appearing
#   important  check soon: login from a new address, password login, sudo
#              misuse, new accounts or admins, SSH key / sudoers / sshd /
#              cron / service changes, a new listening port, OOM kills
#   info       recorded for the timeline: normal logins, password changes
#
# Changes made while server-setup itself holds its lock are recorded as info,
# and the first run only learns (known login addresses, file and port
# baselines) so installing the watch does not raise old alarms.
#
# Files (all mode 600 in $SS_STATE_DIR): watch.json (journal cursor,
# baselines, recent failures), events.jsonl (events, newest last),
# watch-banner (the login message, present only while events need review).

WATCH_UNIT=server-setup-watch
WATCH_UNIT_FILE=${SS_WATCH_UNIT_FILE:-/etc/systemd/system/$WATCH_UNIT.service}
WATCH_MOTD=${SS_WATCH_MOTD:-/etc/update-motd.d/60-server-setup}

_watch_py() {
  python3 -I - "$SS_STATE_DIR" "$SS_CONF_DIR" "$@" <<'PY'
import fcntl, glob, hashlib, ipaddress, json, os, pwd, re, select, socket, subprocess, sys, time, urllib.request

state_dir, conf_dir, mode, args = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
P = lambda n: os.path.join(state_dir, n)
WF, EV, ST, BANNER, LOCK, WLOCK = P("watch.json"), P("events.jsonl"), P("state.json"), P("watch-banner"), P("lock"), P("watch.lock")
INBOX = P("events-inbox.jsonl")
START = time.time()

def iso(t): return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(t))

def load(p, d):
    try:
        with open(p) as f: return json.load(f)
    except (OSError, ValueError): return d

def save(p, obj):
    tmp = p + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f: json.dump(obj, f, sort_keys=True)
    os.replace(tmp, p)

W = load(WF, {})
for k, v in (("seq", 0), ("known", {}), ("fails", []), ("alerted", {}), ("stats", {}), ("snap", {}), ("outbox", []), ("alert_last", {})):
    W.setdefault(k, v)
FIRST = W.get("cursor") is None and W.get("hashes") is None   # learning run
NEW = []

# ---------------------------------------------------------------- helpers
def trusted_nets():
    nets = []
    try:
        for line in open(os.path.join(conf_dir, "config.env")):
            m = re.match(r"""TRUSTED_CIDRS=["']?([^"']*)""", line.strip())
            for c in (m.group(1).split() if m else []):
                try: nets.append(ipaddress.ip_network(c, strict=False))
                except ValueError: pass
    except OSError: pass
    return nets
TRUSTED = trusted_nets()

def is_trusted(ip):
    try: a = ipaddress.ip_address(ip)
    except ValueError: return False
    return a.is_loopback or any(a in n for n in TRUSTED)

def setup_running():
    """True while server-setup holds its lock (it is the one changing things)."""
    if os.environ.get("SS_WATCH_ASSUME_SETUP") == "1": return True
    try: fd = os.open(LOCK, os.O_RDONLY)
    except OSError: return False
    try:
        fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB); fcntl.flock(fd, fcntl.LOCK_UN); return False
    except OSError: return True
    finally: os.close(fd)

def emit(sev, kind, msg, t=None, own=False, **kw):
    t = t or time.time()
    if FIRST and t < START: sev = "info"                      # learning: no alarms for the past
    elif sev != "critical" and not own and setup_running():
        sev, msg = "info", msg + " (while server-setup was making changes)"
    W["seq"] += 1
    ev = {"id": W["seq"], "time": iso(t), "sev": sev, "kind": kind, "msg": msg}
    ev.update({k: v for k, v in kw.items() if v})
    NEW.append(ev)

def once_per_day(key):
    day = time.strftime("%F")
    if W["alerted"].get(key) == day: return False
    W["alerted"][key] = day
    return True

# ---------------------------------------------------------------- alerts
# Settings: $SS_CONF_DIR/alerts.env (KEY="value", parsed here, never sourced).
# Messages are sent from this process, so tokens never appear in a command line.
LEVELS = {"info": 0, "important": 1, "critical": 2}
def alert_conf():
    c = {}
    try:
        for line in open(os.path.join(conf_dir, "alerts.env")):
            m = re.match(r"""^([A-Z_]+)=["']?(.*?)["']?$""", line.strip())
            if m: c[m.group(1)] = m.group(2)
    except OSError: pass
    return c
A = alert_conf()
HOST = socket.gethostname()

def channels():
    out = []
    if A.get("ALERT_NTFY_URL"): out.append("ntfy")
    if A.get("ALERT_WEBHOOK_URL"): out.append("webhook")
    if A.get("ALERT_SLACK_WEBHOOK"): out.append("slack")
    if A.get("ALERT_TELEGRAM_TOKEN") and A.get("ALERT_TELEGRAM_CHAT"): out.append("telegram")
    if A.get("ALERT_EMAIL_TO"): out.append("email")
    return out

def post(url, data, headers):
    if not url.startswith("https://") and os.environ.get("SS_ALERT_ALLOW_HTTP") != "1":
        raise ValueError("only https:// addresses are allowed")
    req = urllib.request.Request(url, data=data, headers=dict(headers, **{"User-Agent": "server-setup"}), method="POST")
    with urllib.request.urlopen(req, timeout=10) as r: r.read(2000)

def send(ch, title, text, sev, extra):
    if ch == "ntfy":
        h = {"Title": title, "Priority": {"critical": "5", "important": "4"}.get(sev, "3"),
             "Tags": {"critical": "rotating_light", "important": "warning"}.get(sev, "information_source")}
        if A.get("ALERT_NTFY_TOKEN"): h["Authorization"] = "Bearer " + A["ALERT_NTFY_TOKEN"]
        post(A["ALERT_NTFY_URL"], text.encode(), h)
    elif ch == "webhook":
        post(A["ALERT_WEBHOOK_URL"], json.dumps(dict(extra, host=HOST, severity=sev, title=title, text=text)).encode(), {"Content-Type": "application/json"})
    elif ch == "slack":
        post(A["ALERT_SLACK_WEBHOOK"], json.dumps({"text": f"*{title}*\n{text}"}).encode(), {"Content-Type": "application/json"})
    elif ch == "telegram":
        api = os.environ.get("SS_TELEGRAM_API", "https://api.telegram.org")
        post(f"{api}/bot{A['ALERT_TELEGRAM_TOKEN']}/sendMessage",
             json.dumps({"chat_id": A["ALERT_TELEGRAM_CHAT"], "text": f"{title}\n{text}", "disable_web_page_preview": True}).encode(),
             {"Content-Type": "application/json"})
    elif ch == "email":
        msg = f"To: {A['ALERT_EMAIL_TO']}\nSubject: {title}\nContent-Type: text/plain; charset=utf-8\n\n{text}\n"
        r = subprocess.run(["msmtp", "-t"], input=msg, text=True, capture_output=True, timeout=30)
        if r.returncode: raise OSError((r.stderr or "msmtp failed").strip()[:200])

def queue_alerts(evs):
    chs = channels()
    if not chs: return
    lvl = LEVELS.get(A.get("ALERT_MIN_LEVEL", "important"), 1)
    pick = [e for e in evs if e.get("notify") or LEVELS.get(e["sev"], 0) >= lvl]
    if not pick: return
    review = "\nReview in the dashboard: sudo server-setup"
    if len(pick) > 5:      # a burst becomes one message, not a flood
        worst = max(pick, key=lambda e: LEVELS.get(e["sev"], 0))["sev"]
        text = "\n".join(f"- [{e['sev']}] {e['msg']}" for e in pick[:10]) + (f"\n...and {len(pick) - 10} more" if len(pick) > 10 else "")
        items = [(f"server-setup {HOST}: {len(pick)} events", text + review, worst, {"ids": [e["id"] for e in pick]})]
    else:
        items = [(f"server-setup {HOST}: {e.get('title') or e['sev']}", e["msg"] + (review if e["sev"] != "info" else ""), e["sev"],
                  {"id": e["id"], "kind": e["kind"], "time": e["time"], "message": e["msg"]}) for e in pick]
    for ch in chs:
        for title, text, sev, extra in items:
            W["outbox"].append({"ch": ch, "title": title, "text": text, "sev": sev, "extra": extra, "tries": 0, "next": 0, "since": time.time()})
    del W["outbox"][:-500]

def deliver():
    now, keep, chs = time.time(), [], channels()
    for m in W["outbox"]:
        if m["ch"] not in chs: continue                       # channel was removed
        if m["next"] > now: keep.append(m); continue
        try:
            send(m["ch"], m["title"], m["text"], m["sev"], m["extra"])
            W["alert_last"][m["ch"]] = {"time": iso(now), "ok": True}
        except Exception as ex:                               # retried with back-off for a day
            m["tries"] += 1; m["next"] = now + min(60 * 2 ** m["tries"], 3600); m["error"] = str(ex)[:200]
            W["alert_last"][m["ch"]] = {"time": iso(now), "ok": False, "error": m["error"]}
            if now - m["since"] < 86400: keep.append(m)
            elif once_per_day("alert-failed:" + m["ch"]):
                emit("important", "alert-failed", f"Alerts to {m['ch']} have failed for a day: {m['error']}", own=True)
    W["outbox"] = keep

def ingest_inbox():
    """Events raised by server-setup itself (maintenance, reports) arrive here."""
    work = INBOX + ".work"
    if not os.path.exists(work):
        try: os.rename(INBOX, work)
        except OSError: return
    try:
        with open(work) as fh: lines = fh.read().splitlines()
    except OSError: return
    for l in lines:
        try: e = json.loads(l)
        except ValueError: continue
        if e.get("sev") in LEVELS and e.get("msg"):
            emit(e["sev"], str(e.get("kind", "server-setup")), str(e["msg"]), own=True, notify=bool(e.get("notify")), title=e.get("title"))
    os.remove(work)

# ---------------------------------------------------------------- health
def health_probe():
    if os.environ.get("SS_HEALTH_PROBE") is not None:
        return load(os.environ["SS_HEALTH_PROBE"], {})
    h = {"disk": {}, "inodes": {}, "failed": []}
    for mnt in ("/", "/boot", "/var", "/home"):
        if mnt != "/" and not os.path.ismount(mnt): continue
        try: s = os.statvfs(mnt)
        except OSError: continue
        if s.f_blocks: h["disk"][mnt] = round(100 * (1 - s.f_bavail / s.f_blocks))
        if s.f_files: h["inodes"][mnt] = round(100 * (1 - s.f_favail / s.f_files))
    try:
        mi = {l.split(":")[0]: int(l.split()[1]) for l in open("/proc/meminfo")}
        h["mem_avail"] = round(100 * mi["MemAvailable"] / mi["MemTotal"])
    except (OSError, KeyError, ValueError, ZeroDivisionError): pass
    try:
        out = subprocess.run(["systemctl", "--failed", "--no-legend", "--plain"], capture_output=True, text=True, timeout=20).stdout
        h["failed"] = [l.split()[0] for l in out.splitlines() if l.strip()]
    except (OSError, subprocess.SubprocessError): pass
    return h

def check_health():
    if A.get("ALERT_HEALTH", "true") == "false": return
    h, probs = health_probe(), {}
    for m, p in h.get("disk", {}).items():
        if p >= 90: probs["disk:" + m] = ("critical" if p >= 97 else "important", f"Disk {m} is {p}% full")
    for m, p in h.get("inodes", {}).items():
        if p >= 90: probs["inodes:" + m] = ("important", f"Disk {m} is running out of inodes ({p}% used)")
    if h.get("mem_avail", 100) <= 5: probs["mem"] = ("important", f"Memory is almost full ({h['mem_avail']}% available)")
    for u in h.get("failed", []): probs["unit:" + u] = ("important", f"Service {u} has failed")
    seen = W.get("health", {})
    for k, (sev, msg) in sorted(probs.items()):              # once per problem, again only after it recovers
        if k not in seen: emit(sev, "health", msg, own=True)
    for k in sorted(set(seen) - set(probs)):
        emit("info", "health-ok", f"Back to normal: {seen[k]}", own=True)
    W["health"] = {k: v[1] for k, v in probs.items()}

# ---------------------------------------------------------------- journal
SSH_IDS = {"sshd", "sshd-session", "sshd-auth"}
R_ACC  = re.compile(r"^Accepted (\S+) for (\S+) from (\S+) port \d+")
R_FAIL = re.compile(r"^Failed (\S+) for (\S+) from (\S+) port \d+")          # valid accounts only
R_INV  = re.compile(r"^Invalid user (\S*) from (\S+) port \d+")
ADMIN_GROUPS = {"sudo", "admin", "wheel", "root", "ssh-users", "adm", "lxd", "docker"}

def fail(t, ip, user, invalid):
    W["fails"].append([round(t), ip, user, 1 if invalid else 0])
    if invalid or is_trusted(ip): return
    n = sum(1 for f in W["fails"] if f[1] == ip and not f[3] and t - f[0] < 3600)
    if n >= 10 and once_per_day("brute:" + ip):
        users = sorted({f[2] for f in W["fails"] if f[1] == ip and not f[3]})
        emit("important", "brute-force", f"{n} failed logins in an hour from {ip} to real account(s): {', '.join(users)}", t, ip=ip)

def login(t, method, user, ip):
    known = W["known"].setdefault(user, [])
    recent = sum(1 for f in W["fails"] if f[1] == ip and t - f[0] < 3600)
    via = "a password" if method.startswith(("password", "keyboard")) else "a key"
    if user == "root":
        emit("critical", "root-login", f"root logged in over SSH from {ip} with {via}", t, ip=ip, user=user)
    elif recent >= 5 and not is_trusted(ip):
        emit("critical", "login-after-failures", f"{user} logged in from {ip} right after {recent} failed attempts from that address", t, ip=ip, user=user)
    elif via == "a password":
        emit("important", "password-login", f"{user} logged in with a password from {ip} (SSH should accept keys only)", t, ip=ip, user=user)
    elif known and ip not in known and not is_trusted(ip):
        emit("important", "new-address", f"{user} logged in from a new address {ip}", t, ip=ip, user=user)
    else:
        emit("info", "login", f"{user} logged in from {ip}", t, ip=ip, user=user)
    if ip in known: known.remove(ip)
    known.insert(0, ip); del known[30:]
    W["last_login"] = {"time": iso(t), "user": user, "ip": ip, "new": bool(known[1:]) and ip not in known[1:]}

def handle(e):
    msg = e.get("MESSAGE")
    if isinstance(msg, list): msg = bytes(msg).decode("utf-8", "replace")
    if not isinstance(msg, str): return
    ident = e.get("SYSLOG_IDENTIFIER", "")
    try: t = int(e.get("__REALTIME_TIMESTAMP")) / 1e6
    except (TypeError, ValueError): t = time.time()
    st = W["stats"]
    if ident in SSH_IDS:
        m = R_ACC.match(msg)
        if m: return login(t, *m.groups())
        m = R_FAIL.match(msg)
        if m and not m.group(2).startswith("invalid"): return fail(t, m.group(3), m.group(2), False)
        m = R_INV.match(msg)
        if m: return fail(t, m.group(2), m.group(1) or "?", True)
    elif ident == "sudo":
        m = re.match(r"^\s*(\S+) : (?:\d+ )?incorrect password attempts?", msg)
        if m: return emit("important", "sudo-failed", f"Wrong sudo password for {m.group(1)}", t, user=m.group(1))
        m = re.match(r"^\s*(\S+) : (user NOT in sudoers|command not allowed)", msg)
        if m: return emit("important", "sudo-denied", f"{m.group(1)} tried to use sudo without permission", t, user=m.group(1))
        if " COMMAND=" in msg: st["sudo"] = st.get("sudo", 0) + 1
    elif ident == "su":
        m = re.search(r"FAILED SU \(to (\S+)\) (\S+)", msg)
        if m: return emit("important", "su-failed", f"{m.group(2)} failed to switch to {m.group(1)} with su", t, user=m.group(2))
    elif ident == "useradd":
        m = re.search(r"new user: name=([^,]+),\s*UID=(\d+)", msg)
        if m:
            W.setdefault("created", []).append(m.group(1)); del W["created"][:-50]
            sev = "critical" if m.group(2) == "0" else "important"
            return emit(sev, "account-created", f"New account {m.group(1)} was created (UID {m.group(2)})", t, user=m.group(1))
    elif ident == "userdel":
        m = re.search(r"delete user '([^']+)'", msg)
        if m: return emit("important", "account-deleted", f"Account {m.group(1)} was deleted", t, user=m.group(1))
    elif ident in ("usermod", "gpasswd"):
        m = re.search(r"add '([^']+)' to group '([^']+)'", msg) or re.search(r"user (\S+) added by \S+ to group (\S+)", msg)
        if m and m.group(2) in ADMIN_GROUPS:
            W.setdefault("granted", []).append(f"{m.group(1)}:{m.group(2)}"); del W["granted"][:-50]
            return emit("important", "group-added", f"{m.group(1)} was added to the {m.group(2)} group", t, user=m.group(1))
    elif ident in ("passwd", "chpasswd"):
        m = re.search(r"password changed for (\S+)", msg)
        if m: return emit("important" if m.group(1) == "root" else "info", "password-changed", f"Password changed for {m.group(1)}", t, user=m.group(1))
    elif e.get("_TRANSPORT") == "kernel" or ident == "kernel":
        m = re.search(r"Out of memory: Killed process \d+ \(([^)]+)\)", msg)
        if m: return emit("important", "oom", f"Out of memory: the kernel stopped {m.group(1)}", t)
        if "[UFW BLOCK]" in msg: st["fw_blocked"] = st.get("fw_blocked", 0) + 1
        elif 'apparmor="DENIED"' in msg: st["apparmor"] = st.get("apparmor", 0) + 1

def journal_cmd(follow):
    if os.environ.get("SS_JOURNAL_CMD"): return ["sh", "-c", os.environ["SS_JOURNAL_CMD"]]
    cmd = ["journalctl", "-o", "json", "--no-pager", "-q"]
    cmd += ["--after-cursor", W["cursor"]] if W.get("cursor") else ["--since", "-24h"]
    return cmd + (["-f"] if follow else [])

def feed(line):
    try: e = json.loads(line)
    except ValueError: return
    handle(e)
    if e.get("__CURSOR"): W["cursor"] = e["__CURSOR"]

# ---------------------------------------------------------------- files and ports
def watched_files():
    env = os.environ.get("SS_WATCH_FILES")
    pats = env.split() if env is not None else [
        "/etc/passwd", "/etc/group", "/etc/sudoers", "/etc/sudoers.d/*", "/etc/ssh/sshd_config",
        "/etc/ssh/sshd_config.d/*", "/etc/crontab", "/etc/cron.d/*", "/etc/ld.so.preload",
        "/etc/systemd/system/*.service", "/root/.ssh/authorized_keys"]
    if env is None:
        for p in pwd.getpwall():
            if p.pw_uid >= 1000 and p.pw_dir not in ("/", "/nonexistent"):
                pats.append(os.path.join(p.pw_dir, ".ssh/authorized_keys"))
    return sorted({f for pat in pats for f in glob.glob(pat) if os.path.isfile(f)})

SNAP = re.compile(r"(authorized_keys|/passwd|/group)$")
def lines_of(f):
    try:
        with open(f, errors="replace") as fh: return fh.read(65536).splitlines()
    except OSError: return []

def managed_hashes():
    m = load(ST, {}).get("managed", {})
    return {k.replace("%2E", "."): v for k, v in m.items()}

def owner_of(f):
    best = ("?", 0)
    for p in pwd.getpwall():
        d = p.pw_dir.rstrip("/")
        if d and f.startswith(d + "/") and len(d) > best[1]: best = (p.pw_name, len(d))
    return best[0]

def describe(f, old_lines, new_lines, created):
    added = [l for l in new_lines if l not in set(old_lines)]
    if f.endswith("authorized_keys"):
        who = owner_of(f)
        keys = [l for l in added if l.strip() and not l.startswith("#")]
        for k in keys or [None]:
            label = (k.split()[-1] if k and len(k.split()) > 2 else "a key") if k else None
            if label is None:
                emit("info", "keys-changed", f"SSH keys for {who} changed (keys removed)", user=who, file=f)
            else:
                emit("critical" if who == "root" else "important", "key-added", f"SSH key added for {who}: {label}", user=who, file=f)
        return
    if f.endswith("/passwd"):
        known = set(W.get("created", []))
        for l in added:
            p = l.split(":")
            if len(p) < 7: continue
            if p[2] == "0" and p[0] != "root":
                emit("critical", "uid0", f"Account {p[0]} now has root rights (UID 0)", user=p[0], file=f)
            elif p[0] not in known and p[6] not in ("/usr/sbin/nologin", "/bin/false", "/sbin/nologin"):
                emit("important", "account-created", f"New login account {p[0]} appeared in /etc/passwd", user=p[0], file=f)
        return
    if f.endswith("/group"):
        granted = set(W.get("granted", []))
        old = {l.split(":")[0]: set(filter(None, l.split(":")[3].split(","))) for l in old_lines if l.count(":") >= 3}
        for l in new_lines:
            p = l.split(":")
            if len(p) < 4 or p[0] not in ADMIN_GROUPS: continue
            for u in set(filter(None, p[3].split(","))) - old.get(p[0], set()):
                if f"{u}:{p[0]}" not in granted:
                    emit("important", "group-added", f"{u} was added to the {p[0]} group", user=u, file=f)
        return
    if f == "/etc/ld.so.preload" or f.endswith("ld.so.preload"):
        return emit("critical", "preload", f"{f} was {'created' if created else 'changed'}: a common way to hide malware", file=f)
    if "sudoers" in f: return emit("important", "sudoers", f"sudo rules {'added' if created else 'changed'}: {f}", file=f)
    if "/ssh/" in f:   return emit("important", "sshd-config", f"SSH server settings {'added' if created else 'changed'}: {f}", file=f)
    if "cron" in f:    return emit("important", "cron", f"Scheduled task {'added' if created else 'changed'}: {f}", file=f)
    if f.endswith(".service"):
        return emit("important", "service", f"{'New' if created else 'Changed'} system service: {os.path.basename(f)}", file=f)
    emit("important", "file", f"{f} changed", file=f)

def check_files():
    cur = {}
    for f in watched_files():
        try:
            with open(f, "rb") as fh: cur[f] = hashlib.sha256(fh.read()).hexdigest()
        except OSError: pass
    old, managed = W.get("hashes"), managed_hashes()
    if old is not None:
        for f, h in cur.items():
            if old.get(f) == h or managed.get(f) == h: continue
            describe(f, W["snap"].get(f, []), lines_of(f), f not in old)
    W["hashes"] = cur
    W["snap"] = {f: lines_of(f) for f in cur if SNAP.search(f)}

def listening():
    if os.environ.get("SS_PROBE_PORTS") is not None:
        raw = open(os.environ["SS_PROBE_PORTS"]).read()
    else:
        try: raw = subprocess.run(["ss", "-H", "-tulpn"], capture_output=True, text=True, timeout=20).stdout
        except (OSError, subprocess.SubprocessError): return None
    out = {}
    for l in raw.splitlines():
        p = l.split()
        if len(p) < 5: continue
        host, _, port = p[4].rpartition(":")
        if host.startswith("127.") or host in ("[::1]", "::1") or "%lo" in host: continue
        proc = re.search(r'users:\(\("([^"]+)"', l)
        out[f"{port}/{p[0]}"] = proc.group(1) if proc else "-"
    return out

def check_ports():
    cur = listening()
    if cur is None: return
    old = W.get("ports")
    if old is not None:
        for k, proc in sorted(cur.items()):
            if k not in old:
                emit("important", "new-port", f"New service listening on port {k} ({proc})", port=k)
    W["ports"] = cur

def periodic():
    check_files(); check_ports(); check_health()
    W["fails"] = [f for f in W["fails"] if time.time() - f[0] < 86400][-20000:]
    W["last_check"] = iso(time.time())

# ---------------------------------------------------------------- output
def unreviewed():
    st = load(ST, {}); acked = set(st.get("events_ack", [])); upto = st.get("events_ack_upto", 0)
    out = []
    try:
        with open(EV) as fh:
            for l in fh:
                try: e = json.loads(l)
                except ValueError: continue
                if e.get("sev") in ("critical", "important") and e["id"] > upto and e["id"] not in acked: out.append(e)
    except OSError: pass
    return out

def flush():
    ingest_inbox()
    queue_alerts(NEW)
    deliver()
    if NEW:
        fd = os.open(EV, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a") as fh:
            for e in NEW: fh.write(json.dumps(e, ensure_ascii=False) + "\n")
        if os.path.getsize(EV) > 1_000_000:
            with open(EV) as fh: lines = fh.readlines()
            fd = os.open(EV + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as fh: fh.writelines(lines[len(lines) // 2:])
            os.replace(EV + ".tmp", EV)
        for e in NEW:
            if e["sev"] != "info": print(f"{e['sev'].upper()}: {e['msg']}", flush=True)
        NEW.clear()
    save(WF, W)
    write_banner()

def write_banner():
    u = unreviewed()
    if not u:
        try: os.remove(BANNER)
        except FileNotFoundError: pass
        return
    c = sum(1 for e in u if e["sev"] == "critical")
    color = "\033[1;31m" if c else "\033[1;33m"
    text = f"\n  {color}server-setup: {len(u)} security event(s) need your attention" + (f" ({c} critical)" if c else "") + \
           f".\033[0m\n  Latest: {u[-1]['msg']}\n  Review them in the dashboard: sudo server-setup\n\n"
    fd = os.open(BANNER + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh: fh.write(text)
    os.replace(BANNER + ".tmp", BANNER)

def take_watch_lock(block):
    fd = os.open(WLOCK, os.O_WRONLY | os.O_CREAT, 0o600)
    try: fcntl.flock(fd, fcntl.LOCK_EX | (0 if block else fcntl.LOCK_NB)); return fd
    except OSError: os.close(fd); return None

# ---------------------------------------------------------------- modes
if mode == "once":
    if take_watch_lock(False) is None: sys.exit(0)            # the service is already on it
    p = subprocess.run(journal_cmd(False), capture_output=True, text=True)
    for line in p.stdout.splitlines(): feed(line)
    periodic(); flush()

elif mode == "follow":
    take_watch_lock(True)
    print(f"server-setup watch started ({'learning baseline' if FIRST else 'resuming'})", flush=True)
    periodic(); flush()
    proc = subprocess.Popen(journal_cmd(True), stdout=subprocess.PIPE, text=True, bufsize=1)
    last_periodic = last_flush = time.time()
    while True:
        ready, _, _ = select.select([proc.stdout], [], [], 5)
        if ready:
            line = proc.stdout.readline()
            if not line: break
            feed(line)
        now = time.time()
        if now - last_periodic >= int(os.environ.get("SS_WATCH_INTERVAL", "300")):
            periodic(); last_periodic = now
        if NEW or now - last_flush >= 10:
            flush(); last_flush = now
    flush()
    sys.exit(proc.wait() or 1)                                 # systemd restarts us

elif mode == "summary":                                        # key<TAB>value lines for the dashboard
    now = time.time()
    f24 = [f for f in W["fails"] if now - f[0] < 86400]
    u = unreviewed()
    print(f"fails\t{len(f24)}"); print(f"fail_ips\t{len({f[1] for f in f24})}")
    print(f"real_fails\t{sum(1 for f in f24 if not f[3])}")
    ll = W.get("last_login") or {}
    if ll: print(f"last_login\t{ll['time']}\t{ll['user']}\t{ll['ip']}\t{'new' if ll.get('new') else 'known'}")
    print(f"unreviewed\t{len(u)}\t{sum(1 for e in u if e['sev'] == 'critical')}\t{u[-1]['id'] if u else 0}")
    for e in u[-3:][::-1]: print(f"event\t{e['id']}\t{e['sev']}\t{e['time']}\t{e['msg']}")
    print(f"last_check\t{W.get('last_check', '')}")
    print(f"learning\t{1 if W.get('cursor') is None else 0}")

elif mode == "list":      # id time sev kind reviewed ip user msg, separated by \x1f (fields may be empty)
    n = int(args[0]) if args else 30
    st = load(ST, {}); acked = set(st.get("events_ack", [])); upto = st.get("events_ack_upto", 0)
    try: lines = open(EV).readlines()[-n:]
    except OSError: lines = []
    for l in reversed(lines):
        try: e = json.loads(l)
        except ValueError: continue
        rev = "yes" if e["sev"] == "info" or e["id"] <= upto or e["id"] in acked else "no"
        print("\x1f".join(str(x) for x in (e["id"], e["time"], e["sev"], e["kind"], rev, e.get("ip", ""), e.get("user", ""), e["msg"])))

elif mode == "banner":
    write_banner()

elif mode == "alert-test":                                     # channel<TAB>ok|error, sent right now
    if not channels(): sys.exit(1)
    for ch in channels():
        try:
            send(ch, f"server-setup {HOST}: test", "This is a test alert from server-setup. Alerts work.", "info", {"kind": "test"})
            print(f"{ch}\tok")
        except Exception as ex: print(f"{ch}\t{str(ex)[:200]}")

elif mode == "alert-status":                                   # channel<TAB>time<TAB>ok<TAB>error, then pending<TAB>n
    for ch in channels():
        l = W["alert_last"].get(ch, {})
        print(f"{ch}\t{l.get('time', '')}\t{'yes' if l.get('ok') else ('no' if l else '')}\t{l.get('error', '')}")
    print(f"pending\t{len(W['outbox'])}")
else:
    sys.exit("unknown watch mode: " + mode)
PY
}

watch_running() { systemctl is-active --quiet "$WATCH_UNIT" 2>/dev/null; }
watch_installed() { [[ -f $WATCH_UNIT_FILE ]]; }

# watch_scan: catch up on the journal when the service is not running, so the
# dashboard is never stale. Quick: it resumes from the saved cursor.
watch_scan() { watch_running || _watch_py once >/dev/null 2>&1 || true; }

cmd_watch() { if [[ ${1:-} == once ]]; then _watch_py once; else _watch_py follow; fi; }

# ------------------------------------------------------------ reviewing
events_ack() {   # events_ack ID... | all UPTO_ID
  local cur ids
  if [[ $1 == all ]]; then state_set events_ack_upto "$2"; state_set events_ack '[]'
  else
    cur=$(state_get events_ack); cur=${cur:-[]}
    ids=$(python3 -I -c 'import json,sys; a=json.loads(sys.argv[1]); a += [int(x) for x in sys.argv[2:]]; print(json.dumps(sorted(set(a))[-500:]))' "$cur" "$@")
    state_set events_ack "$ids"
  fi
  _watch_py banner || true
}

event_get() {    # event_get ID → the event's line from "list"
  _watch_py list 2000 | awk -F'\x1f' -v id="$1" '$1 == id' | head -1
}

sev_mark() {
  case $1 in critical) printf '%s‼%s' "$C_RED$C_BOLD" "$C_0" ;; important) printf '%s!%s' "$C_AMBER" "$C_0" ;; *) printf '%s·%s' "$C_DIM" "$C_0" ;; esac
}

# ip_block IP: deny everything from it at the top of the firewall.
ip_block() {
  local ip=$1 me=${SSH_CONNECTION:-}; me=${me%% *}
  valid_cidr "$ip" || { warn "Not an IP address: $ip"; return 1; }
  if [[ -n $me && $ip == "$me" ]]; then warn "$ip is the address you are connected from. Not blocking it."; return 1; fi
  if python3 -I -c 'import ipaddress,sys; a=ipaddress.ip_address(sys.argv[1]); sys.exit(0 if a.is_loopback else 1)' "$ip" 2>/dev/null; then warn "Not blocking a local address."; return 1; fi
  local c; for c in $(cfg_reset; cfg_load "$(CONFIG_FILE)"; echo "${CFG[TRUSTED_CIDRS]}"); do
    if python3 -I -c 'import ipaddress,sys; sys.exit(0 if ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2], strict=False) else 1)' "$ip" "$c" 2>/dev/null; then
      warn "$ip is inside your trusted range $c. Remove it from the trusted ranges first if you really want to block it."; return 1
    fi
  done
  command -v ufw >/dev/null && ufw status | grep -q '^Status: active' || { warn "The firewall is off, so nothing can be blocked. Turn it on from Set up."; return 1; }
  backup_file /etc/ufw/user.rules; backup_file /etc/ufw/user6.rules
  ufw insert 1 deny from "$ip" comment 'server-setup: blocked from the security watch' >/dev/null
  history_add block-ip ok "blocked $ip"
  log "Blocked all connections from $ip. Undo: Firewall & ports, or sudo ufw delete deny from $ip"
}

# account_lock USER: lock the password, expire the account (stops key logins
# too) and end its sessions. Refuses the account you are using.
account_lock() {
  local u=$1 admins n a
  id "$u" &>/dev/null || { warn "No account $u."; return 1; }
  [[ $u == root ]] && { warn "Root is handled by Set up (it is locked when an admin has a password)."; return 1; }
  [[ $u == "${SUDO_USER:-}" ]] && { warn "$u is the account you are using right now. Not locking it."; return 1; }
  admins=$(state_get setup.admins | tr -d '[]",'); n=0
  for a in $admins; do [[ $a != "$u" ]] && id "$a" &>/dev/null && n=$((n + 1)); done
  if [[ " $admins " == *" $u "* ]] && (( n == 0 )); then warn "$u is the only admin left. Not locking it."; return 1; fi
  usermod -L -e 1 "$u"
  loginctl terminate-user "$u" 2>/dev/null || pkill -KILL -u "$u" 2>/dev/null || true
  history_add lock-account ok "locked $u and ended its sessions"
  log "Locked $u and ended its sessions. Undo: sudo usermod -U -e '' $u"
}

# event_popup ID: one event, with what you can do about it.
event_popup() {
  local line id time sev kind rev ip user msg color items=() acts=()
  line=$(event_get "$1"); [[ -n $line ]] || return 0
  IFS=$'\x1f' read -r id time sev kind rev ip user msg <<<"$line"
  case $sev in critical) color=$C_RED ;; important) color=$C_AMBER ;; *) color=$C_CYAN ;; esac
  local body=("$msg" "" "When: $(date -d "$time" '+%a %-d %b %H:%M' 2>/dev/null || echo "$time")")
  [[ -n $ip ]] && body+=("From: $ip$( [[ -n ${SSH_CONNECTION:-} && $ip == "${SSH_CONNECTION%% *}" ]] && echo "  (that is you, right now)" || true)")
  [[ -n $user ]] && body+=("Account: $user")
  body+=("" "$(event_advice "$kind")")
  [[ $rev == no ]] && { items+=("This was me / expected|mark as reviewed"); acts+=(ack); }
  [[ -n $ip && $kind != oom ]] && { items+=("Block $ip|deny all connections from it in the firewall"); acts+=(block); }
  [[ -n $user && $user != root && $kind =~ ^(login|new-address|password-login|login-after-failures|account-created|group-added|key-added|sudo-failed|sudo-denied|su-failed)$ ]] && { items+=("Lock account $user|stop it logging in, end its sessions"); acts+=(lock); }
  items+=("Back|"); acts+=(back)
  ui_clear
  UI_POPUP_NOTE='' ui_popup "$color" "Security event (${sev})" "${body[@]}" -- "${items[@]}"
  (( UI_CHOICE >= 0 )) || return 0
  case ${acts[$UI_CHOICE]} in
    ack)   events_ack "$id" ;;
    block) confirm_popup "Block all connections from $ip?" "It is added at the top of the firewall. You can remove it later under Firewall & ports." \
             && { dash_lock || return 0; ui_clear; ip_block "$ip" && events_ack "$id"; ss_unlock; ui_pause; } ;;
    lock)  confirm_popup "Lock the account $user?" "Its password is locked, the account is expired (so SSH keys stop working too) and its sessions end." \
             && { dash_lock || return 0; ui_clear; account_lock "$user" && events_ack "$id"; ss_unlock; ui_pause; } ;;
  esac
}

confirm_popup() {   # confirm_popup TITLE TEXT: "No" first so a stray enter does nothing
  ui_clear
  UI_POPUP_NOTE='' ui_popup "$C_AMBER" "$1" "$2" -- "No|back" "Yes|do it now"
  (( UI_CHOICE == 1 ))
}

event_advice() {
  case $1 in
    root-login) echo "Root should never log in over SSH. If this was not you, block the address, change keys and check what root did." ;;
    login-after-failures) echo "A login that follows many failures can mean a guessed password. If not you: lock the account and block the address." ;;
    password-login) echo "SSH accepted a password, so SSH may have been changed to allow passwords. Run the security check." ;;
    new-address) echo "Usually you on a new network. If not, lock the account and block the address." ;;
    brute-force) echo "Someone is guessing passwords for real accounts. Fail2ban bans them for a while; blocking keeps them out for good." ;;
    key-added) echo "Anyone with this key can log in. If you did not add it, remove it under Users & SSH keys and lock the account." ;;
    uid0|preload) echo "This is a sign of a compromised machine. Disconnect it from the network and investigate." ;;
    account-created|group-added|account-deleted) echo "If nobody on your team did this, lock the account and check sudo logs." ;;
    sudo-failed|sudo-denied|su-failed) echo "Someone tried to get admin rights. If it was not a typo by you, find out who." ;;
    sudoers|sshd-config|cron|service|file) echo "If you or a package update did not change this, compare it with a backup." ;;
    new-port) echo "A program started accepting connections. If you don't know it, find it: Open ports panel." ;;
    oom) echo "The machine ran out of memory. Add swap or memory, or limit the program." ;;
    health) echo "Disk: Install updates (3) also cleans up; journals and old kernels are the usual culprits. Failed service: systemctl status NAME." ;;
    score-drop) echo "Run the security check (2) to see what changed and how to fix it." ;;
    stale-admin) echo "Unused admin accounts are an easy way in. Lock the ones nobody needs under Users & SSH keys (4)." ;;
    alert-failed) echo "Check the channel under Alerts (6) and send a test." ;;
    new-release) echo "Upgrade Ubuntu (8) checks the machine is ready before it starts." ;;
    *) echo "" ;;
  esac
}

# The pop-up shown when new events need attention (on open and as they arrive).
events_attention_popup() {
  local -a ids=() items=(); local id sev time msg line kind rev ip user n=0 upto
  upto=0
  while IFS=$'\x1f' read -r id time sev kind rev ip user msg; do
    [[ $rev == no ]] || continue
    (( id > upto )) && upto=$id
    ids+=("$id"); items+=("$(sev_mark "$sev") $msg|$(human_time "$time")"); n=$((n + 1))
    (( n >= 8 )) && break
  done < <(_watch_py list 300 | awk -F'\x1f' '{print ($3 == "critical" ? 0 : 1) "\x1f" $0}' | sort -t$'\x1f' -k1,1n -s | cut -d$'\x1f' -f2-)
  (( n )) || return 0
  state_set events_popup_upto "$upto"
  items+=("Mark all as reviewed|they stay in the event list" "Later|")
  [[ $(event_get "${ids[0]}" | cut -d$'\x1f' -f3) == critical ]] && printf '\a'
  ui_clear
  UI_POPUP_NOTE='' ui_popup "$C_RED" "Security events need your attention" \
    "The security watch found $n thing(s) to check. Pick one for details and actions." -- "${items[@]}"
  if (( UI_CHOICE >= 0 && UI_CHOICE < ${#ids[@]} )); then event_popup "${ids[$UI_CHOICE]}"; events_attention_popup
  elif (( UI_CHOICE == ${#ids[@]} )); then events_ack all "$upto"; fi
}

# e: the full list.
screen_events() {
  local -a ids=() items=(); local id time sev kind rev ip user msg
  while IFS=$'\x1f' read -r id time sev kind rev ip user msg; do
    ids+=("$id")
    items+=("$(sev_mark "$sev") $( [[ $rev == no ]] && echo "${C_BOLD}" || true)$msg${C_0}|$(human_time "$time")")
  done < <(_watch_py list 15)
  ui_clear; step "Security events"
  if ! watch_installed; then printf '  %sThe security watch service is off; this list is updated only while the dashboard is open.%s\n' "$C_AMBER" "$C_0"; fi
  if (( ${#ids[@]} == 0 )); then printf '\n  Nothing recorded yet.\n'; ui_pause; return; fi
  UI_MENU_WIDTH=$(( $(ui_cols) - 24 )) ui_menu "Newest first; bold ones are not reviewed yet. Pick one for details and actions" "${items[@]}" "Mark all as reviewed|" "Back|"
  if (( UI_CHOICE >= 0 && UI_CHOICE < ${#ids[@]} )); then event_popup "${ids[$UI_CHOICE]}"; screen_events
  elif (( UI_CHOICE == ${#ids[@]} )); then events_ack all "${ids[0]}"; fi
}

# ------------------------------------------------------------ dashboard panel
panel_watch() {
  local w=$1 rows=() k a b c d status
  local fails=0 ips=0 real=0 unrev=0 crit=0 ll="" learning=0 evs=()
  while IFS=$'\t' read -r k a b c d; do
    case $k in
      fails) fails=$a ;; fail_ips) ips=$a ;; real_fails) real=$a ;;
      unreviewed) unrev=$a; crit=$b ;;
      last_login) ll="$b from $c · $(human_time "$a")$( [[ $d == new ]] && echo " ${C_AMBER}(new address)${C_0}" || true)" ;;
      event) evs+=("$(sev_mark "$b") $d  ${C_DIM}$(human_time "$c")${C_0}") ;;
      learning) learning=$a ;;
    esac
  done < <(_watch_py summary 2>/dev/null)
  if watch_running; then status="${C_GREEN}● watching live${C_0}"
  elif watch_installed; then status="${C_RED}● service stopped${C_0}"
  else status="${C_AMBER}● off · press w to turn on${C_0}"; fi
  (( learning )) && status+="  ${C_DIM}(learning what is normal)${C_0}"
  if (( unrev > 0 )); then
    rows+=("$(lr "$( (( crit )) && echo "${C_RED}${C_BOLD}‼ $unrev event(s) need your attention ($crit critical)${C_0}" || echo "${C_AMBER}${C_BOLD}! $unrev event(s) need your attention${C_0}") · press e" "$status")")
  else
    rows+=("$(lr "$(ok_mark) Nothing new to review" "$status")")
  fi
  rows+=("Last 24h: $fails failed SSH login(s) from $ips address(es)$( (( real )) && echo ", ${C_AMBER}$real against real accounts${C_0}" || true)")
  [[ -n $ll ]] && rows+=("Last login: $ll")
  rows+=("${evs[@]}")
  panel "Security watch" "$w" "${rows[@]}"
}

# ------------------------------------------------------------ setup component
apply_watch() {
  step "Security watch"
  if ! command -v journalctl >/dev/null || [[ ! -d /run/systemd/system && -z ${SS_PATH_PREFIX:-} ]]; then
    warn "No systemd journal here (container?); the security watch runs only while the dashboard is open."
    return 0
  fi
  write_file "$WATCH_UNIT_FILE" 644 <<EOF
# Managed by server-setup
[Unit]
Description=server-setup security watch (suspicious logins, admin and config changes)
After=systemd-journald.service network.target

[Service]
Type=simple
ExecStart=$(ss_self) watch
Restart=always
RestartSec=10
Nice=10
IOSchedulingClass=idle
MemoryMax=256M
CPUQuota=20%
# Read-only view of the system; it only writes its own state.
ProtectSystem=strict
ReadWritePaths=$SS_STATE_DIR
ProtectHome=read-only
PrivateTmp=yes
NoNewPrivileges=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
LockPersonality=yes

[Install]
WantedBy=multi-user.target
EOF
  write_file "$WATCH_MOTD" 755 <<EOF
#!/bin/sh
# Managed by server-setup: show security events that need review at login.
[ -r $SS_STATE_DIR/watch-banner ] && cat $SS_STATE_DIR/watch-banner
exit 0
EOF
  [[ $SS_DRY_RUN == true ]] && return 0
  systemctl daemon-reload
  systemctl enable "$WATCH_UNIT" >/dev/null 2>&1 || true
  systemctl restart "$WATCH_UNIT" || warn "The security watch did not start; check: systemctl status $WATCH_UNIT"
  log "Security watch on: it follows the system log live and shows events here and at login."
}

# w on the dashboard: turn the watch on for a machine set up before it existed.
watch_turn_on() {
  ui_clear
  UI_POPUP_NOTE='' ui_popup "$C_CYAN" "Turn on the security watch?" \
    "A small background service follows the system log and warns you about:" \
    "  · logins from new addresses, root or password logins, logins after many failures" \
    "  · repeated failed logins to real accounts" \
    "  · new accounts or admins, sudo misuse, SSH key, sudoers, SSH, cron and service changes" \
    "  · new programs listening on the network" \
    "" "Events show here, as a pop-up when they arrive, and as a message when you log in." \
    "It only reads logs; it never changes anything by itself." \
    -- "Turn it on|recommended" "Not now|"
  (( UI_CHOICE == 0 )) || return 0
  dash_lock || return 0
  ui_clear; apply_watch
  cfg_reset; cfg_load "$(CONFIG_FILE)"
  cfg_has watch || { CFG[COMPONENTS]=$(xargs <<<"${CFG[COMPONENTS]} watch"); [[ -f $(CONFIG_FILE) ]] && cfg_save "$(CONFIG_FILE)"; }
  history_add watch ok "security watch turned on"
  ss_unlock; ui_pause
}
