# Module 04 — Configuration Basics

> **Level:** Beginner  
> **Prerequisites:** [Module 03 — Core Concepts](./03-core-concepts.md)  
> **Time to complete:** ~60 minutes

---

## Table of Contents

1. [The Configuration Hierarchy](#1-the-configuration-hierarchy)
2. [fail2ban.conf — Global Daemon Settings](#2-fail2banconf--global-daemon-settings)
3. [Creating fail2ban.local](#3-creating-fail2banlocal)
4. [jail.conf — Understanding the Defaults](#4-jailconf--understanding-the-defaults)
5. [Creating jail.local — Your Primary Config File](#5-creating-jaillocal--your-primary-config-file)
6. [The [DEFAULT] Section](#6-the-default-section)
7. [paths-fedora.conf — RHEL Log Paths](#7-paths-fedoraconf--rhel-log-paths)
8. [The jail.d/ Drop-in Directory](#8-the-jaild-drop-in-directory)
9. [Configuration Syntax Rules](#9-configuration-syntax-rules)
10. [Testing Configuration Syntax](#10-testing-configuration-syntax)
11. [Reloading Configuration](#11-reloading-configuration)
12. [Lab 04 — Build Your First jail.local](#12-lab-04--build-your-first-jaillocal)
13. [Summary](#13-summary)

---

## 1. The Configuration Hierarchy

Fail2ban loads configuration in a defined order. Files loaded later override
settings from files loaded earlier. This is how you customise behaviour without
touching the package-managed files.

### Global (daemon) configuration load order

```
1. /etc/fail2ban/fail2ban.conf          (package defaults — never edit)
2. /etc/fail2ban/fail2ban.d/*.conf      (drop-in files, alphabetical)
3. /etc/fail2ban/fail2ban.local         (YOUR overrides — create this)
4. /etc/fail2ban/fail2ban.d/*.local     (drop-in local overrides, alphabetical)
```

### Jail configuration load order

```
1. /etc/fail2ban/jail.conf              (package defaults — never edit)
2. /etc/fail2ban/jail.d/*.conf          (drop-in files, alphabetical)
3. /etc/fail2ban/jail.local             (YOUR overrides — create this)
4. /etc/fail2ban/jail.d/*.local         (drop-in local overrides, alphabetical)
```

### Visual representation

```
jail.conf          jail.d/00-firewalld.conf     jail.local
───────────        ─────────────────────────    ──────────
[DEFAULT]          [DEFAULT]                    [DEFAULT]
bantime = 10m  ──► banaction =             ──►  bantime = 1h   ◄── Final value
                     firewallcmd-ipset           maxretry = 3
```

The rightmost file wins. Your `jail.local` settings always take precedence over
anything in `jail.conf`.

[↑ Back to TOC](#table-of-contents)

---

## 2. fail2ban.conf — Global Daemon Settings

This file controls how the fail2ban **daemon itself** behaves (logging, socket
path, database). Look but don't touch:

```bash
cat /etc/fail2ban/fail2ban.conf
```

Key settings to understand:

```ini
[Definition]

# Log level: CRITICAL, ERROR, WARNING, NOTICE, INFO, DEBUG
loglevel = INFO

# Where fail2ban writes its own log
logtarget = /var/log/fail2ban.log

# Syslog socket (alternative to file logging)
# logtarget = SYSLOG

# Path to the Unix socket (used by fail2ban-client)
socket = /var/run/fail2ban/fail2ban.sock

# PID file
pidfile = /var/run/fail2ban/fail2ban.pid

# SQLite database path
dbfile = /var/lib/fail2ban/fail2ban.sqlite3

# How long to keep ban records in the database
# (important for recidive jail)
dbpurgeage = 1d
```

[↑ Back to TOC](#table-of-contents)

---

## 3. Creating fail2ban.local

Create your global override file to customise daemon behaviour:

```bash
sudo tee /etc/fail2ban/fail2ban.local << 'EOF'
[Definition]

# Increase log verbosity during initial setup (change to INFO in production)
loglevel = INFO

# Log to file (default is fine for RHEL 10)
logtarget = /var/log/fail2ban.log

# Keep ban history for 7 days (longer history helps recidive jail)
dbpurgeage = 7d
EOF
```

> **Tip:** You only need to include settings in `.local` files that differ from
> the defaults. An empty `.local` file is perfectly valid (and means "use all
> defaults").

[↑ Back to TOC](#table-of-contents)

---

## 4. jail.conf — Understanding the Defaults

The `jail.conf` file is large (~800 lines). It contains:
- A `[DEFAULT]` section with global jail defaults
- Definitions for every built-in jail (sshd, httpd, postfix, etc.)
- All jails are **disabled by default** (`enabled = false` or no `enabled` key)

Browse it to understand what's available:

```bash
# Count available jails
grep -c '^\[' /etc/fail2ban/jail.conf
```

```bash
# List all jail names
grep '^\[' /etc/fail2ban/jail.conf | tr -d '[]'
```

```bash
# View the DEFAULT section
sed -n '/^\[DEFAULT\]/,/^\[/p' /etc/fail2ban/jail.conf | head -60
```

### Key DEFAULT values in jail.conf

```ini
[DEFAULT]
# Default ban time (10 minutes)
bantime  = 10m

# Time window for counting failures (10 minutes)
findtime = 10m

# Failures before ban
maxretry = 5

# On RHEL 10 with fail2ban-firewalld package:
banaction = firewallcmd-ipset
banaction_allports = firewallcmd-allports

# Default backend
backend = auto
```

[↑ Back to TOC](#table-of-contents)

---

## 5. Creating jail.local — Your Primary Config File

This is the **most important file you will create**. All your jail configuration
goes here. Create it with your RHEL 10 baseline:

```bash
sudo tee /etc/fail2ban/jail.local << 'EOF'
# =============================================================================
# /etc/fail2ban/jail.local
# Fail2ban jail configuration for RHEL 10 with firewalld
# =============================================================================
# IMPORTANT: This file overrides jail.conf.
# Only specify settings you want to change from the defaults.
# =============================================================================

[DEFAULT]

# -----------------------------------------------------------------------
# WHITELIST — IPs that will NEVER be banned
# Add your management IP(s) here before enabling any jails!
# -----------------------------------------------------------------------
ignoreip = 127.0.0.1/8
           ::1

# -----------------------------------------------------------------------
# Timing defaults (override per-jail as needed)
# -----------------------------------------------------------------------
# How long to ban an offending IP
bantime  = 1h

# Time window in which maxretry failures must occur
findtime = 10m

# Number of failures before banning
maxretry = 5

# -----------------------------------------------------------------------
# RHEL 10 / firewalld settings
# -----------------------------------------------------------------------
# Use firewalld ipset for banning (recommended for RHEL 10)
banaction = firewallcmd-ipset
banaction_allports = firewallcmd-allports

# Use systemd journal backend for RHEL 10 services
backend = systemd

# -----------------------------------------------------------------------
# Encoding for log files
# -----------------------------------------------------------------------
encoding = UTF-8

# -----------------------------------------------------------------------
# Email notifications (configure in Module 07)
# -----------------------------------------------------------------------
# destemail = admin@example.com
# sendername = Fail2Ban
# mta = sendmail
# action = %(action_mwl)s

# =============================================================================
# JAILS
# =============================================================================

[sshd]
# Protect SSH from brute-force attacks
enabled  = true
port     = ssh
filter   = sshd
# logpath is not needed when backend = systemd
# The journalmatch in filter.d/sshd.conf handles service selection
bantime  = 24h
maxretry = 3

EOF
```

```bash
# Verify syntax is correct
sudo fail2ban-client -t
```

```
OK: configuration test is successful
```

[↑ Back to TOC](#table-of-contents)

---

## 6. The [DEFAULT] Section

The `[DEFAULT]` section in `jail.local` sets values that apply to **every
jail** unless the individual jail overrides them. This is where you set your
RHEL 10-wide defaults.

### Full annotated [DEFAULT] reference

```ini
[DEFAULT]

# ── Whitelist ──────────────────────────────────────────────────────────────
# Space or newline separated list of IPs/CIDRs/hostnames never to ban
ignoreip = 127.0.0.1/8 ::1

# ── Timing ─────────────────────────────────────────────────────────────────
# Supports: s (seconds), m (minutes), h (hours), d (days), w (weeks)
bantime  = 1h      # How long bans last
findtime = 10m     # Sliding window for counting failures
maxretry = 5       # Failures within findtime to trigger ban

# Incremental ban time (bans get longer for repeat offenders)
# bantime.increment  = true
# bantime.multiplier = 2
# bantime.maxtime    = 1w

# ── Ban action (firewalld) ─────────────────────────────────────────────────
banaction          = firewallcmd-ipset        # Default: ban specific ports
banaction_allports = firewallcmd-allports     # Used when port = any

# ── Backend ────────────────────────────────────────────────────────────────
backend = systemd     # Use journald (recommended for RHEL 10)

# ── Protocol ───────────────────────────────────────────────────────────────
protocol = tcp

# ── Chain/Zone (firewalld) ─────────────────────────────────────────────────
# chain = INPUT   # Not used with firewalld actions

# ── Email notifications ────────────────────────────────────────────────────
# destemail  = root@localhost
# sender     = fail2ban@localhost
# mta        = sendmail

# ── Action preset shortcuts ────────────────────────────────────────────────
# action_ = ban only
# action_mw = ban + email
# action_mwl = ban + email + whois + log lines
action = %(action_)s    # Default: ban only, no email
```

### Overriding DEFAULT in individual jails

```ini
[sshd]
enabled  = true
bantime  = 24h      # Override DEFAULT bantime for this jail only
maxretry = 3        # Override DEFAULT maxretry for this jail only
# findtime is inherited from DEFAULT (10m)
# banaction is inherited from DEFAULT (firewallcmd-ipset)
```

[↑ Back to TOC](#table-of-contents)

---

## 7. paths-fedora.conf — RHEL Log Paths

Fail2ban ships with a `paths-fedora.conf` file that pre-defines the correct log
file paths for RHEL/Fedora systems. Many filters reference these path variables
rather than hard-coding file paths.

```bash
cat /etc/fail2ban/paths-fedora.conf
```

```ini
[INCLUDES]
before = paths-common.conf

[DEFAULT]
# SSH authentication log
sshd_log = /var/log/secure

# The failregex also matches journald entries:
sshd_backend = systemd

# Apache/httpd
httpd_log = /var/log/httpd/error_log

# Postfix
postfix_log = /var/log/maillog

# Dovecot
dovecot_log = /var/log/maillog
```

These path variables are referenced in filter files:

```ini
# In filter.d/sshd.conf:
[INCLUDES]
before = common.conf    # loads paths-fedora.conf variables

[DEFAULT]
_daemon = sshd

[Definition]
# Uses %(sshd_log)s variable from paths-fedora.conf
```

> **RHEL 10 note:** On RHEL 10, most services log exclusively to journald.
> The `paths-fedora.conf` values point fail2ban toward `/var/log/secure` for
> compatibility, but the `systemd` backend bypasses this entirely.

[↑ Back to TOC](#table-of-contents)

---

## 8. The jail.d/ Drop-in Directory

Instead of putting everything in `jail.local`, you can place individual jail
files in `/etc/fail2ban/jail.d/`. This is useful for:
- Organising many jails into separate files
- Enabling/disabling specific services without touching a large monolithic file
- Deploying configuration with automation tools (Ansible, Puppet, etc.)

### Example: separate file per service

```bash
# Create a dedicated SSH jail file
sudo tee /etc/fail2ban/jail.d/sshd.local << 'EOF'
[sshd]
enabled  = true
port     = ssh
bantime  = 24h
maxretry = 3
EOF

# Create a dedicated web jail file
sudo tee /etc/fail2ban/jail.d/httpd.local << 'EOF'
[httpd-auth]
enabled  = true
port     = http,https
filter   = httpd-auth
logpath  = /var/log/httpd/error_log
backend  = auto
bantime  = 1h
maxretry = 5
EOF
```

### The 00-firewalld.conf file

When you install `fail2ban-firewalld`, a file is placed at:
```
/etc/fail2ban/jail.d/00-firewalld.conf
```

```bash
cat /etc/fail2ban/jail.d/00-firewalld.conf
```

```ini
[DEFAULT]
banaction = firewallcmd-ipset
banaction_allports = firewallcmd-allports
```

This file sets firewalld as the default ban action for all jails on RHEL 10.
The `00-` prefix ensures it loads first and can be overridden by your files.

[↑ Back to TOC](#table-of-contents)

---

## 9. Configuration Syntax Rules

Fail2ban uses an INI-style configuration format. Key rules:

### Sections
```ini
[sectionname]     # Square brackets, no spaces inside
```

### Key-value pairs
```ini
key = value       # Standard assignment
key   =   value   # Extra spaces are fine
```

### Multi-line values
```ini
# Indent continuation lines with whitespace
ignoreip = 127.0.0.1/8
           ::1
           10.0.0.0/8

# Or use spaces within single line
ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8
```

### Comments
```ini
# Hash comments (preferred)
; Semicolon comments (also valid)
```

### Variable interpolation
```ini
# Define a variable
_my_var = /var/log

# Use it later with %(varname)s syntax
logpath = %(_my_var)s/secure
```

### Time format shortcuts
```ini
bantime = 600     # 600 seconds (plain integer = seconds)
bantime = 10m     # 10 minutes
bantime = 1h      # 1 hour
bantime = 1d      # 1 day
bantime = 1w      # 1 week
bantime = -1      # Permanent
```

### Boolean values
```ini
enabled = true    # or: 1, yes, on
enabled = false   # or: 0, no, off
```

[↑ Back to TOC](#table-of-contents)

---

## 10. Testing Configuration Syntax

Always test your configuration before reloading:

```bash
# Test all configuration files for syntax errors
sudo fail2ban-client -t
```

**Success:**
```
OK: configuration test is successful
```

**Failure example:**
```
ERROR   Failed during configuration: Have not found 'jail' section in configuration.
```

### Common syntax errors and fixes

| Error | Cause | Fix |
|-------|-------|-----|
| `No section: 'DEFAULT'` | Missing `[DEFAULT]` header | Add `[DEFAULT]` at top of jail.local |
| `No option 'filter'` | Jail missing required `filter =` | Add `filter = <filtername>` |
| `Unable to read the filter` | Filter file doesn't exist | Check `/etc/fail2ban/filter.d/` for correct name |
| `'NoneType' object has no attribute` | Empty value for required key | Remove the key or provide a value |

### Verbose testing

```bash
# Show detailed parsing information
sudo fail2ban-client -vvv -t 2>&1 | head -50
```

[↑ Back to TOC](#table-of-contents)

---

## 11. Reloading Configuration

After editing configuration files, you have three options:

### Option 1 — Reload (recommended, no ban disruption)

```bash
sudo fail2ban-client reload
```

Reloads all configuration files **without** stopping the service. Active bans
are preserved. This is the safest option for production systems.

```
OK
```

### Option 2 — Reload a single jail

```bash
sudo fail2ban-client reload sshd
```

Reloads only the `sshd` jail configuration. Other jails are unaffected.

### Option 3 — Restart (clears all bans)

```bash
sudo systemctl restart fail2ban
```

Stops and restarts the service. Active bans in firewalld are removed and
re-applied from the database. Use this only if `reload` doesn't work.

### After any configuration change

```bash
# Test first
sudo fail2ban-client -t

# Then reload
sudo fail2ban-client reload

# Verify the change took effect
sudo fail2ban-client get sshd bantime
sudo fail2ban-client status
```

[↑ Back to TOC](#table-of-contents)

---

## 12. Lab 04 — Build Your First jail.local

In this lab you will create a complete, production-ready `jail.local` from
scratch and verify it works correctly.

### Step 1 — Find your current IP address

Before creating any configuration, whitelist your IP so you don't lock yourself
out:

```bash
# Your current SSH session source IP
echo $SSH_CLIENT | awk '{print $1}'

# Or check your public IP
curl -s https://ifconfig.me
```

Note this IP — you will add it to `ignoreip`.

### Step 2 — Back up any existing jail.local

```bash
[ -f /etc/fail2ban/jail.local ] && \
  sudo cp /etc/fail2ban/jail.local /etc/fail2ban/jail.local.backup
```

### Step 3 — Create the jail.local

Replace `YOUR_IP_HERE` with your actual management IP:

```bash
sudo tee /etc/fail2ban/jail.local << 'EOF'
# =============================================================================
# /etc/fail2ban/jail.local — RHEL 10 baseline configuration
# Created: $(date +%Y-%m-%d)
# =============================================================================

[DEFAULT]
# --- Whitelist (ALWAYS include your management IP) ---
ignoreip = 127.0.0.1/8
           ::1
           YOUR_IP_HERE

# --- Timing ---
bantime  = 1h
findtime = 10m
maxretry = 5

# --- RHEL 10 / firewalld ---
banaction          = firewallcmd-ipset
banaction_allports = firewallcmd-allports
backend            = systemd
encoding           = UTF-8

# --- Default action (ban only, no email) ---
action = %(action_)s

# =============================================================================
[sshd]
enabled  = true
port     = ssh
filter   = sshd
bantime  = 24h
maxretry = 3
EOF
```

### Step 4 — Test the syntax

```bash
sudo fail2ban-client -t
```

**Expected:** `OK: configuration test is successful`

### Step 5 — Reload fail2ban

```bash
sudo fail2ban-client reload
```

**Expected:** `OK`

### Step 6 — Verify the jail is active

```bash
sudo fail2ban-client status
```

```
Status
|- Number of jail:      1
`- Jail list:   sshd
```

```bash
sudo fail2ban-client status sshd
```

### Step 7 — Verify your IP is whitelisted

```bash
sudo fail2ban-client get sshd ignoreip
```

Your IP should appear in the output.

### Step 8 — Check the log for the reload

```bash
sudo tail -10 /var/log/fail2ban.log
```

You should see lines showing the jail was reloaded with your new settings:
```
INFO    Reload jail 'sshd'
INFO    Set banTime = 86400
INFO    Set findTime = 600
INFO    Set maxRetry = 3
INFO    Jail 'sshd' started
```

### Step 9 — Verify the custom bantime took effect

```bash
sudo fail2ban-client get sshd bantime
```

```
86400
```

(1 hour = 3600 seconds... wait, we set 24h = 86400 for sshd)

### Lab Complete ✓

You now have a working `jail.local` that:
- Whitelists your management IP
- Sets sensible RHEL 10 defaults in `[DEFAULT]`
- Has the SSH jail active with stricter-than-default settings
- Uses firewalld for enforcement
- Uses the systemd backend for log monitoring

**Self-check — verify you can answer yes to each:**

- [ ] `sudo fail2ban-client -t` returns `OK: configuration test is successful`
- [ ] `sudo fail2ban-client status sshd` shows `bantime = 86400` (24 hours in seconds)
- [ ] `sudo fail2ban-client get sshd ignoreip` shows your management IP
- [ ] I know the difference between editing `jail.conf` (never) and `jail.local` (always)
- [ ] I can explain why `backend = systemd` is correct for RHEL 10
- [ ] My `fail2ban.local` has `dbpurgeage = 7d` set

[↑ Back to TOC](#table-of-contents)

---

## 13. Summary

In this module you learned:

- The **configuration hierarchy**: `.conf` (package) → `.d/` (drop-ins) → `.local` (yours)
- **`fail2ban.conf`**: global daemon settings — never edit this file
- **`fail2ban.local`**: your global daemon overrides
- **`jail.conf`**: all built-in jail definitions — never edit this file
- **`jail.local`**: your primary configuration file — create and maintain this
- The **`[DEFAULT]` section** and how it applies settings across all jails
- **`paths-fedora.conf`**: pre-defined RHEL/Fedora log paths
- **`jail.d/`**: drop-in directory for per-service jail files
- INI syntax rules including **time format shortcuts** (`1h`, `1d`, etc.)
- How to **test** (`fail2ban-client -t`) and **reload** configuration safely

### Next Steps

Proceed to **[Module 05 — Jails](./05-jails.md)** to explore all the built-in
jails and learn to configure them for your services.

---

| ← Previous | Home | Next → |
|-----------|------|--------|
| [03 — Core Concepts](./03-core-concepts.md) | [Course README](./README.md) | [05 — Jails](./05-jails.md) |
