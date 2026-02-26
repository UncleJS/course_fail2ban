# Module 13 — Troubleshooting

> **Level:** Advanced  
> **Prerequisites:** [Module 11 — Systemd and Journald](./11-systemd-and-journald.md), [Module 12 — Healthchecks](./12-healthchecks.md)  
> **Time to complete:** ~90 minutes

---

## Table of Contents

1. [Troubleshooting Methodology](#1-troubleshooting-methodology)
2. [Fail2ban Will Not Start](#2-fail2ban-will-not-start)
3. [Fail2ban Starts But Crashes Immediately](#3-fail2ban-starts-but-crashes-immediately)
4. [A Jail Is Not Activating](#4-a-jail-is-not-activating)
5. [Bans Are Not Firing](#5-bans-are-not-firing)
6. [Regex Is Not Matching Log Lines](#6-regex-is-not-matching-log-lines)
7. [Firewalld Integration Failures](#7-firewalld-integration-failures)
8. [IPs Are Not Being Unbanned](#8-ips-are-not-being-unbanned)
9. [False Positives — Legitimate IPs Getting Banned](#9-false-positives--legitimate-ips-getting-banned)
10. [SELinux Denials Blocking Bans](#10-selinux-denials-blocking-bans)
11. [Performance and High CPU Usage](#11-performance-and-high-cpu-usage)
12. [Log Rotation Issues](#12-log-rotation-issues)
13. [Email Notification Failures](#13-email-notification-failures)
14. [Database and Persistence Issues](#14-database-and-persistence-issues)
15. [Recidive Jail Not Triggering](#15-recidive-jail-not-triggering)
16. [Diagnostic Command Cheat Sheet](#16-diagnostic-command-cheat-sheet)
17. [Lab 13 — Multi-Scenario Troubleshooting Lab](#lab-13--multi-scenario-troubleshooting-lab)

---

## 1. Troubleshooting Methodology

When fail2ban is not working as expected, work through the problem systematically rather than randomly changing settings.

### The Five-Layer Model

```
Layer 5: Expected outcome   ← "Why isn't IP 203.0.113.45 banned?"
             ↓
Layer 4: Action/firewalld   ← "Did the ban action execute?"
             ↓
Layer 3: Jail logic         ← "Did the failure counter reach maxretry?"
             ↓
Layer 2: Filter/regex       ← "Did the regex match the log line?"
             ↓
Layer 1: Log source         ← "Is fail2ban reading the right log?"
```

Start at **Layer 1** and work upward. Most problems are at layers 1 or 2.

### First three commands to run

```bash

[↑ Back to TOC](#table-of-contents)

# 1. Is fail2ban alive?
sudo fail2ban-client ping

# 2. What does fail2ban know about itself?
sudo fail2ban-client status

# 3. What errors has fail2ban logged?
sudo journalctl -u fail2ban.service -n 50 --no-pager | grep -E "ERROR|WARNING|CRITICAL"
```

### Enable debug logging temporarily

```bash
sudo fail2ban-client set loglevel DEBUG
# reproduce the problem
sudo journalctl -u fail2ban.service -n 100 --no-pager
# restore normal logging
sudo fail2ban-client set loglevel NOTICE
```

---

## 2. Fail2ban Will Not Start

### Symptom

```
$ sudo systemctl start fail2ban.service
Job for fail2ban.service failed. See 'journalctl -xe' for details.
```

### Diagnosis

```bash

[↑ Back to TOC](#table-of-contents)

# Step 1: Check systemd status
sudo systemctl status fail2ban.service

# Step 2: Check the journal for the startup error
sudo journalctl -u fail2ban.service -n 50 --no-pager

# Step 3: Try starting the server manually for verbose output
sudo fail2ban-server -xf start
```

### Common causes and fixes

#### Cause A — Config file syntax error

**Error message:**
```
fail2ban.config : ERROR  Failed to read the config
```

**Fix:**
```bash
# Validate config
sudo fail2ban-client --test

# Find the broken file
sudo fail2ban-client -d 2>&1 | head -50

# Common culprits:
# - Missing closing bracket in jail.local
# - Typo in option name
# - Wrong indentation in multiline failregex
```

#### Cause B — firewalld is not running

**Error message:**
```
fail2ban.action : ERROR  Failed to execute ban
```

**Fix:**
```bash
sudo systemctl start firewalld.service
sudo systemctl enable firewalld.service
sudo systemctl start fail2ban.service
```

#### Cause C — Database is locked or corrupted

**Error message:**
```
fail2ban.server : ERROR  database: /var/lib/fail2ban/fail2ban.sqlite3
                          OperationalError: database disk image is malformed
```

**Fix:**
```bash
# Backup the broken database
sudo mv /var/lib/fail2ban/fail2ban.sqlite3 /var/lib/fail2ban/fail2ban.sqlite3.broken

# Fail2ban will create a fresh database on next start
sudo systemctl start fail2ban.service
```

#### Cause D — PID file or socket from a crashed instance

**Error message:**
```
fail2ban.server : ERROR  Server already running
```

**Fix:**
```bash
sudo rm -f /run/fail2ban/fail2ban.pid
sudo rm -f /run/fail2ban/fail2ban.sock
sudo systemctl start fail2ban.service
```

#### Cause E — Missing Python dependency

**Error message:**
```
ModuleNotFoundError: No module named 'systemd'
```

**Fix:**
```bash
# Reinstall fail2ban and dependencies
sudo dnf reinstall fail2ban fail2ban-firewalld
```

---

## 3. Fail2ban Starts But Crashes Immediately

### Symptom

Fail2ban shows `active (running)` briefly, then shows `failed`:

```bash
systemctl status fail2ban.service

[↑ Back to TOC](#table-of-contents)

# ● fail2ban.service - Fail2Ban Service
#    Active: failed (Result: exit-code)
```

### Diagnosis

```bash
# Check for crash details
sudo journalctl -u fail2ban.service --since "5 minutes ago" --no-pager

# Look for Python tracebacks
sudo journalctl -u fail2ban.service --since "5 minutes ago" --no-pager | grep -A10 "Traceback"
```

### Common causes

#### Cause A — Action file references a command that does not exist

```bash
# Check which actions are configured
sudo grep -r "actionban\|actionunban" /etc/fail2ban/action.d/*.local 2>/dev/null
sudo grep -r "actionban\|actionunban" /etc/fail2ban/jail.d/*.conf 2>/dev/null

# Verify the command exists
which firewall-cmd
```

#### Cause B — Log file path does not exist

```bash
# Check for missing log paths in jail configs
sudo fail2ban-client -d 2>&1 | grep "logpath"

# Verify paths exist
sudo ls -la /var/log/httpd/ /var/log/nginx/ /var/log/myapp/ 2>/dev/null
```

**Fix:** Either create the log directory/file, or disable the jail that references it.

#### Cause C — Filter file has a regex error

```bash
# Test the filter directly
sudo fail2ban-regex /dev/null /etc/fail2ban/filter.d/myapp.conf
```

If this outputs a Python traceback with `re.error`, the regex is invalid.

---

## 4. A Jail Is Not Activating

### Symptom

```bash
sudo fail2ban-client status

[↑ Back to TOC](#table-of-contents)

# Jail list: sshd
# (expected jail 'myapp' is not listed)
```

### Diagnosis

```bash
# Step 1: Is it enabled?
grep -r "enabled" /etc/fail2ban/jail.d/myapp.conf

# Step 2: Does fail2ban see the jail?
sudo fail2ban-client -d 2>&1 | grep -A20 "\[myapp\]"

# Step 3: Check for errors during load
sudo journalctl -u fail2ban.service --since "2 minutes ago" --no-pager | grep -i "myapp\|error"
```

### Common causes and fixes

#### Cause A — `enabled = false` or missing

**Fix:**
```ini
# /etc/fail2ban/jail.d/myapp.conf
[myapp]
enabled = true
```

#### Cause B — Typo in jail name or filter name

```bash
# Verify filter file exists
ls /etc/fail2ban/filter.d/myapp.conf

# Check the jail references correct filter name
grep "filter" /etc/fail2ban/jail.d/myapp.conf
# filter = myapp   ← must match the filename without .conf
```

#### Cause C — Log file does not exist (flat-file jail)

```bash
grep "logpath" /etc/fail2ban/jail.d/myapp.conf
# If using a flat file, verify it exists:
sudo ls -la /var/log/myapp/auth.log
```

**Fix:** Create the log file or correct the path:
```bash
sudo mkdir -p /var/log/myapp
sudo touch /var/log/myapp/auth.log
sudo chmod 640 /var/log/myapp/auth.log
sudo fail2ban-client reload
```

#### Cause D — Backend mismatch

If the jail has `backend = systemd` but the filter has no `journalmatch`, or vice versa:

```bash
# Check backend setting
grep "backend" /etc/fail2ban/jail.d/myapp.conf

# Check filter has journalmatch if backend = systemd
grep "journalmatch" /etc/fail2ban/filter.d/myapp.conf
```

---

## 5. Bans Are Not Firing

### Symptom

The jail is active, failures are happening, but `Currently banned: 0` and `Total banned: 0` never change.

### Diagnosis

```bash

[↑ Back to TOC](#table-of-contents)

# Step 1: Is the failure counter incrementing?
sudo fail2ban-client status sshd
# Watch: Currently failed should go up

# Step 2: Check find time and maxretry
sudo fail2ban-client get sshd maxretry
sudo fail2ban-client get sshd findtime

# Step 3: Is the IP in ignoreip?
sudo fail2ban-client get sshd ignoreip

# Step 4: Watch ban events in real time
sudo journalctl -u fail2ban.service -f &
# Then trigger a failure
```

### Common causes and fixes

#### Cause A — `Currently failed` stays at 0 (filter not matching)

The regex is not matching the log lines. See **Section 6** for filter/regex debugging.

#### Cause B — `Currently failed` increments but never reaches `maxretry`

The failures happen slowly — spread over a period longer than `findtime`.

```bash
# Check current findtime
sudo fail2ban-client get sshd findtime
# Returns seconds — e.g., 600 = 10 minutes

# If attackers are slow-scanning (one attempt per hour), increase findtime:
# /etc/fail2ban/jail.d/sshd.conf
# findtime = 24h
```

#### Cause C — `maxretry` is too high

```bash
sudo fail2ban-client get sshd maxretry
# If set to 100, it takes 100 failures before a ban
# Lower it in jail config:
# maxretry = 5
```

#### Cause D — The attacker's IP is in `ignoreip`

```bash
sudo fail2ban-client get sshd ignoreip
# Check if the attacking IP or its network is listed
```

Remove the IP from `ignoreip` in `jail.local` and reload.

#### Cause E — Clock skew between log timestamp and system time

If the log timestamps are significantly different from the system clock, fail2ban may fail to parse them within `findtime`.

```bash
date
sudo tail -5 /var/log/myapp/auth.log  # Compare timestamps
timedatectl status  # Check NTP sync
```

**Fix:** Synchronize the clock:
```bash
sudo systemctl enable --now chronyd
sudo chronyc makestep
```

---

## 6. Regex Is Not Matching Log Lines

### Symptom

`fail2ban-regex` reports 0 matches, or `Currently failed` is always 0.

### Diagnosis workflow

```bash

[↑ Back to TOC](#table-of-contents)

# Step 1: Test the filter against the actual log
sudo fail2ban-regex /var/log/myapp/auth.log /etc/fail2ban/filter.d/myapp.conf

# Step 2: Look at which lines are "missed"
sudo fail2ban-regex --print-all-missed /var/log/myapp/auth.log /etc/fail2ban/filter.d/myapp.conf | head -20

# Step 3: Test a specific log line inline
sudo fail2ban-regex \
  '2026-02-15 14:22:01 [AUTH_FAIL] Invalid credentials for user '"'"'admin'"'"' from 203.0.113.1' \
  '\[AUTH_FAIL\] Invalid credentials for user .* from <HOST>'
```

### Common causes and fixes

#### Cause A — Timestamp not recognized

**Symptom:** `fail2ban-regex` prints `ERROR No 'host' group in...` or date parse errors.

```bash
# Run with -D flag to see timestamp parsing
sudo fail2ban-regex -D /var/log/myapp/auth.log /etc/fail2ban/filter.d/myapp.conf 2>&1 | head -30
```

**Fix:** Set a custom `datepattern` in the filter's `[Init]` section:

```ini
[Init]
# Match: 2026-02-15 14:22:01
datepattern = %%Y-%%m-%%d %%H:%%M:%%S

# Match: 15/Feb/2026:14:22:01 +0000 (Apache combined log)
datepattern = {^LN-BEG}%%d/%%b/%%Y:%%H:%%M:%%S %%z
```

#### Cause B — Special regex characters not escaped

```ini
# BAD — [ is a special char
failregex = [AUTH_FAIL] ...

# GOOD
failregex = \[AUTH_FAIL\] ...
```

#### Cause C — IPv6 address format unexpected

Some applications log IPv6 with or without brackets, or in short form. Test with actual IPv6 addresses if your network uses IPv6.

#### Cause D — Trailing whitespace or Windows line endings

```bash
# Check for Windows line endings (CRLF) in the log
file /var/log/myapp/auth.log
# "CRLF line terminators" = problem

# Strip CRLF
sudo sed -i 's/\r//' /var/log/myapp/auth.log
```

#### Cause E — Log line is multi-line

Fail2ban processes one line at a time. If the IP and the failure indicator are on separate lines, the standard approach will not work. Consider pre-processing with a log normalizer.

#### Cause F — `journalmatch` is too restrictive (systemd backend)

```bash
# Test the journalmatch manually
sudo journalctl _SYSTEMD_UNIT=myservice.service -n 10 --no-pager
# If no output, the unit name is wrong

# Find the correct unit name
sudo journalctl | grep -i "myservice" | tail -5
sudo systemctl list-units | grep -i "myservice"
```

---

## 7. Firewalld Integration Failures

### Symptom

Bans show in `fail2ban-client status` but the IP is not in the firewalld ipset. Or ban actions show errors in the log.

### Diagnosis

```bash

[↑ Back to TOC](#table-of-contents)

# Check for action errors in fail2ban log
sudo journalctl -u fail2ban.service --since "30 minutes ago" --no-pager | grep -i "error\|failed\|action"

# Check firewalld state
sudo firewall-cmd --state

# List all fail2ban ipsets
sudo firewall-cmd --get-ipsets | tr ' ' '\n' | grep f2b

# Check specific ipset entries
sudo firewall-cmd --ipset=f2b-sshd --get-entries
```

### Common causes and fixes

#### Cause A — firewalld is not running

```bash
sudo systemctl start firewalld.service
sudo fail2ban-client reload
```

#### Cause B — firewalld was restarted after fail2ban

When firewalld restarts, all runtime rules (including ipsets and their entries) are cleared. Fail2ban does not automatically re-apply bans in this scenario.

**Check:**
```bash
# When did firewalld last restart?
sudo journalctl -u firewalld.service --since "1 hour ago" --no-pager | grep "Started\|Stopped"

# When did fail2ban last restart?
sudo journalctl -u fail2ban.service --since "1 hour ago" --no-pager | grep "Started\|Stopped"
```

**Fix:** Restart fail2ban after firewalld restarts:

```bash
sudo systemctl restart fail2ban.service
```

For automatic recovery, configure fail2ban to restart when firewalld restarts:

```bash
sudo systemctl edit fail2ban.service
```

Add:

```ini
[Unit]
PartOf=firewalld.service
After=firewalld.service
```

```bash
sudo systemctl daemon-reload
```

#### Cause C — Wrong firewalld zone

By default, fail2ban applies bans to the `public` zone. If your service is in a different zone, the ban has no effect on that service.

```bash
# Check which zone your network interface is in
sudo firewall-cmd --get-active-zones

# Check which zone the service is in
sudo firewall-cmd --list-all --zone=public
sudo firewall-cmd --list-all --zone=trusted

# Override the zone in the action:
# banaction = firewallcmd-ipset[zone=internal]
```

#### Cause D — SELinux blocking firewall-cmd execution

See **Section 10** for SELinux-specific troubleshooting.

#### Cause E — ipset has reached maxelem

```bash
# Check ipset entry count
sudo firewall-cmd --ipset=f2b-sshd --get-entries | wc -l

# Default maxelem is 65536
# If near the limit, raise it:
# /etc/fail2ban/action.d/firewallcmd-ipset.local
# [Init]
# maxelem = 131072
```

---

## 8. IPs Are Not Being Unbanned

### Symptom

Banned IPs remain in the firewalld ipset after their `bantime` has expired. Or `fail2ban-client set jail unbanip IP` does not work.

### Diagnosis

```bash

[↑ Back to TOC](#table-of-contents)

# Check if IP is still shown as banned in fail2ban
sudo fail2ban-client status sshd | grep "Banned IP list"

# Check if IP is in the firewalld ipset
sudo firewall-cmd --ipset=f2b-sshd --get-entries | grep "203.0.113.45"

# Manual unban
sudo fail2ban-client set sshd unbanip 203.0.113.45
```

### Common causes and fixes

#### Cause A — bantime = -1 (permanent ban)

```bash
# Check if jail has permanent bantime
sudo fail2ban-client get sshd bantime
# If -1, bans are permanent by design

# To unban: must be done manually
sudo fail2ban-client set sshd unbanip 203.0.113.45
```

#### Cause B — IP is banned in multiple jails

If the IP is banned in both `sshd` and `recidive`, unbanning from one does not remove the other:

```bash
# Check all jails
for jail in $(sudo fail2ban-client status | grep "Jail list" | sed 's/.*Jail list:\s*//' | tr ', ' ' '); do
  if sudo fail2ban-client status "$jail" 2>/dev/null | grep -q "203.0.113.45"; then
    echo "Banned in jail: $jail"
    sudo fail2ban-client set "$jail" unbanip 203.0.113.45
  fi
done
```

#### Cause C — Unban action failed (firewall-cmd error)

```bash
# Check for unban errors in the log
sudo journalctl -u fail2ban.service --since "30 minutes ago" | grep -i "unban\|error"

# Manual firewalld removal
sudo firewall-cmd --ipset=f2b-sshd --remove-entry=203.0.113.45
```

#### Cause D — fail2ban restarted while IP was banned (database check)

After a restart, fail2ban re-reads the database and re-applies unexpired bans. If the database has a future unban time, the IP stays banned:

```bash
sudo sqlite3 /var/lib/fail2ban/fail2ban.sqlite3 \
  "SELECT jail, ip, datetime(timeofban + bantime, 'unixepoch', 'localtime') as unban_at
   FROM bans
   WHERE ip = '203.0.113.45'
   ORDER BY timeofban DESC LIMIT 5;"
```

---

## 9. False Positives — Legitimate IPs Getting Banned

### Symptom

A user, monitoring system, or internal server is getting banned.

### Immediate action — unban the IP

```bash

[↑ Back to TOC](#table-of-contents)

# Find which jail banned the IP
for jail in $(sudo fail2ban-client status | grep "Jail list" | sed 's/.*Jail list:\s*//' | tr ', ' ' '); do
  BANNED=$(sudo fail2ban-client status "$jail" 2>/dev/null | grep "Banned IP list")
  if echo "$BANNED" | grep -q "203.0.113.45"; then
    echo "Banned in: $jail"
    sudo fail2ban-client set "$jail" unbanip 203.0.113.45
  fi
done
```

### Long-term fix — add to ignoreip

```ini
# /etc/fail2ban/jail.local

[DEFAULT]
ignoreip = 127.0.0.1/8
           ::1
           10.0.0.0/8
           # Monitoring server — never ban:
           203.0.113.45
           # Load balancer range:
           198.51.100.0/24
```

```bash
sudo fail2ban-client reload
```

### Investigate why the IP was banned

```bash
# Check fail2ban log for the ban event
sudo journalctl -u fail2ban.service --since "1 hour ago" | grep "203.0.113.45"

# Check which log lines triggered the ban
# (requires loglevel INFO or higher, and matches logged when DEBUG)
```

### Prevent false positives from monitoring tools

Monitoring tools like Nagios, Zabbix, or Prometheus node exporters may trigger auth-related checks. Add their source IPs to `ignoreip`.

### Adjust maxretry and findtime

If legitimate users occasionally make 3-4 failed logins (forgotten password), increase `maxretry`:

```ini
[sshd]
maxretry = 10    # Give legitimate users more chances
findtime = 5m
```

---

## 10. SELinux Denials Blocking Bans

### Symptom

Fail2ban appears to work (jail status shows bans) but firewalld ipsets are empty. Or the fail2ban log shows action errors.

### Diagnosis

```bash

[↑ Back to TOC](#table-of-contents)

# Step 1: Check for AVC denials
sudo ausearch -m avc -ts recent --no-pager | grep "fail2ban\|firewall"

# Step 2: Get human-readable explanation
sudo ausearch -m avc -ts recent --no-pager | audit2why

# Step 3: Check SELinux mode
getenforce

# Step 4: Temporarily set permissive to test
sudo setenforce 0
# Try the failing action — if it now works, SELinux is the cause
sudo setenforce 1
```

### Generating and loading a policy fix

```bash
# 1. Collect denials (run in permissive mode to collect all needed permissions)
sudo setenforce 0
# Trigger the failing operation
sudo ausearch -m avc -ts recent > /tmp/fail2ban-avc.txt

# 2. Generate policy module
sudo audit2allow -i /tmp/fail2ban-avc.txt -M fail2ban-custom

# 3. Review what it allows
cat fail2ban-custom.te

# 4. Load the module
sudo semodule -i fail2ban-custom.pp

# 5. Re-enable enforcing
sudo setenforce 1

# 6. Test
sudo fail2ban-client reload
# Trigger a ban and verify it fires
```

### Relabeling custom log files

```bash
# If a custom log path has wrong SELinux context:
ls -Z /var/log/myapp/

# Apply the correct context:
sudo semanage fcontext -a -t var_log_t "/var/log/myapp(/.*)?"
sudo restorecon -Rv /var/log/myapp/

# Verify:
ls -Z /var/log/myapp/
```

---

## 11. Performance and High CPU Usage

### Symptom

`fail2ban-server` consumes high CPU, especially under heavy attack traffic.

### Diagnosis

```bash

[↑ Back to TOC](#table-of-contents)

# Check CPU usage
top -p $(pgrep fail2ban-server)
# Or
ps aux | grep fail2ban

# Check how many entries are in ipsets
sudo firewall-cmd --get-ipsets | tr ' ' '\n' | grep f2b | while read ipset; do
  echo "$ipset: $(sudo firewall-cmd --ipset="$ipset" --get-entries | wc -l) entries"
done
```

### Common causes and fixes

#### Cause A — Catastrophic backtracking in regex

A poorly written `failregex` with nested quantifiers causes exponential CPU usage.

**Diagnosis:**
```bash
# Profile the filter
time sudo fail2ban-regex /var/log/myapp/auth.log /etc/fail2ban/filter.d/myapp.conf
```

If this takes more than a few seconds on a 10,000-line log, the regex is too slow.

**Fix:** Rewrite the regex to avoid `.*` nested inside other quantifiers. See Module 09 Section 7.

#### Cause B — Too many log sources or very large log files

```bash
# Check log file sizes
sudo ls -lh /var/log/httpd/*.log /var/log/nginx/*.log 2>/dev/null

# Rotate large logs immediately
sudo logrotate -f /etc/logrotate.d/httpd
```

#### Cause C — Polling backend on a fast-writing log

If `backend = polling` is set for a high-volume log, fail2ban re-reads the entire file periodically. Switch to `auto` (which uses inotify) or `pyinotify`:

```ini
[myapp]
backend = auto
```

#### Cause D — Too many concurrent jails with systemd backend

Each systemd-backend jail opens a separate journal subscription. More than 10-15 systemd jails can cause performance issues. Consolidate where possible using multi-service filters.

#### Cause E — Large database with no purge

```bash
sudo du -h /var/lib/fail2ban/fail2ban.sqlite3

# Configure purge:
# /etc/fail2ban/fail2ban.local
# [Definition]
# dbpurgeage = 7d
```

---

## 12. Log Rotation Issues

### Symptom

After log rotation, fail2ban stops detecting failures. The `File list` in jail status shows the old rotated filename.

### How fail2ban handles log rotation

Fail2ban tracks log files by inode (filesystem ID), not filename. When a file is rotated (renamed), fail2ban detects the inode change and automatically switches to the new file — **if** using `backend = auto` or `pyinotify`.

With `backend = polling`, fail2ban may miss entries written between the rotation and the next poll.

### Diagnosis

```bash

[↑ Back to TOC](#table-of-contents)

# Check which file(s) fail2ban is watching
sudo fail2ban-client status myapp | grep "File list"

# Verify the file exists and is being written to
sudo tail -5 /var/log/myapp/auth.log
sudo ls -la /var/log/myapp/

# Check if fail2ban re-opened the log after rotation
sudo journalctl -u fail2ban.service --since "30 minutes ago" | grep -i "log\|file\|rotat"
```

### Fix — Ensure backend is set to auto

```ini
# /etc/fail2ban/jail.d/myapp.conf
[myapp]
backend = auto     # inotify-based — survives log rotation
```

### Fix — Correct logrotate configuration

The `logrotate` script for your application should signal fail2ban (or the application) to re-open its log file:

```bash
# /etc/logrotate.d/myapp
sudo tee /etc/logrotate.d/myapp > /dev/null << 'EOF'
/var/log/myapp/auth.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    create 0640 myapp myapp
    postrotate
        # Signal fail2ban to re-read logs (not strictly needed with inotify but safe)
        fail2ban-client reload 2>/dev/null || true
    endscript
}
EOF
```

### Fix for fail2ban's own log rotation

```bash
# /etc/logrotate.d/fail2ban
sudo tee /etc/logrotate.d/fail2ban > /dev/null << 'EOF'
/var/log/fail2ban.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    postrotate
        fail2ban-client flushlogs 1>/dev/null
    endscript
}
EOF
```

---

## 13. Email Notification Failures

### Symptom

Email actions are configured but emails are not arriving.

### Diagnosis

```bash

[↑ Back to TOC](#table-of-contents)

# Step 1: Test if MTA is working
echo "Test from $(hostname)" | mail -s "fail2ban test" admin@example.com

# Step 2: Check for action errors in fail2ban log
sudo journalctl -u fail2ban.service --since "30 minutes ago" | grep -i "mail\|sendmail\|smtp\|action"

# Step 3: Check Postfix mail queue
sudo postqueue -p   # Or: mailq
sudo journalctl -u postfix.service -n 20 --no-pager
```

### Common causes and fixes

#### Cause A — Postfix is not installed or running

```bash
sudo dnf install postfix -y
sudo systemctl enable --now postfix.service
```

#### Cause B — `sendmail` command not found

Fail2ban's email actions use `sendmail` (or `mail`). Verify:

```bash
which sendmail || which mail
# If not found:
sudo dnf install mailx -y
```

#### Cause C — Incorrect `destemail` or `sender` configuration

```ini
# /etc/fail2ban/jail.local

[DEFAULT]
destemail = admin@example.com
sender    = fail2ban@yourhostname.example.com
mta       = sendmail    # or 'mail'
```

#### Cause D — Firewall blocking outbound port 25

```bash
# Test SMTP connectivity
nc -zv smtp.example.com 25
# Or test via firewall
sudo firewall-cmd --list-all | grep "25\|smtp"
```

---

## 14. Database and Persistence Issues

### Symptom

After fail2ban restarts, previously banned IPs are not re-banned. Or fail2ban reports database errors.

### Diagnosis

```bash

[↑ Back to TOC](#table-of-contents)

# Check database file
sudo ls -la /var/lib/fail2ban/fail2ban.sqlite3

# Check database integrity
sudo sqlite3 /var/lib/fail2ban/fail2ban.sqlite3 "PRAGMA integrity_check;"

# Check fail2ban is configured to use the database
sudo grep -E "^dbfile|^dbpurgeage" /etc/fail2ban/fail2ban.local 2>/dev/null
sudo grep -E "^dbfile" /etc/fail2ban/fail2ban.conf
```

### Common causes and fixes

#### Cause A — Database disabled in config

```bash
sudo grep "dbfile" /etc/fail2ban/fail2ban.conf /etc/fail2ban/fail2ban.local 2>/dev/null
```

If `dbfile =` (empty) or `dbfile = :memory:`, persistence is disabled. Fix:

```ini
# /etc/fail2ban/fail2ban.local
[Definition]
dbfile = /var/lib/fail2ban/fail2ban.sqlite3
```

#### Cause B — Database corrupted

```bash
# Check integrity
sudo sqlite3 /var/lib/fail2ban/fail2ban.sqlite3 "PRAGMA integrity_check;"

# If not "ok", replace the database
sudo systemctl stop fail2ban.service
sudo mv /var/lib/fail2ban/fail2ban.sqlite3 /var/lib/fail2ban/fail2ban.sqlite3.corrupted
sudo systemctl start fail2ban.service
```

> **Note:** After replacing the database, previously banned IPs will not be re-applied on restart. Re-apply important permanent bans manually.

#### Cause C — Disk full

```bash
df -h /var/lib/fail2ban/
```

If disk is full, bans cannot be written to the database. Free disk space.

#### Cause D — Permission issues

```bash
sudo ls -la /var/lib/fail2ban/
# fail2ban.sqlite3 should be owned by root or fail2ban user

# Fix permissions:
sudo chown root:root /var/lib/fail2ban/fail2ban.sqlite3
sudo chmod 600 /var/lib/fail2ban/fail2ban.sqlite3
```

---

## 15. Recidive Jail Not Triggering

### Symptom

An IP is being banned repeatedly but the recidive jail never fires a long-term ban.

### Diagnosis

```bash

[↑ Back to TOC](#table-of-contents)

# Check recidive jail is active
sudo fail2ban-client status recidive

# Check recidive configuration
sudo fail2ban-client get recidive maxretry
sudo fail2ban-client get recidive findtime

# Check the logpath
sudo fail2ban-client get recidive logpath 2>/dev/null || echo "Using systemd backend"

# Check if fail2ban is logging ban events to the file recidive is watching
sudo grep "Ban" /var/log/fail2ban.log | tail -10
```

### Common causes and fixes

#### Cause A — fail2ban is not logging to a flat file

The recidive filter needs to read fail2ban's ban log lines. If fail2ban logs to journal only, the recidive filter (which looks at a flat file by default) sees nothing.

**Fix:** Configure fail2ban to write to a flat file AND configure recidive to read it:

```ini
# /etc/fail2ban/fail2ban.local
[Definition]
logtarget = /var/log/fail2ban.log
loglevel  = NOTICE
```

```bash
sudo touch /var/log/fail2ban.log
sudo chmod 640 /var/log/fail2ban.log
sudo systemctl restart fail2ban
```

#### Cause B — recidive findtime is too short

If an IP is banned, waits for the ban to expire, then attacks again, the bans may be spaced further apart than `findtime`:

```ini
[recidive]
findtime = 1w    # Look back one week for repeat bans
maxretry = 2
bantime  = 30d
```

#### Cause C — The banned IP is in recidive's ignoreip

```bash
sudo fail2ban-client get recidive ignoreip
```

#### Cause D — recidive filter regex does not match your log format

```bash
# Test recidive filter against the fail2ban log
sudo fail2ban-regex /var/log/fail2ban.log /etc/fail2ban/filter.d/recidive.conf

# Check how fail2ban formats ban lines in your version:
sudo grep "Ban" /var/log/fail2ban.log | head -3

# Expected format the recidive filter looks for:
# fail2ban.actions[...]: NOTICE  [sshd] Ban 203.0.113.45
```

If the log format differs, update the recidive filter's `failregex` in `/etc/fail2ban/filter.d/recidive.local`.

---

## 16. Diagnostic Command Cheat Sheet

### Service status

```bash

[↑ Back to TOC](#table-of-contents)

# Is fail2ban running?
sudo fail2ban-client ping

# Full service status
sudo systemctl status fail2ban.service

# Is firewalld running?
sudo firewall-cmd --state
```

### Jail inspection

```bash
# List all active jails
sudo fail2ban-client status

# Status of a specific jail
sudo fail2ban-client status sshd

# Get a jail parameter
sudo fail2ban-client get sshd maxretry
sudo fail2ban-client get sshd findtime
sudo fail2ban-client get sshd bantime
sudo fail2ban-client get sshd ignoreip

# List currently banned IPs
sudo fail2ban-client get sshd banned
```

### Manual ban / unban

```bash
# Manually ban an IP
sudo fail2ban-client set sshd banip 198.51.100.1

# Manually unban an IP
sudo fail2ban-client set sshd unbanip 198.51.100.1

# Unban from ALL jails (loop)
IP="198.51.100.1"
for jail in $(sudo fail2ban-client status | grep "Jail list" | sed 's/.*Jail list:\s*//' | tr ', ' ' '); do
  sudo fail2ban-client set "$jail" unbanip "$IP" 2>/dev/null
done
```

### Filter testing

```bash
# Test filter against a log file
sudo fail2ban-regex /var/log/myapp/auth.log /etc/fail2ban/filter.d/myapp.conf

# Test with verbose output (show matched lines)
sudo fail2ban-regex --print-all-matched /var/log/myapp/auth.log /etc/fail2ban/filter.d/myapp.conf

# Show missed lines (to understand what did NOT match)
sudo fail2ban-regex --print-all-missed /var/log/myapp/auth.log /etc/fail2ban/filter.d/myapp.conf

# Test against live systemd journal
sudo fail2ban-regex systemd-journal /etc/fail2ban/filter.d/sshd.conf

# Test inline regex against a single line
sudo fail2ban-regex 'LOGLINE' 'REGEX'
```

### Firewalld inspection

```bash
# List all fail2ban ipsets
sudo firewall-cmd --get-ipsets | tr ' ' '\n' | grep f2b

# Show entries in an ipset
sudo firewall-cmd --ipset=f2b-sshd --get-entries

# Count entries in an ipset
sudo firewall-cmd --ipset=f2b-sshd --get-entries | wc -l

# List rich rules (allports bans)
sudo firewall-cmd --list-rich-rules

# View nftables (underlying firewalld rules)
sudo nft list ruleset | grep -A5 "f2b"
```

### Logs and events

```bash
# Recent fail2ban log (journal)
sudo journalctl -u fail2ban.service -n 100 --no-pager

# Follow fail2ban log in real time
sudo journalctl -u fail2ban.service -f

# Filter for errors only
sudo journalctl -u fail2ban.service -n 100 --no-pager | grep -E "ERROR|WARNING|CRITICAL"

# Search for a specific IP in the log
sudo journalctl -u fail2ban.service | grep "203.0.113.45"

# Increase log verbosity temporarily
sudo fail2ban-client set loglevel DEBUG
sudo fail2ban-client set loglevel NOTICE  # reset
```

### Database queries

```bash
# View recent bans
sudo sqlite3 /var/lib/fail2ban/fail2ban.sqlite3 \
  "SELECT jail, ip, bancount, datetime(timeofban,'unixepoch','localtime') FROM bans ORDER BY timeofban DESC LIMIT 20;"

# Count bans per jail
sudo sqlite3 /var/lib/fail2ban/fail2ban.sqlite3 \
  "SELECT jail, COUNT(*) FROM bans GROUP BY jail;"

# Find repeat offenders
sudo sqlite3 /var/lib/fail2ban/fail2ban.sqlite3 \
  "SELECT ip, SUM(bancount) as total FROM bans GROUP BY ip HAVING total > 1 ORDER BY total DESC LIMIT 10;"

# Database integrity
sudo sqlite3 /var/lib/fail2ban/fail2ban.sqlite3 "PRAGMA integrity_check;"
```

### Config validation

```bash
# Validate all config (dry run)
sudo fail2ban-client --test

# Dump effective config (shows what fail2ban actually loaded)
sudo fail2ban-client -d 2>&1 | less

# Reload config
sudo fail2ban-client reload

# Reload a single jail
sudo fail2ban-client reload sshd
```

### SELinux diagnostics

```bash
# Check SELinux mode
getenforce

# Recent AVC denials for fail2ban
sudo ausearch -m avc -ts recent --no-pager | grep fail2ban

# Human-readable AVC explanations
sudo ausearch -m avc -ts recent | audit2why

# fail2ban's SELinux domain
ps -eZ | grep fail2ban
```

---

## Lab 13 — Multi-Scenario Troubleshooting Lab

### Objective

Practice diagnosing and fixing four deliberately broken fail2ban configurations. Each scenario introduces a specific failure that you must identify and fix using the methodology from this module.

### Prerequisites

- Fail2ban installed and running
- `labapp` jail from Module 09 lab is working
- Access to modify config files with `sudo`

[↑ Back to TOC](#table-of-contents)

---

### Scenario 1 — Jail Not Activating

**Setup (break it):**

```bash
# Introduce a syntax error in the jail config
sudo tee /etc/fail2ban/jail.d/scenario1.conf > /dev/null << 'EOF'
[scenario1-jail
enabled = true
filter  = labapp
logpath = /var/log/labapp/auth.log
maxretry = 5
EOF

sudo fail2ban-client reload 2>&1
```

**Your task:** Why is `scenario1-jail` not appearing in `fail2ban-client status`? Diagnose and fix it.

**Hint:** Check `sudo journalctl -u fail2ban.service -n 20 --no-pager` for config errors.

**Fix:**

```bash
# The section header is missing the closing bracket
sudo tee /etc/fail2ban/jail.d/scenario1.conf > /dev/null << 'EOF'
[scenario1-jail]
enabled  = true
filter   = labapp
logpath  = /var/log/labapp/auth.log
maxretry = 5
bantime  = 10m
EOF

sudo fail2ban-client reload
sudo fail2ban-client status | grep scenario1
```

**Expected:** `scenario1-jail` appears in the jail list.

**Cleanup:**
```bash
sudo rm /etc/fail2ban/jail.d/scenario1.conf
sudo fail2ban-client reload
```

---

### Scenario 2 — Filter Regex Not Matching

**Setup (break it):**

```bash
# Create a filter with a regex that will NOT match the labapp log format
sudo tee /etc/fail2ban/filter.d/scenario2.conf > /dev/null << 'EOF'
[Definition]
# This regex looks for the wrong string
failregex = \[LOGIN_FAILURE\] Bad credentials from <HOST>

ignoreregex =
EOF

sudo tee /etc/fail2ban/jail.d/scenario2.conf > /dev/null << 'EOF'
[scenario2-jail]
enabled  = true
filter   = scenario2
logpath  = /var/log/labapp/auth.log
backend  = auto
maxretry = 5
bantime  = 10m
EOF

sudo fail2ban-client reload
```

**Your task:** Generate 10 failures and verify no bans fire for `scenario2-jail`. Then diagnose why the regex fails and fix it.

```bash
# Generate failures
sudo labapp-fail.sh 192.0.2.200 10
sleep 5
sudo fail2ban-client status scenario2-jail
```

Expected: `Currently failed: 0` — regex does not match.

**Diagnosis:**
```bash
sudo fail2ban-regex /var/log/labapp/auth.log /etc/fail2ban/filter.d/scenario2.conf
```

Expected: `0 matched` — tells you the regex is wrong.

```bash
# Look at actual log lines
sudo tail -5 /var/log/labapp/auth.log
```

**Fix:**

```bash
sudo tee /etc/fail2ban/filter.d/scenario2.conf > /dev/null << 'EOF'
[Definition]
# Fixed regex matches actual log format
failregex = \[AUTH_FAIL\] Invalid credentials for user '\S+' source_ip=<HOST>

ignoreregex =
EOF

sudo fail2ban-client reload
# Test again
sudo fail2ban-regex /var/log/labapp/auth.log /etc/fail2ban/filter.d/scenario2.conf
```

Expected: matches found.

**Cleanup:**
```bash
sudo rm /etc/fail2ban/filter.d/scenario2.conf
sudo rm /etc/fail2ban/jail.d/scenario2.conf
sudo fail2ban-client reload
```

---

### Scenario 3 — firewalld ipset Missing After Restart

**Setup (simulate firewalld restart):**

```bash
# First, create a real ban
sudo truncate -s 0 /var/log/labapp/auth.log
sudo labapp-fail.sh 192.0.2.201 6
sleep 5
echo "Before firewalld restart:"
sudo fail2ban-client status labapp | grep "Banned IP"
sudo firewall-cmd --ipset=f2b-labapp --get-entries 2>/dev/null || echo "ipset does not exist yet"

# Now restart firewalld (this clears runtime rules)
sudo systemctl restart firewalld.service
sleep 2

echo "After firewalld restart (before fail2ban restart):"
sudo firewall-cmd --ipset=f2b-labapp --get-entries 2>/dev/null || echo "ipset gone — rules cleared"
```

**Your task:** Diagnose why `192.0.2.201` is still shown as banned in fail2ban but NOT present in the firewalld ipset. Fix it.

**Hint:** When firewalld restarts, it clears all runtime rules. The fix is to restart fail2ban so it re-applies bans from its database.

**Fix:**
```bash
sudo systemctl restart fail2ban.service
sleep 3

echo "After fail2ban restart:"
sudo firewall-cmd --ipset=f2b-labapp --get-entries 2>/dev/null
sudo fail2ban-client status labapp | grep "Banned IP"
```

Expected: `192.0.2.201` appears in both places again.

**Cleanup:**
```bash
sudo fail2ban-client set labapp unbanip 192.0.2.201 2>/dev/null
sudo truncate -s 0 /var/log/labapp/auth.log
```

---

### Scenario 4 — IP Locked Out Due to False Positive

**Setup:**

```bash
# Simulate a monitoring server that hits the log repeatedly
sudo labapp-fail.sh 10.20.30.40 10
sleep 5
sudo fail2ban-client status labapp | grep "Banned IP"
```

The IP `10.20.30.40` is now banned. This is a monitoring server that should never be banned.

**Your task:**
1. Unban `10.20.30.40` immediately
2. Add it to `ignoreip` so it is never banned again
3. Verify the fix

**Fix:**

```bash
# Step 1: Immediate unban
sudo fail2ban-client set labapp unbanip 10.20.30.40

# Step 2: Add to ignoreip
sudo tee /etc/fail2ban/jail.d/labapp.conf > /dev/null << 'EOF'
[labapp]
enabled             = true
filter              = labapp
logpath             = /var/log/labapp/auth.log
backend             = auto
maxretry            = 5
findtime            = 5m
bantime             = 10m
bantime.increment   = true
bantime.factor      = 2
bantime.maxtime     = 30m
port                = http,https
ignoreip            = 127.0.0.1/8 ::1 10.0.0.0/8
EOF

sudo fail2ban-client reload

# Step 3: Verify ignoreip is applied
sudo fail2ban-client get labapp ignoreip

# Step 4: Simulate monitoring server activity — should NOT be banned
sudo truncate -s 0 /var/log/labapp/auth.log
sudo labapp-fail.sh 10.20.30.40 10
sleep 5
sudo fail2ban-client status labapp | grep "Banned IP"
```

Expected: `Banned IP list:` is empty — `10.20.30.40` is ignored.

---

### Lab Summary

| Scenario | Problem | Technique used |
|----------|---------|---------------|
| 1 | Jail not activating — config syntax error | `journalctl`, config file inspection |
| 2 | Bans not firing — regex mismatch | `fail2ban-regex --print-all-missed` |
| 3 | Bans exist in fail2ban but not firewalld | Understanding firewalld restart behavior |
| 4 | False positive — legitimate IP banned | `unbanip`, `ignoreip` configuration |

**You have completed the full fail2ban troubleshooting module.**

### Lab Complete ✓

**Self-check — verify you can answer yes to each:**

- [ ] I can diagnose a jail-not-active problem using `journalctl -u fail2ban` and `fail2ban-client -t`
- [ ] I know how to use `fail2ban-regex --print-all-missed` to debug a filter that matches nothing
- [ ] I understand why bans disappear from firewalld after `firewall-cmd --reload` and how to recover them
- [ ] I successfully unbanned a false-positive IP with `fail2ban-client set <jail> unbanip <IP>`
- [ ] I added a permanent `ignoreip` entry to prevent future false positives for that IP
- [ ] I can locate and interpret `fail2ban.actions` log lines to trace the full ban lifecycle

---

*You have completed all 13 modules of the Fail2ban on RHEL 10 course.*

---

| ← Previous | Home |
|-------------|------|
| [12 — Healthchecks](./12-healthchecks.md) | [Course README](./README.md) |
