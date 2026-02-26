# Module 11 — Systemd and Journald

> **Level:** Advanced  
> **Prerequisites:** [Module 10 — Advanced Topics](./10-advanced-topics.md)  
> **Time to complete:** ~75 minutes

---

## Table of Contents

1. [Why Systemd and Journald Matter for Fail2ban](#1-why-systemd-and-journald-matter-for-fail2ban)
2. [How Journald Works on RHEL 10](#2-how-journald-works-on-rhel-10)
3. [The systemd Backend in Fail2ban](#3-the-systemd-backend-in-fail2ban)
4. [journalmatch — Filtering Journal Entries](#4-journalmatch--filtering-journal-entries)
5. [Finding the Right journalmatch Fields](#5-finding-the-right-journalmatch-fields)
6. [Shipped Filters with Systemd Support](#6-shipped-filters-with-systemd-support)
7. [Writing a systemd-Backend Filter](#7-writing-a-systemd-backend-filter)
8. [Journal Cursor and Where Fail2ban Picks Up](#8-journal-cursor-and-where-fail2ban-picks-up)
9. [Journal Persistence on RHEL 10](#9-journal-persistence-on-rhel-10)
10. [SELinux and Fail2ban on RHEL 10](#10-selinux-and-fail2ban-on-rhel-10)
11. [SELinux — Diagnosing Denials](#11-selinux--diagnosing-denials)
12. [SELinux — Creating a Policy Module](#12-selinux--creating-a-policy-module)
13. [Systemd Service Configuration for Fail2ban](#13-systemd-service-configuration-for-fail2ban)
14. [Lab 11 — Systemd Backend, journalmatch, and SELinux Audit](#lab-11--systemd-backend-journalmatch-and-selinux-audit)

---

## 1. Why Systemd and Journald Matter for Fail2ban

On traditional Linux distributions (Debian, older CentOS), services write authentication and error messages to flat log files like `/var/log/auth.log` or `/var/log/secure`. Fail2ban simply tails those files.

On RHEL 10 (and modern RHEL/Fedora/AlmaLinux/Rocky Linux), the default logging architecture has changed:

| Service | RHEL 10 log destination | Flat file? |
|---------|------------------------|-----------|
| sshd | systemd journal | No (by default) |
| Postfix | systemd journal | No (by default) |
| Dovecot | systemd journal | No (by default) |
| PAM | systemd journal | No (by default) |
| Apache httpd | `/var/log/httpd/` flat files | **Yes** |
| Nginx | `/var/log/nginx/` flat files | **Yes** |
| Custom apps | Depends on app | Varies |

This means fail2ban needs to read from the **systemd journal** for many core services. The `backend = systemd` setting enables this. Without it, fail2ban cannot detect SSH brute force attempts on a default RHEL 10 installation.

[↑ Back to TOC](#table-of-contents)

---

## 2. How Journald Works on RHEL 10

`systemd-journald` is a structured logging daemon. It collects:
- Standard output/error from every systemd unit
- Kernel messages (like `dmesg`)
- Messages sent via the syslog socket
- Messages sent via the journald native API

### Journal storage

```bash

[↑ Back to TOC](#table-of-contents)

# Journal files are stored here:
/run/log/journal/    ← volatile (RAM disk — cleared on reboot)
/var/log/journal/    ← persistent (requires configuration — see section 9)
```

### Viewing journal entries

```bash
# View all journal entries for the SSH daemon
sudo journalctl -u sshd.service

# View last 20 entries for SSH
sudo journalctl -u sshd.service -n 20 --no-pager

# Follow (like tail -f) for SSH
sudo journalctl -u sshd.service -f

# View raw structured output (JSON) for one entry
sudo journalctl -u sshd.service -n 1 -o json | python3 -m json.tool
```

### Journal entry fields

Each journal entry is structured with named fields:

```json
{
  "_SYSTEMD_UNIT": "sshd.service",
  "_COMM": "sshd",
  "SYSLOG_IDENTIFIER": "sshd",
  "_PID": "1234",
  "_UID": "0",
  "MESSAGE": "Failed password for invalid user admin from 203.0.113.45 port 12345 ssh2",
  "PRIORITY": "5",
  "__REALTIME_TIMESTAMP": "1739627721000000"
}
```

These field names are used in `journalmatch` to filter which entries fail2ban processes.

---

## 3. The systemd Backend in Fail2ban

Fail2ban supports multiple backends for reading logs:

| Backend | How it reads logs | Use when |
|---------|------------------|----------|
| `auto` | Uses pyinotify if available, else polling | Flat files (Apache, Nginx, custom apps) |
| `polling` | Polls log file periodically | Flat files on filesystems without inotify |
| `pyinotify` | Uses Linux inotify for file changes | Flat files on local filesystems |
| `systemd` | Reads from systemd journal via D-Bus | Services that log to journald |

### Setting backend per jail

```ini

[↑ Back to TOC](#table-of-contents)

# For SSH (journald on RHEL 10):
[sshd]
backend = systemd

# For Apache (flat file):
[apache-auth]
backend = auto
logpath = /var/log/httpd/*error_log
```

### Setting a global default

```ini
# /etc/fail2ban/jail.local

[DEFAULT]
# Do NOT set systemd as global default — it breaks flat-file jails.
# Set per-jail for services that use journald.
backend = auto
```

### What systemd backend does internally

When `backend = systemd` is set:
1. Fail2ban connects to `systemd-journald` via the journald Python bindings (`systemd.journal`)
2. It subscribes to the journal with the `journalmatch` criteria from the filter
3. Each matching entry's `MESSAGE` field is passed through the `failregex`
4. No `logpath` is needed or used

---

## 4. journalmatch — Filtering Journal Entries

`journalmatch` is a filter directive that pre-filters journal entries before the `failregex` is applied. It reduces CPU usage by only passing relevant entries to the regex engine.

### Where journalmatch is defined

```ini

[↑ Back to TOC](#table-of-contents)

# In the filter file:
# /etc/fail2ban/filter.d/sshd.conf

[Definition]
journalmatch = _SYSTEMD_UNIT=sshd.service + _COMM=sshd
```

### journalmatch syntax

| Operator | Meaning |
|----------|---------|
| `FIELD=value` | Entry must have this field with this exact value |
| `+` | AND — both conditions must match |
| (space between two conditions) | OR — either condition matches |

Examples:

```ini
# Only entries from the sshd unit:
journalmatch = _SYSTEMD_UNIT=sshd.service

# Entries from sshd unit AND sshd process:
journalmatch = _SYSTEMD_UNIT=sshd.service + _COMM=sshd

# Entries from either sshd unit OR sshd process name:
journalmatch = _SYSTEMD_UNIT=sshd.service
               _COMM=sshd

# Entries with specific syslog identifier:
journalmatch = SYSLOG_IDENTIFIER=sshd

# Match by UID (e.g., www-data UID=33):
journalmatch = _UID=33
```

### journalmatch is optional

If `journalmatch` is not set in the filter, and `backend = systemd`, fail2ban reads **all** journal entries and applies `failregex` to every `MESSAGE` field. This is very inefficient. Always set `journalmatch` for systemd-backend filters.

---

## 5. Finding the Right journalmatch Fields

To discover which journal fields are available for a service, examine a real journal entry.

### Method 1 — JSON output

```bash
sudo journalctl -u sshd.service -n 1 -o json | python3 -m json.tool
```

Output (abbreviated):

```json
{
  "__CURSOR": "s=...",
  "__REALTIME_TIMESTAMP": "1739627721000000",
  "_BOOT_ID": "abc123...",
  "_MACHINE_ID": "def456...",
  "_HOSTNAME": "server.example.com",
  "_UID": "0",
  "_GID": "0",
  "_COMM": "sshd",
  "_EXE": "/usr/sbin/sshd",
  "_CMDLINE": "sshd: [accepted]",
  "_SYSTEMD_UNIT": "sshd.service",
  "_SYSTEMD_SLICE": "system.slice",
  "PRIORITY": "6",
  "SYSLOG_FACILITY": "4",
  "SYSLOG_IDENTIFIER": "sshd",
  "SYSLOG_PID": "1234",
  "MESSAGE": "Failed password for admin from 203.0.113.45 port 12345 ssh2"
}
```

The most reliable fields to use for `journalmatch`:
- `_SYSTEMD_UNIT=sshd.service` — exact unit name
- `SYSLOG_IDENTIFIER=sshd` — syslog tag (may vary)
- `_COMM=sshd` — process binary name

### Method 2 — verbose output

```bash
sudo journalctl -u sshd.service -n 5 -o verbose --no-pager
```

### Method 3 — list unique values for a field

```bash

[↑ Back to TOC](#table-of-contents)

# See all unique _SYSTEMD_UNIT values for systemd services
sudo journalctl -F _SYSTEMD_UNIT | sort -u | grep -i ssh
```

### Method 4 — test a journalmatch directly

You can test a journalmatch with `journalctl` to verify it returns the expected entries:

```bash
# These are equivalent to journalmatch = _SYSTEMD_UNIT=sshd.service + _COMM=sshd
sudo journalctl _SYSTEMD_UNIT=sshd.service _COMM=sshd -n 10 --no-pager
```

---

## 6. Shipped Filters with Systemd Support

Many shipped fail2ban filters already include `journalmatch` entries for RHEL 10. Verify before assuming you need a custom filter.

### Check if a shipped filter has journalmatch

```bash
grep -l "journalmatch" /etc/fail2ban/filter.d/*.conf
```

### Key shipped filters for RHEL 10

| Filter | journalmatch |
|--------|-------------|
| `sshd.conf` | `_SYSTEMD_UNIT=sshd.service + _COMM=sshd` |
| `postfix.conf` | `_SYSTEMD_UNIT=postfix.service` |
| `dovecot.conf` | `_SYSTEMD_UNIT=dovecot.service` |
| `pam-generic.conf` | `_SYSTEMD_UNIT=*` (varies) |

### Verify sshd filter journalmatch

```bash
grep -A5 "journalmatch" /etc/fail2ban/filter.d/sshd.conf
```

Expected:
```ini
journalmatch = _SYSTEMD_UNIT=sshd.service + _COMM=sshd
```

If this line is present, the shipped filter handles RHEL 10 journald correctly. You do not need to modify it.

### Enabling sshd jail with systemd backend

```ini

[↑ Back to TOC](#table-of-contents)

# /etc/fail2ban/jail.d/sshd.conf

[sshd]
enabled  = true
backend  = systemd
# No logpath needed
maxretry = 5
bantime  = 1h
```

---

## 7. Writing a systemd-Backend Filter

When a shipped filter does not have `journalmatch` or does not exist for your service, write your own.

### Step 1 — Identify journal fields

```bash

[↑ Back to TOC](#table-of-contents)

# Find a failure entry in the journal
sudo journalctl -u myservice.service -n 20 --no-pager | grep -i "fail\|error\|deny\|invalid"

# Get the structured fields
sudo journalctl -u myservice.service -n 1 -o json | python3 -m json.tool | grep -E '"_SYSTEMD|"SYSLOG|"_COMM|"MESSAGE"'
```

### Step 2 — Write the filter

```ini
# /etc/fail2ban/filter.d/myservice.conf

[Definition]

# Tell fail2ban which journal entries to subscribe to
journalmatch = _SYSTEMD_UNIT=myservice.service

# Apply failregex to the MESSAGE field of matching entries
# (timestamp is handled automatically)
failregex = Authentication failure for \S+ from <HOST>

ignoreregex =
```

### Step 3 — Test against the journal

`fail2ban-regex` can test a systemd-backend filter against the journal:

```bash
sudo fail2ban-regex systemd-journal /etc/fail2ban/filter.d/myservice.conf
```

This reads from the live journal. For better testing, pipe journal output to a file first:

```bash
# Export journal entries to a file for testing
sudo journalctl -u myservice.service --since "1 hour ago" --no-pager \
  -o short > /tmp/myservice-journal.txt

# Test against the file
sudo fail2ban-regex /tmp/myservice-journal.txt /etc/fail2ban/filter.d/myservice.conf
```

### Step 4 — Write the jail

```ini
# /etc/fail2ban/jail.d/myservice.conf

[myservice]
enabled   = true
filter    = myservice
backend   = systemd    # ← required for journald
maxretry  = 5
findtime  = 10m
bantime   = 1h
port      = 8080
```

---

## 8. Journal Cursor and Where Fail2ban Picks Up

When fail2ban starts or reloads, it does not re-read the entire journal history. Instead, it uses a **cursor** — a position marker in the journal — to read only new entries.

### How the cursor is managed

- On first start: fail2ban starts from "now" — no historical entries are processed
- On reload: fail2ban resumes from the last cursor position it remembers
- The cursor position is stored in the SQLite database

### Implications

1. **Bans from before the last start are not re-evaluated** — they are restored from the SQLite database, not re-derived from logs
2. **If you want to process historical journal entries**, you must test with `fail2ban-regex` manually
3. **Log rotation** does not affect systemd-backend jails (journald manages rotation internally)

### Check the cursor stored in the database

```bash
sudo sqlite3 /var/lib/fail2ban/fail2ban.sqlite3 \
  "SELECT * FROM logs LIMIT 10;" ".mode column" ".headers on"
```

[↑ Back to TOC](#table-of-contents)

---

## 9. Journal Persistence on RHEL 10

By default, RHEL 10 stores journal data in `/run/log/journal/` which is a tmpfs (RAM disk). Journal entries are **lost on reboot**. This matters for fail2ban because historical log analysis is limited to the current boot.

### Check current journal storage mode

```bash
sudo journalctl --disk-usage
ls /var/log/journal/    # Exists = persistent; not exists = volatile
```

### Enable persistent journal storage

```bash
sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo systemctl restart systemd-journald
```

Or set it in `journald.conf`:

```bash
sudo tee /etc/systemd/journald.conf.d/persistent.conf > /dev/null << 'EOF'
[Journal]
Storage=persistent
EOF
sudo systemctl restart systemd-journald
```

### Verify persistence

```bash
ls /var/log/journal/

[↑ Back to TOC](#table-of-contents)

# Should show a machine-ID directory with .journal files
```

### Set journal retention limits (prevent disk fill)

```bash
sudo tee /etc/systemd/journald.conf.d/limits.conf > /dev/null << 'EOF'
[Journal]
Storage=persistent
SystemMaxUse=500M
SystemKeepFree=200M
MaxRetentionSec=30day
EOF
sudo systemctl restart systemd-journald
```

---

## 10. SELinux and Fail2ban on RHEL 10

SELinux is **enforcing by default** on RHEL 10. Fail2ban needs to:
1. Read the systemd journal
2. Execute `firewall-cmd` (a privileged command)
3. Write to its log file and SQLite database
4. Manage its PID file

The fail2ban package ships with an SELinux policy that allows all of these on a standard installation. However, custom configurations — custom log paths, custom action scripts — can trigger SELinux denials.

### Check current SELinux mode

```bash
getenforce

[↑ Back to TOC](#table-of-contents)

# Enforcing   ← default on RHEL 10 (recommended)
# Permissive  ← logs denials but does not enforce
# Disabled    ← SELinux completely off (not recommended)
```

### Check fail2ban's SELinux context

```bash
ps -eZ | grep fail2ban
```

Expected:
```
system_u:system_r:fail2ban_t:s0  1234  ?  fail2ban-server
```

The `fail2ban_t` domain means the fail2ban-specific SELinux policy is active.

### Verify fail2ban can call firewall-cmd

```bash
# Test: can fail2ban_t execute firewall-cmd?
sudo sesearch --allow -s fail2ban_t -t firewall_exec_t 2>/dev/null | head -5

# Or simply check the audit log for denials
sudo ausearch -m avc -ts recent | grep fail2ban
```

If `ausearch` returns no output, SELinux is not blocking fail2ban.

---

## 11. SELinux — Diagnosing Denials

When fail2ban fails to apply bans, SELinux denials are a common cause on RHEL 10. Here's how to diagnose them.

### Check the audit log

```bash

[↑ Back to TOC](#table-of-contents)

# Show all AVC (access vector cache) denials in the last hour
sudo ausearch -m avc -ts recent --no-pager

# Filter specifically for fail2ban denials
sudo ausearch -m avc -ts recent --no-pager | grep fail2ban
```

### Use audit2why for human-readable explanations

```bash
sudo ausearch -m avc -ts recent | audit2why
```

Sample output when fail2ban cannot execute firewall-cmd:

```
type=AVC msg=audit(1739627721.234:567): avc: denied { execute } for pid=1234
  comm="fail2ban-server" name="firewall-cmd" dev="sda1" ino=789012
  scontext=system_u:system_r:fail2ban_t:s0
  tcontext=system_u:object_r:bin_t:s0
  tclass=file permissive=0

Was caused by:
  Missing type enforcement (TE) allow rule.
  You can use audit2allow to generate a loadable module to allow this access.
```

### Check journald for SELinux messages

```bash
sudo journalctl -k | grep "avc:"
```

### Common fail2ban SELinux denial scenarios

| Scenario | Denial type |
|----------|------------|
| fail2ban cannot call `firewall-cmd` | `execute` denied on `firewall-cmd` |
| fail2ban cannot write to custom log path | `write` denied on custom log directory |
| fail2ban cannot read a custom log file | `read` denied on custom log type |
| Custom action script cannot run | `execute` denied on custom script |

---

## 12. SELinux — Creating a Policy Module

If you have custom paths or scripts that SELinux denies, create a targeted policy module to allow the specific access.

### Step 1 — Temporarily put SELinux in permissive mode (for testing only)

```bash

[↑ Back to TOC](#table-of-contents)

# Switch to permissive — logs denials but does not block
sudo setenforce 0
# Test your fail2ban configuration
# Then re-enable:
sudo setenforce 1
```

> **Warning:** Never leave SELinux in permissive mode in production. It is only for testing.

### Step 2 — Collect all denial messages

Reproduce the failure while SELinux is in permissive mode, then collect the audit logs:

```bash
sudo ausearch -m avc -ts recent > /tmp/fail2ban-denials.txt
```

### Step 3 — Generate a policy module

```bash
# Create a policy module from the denial messages
sudo audit2allow -i /tmp/fail2ban-denials.txt -M fail2ban-custom

# This creates two files:
# fail2ban-custom.te   ← human-readable policy
# fail2ban-custom.pp   ← compiled policy module
```

### Step 4 — Review the generated policy

```bash
cat fail2ban-custom.te
```

Verify the policy only allows what you intend. Do not blindly load policy modules that allow overly broad access.

### Step 5 — Load the policy module

```bash
sudo semodule -i fail2ban-custom.pp
```

### Step 6 — Verify it is loaded

```bash
sudo semodule -l | grep fail2ban
```

### Step 7 — Re-enable enforcing and test

```bash
sudo setenforce 1
sudo fail2ban-client reload
# Trigger a test failure and verify the ban fires
```

### Alternative — Relabel a custom log file

If your custom application log is in a non-standard path, relabel it with the correct context:

```bash
# Check current context
ls -Z /var/log/myapp/auth.log

# Set the correct context for log files
sudo semanage fcontext -a -t var_log_t "/var/log/myapp(/.*)?"
sudo restorecon -Rv /var/log/myapp/
```

---

## 13. Systemd Service Configuration for Fail2ban

Understanding how fail2ban is managed by systemd helps with startup ordering, watchdog integration, and service hardening.

### View the unit file

```bash
systemctl cat fail2ban.service
```

Expected (abbreviated):

```ini
[Unit]
Description=Fail2Ban Service
Documentation=man:fail2ban(1)
After=network.target iptables.service firewalld.service ip6tables.service ipset.service
PartOf=firewalld.service

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p /run/fail2ban
ExecStart=/usr/bin/fail2ban-server -xf start
ExecStop=/usr/bin/fail2ban-client stop
ExecReload=/usr/bin/fail2ban-client reload
PIDFile=/run/fail2ban/fail2ban.pid
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

### Key dependency: `After=firewalld.service`

This ensures fail2ban starts **after** firewalld. If firewalld is not running when fail2ban starts, the firewallcmd actions will fail.

### `PartOf=firewalld.service`

This means if firewalld is stopped, fail2ban is automatically stopped too. This is intentional — without firewalld, fail2ban cannot apply bans.

### Override unit settings (do not edit the file directly)

```bash

[↑ Back to TOC](#table-of-contents)

# Create a drop-in override
sudo systemctl edit fail2ban.service
```

This opens an editor. Add override stanzas:

```ini
[Service]
# Increase restart delay to avoid thrashing
RestartSec=10s

# Add watchdog support (see Module 12)
WatchdogSec=30s
```

### Reload systemd after changes

```bash
sudo systemctl daemon-reload
sudo systemctl restart fail2ban.service
```

### Check service status and startup time

```bash
systemctl status fail2ban.service
systemd-analyze blame | grep fail2ban
```

---

## Lab 11 — Systemd Backend, journalmatch, and SELinux Audit

### Objective

Explore how fail2ban reads from the systemd journal, verify the sshd jail is using the systemd backend correctly, and inspect for SELinux denials.

### Prerequisites

- Fail2ban installed and running
- SELinux in enforcing mode (`getenforce` returns `Enforcing`)

[↑ Back to TOC](#table-of-contents)

---

### Part A — Verify Journal Persistence

**1. Check current journal storage:**

```bash
journalctl --disk-usage
ls /var/log/journal/ 2>/dev/null && echo "Persistent" || echo "Volatile (tmpfs)"
```

**2. Enable persistent storage if volatile:**

```bash
sudo mkdir -p /var/log/journal
sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo systemctl restart systemd-journald
journalctl --disk-usage
```

---

### Part B — Inspect SSH Journal Entries

**3. View recent SSH journal entries:**

```bash
sudo journalctl -u sshd.service -n 20 --no-pager
```

**4. View structured (JSON) output of a single entry:**

```bash
sudo journalctl -u sshd.service -n 1 -o json | python3 -m json.tool
```

Note the `_SYSTEMD_UNIT`, `SYSLOG_IDENTIFIER`, `_COMM`, and `MESSAGE` fields.

**5. Test a journalmatch manually with journalctl:**

```bash
sudo journalctl _SYSTEMD_UNIT=sshd.service -n 10 --no-pager
```

This is exactly what fail2ban's `journalmatch = _SYSTEMD_UNIT=sshd.service` subscribes to.

---

### Part C — Verify the sshd Jail Uses systemd Backend

**6. Check the sshd jail configuration:**

```bash
sudo fail2ban-client get sshd logpath 2>/dev/null || echo "No logpath (uses journal)"
sudo fail2ban-client -d 2>&1 | grep -A30 "^\[sshd\]" | grep -E "backend|logpath|journal"
```

**7. View the sshd filter's journalmatch:**

```bash
grep -A5 "journalmatch" /etc/fail2ban/filter.d/sshd.conf
```

Expected:
```ini
journalmatch = _SYSTEMD_UNIT=sshd.service + _COMM=sshd
```

---

### Part D — Test fail2ban-regex Against Journal

**8. Export recent SSH journal entries to a test file:**

```bash
sudo journalctl -u sshd.service --since "1 hour ago" --no-pager \
  -o short > /tmp/sshd-journal-test.txt
wc -l /tmp/sshd-journal-test.txt
```

**9. Run fail2ban-regex against the export:**

```bash
sudo fail2ban-regex /tmp/sshd-journal-test.txt /etc/fail2ban/filter.d/sshd.conf
```

Note: Lines matched should correspond to failed login attempts.

**10. Run fail2ban-regex against live journal:**

```bash
sudo fail2ban-regex systemd-journal /etc/fail2ban/filter.d/sshd.conf
```

---

### Part E — SELinux Audit

**11. Check SELinux mode:**

```bash
getenforce
```

Expected: `Enforcing`

**12. Check fail2ban's SELinux domain:**

```bash
ps -eZ | grep fail2ban
```

Expected: `system_u:system_r:fail2ban_t:s0`

**13. Search for recent SELinux denials related to fail2ban:**

```bash
sudo ausearch -m avc -ts recent --no-pager 2>/dev/null | grep -i fail2ban || echo "No AVC denials for fail2ban"
```

Expected: `No AVC denials for fail2ban` — meaning the policy is working correctly.

**14. Check if fail2ban can call firewall-cmd (policy check):**

```bash
sudo sesearch --allow -s fail2ban_t -t firewalld_exec_t 2>/dev/null | head -5
# OR
sudo sesearch --allow -s fail2ban_t 2>/dev/null | grep "firewall" | head -10
```

**15. Check the audit log for any historical fail2ban issues:**

```bash
sudo ausearch -m avc --comm fail2ban-server --no-pager 2>/dev/null | tail -20 || echo "No denials found"
```

---

### Part F — Simulate an SSH Failure and Trace Through Journal

**16. Generate a test SSH failure (using a bad password):**

```bash
# Attempt SSH with wrong password — this will fail
ssh -o StrictHostKeyChecking=no -o PasswordAuthentication=yes \
    -p 22 baduser@127.0.0.1 2>/dev/null || true
```

> Note: This requires password authentication to be enabled for SSH. If only key auth is configured, use `fail2ban-client set sshd banip 198.51.100.1` to manually test.

**17. Check if the failure appeared in the journal:**

```bash
sudo journalctl -u sshd.service --since "1 minute ago" --no-pager | grep -i "fail\|invalid\|disconnect"
```

**18. Check if fail2ban detected the failure:**

```bash
sudo fail2ban-client status sshd
```

Look for `Currently failed` count to increment.

---

### Lab Summary

| Step | What you verified |
|------|------------------|
| A | Journal persistence status on your system |
| B | SSH log entries have the expected structure and fields |
| C | sshd jail uses systemd backend with correct journalmatch |
| D | fail2ban-regex works against journal export and live journal |
| E | No SELinux denials blocking fail2ban; correct SELinux domain |
| F | SSH failure flows from journal → fail2ban detection |

### Lab Complete ✓

**Self-check — verify you can answer yes to each:**

- [ ] `journalctl --disk-usage` shows journal data and I know whether persistence is enabled on my system
- [ ] `journalctl -u sshd --since "5 minutes ago"` shows SSH entries with `_HOSTNAME`, `SYSLOG_IDENTIFIER`, and `MESSAGE` fields
- [ ] `fail2ban-client get sshd backend` returns `systemd`
- [ ] `fail2ban-client get sshd journalmatch` returns a value (e.g. `_SYSTEMD_UNIT=sshd.service`)
- [ ] `fail2ban-regex` matched failures from a `journalctl` export or the live journal
- [ ] `getenforce` returns `Enforcing` and `ausearch` found no fail2ban AVC denials

---

### Next Steps

Proceed to **[Module 12 — Healthchecks and Monitoring](./12-healthchecks.md)**
to build a production healthcheck script, systemd timers, and Nagios-compatible monitoring.

---

| ← Previous | Home | Next → |
|-------------|------|---------|
| [10 — Advanced Topics](./10-advanced-topics.md) | [Course README](./README.md) | [12 — Healthchecks](./12-healthchecks.md) |
