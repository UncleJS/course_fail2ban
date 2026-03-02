# Module 10 — Advanced Topics
[![CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey)](./LICENSE.md)
[![RHEL 10](https://img.shields.io/badge/platform-RHEL%2010-red)](https://access.redhat.com/products/red-hat-enterprise-linux)
[![fail2ban](https://img.shields.io/badge/fail2ban-RHEL%2010-red)](https://access.redhat.com/products/red-hat-enterprise-linux)

> **Level:** Advanced  
> **Prerequisites:** [Module 09 — Custom Jails and Filters](./09-custom-jails-and-filters.md)  
> **Time to complete:** ~90 minutes

---

## Table of Contents

1. [Overview of Advanced Features](#1-overview-of-advanced-features)
2. [The Recidive Jail — Banning Repeat Offenders](#2-the-recidive-jail--banning-repeat-offenders)
3. [Incremental Ban Time (bantime.increment)](#3-incremental-ban-time-bantimeincrement)
4. [Permanent Bans](#4-permanent-bans)
5. [Fine-Tuning ignoreip](#5-fine-tuning-ignoreip)
6. [Multi-Port Jails](#6-multi-port-jails)
7. [firewallcmd-allports — Blocking All Ports](#7-firewallcmd-allports--blocking-all-ports)
8. [The Fail2ban Database — SQLite Persistence](#8-the-fail2ban-database--sqlite-persistence)
9. [Aggregated and Centralized Logging](#9-aggregated-and-centralized-logging)
10. [ipset Performance Tuning](#10-ipset-performance-tuning)
11. [Rate-Limiting with Multiple Jails per Service](#11-rate-limiting-with-multiple-jails-per-service)
12. [Whitelisting and Trusted Networks](#12-whitelisting-and-trusted-networks)
13. [Adjusting Fail2ban Log Level and Log Target](#13-adjusting-fail2ban-log-level-and-log-target)
14. [Managing Fail2ban in a Cluster or Load-Balanced Environment](#14-managing-fail2ban-in-a-cluster-or-load-balanced-environment)
15. [Lab 10 — Recidive Jail and Incremental Bans](#lab-10--recidive-jail-and-incremental-bans)

---

## 1. Overview of Advanced Features

The core concepts (jails, filters, actions, firewalld) covered in earlier modules handle the majority of production use cases. The advanced features in this module let you:

| Feature | What problem it solves |
|---------|----------------------|
| **Recidive jail** | Escalates punishment for IPs that are banned repeatedly |
| **bantime.increment** | Automatically lengthens ban time with each repeat offense |
| **Permanent bans** | Never-expiring bans for known-bad IPs |
| **Multi-port jails** | Single jail covers multiple services at once |
| **firewallcmd-allports** | Block an IP on every port, not just the attacked port |
| **SQLite database** | Survives restarts; audit trail of all bans |
| **ipset tuning** | Handle high-volume attacks without performance degradation |
| **Aggregated logging** | Forward fail2ban events to centralized log management |

[↑ Back to TOC](#table-of-contents)

---

## 2. The Recidive Jail — Banning Repeat Offenders

The **recidive jail** is a special jail that watches the fail2ban log itself. When an IP is banned by any other jail, that ban is logged. If the same IP gets banned multiple times within `findtime`, the recidive jail imposes a much longer secondary ban.

### How it works

```
Normal jail bans IP → fail2ban logs "Ban 203.0.113.45"
                             ↓
Recidive filter matches that log line
                             ↓
Recidive counts bans per IP within findtime
                             ↓
If bans >= maxretry → long-term ban (e.g., 1 week)
```

### RHEL 10 — check your fail2ban log destination first

Before enabling recidive, confirm where fail2ban logs its own events. On RHEL 10,
the default `logtarget` is `SYSLOG`, which routes to journald — **not** a flat file.

```bash
sudo grep -E "^logtarget" /etc/fail2ban/fail2ban.local 2>/dev/null || \
  grep -E "^logtarget" /etc/fail2ban/fail2ban.conf
```

Common values and what they mean for recidive:

| `logtarget` value | Where logs go | Recidive approach |
|-------------------|--------------|-------------------|
| `/var/log/fail2ban.log` | Flat file | Use **Option A** (flat-file recidive) |
| `SYSLOG` | journald | Use **Option B** (systemd-backend recidive) |
| `SYSTEMD-JOURNAL` | journald | Use **Option B** (systemd-backend recidive) |

### Enabling the recidive jail

The filter `recidive.conf` ships with fail2ban. Choose the option that matches
your `logtarget` setting above.

**Option A — systemd-backend recidive (recommended for default RHEL 10):**

On RHEL 10 with `logtarget = SYSLOG`, fail2ban logs go to journald. Use a
custom recidive filter that reads from the journal directly:

```ini

[↑ Back to TOC](#table-of-contents)

# /etc/fail2ban/filter.d/recidive-systemd.conf

[Definition]
journalmatch = _SYSTEMD_UNIT=fail2ban.service

# Match fail2ban's own ban lines in the journal
failregex = fail2ban\.actions\S+\s+NOTICE\s+\[\S+\] Ban <HOST>

ignoreregex =
```

And the jail:

```ini
# /etc/fail2ban/jail.d/recidive.conf

[recidive]
enabled   = true
filter    = recidive-systemd
backend   = systemd

# If banned 3 times within 12 hours → long ban
maxretry  = 3
findtime  = 12h
bantime   = 1w          # 1 week

banaction = firewallcmd-allports    # block ALL ports for recidivists
```

**Option B — flat-file recidive (only if logtarget is a file path):**

If you have configured fail2ban to write to `/var/log/fail2ban.log`, use the
shipped `recidive` filter which reads that file:

```bash
# First, ensure the log file exists (create if missing):
sudo touch /var/log/fail2ban.log
sudo chown root:root /var/log/fail2ban.log
sudo chmod 640 /var/log/fail2ban.log
```

```ini
# /etc/fail2ban/fail2ban.local  (if not already set to file logging)
[Definition]
logtarget = /var/log/fail2ban.log
loglevel  = NOTICE
```

```bash
sudo systemctl restart fail2ban
```

Then enable the jail:

```ini
# /etc/fail2ban/jail.d/recidive.conf

[recidive]
enabled   = true
filter    = recidive
logpath   = /var/log/fail2ban.log

# If banned 3 times within 12 hours → long ban
maxretry  = 3
findtime  = 12h
bantime   = 1w          # 1 week

banaction = firewallcmd-allports    # block ALL ports for recidivists
```

> **`dbpurgeage` note:** The recidive jail uses `findtime = 12h`. Ensure your
> `dbpurgeage` in `fail2ban.local` is set to at least `86400` (24 hours, the
> default) so ban history isn't pruned before recidive can count it. Setting
> `dbpurgeage` shorter than `findtime` will cause recidive to silently miss
> repeat offenders.

### Viewing recidive bans

```bash
sudo fail2ban-client status recidive
```

---

## 3. Incremental Ban Time (bantime.increment)

Instead of a fixed ban time, fail2ban can automatically **increase the ban duration** each time the same IP is banned. This is effective against persistent attackers.

### Configuration

```ini

[↑ Back to TOC](#table-of-contents)

# /etc/fail2ban/jail.local  (in [DEFAULT] section, or per-jail)

[DEFAULT]

# Enable incremental ban time
bantime.increment   = true

# Base ban time (starting value)
bantime             = 10m

# Multiplier applied each time — ban doubles with each offense
bantime.factor      = 2

# Maximum ban time (prevent infinite bans unless you want permanent)
bantime.maxtime     = 24h

# OR set to -1 for permanent after enough repeats:
# bantime.maxtime   = -1

# Only count bans within this lookback window
bantime.rndtime     = 0        # add random jitter (seconds) to avoid bot detection of ban timing
bantime.overalljails = false   # true = count bans across ALL jails; false = per-jail only
```

### Progression example

With `bantime = 10m`, `bantime.factor = 2`, `bantime.maxtime = 24h`:

| Offense | Ban duration |
|---------|-------------|
| 1st ban | 10 minutes |
| 2nd ban | 20 minutes |
| 3rd ban | 40 minutes |
| 4th ban | 80 minutes |
| 5th ban | 160 minutes |
| 6th ban | 320 minutes (5h 20m) |
| 7th ban | 640 minutes — capped at 24h |
| 8th+ ban | 24 hours (maxtime cap) |

### View current ban time for an IP

```bash
# The current ban time is stored in the SQLite database
sudo sqlite3 /var/lib/fail2ban/fail2ban.sqlite3 \
  "SELECT jail, ip, bantime, bancount FROM bans ORDER BY timeofban DESC LIMIT 20;"
```

### Per-jail incremental override

```ini
[sshd]
bantime.increment = true
bantime           = 5m
bantime.factor    = 4
bantime.maxtime   = 7d
```

---

## 4. Permanent Bans

A ban of `-1` means the ban never expires. Use this for known-malicious IPs that have demonstrated persistent intent.

### Setting bantime to permanent

```ini

[↑ Back to TOC](#table-of-contents)

# Per-jail permanent ban:
[sshd]
bantime = -1
```

### Permanent ban via manual command

```bash
# Ban permanently (bantime = -1)
sudo fail2ban-client set sshd banip 203.0.113.45
# This uses the jail's configured bantime.
# To force permanent regardless of jail bantime:
sudo fail2ban-client set sshd bantime -1
sudo fail2ban-client set sshd banip 203.0.113.45
```

> **Warning:** Permanent bans accumulate in the firewalld ipset. On very high-volume attacks, thousands of entries can slow down ipset lookups. Monitor ipset size.

### Viewing permanent bans

```bash
sudo fail2ban-client status sshd
sudo firewall-cmd --ipset=f2b-sshd --get-entries | wc -l
```

### Removing a permanent ban

```bash
sudo fail2ban-client set sshd unbanip 203.0.113.45
```

---

## 5. Fine-Tuning ignoreip

`ignoreip` is a space- or newline-separated list of IPs, CIDR ranges, or DNS names that fail2ban will never ban. Misconfiguring this can lock you out.

### Global ignoreip (in [DEFAULT])

```ini

[↑ Back to TOC](#table-of-contents)

# /etc/fail2ban/jail.local

[DEFAULT]
ignoreip = 127.0.0.1/8
           ::1
           10.0.0.0/8
           192.168.0.0/16
           172.16.0.0/12
```

### Per-jail ignoreip override

A jail's `ignoreip` **adds to** the global list, it does not replace it:

```ini
[webapp]
ignoreip = 203.0.113.100    # additional IP just for this jail
```

To set an entirely separate ignoreip for one jail (overriding global), use:

```ini
[webapp]
ignoreip = %(ignoreip)s 203.0.113.100    # inherits global + adds one
```

### Ignoring DNS names

```ini
ignoreip = monitoring.internal.example.com
```

> **Warning:** DNS-based ignoreip entries are resolved at startup. If DNS fails or the hostname changes, the ignore may not work as expected. Prefer CIDR ranges for reliability.

### Verifying ignoreip is working

```bash
# Check if an IP would be ignored
sudo fail2ban-client get sshd ignoreip

# Or check the jail config
sudo fail2ban-client -d 2>&1 | grep -A20 "\[sshd\]" | grep ignore
```

---

## 6. Multi-Port Jails

A single jail can protect multiple ports simultaneously. The `port` parameter accepts comma-separated port names or numbers.

### Named ports

```ini
[webserver]
enabled   = true
filter    = apache-auth
logpath   = /var/log/httpd/*error_log
port      = http,https
bantime   = 1h
```

### Numeric ports

```ini
[myapp]
enabled   = true
filter    = myapp
logpath   = /var/log/myapp/auth.log
port      = 8080,8443,8000
bantime   = 30m
```

### Range of ports

```ini
[myapp]
port = 8080:8090    # ports 8080 through 8090 inclusive
```

### All ports

Do not use `port = all` with `firewallcmd-ipset` — instead switch to `banaction = firewallcmd-allports`:

```ini
[malicious-activity]
enabled     = true
filter      = myapp
logpath     = /var/log/myapp/auth.log
banaction   = firewallcmd-allports
bantime     = 24h
```

[↑ Back to TOC](#table-of-contents)

---

## 7. firewallcmd-allports — Blocking All Ports

The `firewallcmd-allports` action adds a **firewalld rich rule** that drops all traffic from the banned IP across every port and protocol. It is the nuclear option.

### When to use firewallcmd-allports

| Use firewallcmd-allports | Use firewallcmd-ipset |
|--------------------------|----------------------|
| Recidive jail | Regular per-service jails |
| Confirmed malicious host | Unknown/ambiguous attacker |
| Scanning/DDoS activity | Authentication brute force |
| Manual emergency ban | Automated routine ban |

### Configuration

```ini

[↑ Back to TOC](#table-of-contents)

# Use as banaction for a specific jail:
[sshd-aggressive]
enabled     = true
filter      = sshd
backend     = systemd
maxretry    = 2
findtime    = 5m
bantime     = 7d
banaction   = firewallcmd-allports
```

### What firewallcmd-allports does under the hood

```bash
# Ban:
firewall-cmd --add-rich-rule="rule family='ipv4' source address='203.0.113.45' reject"

# Unban:
firewall-cmd --remove-rich-rule="rule family='ipv4' source address='203.0.113.45' reject"
```

> **Note:** Rich rules are O(n) — each new rule adds a linear lookup. For high-volume environments (thousands of IPs), use `firewallcmd-ipset` instead. Use `firewallcmd-allports` only for the recidive jail or known-bad IPs where absolute blocking is required.

### Verify

```bash
sudo firewall-cmd --list-rich-rules | grep "203.0.113.45"
```

---

## 8. The Fail2ban Database — SQLite Persistence

Fail2ban uses an SQLite database to persist ban state across restarts. Without it, all bans would be lost on a service restart or reboot.

### Database location

```
/var/lib/fail2ban/fail2ban.sqlite3
```

### What is stored

| Table | Contents |
|-------|----------|
| `bans` | IP, jail, ban time, unban time, ban count, timestamps |
| `logs` | Log file positions (avoids re-reading the same log) |

### Inspect the database

```bash

[↑ Back to TOC](#table-of-contents)

# List all current/recent bans
sudo sqlite3 /var/lib/fail2ban/fail2ban.sqlite3 \
  "SELECT jail, ip, timeofban, bantime, bancount FROM bans ORDER BY timeofban DESC LIMIT 20;" \
  ".mode column" ".headers on"

# Count bans per jail
sudo sqlite3 /var/lib/fail2ban/fail2ban.sqlite3 \
  "SELECT jail, COUNT(*) as total_bans FROM bans GROUP BY jail ORDER BY total_bans DESC;"

# Find IPs banned more than once (repeat offenders)
sudo sqlite3 /var/lib/fail2ban/fail2ban.sqlite3 \
  "SELECT ip, SUM(bancount) as total_bans FROM bans GROUP BY ip HAVING total_bans > 1 ORDER BY total_bans DESC LIMIT 20;"
```

### Configure database retention

```ini
# /etc/fail2ban/fail2ban.local

[Definition]
# How long to keep records in the database (seconds)
# 86400 = 1 day, 604800 = 7 days, -1 = forever
dbpurgeage = 1d
```

### Disable the database (not recommended)

```ini
# /etc/fail2ban/fail2ban.local

[Definition]
dbfile = :memory:    # ephemeral — bans lost on restart
# OR
dbfile =             # empty = disabled entirely
```

### Database integrity check

```bash
sudo sqlite3 /var/lib/fail2ban/fail2ban.sqlite3 "PRAGMA integrity_check;"
```

Expected: `ok`

### Backup the database

```bash
# Safe backup while fail2ban is running (SQLite supports hot backups)
sudo sqlite3 /var/lib/fail2ban/fail2ban.sqlite3 \
  ".backup /var/lib/fail2ban/fail2ban-backup-$(date +%Y%m%d).sqlite3"
```

---

## 9. Aggregated and Centralized Logging

In multi-server environments, you want fail2ban events from all servers flowing into a central log management system (ELK, Loki, Splunk, etc.).

### Option A — Forward via systemd journal

If your organization uses a centralized journal collector (e.g., `systemd-journal-remote`), fail2ban events are automatically included since fail2ban logs to the journal on RHEL 10.

```bash

[↑ Back to TOC](#table-of-contents)

# Verify fail2ban is logging to journal
sudo journalctl -u fail2ban.service -n 5 --no-pager
```

### Option B — Write to a flat file and forward with a log shipper

```ini
# /etc/fail2ban/fail2ban.local

[Definition]
logtarget = /var/log/fail2ban.log
loglevel  = NOTICE
```

Then configure Filebeat/Fluentd/Vector to ship `/var/log/fail2ban.log`.

### Option C — Custom action that POSTs to a central API

```ini
# /etc/fail2ban/action.d/central-logger.conf

[Definition]
actionban = curl -s -X POST https://log.internal.example.com/api/events \
            -H "Content-Type: application/json" \
            -d "{\"host\":\"$(hostname)\",\"jail\":\"<name>\",\"ip\":\"<ip>\",\"event\":\"ban\",\"time\":\"<time>\"}"

actionunban = curl -s -X POST https://log.internal.example.com/api/events \
              -H "Content-Type: application/json" \
              -d "{\"host\":\"$(hostname)\",\"jail\":\"<name>\",\"ip\":\"<ip>\",\"event\":\"unban\",\"time\":\"<time>\"}"
```

Enable alongside the firewall action:

```ini
[sshd]
action = %(banaction)s[name=%(__name__)s, ...]
         central-logger[name=%(__name__)s]
```

### Log rotation for /var/log/fail2ban.log

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

## 10. ipset Performance Tuning

The `firewallcmd-ipset` action creates a firewalld ipset (a hash table of IP addresses). Ipsets are O(1) for lookups regardless of size — critical for high-volume attack scenarios.

### Check current ipset sizes

```bash

[↑ Back to TOC](#table-of-contents)

# List all fail2ban ipsets and their entry counts
sudo firewall-cmd --get-ipsets | tr ' ' '\n' | grep f2b | while read ipset; do
  count=$(sudo firewall-cmd --ipset="$ipset" --get-entries 2>/dev/null | wc -l)
  echo "$ipset: $count entries"
done
```

### ipset maxelem — maximum entries

By default, ipsets have a limit of 65536 entries. Under very high attack volume, this limit can be reached.

Fail2ban's ipset action accepts a `maxelem` parameter. To raise it:

```ini
# /etc/fail2ban/action.d/firewallcmd-ipset.local

[Init]
# Override the default maxelem for the ipset
maxelem = 131072
```

Or per-jail:

```ini
[sshd]
banaction = firewallcmd-ipset[maxelem=131072]
```

### Hash type

The default ipset type is `hash:ip`. For CIDR range banning, use `hash:net`:

```ini
# /etc/fail2ban/action.d/firewallcmd-ipset.local

[Init]
hashtype = hash:net
```

### Monitor ipset performance

```bash
# Count total entries across all f2b ipsets
sudo nft list ruleset | grep -c "f2b"

# Check nftables set sizes directly
sudo nft list sets | grep -E "f2b|elements"
```

### Database size impact on startup

At startup, fail2ban re-reads the SQLite database and re-applies all unexpired bans to firewalld ipsets. With thousands of bans, this can take several seconds. Tune `dbpurgeage` to keep the database lean:

```ini
# /etc/fail2ban/fail2ban.local

[Definition]
dbpurgeage = 7d    # delete records older than 7 days
```

---

## 11. Rate-Limiting with Multiple Jails per Service

You can run **multiple jails watching the same service** with different thresholds for different response policies. This implements a tiered response:

```
Tier 1: 10 failures → 10-minute ban (suspicious)
Tier 2:  5 failures → 1-hour ban   (probable attacker)
Tier 3:  2 failures → 1-day ban    (aggressive/scanner)
```

### Example: tiered SSH jails

```ini

[↑ Back to TOC](#table-of-contents)

# /etc/fail2ban/jail.d/sshd-tiered.conf

# Tier 1 — frequent failures over a long window
[sshd-slow]
enabled   = true
filter    = sshd
backend   = systemd
maxretry  = 20
findtime  = 1h
bantime   = 10m

# Tier 2 — moderate attack rate
[sshd-medium]
enabled   = true
filter    = sshd
backend   = systemd
maxretry  = 5
findtime  = 10m
bantime   = 1h

# Tier 3 — rapid attack (scanner)
[sshd-rapid]
enabled   = true
filter    = sshd
backend   = systemd
maxretry  = 2
findtime  = 1m
bantime   = 24h
banaction = firewallcmd-allports
```

> **Note:** Multiple jails watching the same log source means each failure is counted independently in each jail. An IP that triggers 5 failures in 1 minute will hit all three tiers simultaneously.

---

## 12. Whitelisting and Trusted Networks

Beyond `ignoreip`, you can implement application-level whitelisting strategies.

### Global trusted networks

```ini

[↑ Back to TOC](#table-of-contents)

# /etc/fail2ban/jail.local

[DEFAULT]
# Internal networks that should never be banned
ignoreip = 127.0.0.1/8
           ::1
           10.0.0.0/8
           192.168.0.0/16
           172.16.0.0/12
           # Monitoring server
           198.51.100.10
           # Office VPN
           203.0.113.0/24
```

### Per-jail whitelist

```ini
# /etc/fail2ban/jail.d/sshd-external.conf

[sshd-external]
enabled   = true
filter    = sshd
backend   = systemd
maxretry  = 3
bantime   = 48h
# Only apply to external IPs — internal already excluded by global ignoreip
ignoreip  = %(ignoreip)s 10.0.0.0/8
```

### Using ignorecommand for dynamic whitelisting

`ignorecommand` allows running a shell command to determine if an IP should be ignored. If the command exits 0, the IP is whitelisted:

```ini
# /etc/fail2ban/jail.local

[DEFAULT]
# Whitelist IPs that are in our "trusted hosts" file
ignorecommand = /usr/local/bin/is-trusted-ip.sh <ip>
```

Example script:

```bash
#!/bin/bash
# /usr/local/bin/is-trusted-ip.sh
# Returns 0 if IP should be ignored, 1 if it should be checked

IP="$1"
if grep -qF "$IP" /etc/fail2ban/trusted-hosts.txt 2>/dev/null; then
  exit 0    # trusted — ignore
fi
exit 1      # not trusted — apply normal rules
```

---

## 13. Adjusting Fail2ban Log Level and Log Target

Controlling what fail2ban logs and where is important for both debugging and production monitoring.

### Log levels

| Level | What is logged |
|-------|---------------|
| `CRITICAL` | Service failures only |
| `ERROR` | Errors (config issues, action failures) |
| `WARNING` | Warnings |
| `NOTICE` | Ban/unban events ← **recommended for production** |
| `INFO` | Detailed operational messages |
| `DEBUG` | Everything — verbose for troubleshooting |

### Configure log level and target

```ini

[↑ Back to TOC](#table-of-contents)

# /etc/fail2ban/fail2ban.local

[Definition]
loglevel  = NOTICE
logtarget = /var/log/fail2ban.log
```

### Log targets

| Target | Description |
|--------|-------------|
| `/path/to/file` | Write to flat file |
| `SYSLOG` | Send to syslog (journald on RHEL 10) |
| `SYSTEMD-JOURNAL` | Send directly to systemd journal |
| `STDOUT` | Print to stdout (useful in containers) |
| `STDERR` | Print to stderr |

### Temporarily increase verbosity for debugging

```bash
# Increase to DEBUG without restarting
sudo fail2ban-client set loglevel DEBUG

# Restore to NOTICE when done
sudo fail2ban-client set loglevel NOTICE
```

### Flush and re-open the log file (after rotation)

```bash
sudo fail2ban-client flushlogs
```

---

## 14. Managing Fail2ban in a Cluster or Load-Balanced Environment

Fail2ban runs locally on each server. In a multi-server environment, bans applied on one server are not automatically shared to others. There are several strategies to handle this.

### Strategy 1 — Accept per-server isolation

Each server bans independently. Adequate for most environments where:
- Attackers do not scatter requests across servers
- Each server receives the same attack traffic

No configuration changes needed.

### Strategy 2 — Shared ban list via custom action

Use a custom action that writes bans to a shared backend (database, Redis, API), and a periodic script that reads from it and applies bans:

```bash

[↑ Back to TOC](#table-of-contents)

# /usr/local/bin/sync-bans.sh — runs via cron/systemd timer
# Reads from central API and applies bans to local fail2ban
curl -s https://banapi.internal.example.com/current | \
  jq -r '.bans[] | .ip' | \
  while read ip; do
    sudo fail2ban-client set sshd banip "$ip" 2>/dev/null
  done
```

### Strategy 3 — Use firewalld's native ipset with shared storage

If servers share a network filesystem (NFS, Ceph), configure firewalld ipsets to read from a shared file. This is complex and outside fail2ban's scope but leverages existing firewalld infrastructure.

### Strategy 4 — Upstream WAF or load balancer

For web traffic, handle rate-limiting and IP blocking at the load balancer (HAProxy, Nginx upstream, or a WAF). Fail2ban remains as a last-resort server-level defense.

---

## Lab 10 — Recidive Jail and Incremental Bans

### Objective

Configure the recidive jail and incremental ban time, then simulate repeat-offense banning and verify the escalation.

### Prerequisites

- Module 09 lab completed (`labapp` jail and filter exist)
- Fail2ban running
- `/var/log/fail2ban.log` writable (configure if needed)

[↑ Back to TOC](#table-of-contents)

---

### Part A — Enable Fail2ban File Logging

**1. Configure fail2ban to log to a file:**

```bash
sudo tee /etc/fail2ban/fail2ban.local > /dev/null << 'EOF'
[Definition]
loglevel  = NOTICE
logtarget = /var/log/fail2ban.log
dbpurgeage = 7d
EOF
```

**2. Create the log file and restart:**

```bash
sudo touch /var/log/fail2ban.log
sudo chmod 640 /var/log/fail2ban.log
sudo systemctl restart fail2ban
```

**3. Verify logging:**

```bash
sudo tail -5 /var/log/fail2ban.log
```

Expected — lines like:
```
2026-02-15 14:22:01,123 fail2ban.server [...]  INFO    ...
```

---

### Part B — Enable Incremental Ban Time for labapp

**4. Update the labapp jail to use incremental bans:**

```bash
sudo tee /etc/fail2ban/jail.d/labapp.conf > /dev/null << 'EOF'
[labapp]
enabled             = true
filter              = labapp
logpath             = /var/log/labapp/auth.log
backend             = auto
maxretry            = 5
findtime            = 5m
bantime             = 1m
bantime.increment   = true
bantime.factor      = 2
bantime.maxtime     = 30m
port                = http,https
EOF
```

**5. Reload:**

```bash
sudo fail2ban-client reload
sudo fail2ban-client status labapp
```

---

### Part C — Enable Recidive Jail

**6. Create the recidive jail config:**

```bash
sudo tee /etc/fail2ban/jail.d/recidive.conf > /dev/null << 'EOF'
[recidive]
enabled   = true
filter    = recidive
logpath   = /var/log/fail2ban.log
maxretry  = 2
findtime  = 30m
bantime   = 1h
banaction = firewallcmd-allports
EOF
```

**7. Reload and verify both jails are active:**

```bash
sudo fail2ban-client reload
sudo fail2ban-client status
```

Expected output includes both `labapp` and `recidive`.

---

### Part D — Simulate Repeat Offenses

**8. First ban — trigger 6 failures:**

```bash
sudo truncate -s 0 /var/log/labapp/auth.log
sudo labapp-fail.sh 192.0.2.100 6
sleep 5
sudo fail2ban-client status labapp
```

Expected: `192.0.2.100` in Banned IP list.

**9. Manually unban to simulate expiry:**

```bash
sudo fail2ban-client set labapp unbanip 192.0.2.100
```

**10. Second ban — trigger again:**

```bash
sudo labapp-fail.sh 192.0.2.100 6
sleep 5
sudo fail2ban-client status labapp
```

**11. Check the fail2ban log — you should see two ban lines:**

```bash
grep "192.0.2.100" /var/log/fail2ban.log
```

Expected:
```
... NOTICE [labapp] Ban 192.0.2.100
... NOTICE [labapp] Unban 192.0.2.100
... NOTICE [labapp] Ban 192.0.2.100
```

**12. Check if recidive has fired:**

```bash
sudo fail2ban-client status recidive
```

If recidive has fired: `192.0.2.100` will appear in its Banned IP list and a rich rule will appear in firewalld.

**13. Check firewalld for the allports rich rule:**

```bash
sudo firewall-cmd --list-rich-rules | grep "192.0.2.100"
```

Expected (if recidive fired):
```
rule family="ipv4" source address="192.0.2.100" reject
```

---

### Part E — Inspect the Database

**14. View ban history with escalating ban times:**

```bash
sudo sqlite3 /var/lib/fail2ban/fail2ban.sqlite3 \
  "SELECT jail, ip, bantime, bancount, datetime(timeofban, 'unixepoch', 'localtime') as banned_at
   FROM bans
   WHERE ip = '192.0.2.100'
   ORDER BY timeofban;"
```

Expected: two rows for `labapp`, potentially one for `recidive`. The `bantime` value should increase (1m → 2m due to `bantime.factor = 2`).

---

### Part F — Clean Up

**15. Unban from all jails:**

```bash
sudo fail2ban-client set labapp unbanip 192.0.2.100 2>/dev/null
sudo fail2ban-client set recidive unbanip 192.0.2.100 2>/dev/null
```

**16. Verify clean state:**

```bash
sudo fail2ban-client status labapp
sudo fail2ban-client status recidive
sudo firewall-cmd --list-rich-rules
```

---

### Lab Summary

| Step | What you did | What you verified |
|------|-------------|-------------------|
| A | Enabled file logging | fail2ban.log receiving events |
| B | Enabled incremental ban time | bantime.increment configured |
| C | Enabled recidive jail | Two jails active |
| D | Triggered two bans for same IP | Second ban logged for recidive to detect |
| E | Inspected SQLite database | Escalating ban times recorded |
| F | Cleaned up | All bans removed |

### Lab Complete ✓

**Self-check — verify you can answer yes to each:**

- [ ] `fail2ban-client get fail2ban logtarget` returns `/var/log/fail2ban.log`
- [ ] `fail2ban-client get labapp bantime` returns a value greater than the initial setting (proof of increment)
- [ ] `fail2ban-client status recidive` shows the recidive jail active
- [ ] The SQLite `bans` table shows escalating `bantime` values for the repeated-offense IP
- [ ] I understand why `dbpurgeage` must be longer than recidive's `findtime`
- [ ] I cleaned up all test bans before finishing

---

### Next Steps

Proceed to **[Module 11 — Systemd and Journald](./11-systemd-and-journald.md)**
to deep-dive into journal-based log monitoring, journalmatch tuning, and SELinux considerations.

---

| ← Previous | Home | Next → |
|-------------|------|---------|
| [09 — Custom Jails & Filters](./09-custom-jails-and-filters.md) | [Course README](./README.md) | [11 — Systemd & Journald](./11-systemd-and-journald.md) |

---

*Licensed under [CC BY-NC-SA 4.0](LICENSE.md) · © 2026 UncleJS*