# Module 12 — Healthchecks and Monitoring
[![CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey)](./LICENSE.md)
[![RHEL 10](https://img.shields.io/badge/platform-RHEL%2010-red)](https://access.redhat.com/products/red-hat-enterprise-linux)
[![fail2ban](https://img.shields.io/badge/fail2ban-RHEL%2010-red)](https://access.redhat.com/products/red-hat-enterprise-linux)

> **Level:** Advanced  
> **Prerequisites:** [Module 10 — Advanced Topics](./10-advanced-topics.md)  
> **Time to complete:** ~75 minutes

---

## Table of Contents

1. [Why Healthchecks Matter](#1-why-healthchecks-matter)
2. [Service-Level Checks](#2-service-level-checks)
3. [Socket and PID Checks](#3-socket-and-pid-checks)
4. [Jail Status Checks](#4-jail-status-checks)
5. [Firewalld Integration Verification](#5-firewalld-integration-verification)
6. [Log Activity Checks](#6-log-activity-checks)
7. [Database Integrity Checks](#7-database-integrity-checks)
8. [End-to-End Smoke Test](#8-end-to-end-smoke-test)
9. [The Full Bash Healthcheck Script](#9-the-full-bash-healthcheck-script)
10. [Systemd Watchdog Integration](#10-systemd-watchdog-integration)
11. [Scheduled Monitoring with Systemd Timers](#11-scheduled-monitoring-with-systemd-timers)
12. [Alerting Integrations](#12-alerting-integrations)
13. [Lab 12 — Deploy the Healthcheck Script and Systemd Timer](#lab-12--deploy-the-healthcheck-script-and-systemd-timer)

---

## 1. Why Healthchecks Matter

Fail2ban can fail silently. Common failure modes that go unnoticed without proactive monitoring:

| Failure mode | Symptom | Detection |
|-------------|---------|-----------|
| fail2ban service stopped | No bans applied | Service check |
| firewalld stopped | Bans queued but not enforced | firewalld check |
| Jail disabled or filter broken | Specific service not protected | Per-jail status check |
| Log file disappeared or rotated improperly | fail2ban reads empty file | Log activity check |
| SQLite database corrupted | Bans lost after restart | Database integrity check |
| SELinux denial | firewall-cmd calls silently failing | SELinux audit check |
| ipset size limit reached | New bans not added to ipset | ipset check |

A healthcheck script catches all of these. Run it via a systemd timer and send alerts when it fails.

[↑ Back to TOC](#table-of-contents)

---

## 2. Service-Level Checks

The most fundamental check: is fail2ban running?

### Check 1 — systemd service state

```bash
systemctl is-active fail2ban.service
```

| Return value | Meaning |
|-------------|---------|
| `active` | Service is running |
| `inactive` | Service is stopped |
| `failed` | Service crashed |
| `activating` | Service is starting |

```bash

[↑ Back to TOC](#table-of-contents)

# Exit code check (0 = active, non-zero = not active)
if ! systemctl is-active --quiet fail2ban.service; then
  echo "CRITICAL: fail2ban service is not active"
fi
```

### Check 2 — fail2ban-client ping

```bash
sudo fail2ban-client ping
```

Expected output: `Server replied: pong`

This confirms the fail2ban server process is responding to requests, not just that the systemd unit is listed as active.

```bash
if ! sudo fail2ban-client ping &>/dev/null; then
  echo "CRITICAL: fail2ban server not responding to ping"
fi
```

### Check 3 — firewalld service state

```bash
systemctl is-active firewalld.service
```

Or with `firewall-cmd`:

```bash
sudo firewall-cmd --state
```

Expected: `running`

### Check 4 — Both services active at the same time

```bash
if systemctl is-active --quiet fail2ban.service && \
   systemctl is-active --quiet firewalld.service; then
  echo "OK: Both fail2ban and firewalld are running"
else
  echo "CRITICAL: One or both services are down"
fi
```

---

## 3. Socket and PID Checks

### Check the PID file

```bash
PID_FILE="/run/fail2ban/fail2ban.pid"

if [[ ! -f "$PID_FILE" ]]; then
  echo "WARNING: PID file missing: $PID_FILE"
else
  PID=$(cat "$PID_FILE")
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "CRITICAL: PID file exists but process $PID is not running (stale PID)"
  else
    echo "OK: fail2ban running with PID $PID"
  fi
fi
```

### Check the socket file

```bash
SOCKET_FILE="/run/fail2ban/fail2ban.sock"

if [[ ! -S "$SOCKET_FILE" ]]; then
  echo "CRITICAL: fail2ban socket missing: $SOCKET_FILE"
else
  echo "OK: fail2ban socket exists"
fi
```

### Check process is actually present

```bash
if pgrep -x "fail2ban-server" > /dev/null; then
  echo "OK: fail2ban-server process found"
else
  echo "CRITICAL: fail2ban-server process not found in process table"
fi
```

[↑ Back to TOC](#table-of-contents)

---

## 4. Jail Status Checks

Verify that expected jails are enabled and active.

### List all active jails

```bash
sudo fail2ban-client status
```

Expected output includes your jail names:

```
Status
|- Number of jail: 3
`- Jail list: labapp, recidive, sshd
```

### Check a specific jail is in the list

```bash
REQUIRED_JAILS=("sshd" "labapp" "recidive")

ACTIVE_JAILS=$(sudo fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*Jail list:\s*//')

for jail in "${REQUIRED_JAILS[@]}"; do
  if echo "$ACTIVE_JAILS" | grep -qw "$jail"; then
    echo "OK: Jail '$jail' is active"
  else
    echo "CRITICAL: Jail '$jail' is NOT active"
  fi
done
```

### Check per-jail statistics

```bash

[↑ Back to TOC](#table-of-contents)

# Get status for a specific jail
sudo fail2ban-client status sshd
```

Output fields to check:
- `Currently failed` — should change over time if service is under attack (or stay 0 if no attacks)
- `Currently banned` — current live ban count
- `File list` / journal — confirms which log source is being monitored

### Detect a jail with 0 total failures over a suspicious period

A jail showing `Total failed: 0` after days of operation may indicate the filter is not matching. Compare with raw log data:

```bash
# Check total failures for sshd jail
TOTAL_FAILED=$(sudo fail2ban-client status sshd 2>/dev/null | grep "Total failed" | awk '{print $NF}')
echo "sshd jail total failures since start: $TOTAL_FAILED"

# If zero, check if SSH attempts are actually being logged
sudo journalctl -u sshd.service --since "1 hour ago" | grep -c "Failed password" || echo "0 SSH failures in journal in last hour"
```

---

## 5. Firewalld Integration Verification

Verify that fail2ban's firewalld ipsets exist and are populated when bans are active.

### Check firewalld is running

```bash
sudo firewall-cmd --state
```

### List all fail2ban ipsets

```bash
sudo firewall-cmd --get-ipsets | tr ' ' '\n' | grep "^f2b-"
```

Expected output (one ipset per enabled jail):

```
f2b-sshd
f2b-labapp
f2b-recidive
```

### Check ipset exists for a specific jail

```bash
JAIL="sshd"
IPSET="f2b-${JAIL}"

if sudo firewall-cmd --get-ipsets 2>/dev/null | grep -qw "$IPSET"; then
  ENTRY_COUNT=$(sudo firewall-cmd --ipset="$IPSET" --get-entries 2>/dev/null | wc -l)
  echo "OK: ipset '$IPSET' exists with $ENTRY_COUNT entries"
else
  echo "WARNING: ipset '$IPSET' does not exist (no bans active or firewalld reset)"
fi
```

### Check active rich rules (for firewallcmd-allports bans)

```bash
RULE_COUNT=$(sudo firewall-cmd --list-rich-rules 2>/dev/null | grep -c "reject\|drop" || echo 0)
echo "Active firewalld rich rules (allports bans): $RULE_COUNT"
```

### Verify firewalld zone contains the ipset source

```bash
ZONE="public"
sudo firewall-cmd --zone="$ZONE" --list-sources 2>/dev/null

[↑ Back to TOC](#table-of-contents)

# Should list ipset:f2b-sshd etc. when bans are active
```

### Cross-reference: ban in fail2ban matches ipset entry

```bash
# Get banned IPs from fail2ban
F2B_BANNED=$(sudo fail2ban-client status sshd 2>/dev/null | grep "Banned IP list" | sed 's/.*Banned IP list:\s*//')

# Get entries from firewalld ipset
IPSET_ENTRIES=$(sudo firewall-cmd --ipset=f2b-sshd --get-entries 2>/dev/null)

echo "fail2ban reports banned: $F2B_BANNED"
echo "firewalld ipset contains: $IPSET_ENTRIES"
```

---

## 6. Log Activity Checks

Verify that fail2ban's log source (flat file or journal) is active and recent.

### Check fail2ban's own log for recent activity

```bash

[↑ Back to TOC](#table-of-contents)

# If using file logging:
if [[ -f /var/log/fail2ban.log ]]; then
  LAST_LINE=$(sudo tail -1 /var/log/fail2ban.log)
  LAST_TIME=$(echo "$LAST_LINE" | grep -oP '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}')
  echo "Last fail2ban log entry: $LAST_TIME"
  
  # Warn if last entry is older than 1 hour
  LAST_EPOCH=$(date -d "$LAST_TIME" +%s 2>/dev/null || echo 0)
  NOW_EPOCH=$(date +%s)
  AGE=$(( NOW_EPOCH - LAST_EPOCH ))
  if (( AGE > 3600 )); then
    echo "WARNING: fail2ban log has not been updated in over 1 hour"
  fi
fi
```

### Check flat log files are recent (for file-based jails)

```bash
# Apache access log should be updated recently
LOG="/var/log/httpd/access_log"
if [[ -f "$LOG" ]]; then
  MTIME=$(stat -c %Y "$LOG")
  NOW=$(date +%s)
  AGE=$(( NOW - MTIME ))
  if (( AGE > 3600 )); then
    echo "WARNING: $LOG has not been updated in over 1 hour"
  else
    echo "OK: $LOG is recent (${AGE}s old)"
  fi
fi
```

### Verify fail2ban is monitoring the log file

```bash
# Check which files are in the jail's watch list
sudo fail2ban-client status apache-auth 2>/dev/null | grep "File list"
```

### Check journal is accessible for systemd-backend jails

```bash
if sudo journalctl -u sshd.service -n 1 --no-pager &>/dev/null; then
  echo "OK: systemd journal is accessible"
else
  echo "CRITICAL: Cannot read systemd journal"
fi
```

---

## 7. Database Integrity Checks

The SQLite database stores ban history. A corrupted database causes bans to be lost on restart.

### Check database file exists

```bash
DB="/var/lib/fail2ban/fail2ban.sqlite3"

if [[ ! -f "$DB" ]]; then
  echo "WARNING: fail2ban database not found at $DB"
else
  echo "OK: Database file exists ($(du -h $DB | cut -f1))"
fi
```

### Run SQLite integrity check

```bash
DB="/var/lib/fail2ban/fail2ban.sqlite3"

RESULT=$(sudo sqlite3 "$DB" "PRAGMA integrity_check;" 2>&1)
if [[ "$RESULT" == "ok" ]]; then
  echo "OK: Database integrity check passed"
else
  echo "CRITICAL: Database integrity check FAILED: $RESULT"
fi
```

### Check database has expected tables

```bash
DB="/var/lib/fail2ban/fail2ban.sqlite3"

TABLES=$(sudo sqlite3 "$DB" ".tables" 2>&1)
for table in bans logs; do
  if echo "$TABLES" | grep -qw "$table"; then
    echo "OK: Table '$table' exists"
  else
    echo "CRITICAL: Table '$table' MISSING from database"
  fi
done
```

### Check database size is not excessive

```bash
DB="/var/lib/fail2ban/fail2ban.sqlite3"
SIZE_BYTES=$(sudo stat -c %s "$DB" 2>/dev/null || echo 0)
SIZE_MB=$(( SIZE_BYTES / 1048576 ))

if (( SIZE_MB > 100 )); then
  echo "WARNING: Database is ${SIZE_MB}MB — consider reducing dbpurgeage"
elif (( SIZE_MB > 500 )); then
  echo "CRITICAL: Database is ${SIZE_MB}MB — immediate action required"
else
  echo "OK: Database size is ${SIZE_MB}MB"
fi
```

### Check recent ban count (sanity check)

```bash
DB="/var/lib/fail2ban/fail2ban.sqlite3"
RECENT_BANS=$(sudo sqlite3 "$DB" \
  "SELECT COUNT(*) FROM bans WHERE timeofban > strftime('%s','now') - 86400;" 2>/dev/null || echo "N/A")
echo "Bans recorded in last 24 hours: $RECENT_BANS"
```

[↑ Back to TOC](#table-of-contents)

---

## 8. End-to-End Smoke Test

A smoke test verifies the full pipeline: write a failure to the log → fail2ban detects it → ban fires → firewalld confirms ban → unban succeeds.

### Smoke test procedure

```bash
#!/bin/bash

[↑ Back to TOC](#table-of-contents)

# End-to-end smoke test for fail2ban + firewalld pipeline

JAIL="labapp"
LOG="/var/log/labapp/auth.log"
TEST_IP="192.0.2.250"   # TEST-NET-3, never routable
MAXRETRY=5

echo "=== Fail2ban Smoke Test ==="

# 1. Verify test IP is not already banned
if sudo fail2ban-client get "$JAIL" banned 2>/dev/null | grep -q "$TEST_IP"; then
  echo "Cleaning up pre-existing ban for $TEST_IP"
  sudo fail2ban-client set "$JAIL" unbanip "$TEST_IP" 2>/dev/null
fi

# 2. Write MAXRETRY+1 failure lines
echo "Writing $((MAXRETRY + 1)) failures for $TEST_IP to $LOG"
for i in $(seq 1 $((MAXRETRY + 1))); do
  echo "$(date '+%Y-%m-%d %H:%M:%S') [AUTH_FAIL] Invalid credentials for user 'smoketest' source_ip=${TEST_IP}" \
    | sudo tee -a "$LOG" > /dev/null
  sleep 0.2
done

# 3. Wait for fail2ban to process
echo "Waiting 5 seconds for fail2ban to process..."
sleep 5

# 4. Check if ban fired
BANNED=$(sudo fail2ban-client get "$JAIL" banned 2>/dev/null)
if echo "$BANNED" | grep -q "$TEST_IP"; then
  echo "PASS: fail2ban banned $TEST_IP"
else
  echo "FAIL: fail2ban did NOT ban $TEST_IP after $((MAXRETRY + 1)) failures"
  exit 1
fi

# 5. Check firewalld ipset
IPSET="f2b-${JAIL}"
if sudo firewall-cmd --ipset="$IPSET" --get-entries 2>/dev/null | grep -q "$TEST_IP"; then
  echo "PASS: firewalld ipset contains $TEST_IP"
else
  echo "FAIL: firewalld ipset does NOT contain $TEST_IP"
  sudo fail2ban-client set "$JAIL" unbanip "$TEST_IP" 2>/dev/null
  exit 1
fi

# 6. Unban
sudo fail2ban-client set "$JAIL" unbanip "$TEST_IP" 2>/dev/null
sleep 2

# 7. Verify unban
if sudo fail2ban-client get "$JAIL" banned 2>/dev/null | grep -q "$TEST_IP"; then
  echo "FAIL: $TEST_IP still banned after unban command"
  exit 1
else
  echo "PASS: $TEST_IP successfully unbanned"
fi

echo "=== Smoke Test PASSED ==="
```

---

## 9. The Full Bash Healthcheck Script

This production-ready healthcheck script combines all checks from sections 2–8 into a single script that outputs a summary and exits with an appropriate code.

```bash
#!/bin/bash

[↑ Back to TOC](#table-of-contents)

# /usr/local/bin/fail2ban-healthcheck.sh
# Fail2ban healthcheck script for RHEL 10
# Exit codes: 0=OK, 1=WARNING, 2=CRITICAL

set -euo pipefail

# ============================================================
# Configuration
# ============================================================
REQUIRED_JAILS=("sshd")              # Jails that MUST be active
OPTIONAL_JAILS=("labapp" "recidive") # Jails to check if present
DB="/var/lib/fail2ban/fail2ban.sqlite3"
LOG_FILE="/var/log/fail2ban.log"
MAX_DB_SIZE_MB=100
MAX_LOG_AGE_SECONDS=7200             # 2 hours

# ============================================================
# State tracking
# ============================================================
WARNINGS=()
CRITICALS=()
OKS=()

warn()  { WARNINGS+=("$1"); }
crit()  { CRITICALS+=("$1"); }
ok()    { OKS+=("$1"); }

# ============================================================
# CHECK 1: fail2ban service
# ============================================================
if systemctl is-active --quiet fail2ban.service; then
  ok "fail2ban service is active"
else
  crit "fail2ban service is NOT active (systemctl is-active failed)"
fi

# ============================================================
# CHECK 2: fail2ban ping
# ============================================================
if fail2ban-client ping &>/dev/null; then
  ok "fail2ban server responds to ping"
else
  crit "fail2ban server does NOT respond to ping"
fi

# ============================================================
# CHECK 3: firewalld service
# ============================================================
if systemctl is-active --quiet firewalld.service; then
  ok "firewalld service is active"
else
  crit "firewalld service is NOT active"
fi

if firewall-cmd --state &>/dev/null; then
  ok "firewalld is in running state"
else
  crit "firewall-cmd --state did not return 'running'"
fi

# ============================================================
# CHECK 4: PID file
# ============================================================
PID_FILE="/run/fail2ban/fail2ban.pid"
if [[ -f "$PID_FILE" ]]; then
  PID=$(cat "$PID_FILE")
  if kill -0 "$PID" 2>/dev/null; then
    ok "fail2ban PID $PID is alive"
  else
    crit "Stale PID file: PID $PID is not running"
  fi
else
  warn "PID file not found at $PID_FILE"
fi

# ============================================================
# CHECK 5: Required jails active
# ============================================================
ACTIVE_JAILS=$(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*Jail list:\s*//')

for jail in "${REQUIRED_JAILS[@]}"; do
  if echo "$ACTIVE_JAILS" | grep -qw "$jail"; then
    ok "Required jail '$jail' is active"
  else
    crit "Required jail '$jail' is NOT active"
  fi
done

for jail in "${OPTIONAL_JAILS[@]}"; do
  if echo "$ACTIVE_JAILS" | grep -qw "$jail"; then
    ok "Optional jail '$jail' is active"
  else
    warn "Optional jail '$jail' is not active (may be intentional)"
  fi
done

# ============================================================
# CHECK 6: firewalld ipsets exist for active jails
# ============================================================
IPSETS=$(firewall-cmd --get-ipsets 2>/dev/null)
for jail in "${REQUIRED_JAILS[@]}"; do
  IPSET="f2b-${jail}"
  if echo "$IPSETS" | grep -qw "$IPSET"; then
    ENTRY_COUNT=$(firewall-cmd --ipset="$IPSET" --get-entries 2>/dev/null | wc -l)
    ok "ipset '$IPSET' exists ($ENTRY_COUNT entries)"
  else
    warn "ipset '$IPSET' does not exist (no active bans or firewalld was recently restarted)"
  fi
done

# ============================================================
# CHECK 7: Database integrity
# ============================================================
if [[ -f "$DB" ]]; then
  DB_RESULT=$(sqlite3 "$DB" "PRAGMA integrity_check;" 2>&1)
  if [[ "$DB_RESULT" == "ok" ]]; then
    DB_SIZE_MB=$(( $(stat -c %s "$DB") / 1048576 ))
    ok "Database integrity OK (${DB_SIZE_MB}MB)"
    if (( DB_SIZE_MB > MAX_DB_SIZE_MB )); then
      warn "Database size ${DB_SIZE_MB}MB exceeds ${MAX_DB_SIZE_MB}MB threshold — consider reducing dbpurgeage"
    fi
  else
    crit "Database integrity check FAILED: $DB_RESULT"
  fi
else
  warn "Database file not found at $DB (expected after first ban)"
fi

# ============================================================
# CHECK 8: Journal accessibility (for systemd-backend jails)
# ============================================================
if journalctl -u sshd.service -n 1 --no-pager &>/dev/null; then
  ok "systemd journal is accessible"
else
  crit "Cannot read systemd journal (journalctl failed)"
fi

# ============================================================
# CHECK 9: Fail2ban log recency (only if file logging is configured)
# ============================================================
if [[ -f "$LOG_FILE" ]]; then
  LAST_MTIME=$(stat -c %Y "$LOG_FILE" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  AGE=$(( NOW - LAST_MTIME ))
  if (( AGE > MAX_LOG_AGE_SECONDS )); then
    warn "fail2ban log not updated in ${AGE}s (threshold: ${MAX_LOG_AGE_SECONDS}s)"
  else
    ok "fail2ban log is recent (${AGE}s old)"
  fi
fi

# ============================================================
# CHECK 10: SELinux mode
# ============================================================
SELINUX_MODE=$(getenforce 2>/dev/null || echo "Unknown")
if [[ "$SELINUX_MODE" == "Enforcing" ]]; then
  ok "SELinux is Enforcing"
elif [[ "$SELINUX_MODE" == "Permissive" ]]; then
  warn "SELinux is in Permissive mode — bans may appear to work but policy is not enforced"
else
  warn "SELinux status: $SELINUX_MODE"
fi

# ============================================================
# CHECK 11: Recent SELinux denials for fail2ban
# ============================================================
AVC_COUNT=$(ausearch -m avc -ts recent --no-pager 2>/dev/null | grep -c "fail2ban" || echo 0)
if (( AVC_COUNT > 0 )); then
  warn "$AVC_COUNT recent SELinux AVC denial(s) related to fail2ban — run: sudo ausearch -m avc -ts recent | grep fail2ban"
else
  ok "No recent SELinux denials for fail2ban"
fi

# ============================================================
# Summary output
# ============================================================
echo "======================================"
echo " Fail2ban Healthcheck — $(date '+%Y-%m-%d %H:%M:%S')"
echo "======================================"

if (( ${#CRITICALS[@]} > 0 )); then
  echo ""
  echo "CRITICAL (${#CRITICALS[@]}):"
  for msg in "${CRITICALS[@]}"; do echo "  [CRIT] $msg"; done
fi

if (( ${#WARNINGS[@]} > 0 )); then
  echo ""
  echo "WARNINGS (${#WARNINGS[@]}):"
  for msg in "${WARNINGS[@]}"; do echo "  [WARN] $msg"; done
fi

if (( ${#OKS[@]} > 0 )); then
  echo ""
  echo "OK (${#OKS[@]}):"
  for msg in "${OKS[@]}"; do echo "  [OK]   $msg"; done
fi

echo ""
echo "======================================"

if (( ${#CRITICALS[@]} > 0 )); then
  echo "RESULT: CRITICAL"
  exit 2
elif (( ${#WARNINGS[@]} > 0 )); then
  echo "RESULT: WARNING"
  exit 1
else
  echo "RESULT: OK"
  exit 0
fi
```

### Deploy the script

```bash
sudo tee /usr/local/bin/fail2ban-healthcheck.sh > /dev/null << 'SCRIPT'
# (paste script content above)
SCRIPT
sudo chmod +x /usr/local/bin/fail2ban-healthcheck.sh
```

### Manual run

```bash
sudo /usr/local/bin/fail2ban-healthcheck.sh
```

---

## 10. Systemd Watchdog Integration

Systemd's watchdog feature allows fail2ban to notify systemd that it is alive. If fail2ban stops sending watchdog pings, systemd restarts it automatically.

### How watchdog works

1. Systemd starts fail2ban with `WatchdogSec=N` in the unit file
2. Fail2ban receives `WATCHDOG_USEC` environment variable
3. Fail2ban must call `sd_notify("WATCHDOG=1")` at least every `N` seconds
4. If the ping is missed, systemd considers fail2ban unhealthy and restarts it

> **Note:** Fail2ban's built-in watchdog support is limited. The more practical approach on RHEL 10 is to use `Restart=on-failure` (already configured in the default unit) combined with the external healthcheck timer approach in section 11.

### Configure systemd to auto-restart fail2ban on failure

```bash
sudo systemctl edit fail2ban.service
```

Add:

```ini
[Service]
Restart=on-failure
RestartSec=10s
StartLimitIntervalSec=120s
StartLimitBurst=5
```

```bash
sudo systemctl daemon-reload
sudo systemctl restart fail2ban.service
```

### Verify the restart policy

```bash
systemctl show fail2ban.service | grep -E "^Restart"
```

Expected:
```
Restart=on-failure
RestartSec=10s
```

### Simulate a crash and verify auto-restart

```bash

[↑ Back to TOC](#table-of-contents)

# Kill fail2ban forcefully
sudo kill -9 $(cat /run/fail2ban/fail2ban.pid 2>/dev/null)
sleep 15

# Verify it restarted
systemctl status fail2ban.service
sudo fail2ban-client ping
```

### Monitor restart count

```bash
systemctl show fail2ban.service | grep -E "NRestarts"
```

---

## 11. Scheduled Monitoring with Systemd Timers

Run the healthcheck script on a schedule using a systemd timer (preferred over cron on RHEL 10).

### Create the service unit

```bash
sudo tee /etc/systemd/system/fail2ban-healthcheck.service > /dev/null << 'EOF'
[Unit]
Description=Fail2ban Healthcheck
After=fail2ban.service firewalld.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fail2ban-healthcheck.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=fail2ban-healthcheck
EOF
```

### Create the timer unit

```bash
sudo tee /etc/systemd/system/fail2ban-healthcheck.timer > /dev/null << 'EOF'
[Unit]
Description=Run fail2ban healthcheck every 15 minutes
After=fail2ban.service

[Timer]

[↑ Back to TOC](#table-of-contents)

# Run 2 minutes after boot (allow services to start)
OnBootSec=2min
# Then every 15 minutes
OnUnitActiveSec=15min
# Ensure timer fires even if system was off at the scheduled time
Persistent=true

[Install]
WantedBy=timers.target
EOF
```

### Enable and start the timer

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now fail2ban-healthcheck.timer
```

### Verify the timer is scheduled

```bash
systemctl list-timers fail2ban-healthcheck.timer
```

Expected:
```
NEXT                        LEFT      LAST PASSED UNIT
Mon 2026-02-16 14:30:00 UTC 14min ago Mon 2026-02-16 14:15:00 UTC fail2ban-healthcheck.timer
```

### View healthcheck run results

```bash
# View output of last healthcheck run
sudo journalctl -u fail2ban-healthcheck.service -n 50 --no-pager

# Follow in real-time
sudo journalctl -u fail2ban-healthcheck.service -f

# Run manually
sudo systemctl start fail2ban-healthcheck.service
sudo journalctl -u fail2ban-healthcheck.service -n 30 --no-pager
```

---

## 12. Alerting Integrations

When the healthcheck detects a problem, you want to be notified. Here are three common integration patterns.

### Pattern A — Email via local MTA (Postfix)

Modify the healthcheck script to send email on failure:

```bash

[↑ Back to TOC](#table-of-contents)

# Add at the end of fail2ban-healthcheck.sh:

ALERT_EMAIL="admin@example.com"

if (( ${#CRITICALS[@]} > 0 )); then
  {
    echo "Subject: [CRITICAL] Fail2ban healthcheck failed on $(hostname)"
    echo "From: fail2ban-monitor@$(hostname)"
    echo "To: $ALERT_EMAIL"
    echo ""
    echo "Healthcheck run at $(date)"
    echo ""
    echo "CRITICAL issues:"
    for msg in "${CRITICALS[@]}"; do echo "  - $msg"; done
    echo ""
    echo "WARNINGS:"
    for msg in "${WARNINGS[@]}"; do echo "  - $msg"; done
  } | sendmail "$ALERT_EMAIL"
fi
```

Test:

```bash
echo "Test email from fail2ban monitor" | mail -s "Test" admin@example.com
```

### Pattern B — Webhook (Slack, Teams, PagerDuty)

```bash
# Webhook alert function — add to healthcheck script:

WEBHOOK_URL="https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX"

send_webhook_alert() {
  local message="$1"
  curl -s -X POST "$WEBHOOK_URL" \
    -H 'Content-type: application/json' \
    --data "{
      \"text\": \"*[CRITICAL] Fail2ban Alert on $(hostname)*\",
      \"attachments\": [{
        \"color\": \"danger\",
        \"text\": \"$message\",
        \"footer\": \"fail2ban-healthcheck | $(date)\"
      }]
    }" &>/dev/null
}

# Call at end of script if criticals exist:
if (( ${#CRITICALS[@]} > 0 )); then
  ALERT_MSG=$(printf '%s\n' "${CRITICALS[@]}" | head -5)
  send_webhook_alert "$ALERT_MSG"
fi
```

### Pattern C — systemd OnFailure directive

Configure the healthcheck service to trigger an alert unit when it exits with a non-zero code:

```bash
# Create an alert service
sudo tee /etc/systemd/system/fail2ban-healthcheck-alert.service > /dev/null << 'EOF'
[Unit]
Description=Send alert when fail2ban healthcheck fails

[Service]
Type=oneshot
ExecStart=/usr/local/bin/send-alert.sh "fail2ban healthcheck FAILED on %H"
EOF

# Modify the healthcheck service to call the alert on failure:
sudo systemctl edit fail2ban-healthcheck.service
```

Add:

```ini
[Unit]
OnFailure=fail2ban-healthcheck-alert.service
```

### Pattern D — Prometheus/Alertmanager (metrics export)

Create a script that writes metrics in Prometheus text format for scraping by the node exporter's textfile collector:

```bash
#!/bin/bash
# /usr/local/bin/fail2ban-metrics.sh
# Writes Prometheus metrics to /var/lib/node_exporter/textfile_collector/

OUTDIR="/var/lib/node_exporter/textfile_collector"
OUTFILE="$OUTDIR/fail2ban.prom"

[[ -d "$OUTDIR" ]] || exit 0

{
  echo "# HELP fail2ban_up fail2ban service is running"
  echo "# TYPE fail2ban_up gauge"
  if fail2ban-client ping &>/dev/null; then
    echo "fail2ban_up 1"
  else
    echo "fail2ban_up 0"
  fi

  echo "# HELP fail2ban_banned_total Current number of banned IPs per jail"
  echo "# TYPE fail2ban_banned_total gauge"
  fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*Jail list:\s*//' | tr ', ' '\n' | grep -v '^$' | while read jail; do
    count=$(fail2ban-client status "$jail" 2>/dev/null | grep "Currently banned" | awk '{print $NF}')
    echo "fail2ban_banned_total{jail=\"$jail\"} ${count:-0}"
  done
} > "$OUTFILE.tmp" && mv "$OUTFILE.tmp" "$OUTFILE"
```

---

## Lab 12 — Deploy the Healthcheck Script and Systemd Timer

### Objective

Deploy the full fail2ban healthcheck script, run it manually, and schedule it with a systemd timer. Verify it detects a simulated failure condition.

### Prerequisites

- Modules 09 and 10 labs completed (`labapp` jail working)
- Fail2ban and firewalld running

[↑ Back to TOC](#table-of-contents)

---

### Part A — Deploy the Healthcheck Script

**1. Create the script:**

```bash
sudo tee /usr/local/bin/fail2ban-healthcheck.sh > /dev/null << 'SCRIPT'
#!/bin/bash
set -euo pipefail

REQUIRED_JAILS=("sshd" "labapp")
DB="/var/lib/fail2ban/fail2ban.sqlite3"
WARNINGS=()
CRITICALS=()
OKS=()

warn() { WARNINGS+=("$1"); }
crit() { CRITICALS+=("$1"); }
ok()   { OKS+=("$1"); }

# Check fail2ban service
if systemctl is-active --quiet fail2ban.service; then
  ok "fail2ban service active"
else
  crit "fail2ban service NOT active"
fi

# Check fail2ban ping
if fail2ban-client ping &>/dev/null; then
  ok "fail2ban server responds to ping"
else
  crit "fail2ban server NOT responding to ping"
fi

# Check firewalld
if systemctl is-active --quiet firewalld.service; then
  ok "firewalld active"
else
  crit "firewalld NOT active"
fi

# Check required jails
ACTIVE_JAILS=$(fail2ban-client status 2>/dev/null | grep "Jail list" | sed 's/.*Jail list:\s*//')
for jail in "${REQUIRED_JAILS[@]}"; do
  if echo "$ACTIVE_JAILS" | grep -qw "$jail"; then
    ok "Jail '$jail' active"
  else
    crit "Jail '$jail' NOT active"
  fi
done

# Check database
if [[ -f "$DB" ]]; then
  if [[ "$(sqlite3 "$DB" "PRAGMA integrity_check;" 2>&1)" == "ok" ]]; then
    ok "Database integrity OK"
  else
    crit "Database integrity FAILED"
  fi
else
  warn "Database not found at $DB"
fi

# Check journal access
if journalctl -u sshd.service -n 1 --no-pager &>/dev/null; then
  ok "Journal accessible"
else
  crit "Journal NOT accessible"
fi

# Output
echo "=== Fail2ban Healthcheck $(date '+%Y-%m-%d %H:%M:%S') ==="
for msg in "${CRITICALS[@]}"; do echo "[CRIT] $msg"; done
for msg in "${WARNINGS[@]}"; do echo "[WARN] $msg"; done
for msg in "${OKS[@]}";      do echo "[OK]   $msg"; done

if (( ${#CRITICALS[@]} > 0 )); then echo "RESULT: CRITICAL"; exit 2;
elif (( ${#WARNINGS[@]} > 0 )); then echo "RESULT: WARNING"; exit 1;
else echo "RESULT: OK"; exit 0; fi
SCRIPT
sudo chmod +x /usr/local/bin/fail2ban-healthcheck.sh
```

**2. Run it manually:**

```bash
sudo /usr/local/bin/fail2ban-healthcheck.sh
```

Expected: `RESULT: OK` with all checks passing.

---

### Part B — Simulate a Failure Condition

**3. Stop fail2ban:**

```bash
sudo systemctl stop fail2ban.service
```

**4. Run the healthcheck:**

```bash
sudo /usr/local/bin/fail2ban-healthcheck.sh; echo "Exit code: $?"
```

Expected:
```
[CRIT] fail2ban service NOT active
[CRIT] fail2ban server NOT responding to ping
[CRIT] Jail 'sshd' NOT active
[CRIT] Jail 'labapp' NOT active
RESULT: CRITICAL
Exit code: 2
```

**5. Restart fail2ban:**

```bash
sudo systemctl start fail2ban.service
sudo /usr/local/bin/fail2ban-healthcheck.sh
```

Expected: `RESULT: OK`

---

### Part C — Deploy the Systemd Timer

**6. Create service and timer units:**

```bash
sudo tee /etc/systemd/system/fail2ban-healthcheck.service > /dev/null << 'EOF'
[Unit]
Description=Fail2ban Healthcheck
After=fail2ban.service firewalld.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fail2ban-healthcheck.sh
StandardOutput=journal
StandardError=journal
SyslogIdentifier=fail2ban-healthcheck
EOF

sudo tee /etc/systemd/system/fail2ban-healthcheck.timer > /dev/null << 'EOF'
[Unit]
Description=Fail2ban Healthcheck Timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF
```

**7. Enable and start the timer:**

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now fail2ban-healthcheck.timer
```

**8. Verify the timer:**

```bash
systemctl list-timers fail2ban-healthcheck.timer
```

**9. Trigger an immediate run:**

```bash
sudo systemctl start fail2ban-healthcheck.service
sudo journalctl -u fail2ban-healthcheck.service -n 30 --no-pager
```

---

### Lab Summary

| Step | What you did | What you verified |
|------|-------------|-------------------|
| A | Deployed healthcheck script | Script runs and reports OK |
| B | Simulated fail2ban failure | Script reported CRITICAL with exit code 2 |
| C | Deployed systemd timer | Timer scheduled and running |

### Lab Complete ✓

**Self-check — verify you can answer yes to each:**

- [ ] `sudo /usr/local/bin/fail2ban-healthcheck.sh` exits with code `0` and prints `RESULT: OK`
- [ ] Stopping fail2ban and re-running the script produces `RESULT: CRITICAL` and exit code `2`
- [ ] `systemctl list-timers` shows `fail2ban-healthcheck.timer` in the list
- [ ] `journalctl -u fail2ban-healthcheck.service -n 10` shows recent run output
- [ ] I know how to customise `REQUIRED_JAILS` at the top of the script for my environment
- [ ] The script is executable (`ls -l /usr/local/bin/fail2ban-healthcheck.sh` shows `-rwxr-xr-x`)

---

### Next Steps

Proceed to **[Module 13 — Troubleshooting](./13-troubleshooting.md)**
to learn systematic diagnosis of common fail2ban problems and recovery procedures.

---

| ← Previous | Home | Next → |
|-------------|------|---------|
| [11 — Systemd & Journald](./11-systemd-and-journald.md) | [Course README](./README.md) | [13 — Troubleshooting](./13-troubleshooting.md) |

---

*Licensed under [CC BY-NC-SA 4.0](LICENSE.md) · © 2026 UncleJS*