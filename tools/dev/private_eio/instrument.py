"""Private matched EIO observations; no sleeps, retries, or queue draining."""
import hashlib
import json
import pathlib
import subprocess
import sys

source = pathlib.Path(sys.argv[1])
variant = sys.argv[2]
if variant not in ("baseline", "candidate"):
    raise SystemExit("Unknown variant")
path = source / "mettle/src/mettle.c"
original = path.read_bytes()
expected = "33ddb0d2709c8009bdb65da2da26fd714190a8c14b8d15690045f8eff4d3303f"
if hashlib.sha256(original).hexdigest() != expected:
    raise SystemExit("Unexpected Mettle source")
text = original.decode()

def replace_once(old, new):
    global text
    if text.count(old) != 1:
        raise SystemExit("Unexpected source context: " + old)
    text = text.replace(old, new, 1)

replace_once("static struct ev_async eio_async_watcher;", """static struct ev_async eio_async_watcher;

/* Main-loop-only observations. Report via the existing heartbeat. */
static unsigned long diagnostic_async_polls;
static unsigned long diagnostic_idle_polls;
static unsigned long diagnostic_done_polls;
static unsigned long diagnostic_notifications_cleared;
static int diagnostic_last_before;
static int diagnostic_last_after;
static int diagnostic_last_active;
""")
replace_once("eio_idle_cb(struct ev_loop *loop, struct ev_idle *w, int revents)\n{",
             "eio_idle_cb(struct ev_loop *loop, struct ev_idle *w, int revents)\n{\n\t++diagnostic_idle_polls;")
replace_once("eio_async_cb(struct ev_loop *loop, struct ev_async *w, int revents)\n{",
             "eio_async_cb(struct ev_loop *loop, struct ev_async *w, int revents)\n{\n\t++diagnostic_async_polls;")
restart = "\tev_async_start(ev_default_loop(EV_LOOP_FLAGS), &eio_async_watcher);"
replace_once(restart, """\tdiagnostic_last_active = ev_is_active(w);
\tdiagnostic_last_before = ev_async_pending(w);
""" + (restart + "\n" if variant == "baseline" else "") + """\tdiagnostic_last_after = ev_async_pending(w);
\tif (diagnostic_last_before && !diagnostic_last_after) {
\t\t++diagnostic_notifications_cleared;
\t}""")
stop = "\tev_async_stop(ev_default_loop(EV_LOOP_FLAGS), &eio_async_watcher);"
replace_once(stop, "\t++diagnostic_done_polls;\n" + (stop if variant == "baseline" else
             "\t/* Keep the watcher active: restarting it can discard worker notifications. */"))
replace_once('\tlog_info("Heartbeat");', """\tlog_info("Heartbeat EIO_DIAGNOSTIC_V1 requests=%u ready=%u pending=%u "
\t\t"async_active=%d async_sent=%d idle_active=%d async_polls=%lu "
\t\t"idle_polls=%lu done_polls=%lu notifications_cleared=%lu "
\t\t"last_active=%d last_before=%d last_after=%d",
\t\teio_nreqs(), eio_nready(), eio_npending(),
\t\tev_is_active(&eio_async_watcher), ev_async_pending(&eio_async_watcher),
\t\tev_is_active(&eio_idle_watcher), diagnostic_async_polls,
\t\tdiagnostic_idle_polls, diagnostic_done_polls,
\t\tdiagnostic_notifications_cleared, diagnostic_last_active,
\t\tdiagnostic_last_before, diagnostic_last_after);""")
path.write_text(text)
receipt = {
    "variant": variant,
    "base_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip(),
    "original_sha256": expected,
    "instrumented_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    "scope": "Main-loop counters and existing heartbeat; no scheduling sleeps. Queue counts are separate snapshots, not an atomic transaction."
}
(source / "diagnostic-source.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(json.dumps(receipt))
