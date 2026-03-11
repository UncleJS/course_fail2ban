# Module 05 — Jails
[![CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey)](./LICENSE.md)
[![RHEL 10](https://img.shields.io/badge/platform-RHEL%2010-red)](https://access.redhat.com/products/red-hat-enterprise-linux)
[![fail2ban](https://img.shields.io/badge/fail2ban-RHEL%2010-red)](https://access.redhat.com/products/red-hat-enterprise-linux)

> **Level:** Intermediate  
> **Prerequisites:** [Module 04 — Configuration Basics](./04-configuration-basics.md)  
> **Time to complete:** ~60 minutes

---

## Table of Contents

1. [What Is a Jail?](#1-what-is-a-jail)
2. [Built-in Jails Overview](#2-built-in-jails-overview)
3. [Enabling the SSH Jail](#3-enabling-the-ssh-jail)
4. [Enabling the Apache/httpd Jail](#4-enabling-the-apachehttpd-jail)
5. [Enabling the Nginx Jail](#5-enabling-the-nginx-jail)
6. [Enabling the Postfix Mail Jail](#6-enabling-the-postfix-mail-jail)
7. [Enabling the Dovecot Jail](#7-enabling-the-dovecot-jail)
8. [Multi-Port Jails](#8-multi-port-jails)
9. [Jail Status and Monitoring Commands](#9-jail-status-and-monitoring-commands)
10. [Manually Banning and Unbanning IPs](#10-manually-banning-and-unbanning-ips)
11. [Per-Jail Overrides](#11-per-jail-overrides)
12. [Lab 05 — Enable and Test Multiple Jails](#12-lab-05--enable-and-test-multiple-jails)
13. [Summary](#13-summary)

---

## 1. What Is a Jail?

A jail is the top-level unit of fail2ban configuration. Each jail:

- **Monitors one service** (SSH, Apache, Nginx, Postfix, etc.)
- **References one filter** (the detection rules in `filter.d/`)
- **References one or more actions** (what to do when banning)
- Has **independent timing parameters** (`bantime`, `findtime`, `maxretry`)
- Can be **enabled or disabled** independently

Think of a jail as a complete "intrusion prevention policy" for one service.

### Minimal jail structure

```ini
[jail-name]
enabled  = true       # Must be true to activate
port     = ssh        # Port(s) the action will block
filter   = sshd       # File in filter.d/ (without .conf extension)
logpath  = ...        # Only needed for file-based backends
maxretry = 5
bantime  = 1h
findtime = 10m
```

[↑ Back to TOC](#table-of-contents)

---

## 2. Built-in Jails Overview

Fail2ban ships with jails for dozens of common services. All are disabled by
default. Here are the most commonly used ones on RHEL 10:

| Jail Name | Service | Filter File | Log Source |
|-----------|---------|-------------|------------|
| `sshd` | OpenSSH | `sshd.conf` | journald / `/var/log/secure` |
| `httpd-auth` | Apache httpd | `httpd-auth.conf` | `/var/log/httpd/error_log` |
| `apache-badbots` | Apache httpd | `apache-badbots.conf` | `/var/log/httpd/access_log` |
| `apache-noscript` | Apache httpd | `apache-noscript.conf` | `/var/log/httpd/access_log` |
| `nginx-http-auth` | Nginx | `nginx-http-auth.conf` | `/var/log/nginx/error.log` |
| `nginx-botsearch` | Nginx | `nginx-botsearch.conf` | `/var/log/nginx/error.log` |
| `postfix` | Postfix MTA | `postfix.conf` | journald / `/var/log/maillog` |
| `postfix-sasl` | Postfix SASL | `postfix-sasl.conf` | journald / `/var/log/maillog` |
| `dovecot` | Dovecot IMAP/POP3 | `dovecot.conf` | journald / `/var/log/maillog` |
| `mysqld-auth` | MySQL / MariaDB | `mysqld-auth.conf` | `/var/log/mysqld.log` |
| `recidive` | Fail2ban itself | `recidive.conf` | `/var/log/fail2ban.log` |
| `vsftpd` | vsftpd | `vsftpd.conf` | `/var/log/vsftpd.log` |
| `proftpd` | ProFTPD | `proftpd.conf` | `/var/log/proftpd/proftpd.log` |

### View all available jails

```bash
grep '^\[' /etc/fail2ban/jail.conf | grep -v '^\[DEFAULT\]' | tr -d '[]' | sort
```

[↑ Back to TOC](#table-of-contents)

---

## 3. Enabling the SSH Jail

The SSH jail is the most commonly used jail. On RHEL 10 it uses the systemd
backend to read directly from journald.

### Add to jail.local

```ini
[sshd]
enabled  = true
port     = ssh
filter   = sshd
# No logpath needed — systemd backend reads journald directly
bantime  = 24h
findtime = 10m
maxretry = 3
```

### What the sshd filter detects

The `filter.d/sshd.conf` filter matches log entries like:

```
Failed password for root from 185.220.101.5 port 44312 ssh2
Failed password for invalid user admin from 45.33.32.156 port 55123 ssh2
Invalid user postgres from 103.99.0.122 port 39456
authentication failure; ... rhost=194.165.16.72
```

### Verify after reload

```bash
sudo fail2ban-client reload sshd
sudo fail2ban-client status sshd
```

```
Status for the jail: sshd
|- Filter
|  |- Currently failed: 0
|  |- Total failed:     0
|  `- Journal matches:  _SYSTEMD_UNIT=sshd.service + _COMM=sshd
`- Actions
   |- Currently banned: 0
   |- Total banned:     0
   `- Banned IP list:
```

### SSH on a non-standard port

If SSH runs on a custom port (e.g., 2222):

```ini
[sshd]
enabled  = true
port     = 2222
filter   = sshd
bantime  = 24h
maxretry = 3
```

[↑ Back to TOC](#table-of-contents)

---

## 4. Enabling the Apache/httpd Jail

Apache (httpd) on RHEL 10 writes logs to `/var/log/httpd/`. Multiple jails
protect different attack vectors.

### Basic auth brute-force protection

```ini
[httpd-auth]
enabled  = true
port     = http,https
filter   = httpd-auth
logpath  = /var/log/httpd/error_log
backend  = auto
bantime  = 1h
maxretry = 5
```

### Scanner / bad bot protection

```ini
[apache-badbots]
enabled  = true
port     = http,https
filter   = apache-badbots
logpath  = /var/log/httpd/access_log
backend  = auto
bantime  = 48h
maxretry = 2
```

### Script injection scanner protection

```ini
[apache-noscript]
enabled  = true
port     = http,https
filter   = apache-noscript
logpath  = /var/log/httpd/access_log
backend  = auto
bantime  = 1h
maxretry = 6
```

### 404 flood protection

```ini
[apache-404]
enabled  = true
port     = http,https
filter   = apache-botsearch
logpath  = /var/log/httpd/access_log
backend  = auto
bantime  = 1h
maxretry = 300
findtime = 300
```

> **Note:** For Apache jails, the `backend` must be set to `auto` (file-based)
> since Apache writes to flat files, not journald. Ensure httpd is installed
> and log files exist before enabling these jails.

[↑ Back to TOC](#table-of-contents)

---

## 5. Enabling the Nginx Jail

Nginx on RHEL 10 writes to `/var/log/nginx/`.

```ini
[nginx-http-auth]
enabled  = true
port     = http,https
filter   = nginx-http-auth
logpath  = /var/log/nginx/error.log
backend  = auto
bantime  = 1h
maxretry = 5

[nginx-botsearch]
enabled  = true
port     = http,https
filter   = nginx-botsearch
logpath  = /var/log/nginx/error.log
backend  = auto
bantime  = 1h
maxretry = 2
```

[↑ Back to TOC](#table-of-contents)

---

## 6. Enabling the Postfix Mail Jail

Postfix on RHEL 10 logs to journald and `/var/log/maillog`.

```ini
[postfix]
enabled  = true
port     = smtp,465,submission
filter   = postfix
# Use journald backend for Postfix on RHEL 10
backend  = systemd
bantime  = 1h
maxretry = 5

[postfix-sasl]
enabled  = true
port     = smtp,465,submission,imap,imaps,pop3,pop3s
filter   = postfix-sasl
backend  = systemd
bantime  = 1h
maxretry = 5
```

> **Note:** `postfix-sasl` catches SASL authentication failures which are
> common in mail server brute-force attacks. Always enable this alongside
> the main postfix jail.

[↑ Back to TOC](#table-of-contents)

---

## 7. Enabling the Dovecot Jail

Dovecot provides IMAP/POP3 services and is a frequent target:

```ini
[dovecot]
enabled  = true
port     = pop3,pop3s,imap,imaps,submission,465,sieve
filter   = dovecot
backend  = systemd
bantime  = 1h
maxretry = 5
```

[↑ Back to TOC](#table-of-contents)

---

## 8. Multi-Port Jails

When you want to ban an IP from multiple ports simultaneously, list them
comma-separated in the `port` parameter:

```ini
# Ban from all mail-related ports
[postfix-all]
enabled  = true
port     = smtp,465,submission,imap,imaps,pop3,pop3s
filter   = postfix-sasl
backend  = systemd
bantime  = 24h
maxretry = 3
```

### Using port numbers instead of names

```ini
port = 25,465,587,143,993,110,995
```

### Blocking ALL ports

Use `banaction_allports` when you want to completely cut off the attacker:

```ini
[sshd-aggressive]
enabled          = true
port             = any
filter           = sshd
banaction        = firewallcmd-allports
bantime          = 24h
maxretry         = 3
```

This uses `firewallcmd-allports` instead of `firewallcmd-ipset`, which creates
a firewalld rule blocking ALL traffic from the banned IP, not just on SSH port.

[↑ Back to TOC](#table-of-contents)

---

## 9. Jail Status and Monitoring Commands

### Global status — all jails

```bash
sudo fail2ban-client status
```

```
Status
|- Number of jail:      3
`- Jail list:   sshd, httpd-auth, postfix-sasl
```

### Per-jail status

```bash
sudo fail2ban-client status sshd
```

```
Status for the jail: sshd
|- Filter
|  |- Currently failed: 2
|  |- Total failed:     157
|  `- Journal matches:  _SYSTEMD_UNIT=sshd.service + _COMM=sshd
`- Actions
   |- Currently banned: 4
   |- Total banned:     23
   `- Banned IP list:   185.220.101.5 45.33.32.156 103.99.0.122 194.165.16.72
```

### Get specific jail settings

```bash
sudo fail2ban-client get sshd bantime
sudo fail2ban-client get sshd findtime
sudo fail2ban-client get sshd maxretry
sudo fail2ban-client get sshd ignoreip
sudo fail2ban-client get sshd filter
sudo fail2ban-client get sshd actions
```

### Watch the log in real time

```bash
sudo tail -f /var/log/fail2ban.log
```

```
2026-01-10 10:15:42,001 fail2ban.filter   [12346]: INFO    [sshd] Found 185.220.101.5 - 2026-01-10 10:15:41
2026-01-10 10:15:43,002 fail2ban.filter   [12346]: INFO    [sshd] Found 185.220.101.5 - 2026-01-10 10:15:42
2026-01-10 10:15:44,003 fail2ban.filter   [12346]: INFO    [sshd] Found 185.220.101.5 - 2026-01-10 10:15:43
2026-01-10 10:15:45,004 fail2ban.actions  [12346]: NOTICE  [sshd] Ban 185.220.101.5
```

[↑ Back to TOC](#table-of-contents)

---

## 10. Manually Banning and Unbanning IPs

Sometimes you need to manually manage bans outside of the automated process.

### Manually ban an IP

```bash
sudo fail2ban-client set sshd banip 185.220.101.5
```

```
1
```

### Manually unban an IP

```bash
sudo fail2ban-client set sshd unbanip 185.220.101.5
```

```
1
```

### Unban an IP from ALL jails at once

```bash
# Useful if you accidentally banned your own IP
for jail in $(sudo fail2ban-client status | grep "Jail list" | sed 's/.*:\s*//' | tr ',' ' '); do
  sudo fail2ban-client set "$jail" unbanip YOUR_IP 2>/dev/null
done
```

### Check if a specific IP is banned

```bash
sudo fail2ban-client status sshd | grep "Banned IP"
# or
sudo fail2ban-client get sshd banip
```

### Flush all bans in a jail

```bash
# Get all banned IPs
JAIL="sshd"
BANNED=$(sudo fail2ban-client status $JAIL | grep "Banned IP" | sed 's/.*:\s*//')
for ip in $BANNED; do
  sudo fail2ban-client set $JAIL unbanip $ip
done
```

[↑ Back to TOC](#table-of-contents)

---

## 11. Per-Jail Overrides

Every jail can override any `[DEFAULT]` setting. This allows fine-grained
control:

### SSH — strict settings

```ini
[sshd]
enabled  = true
port     = ssh
filter   = sshd
bantime  = 7d        # 7 days (much stricter than DEFAULT 1h)
findtime = 5m        # Shorter window
maxretry = 3         # Only 3 attempts
```

### Web login — more lenient

```ini
[httpd-auth]
enabled  = true
port     = http,https
filter   = httpd-auth
logpath  = /var/log/httpd/error_log
backend  = auto
bantime  = 1h        # Short ban (user might have forgotten password)
findtime = 10m
maxretry = 10        # More attempts allowed before ban
```

### Override the ban action per jail

```ini
[sshd]
enabled   = true
port      = ssh
filter    = sshd
# Use allports ban for SSH attackers (block everything from them)
banaction = firewallcmd-allports
bantime   = 7d
maxretry  = 3
```

### Override ignoreip per jail

```ini
[sshd]
enabled  = true
# This jail also allows the backup server IP
ignoreip = 127.0.0.1/8 ::1 10.0.0.0/8 192.168.10.50
```

[↑ Back to TOC](#table-of-contents)

---

## 12. Lab 05 — Enable and Test Multiple Jails

### Step 1 — Check available services

```bash
# Determine which services are running on your system
systemctl is-active sshd httpd nginx postfix dovecot 2>/dev/null
```

### Step 2 — Add multiple jails to jail.local

Add to your existing `/etc/fail2ban/jail.local`:

```bash
sudo tee -a /etc/fail2ban/jail.local << 'EOF'

# ─── Additional jails ─────────────────────────────────────────────────────────

[httpd-auth]
enabled  = true
port     = http,https
filter   = httpd-auth
logpath  = /var/log/httpd/error_log
backend  = auto
bantime  = 1h
maxretry = 5
# Only enable if httpd is running and log file exists

[postfix-sasl]
enabled  = true
port     = smtp,465,submission
filter   = postfix-sasl
backend  = systemd
bantime  = 1h
maxretry = 5
# Only enable if postfix is running
EOF
```

### Step 3 — Test and reload

```bash
sudo fail2ban-client -t && sudo fail2ban-client reload
```

### Step 4 — Check all jails are running

```bash
sudo fail2ban-client status
```

### Step 5 — Test manual ban/unban cycle

```bash
# Create a test IP ban in sshd jail
TEST_IP="203.0.113.99"   # RFC 5737 test IP (safe to use)
sudo fail2ban-client set sshd banip $TEST_IP

# Verify it's in the banned list
sudo fail2ban-client status sshd | grep "Banned IP"

# Verify it's in firewalld
sudo firewall-cmd --info-ipset=fail2ban-sshd 2>/dev/null | grep $TEST_IP

# Unban it
sudo fail2ban-client set sshd unbanip $TEST_IP

# Verify it's gone
sudo fail2ban-client status sshd | grep "Banned IP"
```

### Step 6 — Read the log

```bash
sudo grep "203.0.113.99" /var/log/fail2ban.log
```

You should see both a `Ban` and an `Unban` entry.

### Lab Complete ✓

**Self-check — verify you can answer yes to each:**

- [ ] `fail2ban-client status` lists more than one jail
- [ ] I can run `fail2ban-client status <jailname>` for each enabled jail and read the output
- [ ] I manually banned an IP with `fail2ban-client set sshd banip <IP>` and saw it in `firewall-cmd --info-ipset`
- [ ] I manually unbanned the IP and confirmed it was removed from the ipset
- [ ] I understand when to use `backend = systemd` (journald) vs `backend = auto` (flat files)
- [ ] I found a `Ban` + `Unban` pair for the test IP in the fail2ban log

[↑ Back to TOC](#table-of-contents)

---

## 13. Summary

In this module you learned:

- What a **jail** is and what parameters it contains
- The **built-in jails** available on RHEL 10 and which services they protect
- How to enable the most common jails: **sshd, httpd-auth, nginx, postfix, dovecot**
- When to use `systemd` backend (journald services) vs `auto` backend (flat files)
- **Multi-port jails** and how to block all ports from an attacker
- All the **monitoring commands**: `fail2ban-client status`, per-jail status, log tailing
- How to **manually ban and unban** IPs
- How to **override DEFAULT settings** per individual jail

### Next Steps

Proceed to **[Module 06 — Filters](./06-filters.md)** to understand how the
detection rules work and how to test and tune them.

[↑ Back to TOC](#table-of-contents)

---

| ← Previous | Home | Next → |
|-----------|------|--------|
| [04 — Configuration Basics](./04-configuration-basics.md) | [Course README](./README.md) | [06 — Filters](./06-filters.md) |

---

*Licensed under [CC BY-NC-SA 4.0](LICENSE.md) · © 2026 UncleJS*