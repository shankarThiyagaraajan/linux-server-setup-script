# shellcheck shell=bash
# state.sh: what server-setup knows about this machine.
#
#   state.json     current picture: machine type, setup, last run of each task,
#                  hashes of files it manages, recommendation decisions
#   history.jsonl  one line per run, newest last
#
# JSON is handled by python3, which every Ubuntu install ships. Writes are
# atomic (temp file in the same directory, then rename) and mode 600.

_state_py() {
  python3 -I - "$SS_STATE_DIR" "$@" <<'PY'
import json, os, sys, tempfile, time

d, cmd, args = sys.argv[1], sys.argv[2], sys.argv[3:]
state_f, hist_f = os.path.join(d, "state.json"), os.path.join(d, "history.jsonl")

def load():
    try:
        with open(state_f) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}
    except ValueError:
        sys.exit("state.json is damaged; move it aside and run again")

def save(obj):
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".state.")
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f, indent=2, sort_keys=True, ensure_ascii=False)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, state_f)

def walk(obj, path, create=False):
    keys = path.split(".")
    for k in keys[:-1]:
        if create:
            obj = obj.setdefault(k, {})
        else:
            obj = obj.get(k, {}) if isinstance(obj, dict) else {}
    return obj, keys[-1]

def out(v):
    if v is None:
        return
    if isinstance(v, bool):
        print("true" if v else "false")
    elif isinstance(v, (dict, list)):
        print(json.dumps(v))
    else:
        print(v)

if cmd == "get":
    parent, k = walk(load(), args[0])
    out(parent.get(k) if isinstance(parent, dict) else None)
elif cmd == "set":            # set PATH JSON_VALUE
    s = load()
    parent, k = walk(s, args[0], create=True)
    parent[k] = json.loads(args[1])
    save(s)
elif cmd == "del":
    s = load()
    parent, k = walk(s, args[0])
    if isinstance(parent, dict) and k in parent:
        del parent[k]
        save(s)
elif cmd == "keys":
    parent, k = walk(load(), args[0])
    v = parent.get(k) if isinstance(parent, dict) else None
    for key in sorted(v or {}):
        print(key)
elif cmd == "history-add":    # task trigger result summary run_id
    task, trigger, result, summary, run_id = args
    rec = {"time": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "task": task, "by": trigger,
           "result": result, "summary": summary, "run_id": run_id}
    fd = os.open(hist_f, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    if os.path.getsize(hist_f) > 1_000_000:     # keep roughly the newest half
        with open(hist_f) as f:
            lines = f.readlines()
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".hist.")
        with os.fdopen(fd, "w") as f:
            f.writelines(lines[len(lines) // 2:])
        os.chmod(tmp, 0o600)
        os.replace(tmp, hist_f)
    s = load()
    s.setdefault("last", {})[task] = {"time": rec["time"], "result": result,
                                      "summary": summary, "run_id": run_id}
    save(s)
elif cmd == "history-tail":   # N -> "time<TAB>task<TAB>by<TAB>result<TAB>summary"
    try:
        with open(hist_f) as f:
            lines = f.readlines()[-int(args[0]):]
    except FileNotFoundError:
        lines = []
    for line in reversed(lines):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        print("\t".join(str(r.get(k, "")) for k in ("time", "task", "by", "result", "summary", "run_id")))
else:
    sys.exit("unknown state command: " + cmd)
PY
}

state_get()   { _state_py get "$1"; }
state_set()   { [[ $SS_DRY_RUN == true ]] && return 0; _state_py set "$1" "$2"; }
state_del()   { [[ $SS_DRY_RUN == true ]] && return 0; _state_py del "$1"; }
state_keys()  { _state_py keys "$1"; }
history_tail(){ _state_py history-tail "${1:-20}"; }

# history_add TASK RESULT SUMMARY: records who ran it (user name or "timer").
history_add() {
  [[ $SS_DRY_RUN == true ]] && return 0
  local by=${SUDO_USER:-${USER:-root}}
  [[ -n ${INVOCATION_ID:-} && -z ${SSH_CONNECTION:-} && ! -t 0 ]] && by=timer
  _state_py history-add "$1" "$by" "$2" "$3" "$RUN_ID"
}

# JSON string literal for state_set.
json_str() { python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
json_list() { python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@"; }

# Short relative time for the dashboard: "today 06:00", "Sun 03:00", "2 Sep".
human_time() {
  local t=$1 epoch now days
  [[ -z $t ]] && { printf 'never'; return; }
  epoch=$(date -d "$t" +%s 2>/dev/null) || { printf '%s' "$t"; return; }
  now=$(date +%s); days=$(( (now - epoch) / 86400 ))
  if [[ $(date -d "@$epoch" +%F) == $(date +%F) ]]; then date -d "@$epoch" '+today %H:%M'
  elif (( days < 7 )); then date -d "@$epoch" '+%a %H:%M'
  else date -d "@$epoch" '+%-d %b'
  fi
}
