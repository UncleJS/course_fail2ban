#!/bin/bash

# /usr/local/bin/fail2ban-healthcheck.sh
# Fail2ban healthcheck script for RHEL 10
# Exit codes: 0=OK, 1=WARNING, 2=CRITICAL
#
# INSTALL:
#   sudo cp fail2ban-healthcheck.sh /usr/local/bin/fail2ban-healthcheck.sh
#   sudo chmod +x /usr/local/bin/fail2ban-healthcheck.sh
#
# USAGE:
#   sudo /usr/local/bin/fail2ban-healthcheck.sh
#
# CRON EXAMPLE (run every 5 minutes, alert on non-zero exit):
#   */5 * * * * root /usr/local/bin/fail2ban-healthcheck.sh >> /var/log/fail2ban-health.log 2>&1
#
# NAGIOS/ICINGA COMPATIBLE: exits 0=OK, 1=WARNING, 2=CRITICAL
#
# Reference: Module 12 — Healthchecks and Monitoring (Section 9)

set -euo pipefail

# ============================================================
# Configuration — adjust these for your environment
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
