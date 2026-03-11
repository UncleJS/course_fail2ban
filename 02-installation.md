# Module 02 — Installation on RHEL 10
[![CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey)](./LICENSE.md)
[![RHEL 10](https://img.shields.io/badge/platform-RHEL%2010-red)](https://access.redhat.com/products/red-hat-enterprise-linux)
[![fail2ban](https://img.shields.io/badge/fail2ban-RHEL%2010-red)](https://access.redhat.com/products/red-hat-enterprise-linux)

> **Level:** Beginner  
> **Prerequisites:** [Module 01 — Introduction](./01-introduction.md)  
> **Time to complete:** ~45 minutes

---

## Table of Contents

1. [Pre-Installation Checklist](#1-pre-installation-checklist)
2. [Understanding EPEL](#2-understanding-epel)
3. [Enable the EPEL Repository](#3-enable-the-epel-repository)
4. [Verify firewalld Is Running](#4-verify-firewalld-is-running)
5. [Install Fail2ban](#5-install-fail2ban)
6. [Installed Files Tour](#6-installed-files-tour)
7. [Enable and Start the Service](#7-enable-and-start-the-service)
8. [Verify the Installation](#8-verify-the-installation)
9. [Directory Structure Deep Dive](#9-directory-structure-deep-dive)
10. [Uninstalling Fail2ban](#10-uninstalling-fail2ban)
11. [Lab 02 — Complete Installation Walkthrough](#11-lab-02--complete-installation-walkthrough)
12. [Summary](#12-summary)

---

## 1. Pre-Installation Checklist

Before installing fail2ban, verify your environment is ready:

```bash
# 1. Confirm you are on RHEL 10
cat /etc/redhat-release
```
```
Red Hat Enterprise Linux release 10.0 (Coughlan)
```

```bash
# 2. Confirm you have sudo or root access
sudo whoami
```
```
root
```

```bash
# 3. Confirm internet connectivity (needed to download EPEL and fail2ban)
ping -c 3 8.8.8.8
```

```bash
# 4. Confirm dnf is working
sudo dnf repolist
```

```bash
# 5. Confirm Python 3 is available (fail2ban dependency)
python3 --version
```
```
Python 3.12.x
```

```bash
# 6. Check current disk space (fail2ban is small, ~2MB + Python deps)
df -h /
```

[↑ Back to TOC](#table-of-contents)

---

## 2. Understanding EPEL

**EPEL** (Extra Packages for Enterprise Linux) is a repository maintained by the
Fedora Project that provides high-quality, community-maintained packages not
included in the default RHEL repositories.

Fail2ban is **not** in the default RHEL 10 `BaseOS` or `AppStream` repositories.
It is only available through EPEL.

Key facts about EPEL:
- Maintained by the Fedora community, **backed by Red Hat**
- Packages do not conflict with official RHEL packages
- Free to use, no subscription required
- Widely used in enterprise environments

> **Why isn't fail2ban in base RHEL?**  
> RHEL focuses its base repos on packages that Red Hat directly supports with
> SLAs. Fail2ban is community-supported. EPEL fills this gap.

[↑ Back to TOC](#table-of-contents)

---

## 3. Enable the EPEL Repository

### Option A — Via dnf (recommended)

```bash
sudo dnf install -y epel-release
```

If this fails (EPEL package not found in default repos), use Option B.

### Option B — Via direct RPM URL

```bash
sudo dnf install -y \
  https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm
```

### Verify EPEL is enabled

```bash
sudo dnf repolist | grep epel
```

**Expected output:**
```
epel                Extra Packages for Enterprise Linux 10 - x86_64
```

### Optional — Enable EPEL Next (newer packages)

```bash
sudo dnf install -y epel-next-release
```

### Refresh the package cache

```bash
sudo dnf makecache
```

[↑ Back to TOC](#table-of-contents)

---

## 4. Verify firewalld Is Running

Fail2ban on RHEL 10 uses firewalld to enforce bans. Firewalld **must be running**
before fail2ban starts, or ban actions will fail silently.

```bash
# Check firewalld status
sudo systemctl status firewalld
```

**Expected output:**
```
● firewalld.service - firewalld - dynamic firewall daemon
     Loaded: loaded (/usr/lib/systemd/system/firewalld.service; enabled; preset: enabled)
     Active: active (running) since ...
```

If firewalld is not running:

```bash
# Enable and start firewalld
sudo systemctl enable --now firewalld

# Verify the default zone (usually 'public')
sudo firewall-cmd --get-default-zone
```
```
public
```

```bash
# List current rules to confirm firewalld is functional
sudo firewall-cmd --list-all
```

> **Important:** Do not disable firewalld to "simplify" your setup. Fail2ban
> relies on firewalld to actually block IPs. Without it, fail2ban will detect
> attacks but be unable to stop them.

[↑ Back to TOC](#table-of-contents)

---

## 5. Install Fail2ban

With EPEL enabled and firewalld running, install fail2ban:

```bash
sudo dnf install -y fail2ban
```

**Expected output (abbreviated):**
```
Dependencies resolved.
================================================================================
 Package                Architecture    Version         Repository         Size
================================================================================
Installing:
 fail2ban               noarch          1.1.0-1.el10    epel               17 k
Installing dependencies:
 fail2ban-firewalld     noarch          1.1.0-1.el10    epel               14 k
 fail2ban-server        noarch          1.1.0-1.el10    epel              468 k
 python3-pyinotify      noarch          ...             epel              ...
...

Installed:
  fail2ban-1.1.0-1.el10.noarch
  fail2ban-firewalld-1.1.0-1.el10.noarch
  fail2ban-server-1.1.0-1.el10.noarch
  ...
```

### Understanding the package split

| Package | Purpose |
|---------|---------|
| `fail2ban` | Meta-package, pulls in all components |
| `fail2ban-server` | The core daemon and filters |
| `fail2ban-firewalld` | firewalld-specific action files (critical for RHEL 10) |
| `fail2ban-sendmail` | Email notification actions (optional) |
| `fail2ban-all` | Every optional component |

> **For RHEL 10 with firewalld:** The `fail2ban-firewalld` package is essential.
> It provides the `firewallcmd-ipset.conf` and related action files that
> integrate with firewalld. It is installed automatically when you install
> `fail2ban`.

[↑ Back to TOC](#table-of-contents)

---

## 6. Installed Files Tour

After installation, fail2ban places files in several locations:

```bash
# See everything that was installed
rpm -ql fail2ban-server | head -50
```

### Configuration directory

```bash
ls -la /etc/fail2ban/
```
```
drwxr-xr-x.  6 root root   89 Jan 10 10:00 .
drwxr-xr-x. 84 root root 8192 Jan 10 10:00 ..
drwxr-xr-x.  2 root root   26 Jan 10 10:00 action.d
-rw-r--r--.  1 root root 2359 Jan 10 10:00 fail2ban.conf
drwxr-xr-x.  2 root root    6 Jan 10 10:00 fail2ban.d
-rw-r--r--.  1 root root  23K Jan 10 10:00 jail.conf
drwxr-xr-x.  2 root root    6 Jan 10 10:00 jail.d
drwxr-xr-x.  2 root root 4096 Jan 10 10:00 filter.d
-rw-r--r--.  1 root root  645 Jan 10 10:00 paths-common.conf
-rw-r--r--.  1 root root  573 Jan 10 10:00 paths-fedora.conf
```

### Key subdirectories

```bash
# Action definitions (what to do when banning)
ls /etc/fail2ban/action.d/ | head -10
```
```
firewallcmd-allports.conf
firewallcmd-ipset.conf
firewallcmd-new.conf
firewallcmd-rich-logging.conf
iptables-allports.conf    # (ignore these - we use firewalld)
...
```

```bash
# Filter definitions (what patterns to detect)
ls /etc/fail2ban/filter.d/ | head -10
```
```
apache-auth.conf
dovecot.conf
httpd-auth.conf
nginx-http-auth.conf
postfix.conf
sshd.conf
...
```

### Runtime and data directories

```bash
# Runtime files (created when service starts)
ls /var/run/fail2ban/       # socket and PID file

# Persistent data
ls /var/lib/fail2ban/       # SQLite ban database

# Log file
ls /var/log/fail2ban.log    # created after first start
```

[↑ Back to TOC](#table-of-contents)

---

## 7. Enable and Start the Service

```bash
# Enable fail2ban to start automatically on boot AND start it immediately
sudo systemctl enable --now fail2ban
```
```
Created symlink /etc/systemd/system/multi-user.target.wants/fail2ban.service
→ /usr/lib/systemd/system/fail2ban.service.
```

> **Tip:** `enable --now` is equivalent to running `enable` followed by `start` — it is the preferred one-liner when you want both effects at once. The separate `enable` / `start` form still works if you need them independently (e.g. enabling without starting yet).

```bash
# Check it started successfully
sudo systemctl status fail2ban
```

**Expected output:**
```
● fail2ban.service - Fail2Ban Service
     Loaded: loaded (/usr/lib/systemd/system/fail2ban.service; enabled; preset: disabled)
     Active: active (running) since Thu 2026-01-10 10:05:32 UTC; 5s ago
       Docs: man:fail2ban(1)
    Process: 12345 ExecStartPre=/bin/mkdir -p /run/fail2ban (code=exited, status=0/SUCCESS)
   Main PID: 12346 (fail2ban-server)
      Tasks: 5 (limit: 23452)
     Memory: 24.3M
        CPU: 412ms
     CGroup: /system.slice/fail2ban.service
             └─12346 /usr/bin/python3 /usr/bin/fail2ban-server ...

Jan 10 10:05:32 server systemd[1]: Starting Fail2Ban Service...
Jan 10 10:05:32 server fail2ban-server[12346]: Server ready
Jan 10 10:05:32 server systemd[1]: Started Fail2Ban Service.
```

[↑ Back to TOC](#table-of-contents)

---

## 8. Verify the Installation

Run a series of checks to confirm everything is working:

### Check 1 — Service is active

```bash
systemctl is-active fail2ban
```
```
active
```

### Check 2 — Client can reach the server

```bash
sudo fail2ban-client ping
```
```
Server replied: pong
```

### Check 3 — Check running version

```bash
fail2ban-client --version
```
```
Fail2Ban v1.1.0

Copyright (c) 2004-2008 Cyril Jaquier, 2008- Fail2Ban Contributors
```

### Check 4 — List active jails

```bash
sudo fail2ban-client status
```
```
Status
|- Number of jail:      1
`- Jail list:   sshd
```

> By default on RHEL 10 with the `fail2ban-firewalld` package, the `sshd` jail
> is often pre-enabled. You will configure jails properly in Module 05.

### Check 5 — Check the log

```bash
sudo tail -20 /var/log/fail2ban.log
```
```
2026-01-10 10:05:32,410 fail2ban.server         [12346]: INFO    --------------------------------------------------
2026-01-10 10:05:32,410 fail2ban.server         [12346]: INFO    Starting Fail2ban v1.1.0
2026-01-10 10:05:32,415 fail2ban.database        [12346]: INFO    Connected to fail2ban persistent database '/var/lib/fail2ban/fail2ban.sqlite3'
2026-01-10 10:05:32,520 fail2ban.jail            [12346]: INFO    Creating new jail 'sshd'
2026-01-10 10:05:32,521 fail2ban.jail            [12346]: INFO    Jail 'sshd' uses systemd {}
2026-01-10 10:05:32,530 fail2ban.jail            [12346]: INFO    Initiated 'systemd' backend
2026-01-10 10:05:32,540 fail2ban.actions          [12346]: INFO    Set banAction to 'firewallcmd-ipset'
2026-01-10 10:05:32,550 fail2ban.jail            [12346]: INFO    Jail 'sshd' started
```

### Check 6 — Verify firewalld socket is accessible

```bash
sudo firewall-cmd --state
```
```
running
```

[↑ Back to TOC](#table-of-contents)

---

## 9. Directory Structure Deep Dive

Understanding the directory layout is crucial for configuration:

```
/etc/fail2ban/
│
├── fail2ban.conf          ← Global daemon config (DON'T EDIT)
├── fail2ban.local         ← Your global overrides (CREATE THIS)
├── fail2ban.d/            ← Drop-in global config files
│
├── jail.conf              ← All jail definitions (DON'T EDIT)
├── jail.local             ← Your jail overrides (CREATE THIS)
├── jail.d/                ← Drop-in jail config files
│   └── 00-firewalld.conf  ← firewalld defaults (from fail2ban-firewalld pkg)
│
├── filter.d/              ← Regex filter definitions
│   ├── sshd.conf          ← SSH filter
│   ├── apache-auth.conf   ← Apache filter
│   └── ...                ← Many more built-in filters
│
├── action.d/              ← Ban/unban action scripts
│   ├── firewallcmd-ipset.conf     ← firewalld ipset action (recommended)
│   ├── firewallcmd-new.conf       ← firewalld rich-rules action
│   ├── firewallcmd-allports.conf  ← firewalld block all ports
│   └── ...
│
├── paths-common.conf      ← Log paths for common distros
└── paths-fedora.conf      ← RHEL/Fedora-specific log paths
```

### The Golden Rule: Never Edit `.conf` Files

The `.conf` files are **owned by the package**. When fail2ban is updated, they
will be overwritten and your changes will be lost.

Always create `.local` counterparts:

| Edit this... | Never edit this... |
|-------------|--------------------|
| `/etc/fail2ban/fail2ban.local` | `/etc/fail2ban/fail2ban.conf` |
| `/etc/fail2ban/jail.local` | `/etc/fail2ban/jail.conf` |
| `/etc/fail2ban/filter.d/sshd.local` | `/etc/fail2ban/filter.d/sshd.conf` |
| `/etc/fail2ban/action.d/firewallcmd-ipset.local` | `/etc/fail2ban/action.d/firewallcmd-ipset.conf` |

### Configuration Load Order

Fail2ban loads configuration in this order (later files override earlier ones):

```
1. /etc/fail2ban/fail2ban.conf
2. /etc/fail2ban/fail2ban.d/*.conf  (alphabetical)
3. /etc/fail2ban/fail2ban.local
4. /etc/fail2ban/fail2ban.d/*.local (alphabetical)
```

Same pattern applies to `jail.conf` → `jail.d/` → `jail.local`.

[↑ Back to TOC](#table-of-contents)

---

## 10. Uninstalling Fail2ban

If you need to remove fail2ban (e.g., to start over):

```bash
# Stop and disable the service first
sudo systemctl stop fail2ban
sudo systemctl disable fail2ban

# Remove the package (keeps config files)
sudo dnf remove fail2ban

# Remove config files too (complete wipe)
sudo rm -rf /etc/fail2ban/

# Remove runtime and data files
sudo rm -rf /var/lib/fail2ban/
sudo rm -f /var/log/fail2ban.log
```

> **Note:** `dnf remove fail2ban` by default keeps your configuration files
> in `/etc/fail2ban/`. This is intentional — it allows you to reinstall and
> pick up where you left off. Use `rm -rf` only if you want a clean slate.

[↑ Back to TOC](#table-of-contents)

---

## 11. Lab 02 — Complete Installation Walkthrough

In this lab you will perform a complete installation from scratch and verify
every component is working.

### Step 1 — Record your starting state

```bash
# Document current state before installation
echo "=== Pre-installation state ===" 
rpm -q fail2ban 2>/dev/null || echo "fail2ban: NOT installed"
rpm -q epel-release 2>/dev/null || echo "epel-release: NOT installed"
sudo systemctl is-active firewalld && echo "firewalld: running" || echo "firewalld: NOT running"
```

### Step 2 — Enable EPEL

```bash
sudo dnf install -y epel-release
sudo dnf makecache
sudo dnf repolist | grep epel
```

**Checkpoint:** You should see `epel` in the repolist output.

### Step 3 — Install fail2ban

```bash
sudo dnf install -y fail2ban
```

**Checkpoint:** Command exits with `Complete!`

### Step 4 — Verify firewalld

```bash
sudo systemctl status firewalld --no-pager
sudo firewall-cmd --get-default-zone
```

**Checkpoint:** firewalld shows `active (running)`.

### Step 5 — Start fail2ban

```bash
sudo systemctl enable --now fail2ban
sudo systemctl status fail2ban --no-pager
```

**Checkpoint:** fail2ban shows `active (running)`.

### Step 6 — Run all verification checks

```bash
# Ping the server
sudo fail2ban-client ping

# Check version
fail2ban-client --version

# Check jails
sudo fail2ban-client status

# Check log
sudo tail -5 /var/log/fail2ban.log

# Check firewalld can be called
sudo firewall-cmd --state
```

### Step 7 — Document installed packages

```bash
rpm -qa | grep fail2ban
```

**Expected:**
```
fail2ban-1.1.0-1.el10.noarch
fail2ban-firewalld-1.1.0-1.el10.noarch
fail2ban-server-1.1.0-1.el10.noarch
```

### Step 8 — Explore the directory structure

```bash
find /etc/fail2ban -type f | sort
```

Take a moment to note the number of filter files and action files installed.

### Lab Complete ✓

You now have a working fail2ban installation. The default configuration has the
`sshd` jail active, which is already protecting your SSH service.

**Self-check — verify you can answer yes to each:**

- [ ] `fail2ban-client ping` returns `pong`
- [ ] `fail2ban-client --version` shows the installed version
- [ ] `systemctl is-active fail2ban` returns `active`
- [ ] `fail2ban-client status` shows `sshd` in the jail list
- [ ] `firewall-cmd --get-ipsets` lists the `fail2ban-sshd` ipset
- [ ] I can locate `/etc/fail2ban/jail.local` (or know it needs to be created)

[↑ Back to TOC](#table-of-contents)

---

## 12. Summary

In this module you:

- Confirmed your RHEL 10 system was ready for installation
- Learned about EPEL and why fail2ban requires it
- Enabled the EPEL repository
- Verified firewalld was running (a prerequisite for fail2ban on RHEL 10)
- Installed the `fail2ban`, `fail2ban-server`, and `fail2ban-firewalld` packages
- Explored the installed file structure
- Enabled and started the `fail2ban.service`
- Verified all components are working
- Learned the **Golden Rule**: always use `.local` files, never edit `.conf`
- Understood the configuration load order

### Next Steps

Proceed to **[Module 03 — Core Concepts](./03-core-concepts.md)** to understand
the terminology and building blocks you will configure throughout this course.

[↑ Back to TOC](#table-of-contents)

---

| ← Previous | Home | Next → |
|-----------|------|--------|
| [01 — Introduction](./01-introduction.md) | [Course README](./README.md) | [03 — Core Concepts](./03-core-concepts.md) |

---

*Licensed under [CC BY-NC-SA 4.0](LICENSE.md) · © 2026 UncleJS*