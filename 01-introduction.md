# Module 01 — Introduction to Fail2ban

> **Level:** Beginner  
> **Prerequisites:** None  
> **Time to complete:** ~30 minutes

---

## Table of Contents

1. [What Is Fail2ban?](#1-what-is-fail2ban)
2. [The Problem It Solves](#2-the-problem-it-solves)
3. [How Fail2ban Works — The Big Picture](#3-how-fail2ban-works--the-big-picture)
4. [Fail2ban in the RHEL 10 Security Stack](#4-fail2ban-in-the-rhel-10-security-stack)
5. [What Fail2ban Is NOT](#5-what-fail2ban-is-not)
6. [Core Terminology Preview](#6-core-terminology-preview)
7. [Real-World Use Cases](#7-real-world-use-cases)
8. [Architecture Overview](#8-architecture-overview)
9. [Lab 01 — Observe a Brute-Force Attack in the Wild](#9-lab-01--observe-a-brute-force-attack-in-the-wild)
10. [Summary](#10-summary)

---

## 1. What Is Fail2ban?

Fail2ban is an **intrusion prevention framework** written in Python. It monitors
log files (or the systemd journal) for patterns that indicate malicious behaviour
— such as repeated failed login attempts — and automatically instructs your
firewall to block the offending IP address for a configurable period of time.

It was first released in 2004 and is now a standard tool in the Linux
security toolkit. On RHEL 10 it integrates natively with:

- **firewalld** — to actually block IPs at the network layer
- **systemd / journald** — to monitor service logs without polling flat files
- **SELinux** — which must be aware of what fail2ban is allowed to do

Key facts:
- Written in **Python 3**
- Runs as a **background daemon** (`fail2ban.service`)
- Controlled via a **client/server model** (`fail2ban-client` ↔ `fail2ban-server`)
- Configuration is **plain text** (INI-style `.conf` / `.local` files)
- Completely **free and open source** (GPLv2)

[↑ Back to TOC](#table-of-contents)

---

## 2. The Problem It Solves

Every server exposed to the internet faces a constant stream of automated
attacks. The most common is the **brute-force login attack**:

```
Jan 10 03:14:01 server sshd[1234]: Failed password for root from 185.220.101.5 port 44312 ssh2
Jan 10 03:14:02 server sshd[1234]: Failed password for root from 185.220.101.5 port 44313 ssh2
Jan 10 03:14:03 server sshd[1234]: Failed password for root from 185.220.101.5 port 44314 ssh2
Jan 10 03:14:04 server sshd[1234]: Failed password for root from 185.220.101.5 port 44315 ssh2
... (hundreds more per minute)
```

Without fail2ban:
- Your server wastes CPU and memory handling each attempt
- Logs fill up with noise, hiding real problems
- The attacker keeps trying indefinitely — potentially for days
- If they guess correctly, your system is compromised

With fail2ban:
- After N failed attempts within a time window, the IP is **automatically banned**
- The firewall drops all packets from that IP — no more SSH handshakes, no CPU waste
- The ban lifts automatically after a configurable duration
- You get a log entry and optionally an email alert for every ban

[↑ Back to TOC](#table-of-contents)

---

## 3. How Fail2ban Works — The Big Picture

Fail2ban operates in a continuous loop:

```
┌─────────────────────────────────────────────────────────┐
│                    FAIL2BAN DAEMON                       │
│                                                         │
│  ┌──────────┐    ┌──────────┐    ┌──────────────────┐  │
│  │  MONITOR │    │  FILTER  │    │     ACTION       │  │
│  │          │───►│          │───►│                  │  │
│  │ Watch    │    │ Apply    │    │ Tell firewalld   │  │
│  │ log file │    │ regex    │    │ to block the IP  │  │
│  │ or       │    │ patterns │    │                  │  │
│  │ journald │    │ extract  │    │ Send email alert │  │
│  │          │    │ IP addr  │    │ Run custom script│  │
│  └──────────┘    └──────────┘    └──────────────────┘  │
└─────────────────────────────────────────────────────────┘
         │                │                  │
         ▼                ▼                  ▼
    /var/log/        Regex in           firewall-cmd
    secure or        filter.d/          --add-rich-rule
    journald         sshd.conf
```

Step-by-step:

1. **Monitor** — fail2ban watches a log source (a file or the systemd journal)
   for new entries in real time.

2. **Filter** — each new log line is tested against a set of regular expressions
   defined in a *filter*. If a line matches, fail2ban extracts the source IP
   address from a named capture group called `<HOST>`.

3. **Count** — fail2ban counts how many matching lines came from the same IP
   within a sliding time window (`findtime`).

4. **Ban** — when the count reaches the threshold (`maxretry`), fail2ban
   triggers an *action*. On RHEL 10 this means calling `firewall-cmd` to add a
   rule that drops all traffic from that IP.

5. **Unban** — after `bantime` seconds have elapsed, fail2ban calls the unban
   action to remove the firewall rule and the IP can connect again.

[↑ Back to TOC](#table-of-contents)

---

## 4. Fail2ban in the RHEL 10 Security Stack

RHEL 10 ships with a layered security model. Fail2ban sits at the **detection
and dynamic response** layer:

```
┌──────────────────────────────────────────────────────────┐
│                  RHEL 10 SECURITY LAYERS                 │
├──────────────────────────────────────────────────────────┤
│  SELinux          Mandatory access control on every file │
│                   and process — always active            │
├──────────────────────────────────────────────────────────┤
│  firewalld        Stateful packet filtering — zones,     │
│                   rich rules, ipsets                     │
├──────────────────────────────────────────────────────────┤
│  FAIL2BAN  ◄───   Dynamic IP banning based on log        │  ← YOU ARE HERE
│                   analysis — talks to firewalld          │
├──────────────────────────────────────────────────────────┤
│  auditd           Kernel-level audit logging             │
├──────────────────────────────────────────────────────────┤
│  OpenSSH config   Rate limiting, key-only auth, etc.     │
└──────────────────────────────────────────────────────────┘
```

Fail2ban **does not replace** any of these layers — it complements them. The
recommended RHEL 10 posture is to have all layers active simultaneously.

[↑ Back to TOC](#table-of-contents)

---

## 5. What Fail2ban Is NOT

Understanding limitations prevents misuse:

| Fail2ban IS | Fail2ban IS NOT |
|-------------|-----------------|
| A log-analysis and dynamic ban tool | A stateful firewall |
| Reactive (responds to attempts) | Proactive (cannot predict attacks) |
| Good at stopping brute-force | Not a replacement for strong passwords/keys |
| Effective against single-IP attackers | Less effective against distributed botnets (many IPs) |
| Easy to automate | Not a SIEM or full IDS/IPS system |
| Lightweight and low-resource | Not a WAF (Web Application Firewall) |
| Designed for traditional Linux services | Not a container security tool |

**Important:** Fail2ban works *after* a connection attempt reaches your server.
For SSH, the best first line of defence is still:
- Key-based authentication only (disable password auth)
- Non-standard port (security through obscurity, but reduces noise)
- Fail2ban as a second layer for anything that gets through

> **Container / Podman note:** This course covers fail2ban on a **bare-metal or
> virtual machine RHEL 10 host** running systemd-managed services. Fail2ban can
> protect a host that *runs* containers (e.g., a Podman host), but it does **not**
> run inside containers itself and cannot protect container-internal services
> directly. Container-specific security (seccomp, SELinux labels, network policies,
> rootless Podman isolation) is outside the scope of this course.

[↑ Back to TOC](#table-of-contents)

---

## 6. Core Terminology Preview

These terms will be explained in depth in Module 03. Here they are introduced
so you recognise them throughout this course:

| Term | One-Line Definition |
|------|---------------------|
| **Jail** | A monitoring rule: which service to watch, which filter to use, what action to take |
| **Filter** | A set of regex patterns that identify bad behaviour in logs |
| **Action** | What happens when a ban threshold is crossed (e.g., firewall-cmd block) |
| **Backend** | How fail2ban reads logs (`systemd` for journald, `auto`/`polling` for files) |
| **bantime** | How long (in seconds) a banned IP stays blocked |
| **findtime** | The sliding time window in which maxretry failures must occur |
| **maxretry** | Number of filter matches from one IP before a ban is triggered |
| **ignoreip** | A whitelist of IPs/CIDRs that will never be banned |

[↑ Back to TOC](#table-of-contents)

---

## 7. Real-World Use Cases

Fail2ban can protect any service that writes authentication or access logs:

### SSH (most common)
Block IPs that repeatedly fail SSH logins. This is enabled by default in most
configurations and is the primary reason most admins install fail2ban.

### Web Servers (Apache / Nginx)
- Block IPs probing for WordPress login pages (`/wp-login.php`)
- Block IPs triggering 404 floods (scanner behaviour)
- Block IPs attempting HTTP basic auth brute-force

### Mail Servers (Postfix / Dovecot)
- Block IPs with repeated SASL authentication failures
- Block IPs triggering too many invalid recipients (dictionary harvesting)

### FTP / SFTP
Block IPs with repeated failed FTP logins.

### Custom Applications
Any application that writes structured log entries with IP addresses can be
protected by writing a custom filter (covered in Module 09).

### Recidive (Repeat Offenders)
A special meta-jail that reads fail2ban's own log and applies a **much longer**
ban to IPs that get banned repeatedly — essentially an escalating penalty system.

[↑ Back to TOC](#table-of-contents)

---

## 8. Architecture Overview

Fail2ban uses a **client/server architecture** within a single host:

```
┌─────────────────────────────────────────────────────────────┐
│                         HOST SYSTEM                         │
│                                                             │
│  ┌──────────────┐   Unix socket   ┌────────────────────┐   │
│  │ fail2ban-    │◄───────────────►│  fail2ban-server   │   │
│  │ client       │  /var/run/      │                    │   │
│  │              │  fail2ban/      │  Monitors logs     │   │
│  │ (your CLI    │  fail2ban.sock  │  Applies filters   │   │
│  │  commands)   │                 │  Manages bans      │   │
│  └──────────────┘                 │  Calls actions     │   │
│                                   └────────┬───────────┘   │
│                                            │               │
│                          ┌─────────────────┼──────────┐    │
│                          ▼                 ▼          ▼    │
│                    ┌──────────┐    ┌──────────┐  ┌──────┐  │
│                    │journald /│    │firewalld │  │SQLite│  │
│                    │log files │    │(firewall │  │  DB  │  │
│                    │          │    │  rules)  │  │      │  │
│                    └──────────┘    └──────────┘  └──────┘  │
└─────────────────────────────────────────────────────────────┘
```

**fail2ban-server** is the daemon process. It:
- Runs as a background service (`fail2ban.service`)
- Does all the actual work: log monitoring, filtering, ban management
- Persists ban state to an SQLite database

**fail2ban-client** is the CLI tool you use to:
- Send commands to the running server
- Query status (which IPs are currently banned)
- Manually ban/unban IPs
- Reload configuration
- Test configuration syntax

They communicate through a Unix domain socket at
`/var/run/fail2ban/fail2ban.sock`.

[↑ Back to TOC](#table-of-contents)

---

## 9. Lab 01 — Observe a Brute-Force Attack in the Wild

This lab requires no fail2ban installation. Its purpose is to show you what
fail2ban will eventually respond to.

### Prerequisites
- A RHEL 10 server with SSH accessible from the internet (or a local test VM)
- Root or sudo access

### Step 1 — Check your SSH auth log

On RHEL 10, SSH authentication events go to the systemd journal:

```bash
sudo journalctl -u sshd --since "1 hour ago" | grep "Failed password"
```

**Expected output** (on any internet-facing server):
```
Jan 10 03:14:01 server sshd[1234]: Failed password for root from 185.220.101.5 port 44312 ssh2
Jan 10 03:14:02 server sshd[1234]: Failed password for root from 185.220.101.5 port 44313 ssh2
```

If your server has been up for any length of time with SSH exposed, you will
almost certainly see entries like these.

### Step 2 — Count unique attacking IPs

```bash
sudo journalctl -u sshd --since "24 hours ago" \
  | grep "Failed password" \
  | awk '{print $(NF-3)}' \
  | sort | uniq -c | sort -rn | head -20
```

**Expected output:**
```
    847 185.220.101.5
    312 45.33.32.156
    201 103.99.0.122
     88 194.165.16.72
```

This shows you the top attacking IPs and their attempt counts. These are exactly
the IPs fail2ban would have banned automatically.

### Step 3 — Check the traditional auth log (if available)

Some RHEL configurations also write to `/var/log/secure`:

```bash
sudo tail -50 /var/log/secure | grep "Failed"
```

### Step 4 — Understand the noise

Count total failed attempts in 24 hours:

```bash
sudo journalctl -u sshd --since "24 hours ago" \
  | grep -c "Failed password"
```

On a typical internet-exposed server this number can be in the **thousands per
day**. Fail2ban will reduce this to near zero after the first few attempts from
each attacker.

### What You Learned
- Your server is likely already under constant low-level attack
- Attackers come from many different IP addresses
- The attack pattern is obvious in the logs — this is exactly what fail2ban's
  filters detect

### Lab Complete ✓

**Self-check — verify you can answer yes to each:**

- [ ] I found at least one `Failed password` or `Invalid user` entry in the SSH log
- [ ] I identified that multiple distinct IP addresses are attempting access
- [ ] I understand that the log pattern (`Failed password for ... from <IP>`) is what fail2ban's sshd filter matches
- [ ] I can articulate *why* blocking after N failures is more effective than blocking permanently at the firewall from the start

[↑ Back to TOC](#table-of-contents)

---

## 10. Summary

In this module you learned:

- **What fail2ban is**: a log-monitoring intrusion prevention daemon
- **The problem it solves**: automatically blocking brute-force and scan attacks
- **How it works**: Monitor → Filter → Count → Ban → Unban
- **Where it fits on RHEL 10**: between firewalld (enforcement) and your services (targets)
- **What it cannot do**: replace strong auth, defeat distributed botnets, or act as a full IDS
- **Key terminology**: jail, filter, action, backend, bantime, findtime, maxretry
- **Common use cases**: SSH, web servers, mail servers, custom applications

### Next Steps

Proceed to **[Module 02 — Installation](./02-installation.md)** to install
fail2ban on your RHEL 10 system.

---

| ← Previous | Home | Next → |
|-----------|------|--------|
| — | [Course README](./README.md) | [02 — Installation](./02-installation.md) |
