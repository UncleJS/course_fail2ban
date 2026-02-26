# Module 03 — Core Concepts

> **Level:** Beginner  
> **Prerequisites:** [Module 02 — Installation](./02-installation.md)  
> **Time to complete:** ~45 minutes

---

## Table of Contents

1. [The Three Pillars: Jails, Filters, Actions](#1-the-three-pillars-jails-filters-actions)
2. [Jails — The Control Unit](#2-jails--the-control-unit)
3. [Filters — The Detection Engine](#3-filters--the-detection-engine)
4. [Actions — The Enforcement Layer](#4-actions--the-enforcement-layer)
5. [Backends — How Logs Are Read](#5-backends--how-logs-are-read)
6. [The Timing Triangle: bantime, findtime, maxretry](#6-the-timing-triangle-bantime-findtime-maxretry)
7. [The ignoreip Whitelist](#7-the-ignoreip-whitelist)
8. [The Ban Lifecycle](#8-the-ban-lifecycle)
9. [The SQLite Persistence Database](#9-the-sqlite-persistence-database)
10. [How All the Pieces Fit Together](#10-how-all-the-pieces-fit-together)
11. [Lab 03 — Inspect Live Concepts in Action](#11-lab-03--inspect-live-concepts-in-action)
12. [Summary](#12-summary)

---

## 1. The Three Pillars: Jails, Filters, Actions

Every fail2ban configuration revolves around three interconnected components:

```
┌─────────────────────────────────────────────────────────────┐
│                         JAIL                                │
│                                                             │
│   "Watch SSH service, using the sshd filter,               │
│    and when triggered, use the firewallcmd-ipset action"    │
│                                                             │
│   ┌─────────────┐         ┌─────────────────────────────┐  │
│   │   FILTER    │         │          ACTION              │  │
│   │             │         │                              │  │
│   │ Regex rules │         │ firewall-cmd --add-rich-rule │  │
│   │ that detect │         │ or                           │  │
│   │ bad logins  │         │ firewall-cmd ipset add       │  │
│   └─────────────┘         └─────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

Think of it this way:
- A **jail** is the **policy**: "protect this service with these settings"
- A **filter** is the **detector**: "what does a bad attempt look like?"
- An **action** is the **response**: "what do we do when we detect one?"

[↑ Back to TOC](#table-of-contents)

---

## 2. Jails — The Control Unit

A **jail** is the top-level configuration unit in fail2ban. Each jail:

- Monitors one specific service or log source
- References one filter (detection rules)
- References one or more actions (responses)
- Has its own timing parameters (`bantime`, `findtime`, `maxretry`)
- Can be independently enabled or disabled

### A minimal jail definition

```ini
[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/secure
maxretry = 5
bantime  = 3600
findtime = 600
action   = firewallcmd-ipset
```

### Anatomy of a jail

| Parameter | What It Does | Example |
|-----------|-------------|---------|
| `enabled` | Whether this jail is active | `true` / `false` |
| `port` | Port(s) to block when banning | `ssh`, `http,https`, `22` |
| `filter` | Which filter file to use (from `filter.d/`) | `sshd` |
| `logpath` | Log file(s) to monitor | `/var/log/secure` |
| `backend` | How to read logs | `systemd`, `auto` |
| `maxretry` | Failures before a ban | `5` |
| `bantime` | How long to ban (seconds, or `-1` for permanent) | `3600` |
| `findtime` | Window in which maxretry must occur | `600` |
| `action` | Which action(s) to trigger | `firewallcmd-ipset` |
| `ignoreip` | IPs that will never be banned | `127.0.0.1 10.0.0.0/8` |

### Multiple jails can run simultaneously

You can have dozens of jails active at the same time, each protecting a
different service:

```bash
sudo fail2ban-client status
```
```
Status
|- Number of jail:      4
`- Jail list:   sshd, httpd-auth, postfix, nginx-http-auth
```

[↑ Back to TOC](#table-of-contents)

---

## 3. Filters — The Detection Engine

A **filter** is a file containing regular expressions that identify malicious
or suspicious log entries. Filters live in `/etc/fail2ban/filter.d/`.

### What a filter looks like

```ini
# /etc/fail2ban/filter.d/sshd.conf (simplified)

[Definition]
failregex = ^%(__prefix_line)s(?:error: PAM: )?[aA]uthentication (?:failure|error|failed) for .* from <HOST>( via \S+)?\s*$
            ^%(__prefix_line)sFailed \S+ for .* from <HOST>(?: port \d+)?(?: ssh\d*)?\s*$
            ^%(__prefix_line)sROOT LOGIN REFUSED from <HOST>\s*$

ignoreregex =
```

### The critical `<HOST>` capture group

Every filter must include `<HOST>` in its `failregex`. This is a special
placeholder that fail2ban replaces with a regex that matches IPv4 and IPv6
addresses. The matched IP is what gets banned.

```
Failed password for root from <HOST> port 44312 ssh2
                                ^^^^^^
                            This IP gets banned
```

### How fail2ban uses filters

1. A new log line arrives
2. Fail2ban tests it against every `failregex` in the filter
3. If it matches, fail2ban extracts the IP from the `<HOST>` position
4. The IP is added to a counter for the current `findtime` window
5. When the counter reaches `maxretry`, the ban action fires

### `ignoreregex`

Some log lines look like failures but aren't. The `ignoreregex` field lets
you exclude specific patterns from triggering the fail counter:

```ini
ignoreregex = for user root from 192\.168\.1\.1
```

[↑ Back to TOC](#table-of-contents)

---

## 4. Actions — The Enforcement Layer

An **action** defines what happens when a ban is triggered (and when it is
lifted). Actions live in `/etc/fail2ban/action.d/`.

### On RHEL 10: firewalld actions

Because RHEL 10 uses firewalld, the relevant action files are:

| Action File | Method | Best For |
|-------------|--------|----------|
| `firewallcmd-ipset.conf` | Adds IP to a firewalld-managed ipset | **Recommended** — high performance, scales to thousands of IPs |
| `firewallcmd-new.conf` | Adds a rich rule per IP | Small deployments, easy to inspect with `firewall-cmd --list-rich-rules` |
| `firewallcmd-allports.conf` | Blocks all ports from the IP | Maximum blocking |
| `firewallcmd-rich-logging.conf` | Rich rules with packet logging | Audit trail requirements |

### What an action file contains

An action file has three sections:

```ini
[Definition]
# Command run when the service starts (creates the ipset, etc.)
actionstart = firewall-cmd --permanent --new-ipset=<ipsetname> --type=hash:ip ...
              firewall-cmd --reload

# Command run to BAN an IP
actionban   = firewall-cmd --ipset=<ipsetname> --add-entry=<ip>

# Command run to UNBAN an IP
actionunban = firewall-cmd --ipset=<ipsetname> --remove-entry=<ip>

# Command run when the service stops (cleanup)
actionstop  = firewall-cmd --permanent --delete-ipset=<ipsetname> ...
              firewall-cmd --reload
```

### Action parameters

Actions use placeholder variables that fail2ban substitutes at runtime:

| Placeholder | Value |
|-------------|-------|
| `<ip>` | The IP address being banned |
| `<port>` | The port(s) specified in the jail |
| `<protocol>` | tcp/udp |
| `<name>` | The jail name |
| `<ipsetname>` | Auto-generated ipset name (e.g., `fail2ban-sshd`) |

[↑ Back to TOC](#table-of-contents)

---

## 5. Backends — How Logs Are Read

A **backend** tells fail2ban how to watch log sources. On RHEL 10 there are
two backends you will use:

### `systemd` backend (recommended for RHEL 10)

Uses the systemd journal (journald) directly via the Python `systemd` bindings.
No log file needed — reads from the binary journal.

```ini
[sshd]
backend = systemd
# No logpath needed — reads from journald
journalmatch = _SYSTEMD_UNIT=sshd.service + _COMM=sshd
```

**Advantages:**
- No log file rotation issues
- Works even if the service doesn't write to a flat file
- Structured log fields (not just text matching)
- Recommended for all systemd-managed services on RHEL 10

### `auto` / `polling` backend (for file-based logs)

Monitors flat log files by polling or using inotify:

```ini
[nginx-http-auth]
backend  = auto
logpath  = /var/log/nginx/error.log
```

**When to use:**
- Services that write to flat log files (e.g., nginx, custom apps)
- When the service is not systemd-managed
- When you need to monitor a specific file path

### `auto` backend behaviour

`auto` tries backends in this order:
1. `pyinotify` — uses Linux inotify for real-time file monitoring (fastest)
2. `gamin` — alternative file monitoring library
3. `polling` — falls back to polling the file every second (works everywhere)

[↑ Back to TOC](#table-of-contents)

---

## 6. The Timing Triangle: bantime, findtime, maxretry

These three parameters control the sensitivity and aggressiveness of each jail.
Understanding their interaction is essential for tuning.

```
Sliding window: always looks back findtime seconds from the LATEST event

time:    0    1    2    3    4    5    6    7    8    9   10 (minutes)
         │    │    │    │    │    │    │    │    │    │    │
events:  ✗         ✗         ✗              ✗         ✗
         1         2         3              4         5
                                                      │
                              ◄── findtime=10m ───────┘
                              All 5 events fall within the
                              10-minute window ending at t=8
                              → maxretry=5 reached → BAN FIRES

         ✗    (t=0)  ← If event 1 were at t=0 instead, and we checked
                       at t=11, the window [t=1 → t=11] would exclude
                       event 1, so the counter resets to 4 → NO BAN yet

                               ◄──────── bantime ────────────────►
                               Ban lasts bantime seconds from ban moment
```

> **Sliding window:** `findtime` is always measured **backward from the most
> recent failure** for a given IP. An attacker who pauses long enough for early
> failures to fall outside the `findtime` window will have their counter reset
> — a common evasion technique against low `maxretry` + long `findtime` setups.

### `findtime`

The **sliding time window** in which `maxretry` failures must occur to trigger
a ban.

```ini
findtime = 600   # 600 seconds = 10 minutes
```

If an attacker makes 4 failed attempts, then stops for 11 minutes, then makes
1 more — with `findtime = 600` they will NOT be banned. The earlier attempts
have expired from the window.

### `maxretry`

The **number of filter matches** from a single IP within `findtime` that
triggers a ban.

```ini
maxretry = 5   # 5 failures within findtime = ban
```

Lower values = more sensitive (more false positives possible).
Higher values = less sensitive (attackers can make more attempts before ban).

### `bantime`

How long the ban lasts, in **seconds**.

```ini
bantime = 3600    # 1 hour
bantime = 86400   # 24 hours
bantime = 604800  # 1 week
bantime = -1      # Permanent (until manually unbanned)
```

### Recommended values by use case

| Use Case | findtime | maxretry | bantime |
|----------|----------|----------|---------|
| SSH (strict) | 600 | 3 | 86400 |
| SSH (balanced) | 600 | 5 | 3600 |
| Web login | 300 | 10 | 3600 |
| Mail auth | 600 | 5 | 3600 |
| Recidive | 86400 | 5 | 604800 |

### Incremental ban times

Fail2ban 0.11+ supports **multiplier-based ban time escalation**:

```ini
bantime.increment   = true
bantime.multiplier  = 2
bantime.maxtime     = 604800   # cap at 1 week

# First ban:  bantime * 1  = 1 hour
# Second ban: bantime * 2  = 2 hours
# Third ban:  bantime * 4  = 4 hours
# ...up to maxtime
```

[↑ Back to TOC](#table-of-contents)

---

## 7. The ignoreip Whitelist

`ignoreip` is a space-separated list of IPs, CIDR ranges, or DNS hostnames
that will **never** be banned by any jail. This is where you put your own
management IP addresses.

```ini
[DEFAULT]
ignoreip = 127.0.0.1/8    # localhost (always include)
           ::1             # IPv6 localhost
           10.0.0.0/8      # Private network
           192.168.1.100   # Your management workstation
           vpn.example.com # DNS hostname (resolved at startup)
```

> **Warning:** Forgetting to add your own IP to `ignoreip` is the #1 cause of
> administrators locking themselves out of their own servers. Always add your
> management IP **before** enabling fail2ban in production.

### Where to set ignoreip

Setting it in `[DEFAULT]` applies it to **all jails**:

```ini
# /etc/fail2ban/jail.local
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8
```

Setting it in a specific jail overrides the DEFAULT for that jail only:

```ini
[sshd]
enabled  = true
ignoreip = 127.0.0.1/8 ::1 203.0.113.50
```

[↑ Back to TOC](#table-of-contents)

---

## 8. The Ban Lifecycle

Understanding exactly what happens during a ban helps with both troubleshooting
and building confidence in the system:

```
Log entry arrives
       │
       ▼
Does it match failregex?
  No  ──────────────────► Ignored
  Yes │
       ▼
Extract <HOST> IP
       │
       ▼
Is IP in ignoreip?
  Yes ──────────────────► Ignored
  No  │
       ▼
Increment fail counter for this IP
       │
       ▼
Is fail count >= maxretry within findtime?
  No  ──────────────────► Wait for more failures
  Yes │
       ▼
Is IP already banned?
  Yes ──────────────────► Skip (already blocked)
  No  │
       ▼
Run actionban:
  firewall-cmd --ipset=fail2ban-sshd --add-entry=<ip>
       │
       ▼
Write to fail2ban.log:
  "Ban 185.220.101.5"
       │
       ▼
Store ban in SQLite DB
  (survives service restart)
       │
       ▼
Start ban timer countdown
       │
       ▼ (after bantime seconds)
Run actionunban:
  firewall-cmd --ipset=fail2ban-sshd --remove-entry=<ip>
       │
       ▼
Write to fail2ban.log:
  "Unban 185.220.101.5"
       │
       ▼
Remove from SQLite DB
```

[↑ Back to TOC](#table-of-contents)

---

## 9. The SQLite Persistence Database

Fail2ban stores its ban state in an SQLite database at:
```
/var/lib/fail2ban/fail2ban.sqlite3
```

This enables **ban persistence across service restarts**. If fail2ban is
restarted (e.g., after a system reboot), it reads the database and re-applies
any bans that have not yet expired.

### Inspecting the database

```bash
sudo sqlite3 /var/lib/fail2ban/fail2ban.sqlite3 \
  "SELECT jail, ip, timeofban, bantime FROM bans ORDER BY timeofban DESC LIMIT 20;"
```

```
sshd|185.220.101.5|1736506800|3600
sshd|45.33.32.156|1736506750|3600
httpd-auth|103.99.0.122|1736506700|86400
```

### Key database settings

```ini
# In fail2ban.conf / fail2ban.local

# Path to database file (set to :memory: to disable persistence)
dbfile   = /var/lib/fail2ban/fail2ban.sqlite3

# How long to keep records of past bans (for recidive jail)
dbpurgeage = 86400   # 24 hours
```

Setting `dbpurgeage` too low will cause the recidive jail (Module 10) to lose
history about repeat offenders.

[↑ Back to TOC](#table-of-contents)

---

## 10. How All the Pieces Fit Together

Here is the complete picture with all concepts connected:

```
/etc/fail2ban/jail.local
────────────────────────
[DEFAULT]
ignoreip  = 127.0.0.1/8 ::1 10.0.0.0/8
bantime   = 3600
findtime  = 600
maxretry  = 5
backend   = systemd
banaction = firewallcmd-ipset        ◄── references action.d/firewallcmd-ipset.conf

[sshd]
enabled  = true
port     = ssh
filter   = sshd                      ◄── references filter.d/sshd.conf
logpath  = /var/log/secure
                │                              │
                ▼                              ▼
    /etc/fail2ban/filter.d/         /etc/fail2ban/action.d/
    sshd.conf                       firewallcmd-ipset.conf
    ────────────────                ─────────────────────────
    [Definition]                    [Definition]
    failregex =                     actionban =
      Failed \S+ for .*               firewall-cmd
      from <HOST>                       --ipset=fail2ban-sshd
                                        --add-entry=<ip>
                │                              │
                ▼                              ▼
         Detects bad IP              Blocks IP in firewalld
```

[↑ Back to TOC](#table-of-contents)

---

## 11. Lab 03 — Inspect Live Concepts in Action

### Step 1 — Examine the running jail

```bash
sudo fail2ban-client status sshd
```

```
Status for the jail: sshd
|- Filter
|  |- Currently failed: 2
|  |- Total failed:     47
|  `- Journal matches:  _SYSTEMD_UNIT=sshd.service + _COMM=sshd
`- Actions
   |- Currently banned: 3
   |- Total banned:     12
   `- Banned IP list:   185.220.101.5 45.33.32.156 103.99.0.122
```

Identify each concept in this output:
- **Currently failed** = IPs that have triggered the filter but haven't reached `maxretry` yet
- **Total failed** = cumulative failures since the jail started
- **Journal matches** = the backend query (systemd backend)
- **Currently banned** = active bans right now
- **Banned IP list** = the actual IPs currently blocked in firewalld

### Step 2 — Examine the filter

```bash
sudo cat /etc/fail2ban/filter.d/sshd.conf | grep -A 10 "failregex"
```

Identify the `<HOST>` placeholder in each regex.

### Step 3 — Examine the action

```bash
sudo cat /etc/fail2ban/action.d/firewallcmd-ipset.conf
```

Find the `actionban` and `actionunban` commands. Notice how they use `<ip>` and
`<ipsetname>` placeholders.

### Step 4 — Check the timing settings

```bash
sudo fail2ban-client get sshd bantime
sudo fail2ban-client get sshd findtime
sudo fail2ban-client get sshd maxretry
```

### Step 5 — Inspect the database

```bash
sudo sqlite3 /var/lib/fail2ban/fail2ban.sqlite3 \
  "SELECT jail, ip, datetime(timeofban, 'unixepoch', 'localtime') as banned_at,
   bantime, datetime(timeofban + bantime, 'unixepoch', 'localtime') as expires_at
   FROM bans ORDER BY timeofban DESC LIMIT 5;"
```

### Step 6 — Verify a banned IP is in firewalld

```bash
# Get the list of currently banned IPs
BANNED_IP=$(sudo fail2ban-client status sshd | grep "Banned IP" | awk '{print $NF}' | cut -d' ' -f1)

# Check if it's in the firewalld ipset
sudo firewall-cmd --info-ipset=fail2ban-sshd 2>/dev/null || echo "ipset may not exist yet"
```

### Lab Complete ✓

**Self-check — verify you can answer yes to each:**

- [ ] I can read a jail's `filter` and `action` names from `fail2ban-client get sshd <param>`
- [ ] I located the `sshd.conf` filter file under `/etc/fail2ban/filter.d/` and identified the `failregex` line
- [ ] I can explain what the `<HOST>` placeholder does in a failregex
- [ ] I found a `Ban` or `Unban` entry in the fail2ban log or journal
- [ ] I queried the SQLite database and saw the `bans` table structure
- [ ] I understand the relationship: jail → filter detects → action bans → firewalld enforces

[↑ Back to TOC](#table-of-contents)

---

## 12. Summary

In this module you learned:

- The **three pillars**: Jails (policy), Filters (detection), Actions (response)
- **Jails** are the top-level unit that ties everything together
- **Filters** use regex with a `<HOST>` group to extract offending IPs from logs
- **Actions** on RHEL 10 call `firewall-cmd` to block IPs using firewalld
- **Backends**: `systemd` (recommended for journald on RHEL 10) vs `auto` (for flat files)
- The **timing triangle**: `bantime`, `findtime`, `maxretry` and how they interact
- **`ignoreip`**: your safety net — always whitelist your management IPs
- The **ban lifecycle**: from log entry → filter match → counter → ban → firewalld → unban
- **SQLite database**: persists bans across service restarts

### Next Steps

Proceed to **[Module 04 — Configuration Basics](./04-configuration-basics.md)**
to start writing your own configuration files.

---

| ← Previous | Home | Next → |
|-----------|------|--------|
| [02 — Installation](./02-installation.md) | [Course README](./README.md) | [04 — Configuration Basics](./04-configuration-basics.md) |
