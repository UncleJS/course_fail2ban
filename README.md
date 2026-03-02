# Fail2ban on RHEL 10 — Complete Course

> **Platform:** Red Hat Enterprise Linux 10  
> **Firewall:** firewalld (firewall-cmd / ipset)  
> **Audience:** Complete beginners → Advanced administrators  
> **Style:** Concept explanation + hands-on labs in every module

[![CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey)](LICENSE.md)
[![RHEL 10](https://img.shields.io/badge/platform-RHEL%2010-red)](https://access.redhat.com/products/red-hat-enterprise-linux)
[![fail2ban](https://img.shields.io/badge/fail2ban-RHEL%2010-red)](https://access.redhat.com/products/red-hat-enterprise-linux)

---

## About This Course

This course takes you from zero knowledge of fail2ban to confidently deploying,
tuning, monitoring, and troubleshooting a production-grade intrusion prevention
setup on RHEL 10.

Every module includes:
- A **Table of Contents** with anchor links
- **Concept explanations** with real-world context
- **Configuration examples** specific to RHEL 10 (firewalld, journald, SELinux)
- **Hands-on labs** with expected outputs
- A **"Go to TOC"** link at the bottom of every section

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| OS | RHEL 10 (or compatible: AlmaLinux 10, Rocky Linux 10) |
| Access | Root or sudo privileges |
| Skills | Basic Linux CLI (ls, cd, cat, systemctl) |
| Network | Internet access for EPEL package installation |

---

## Course Table of Contents

| Module | Title | Level |
|--------|-------|-------|
| [01](./01-introduction.md) | Introduction to Fail2ban | Beginner |
| [02](./02-installation.md) | Installation on RHEL 10 | Beginner |
| [03](./03-core-concepts.md) | Core Concepts | Beginner |
| [04](./04-configuration-basics.md) | Configuration Basics | Beginner |
| [05](./05-jails.md) | Jails | Intermediate |
| [06](./06-filters.md) | Filters | Intermediate |
| [07](./07-actions.md) | Actions | Intermediate |
| [08](./08-firewalld-integration.md) | Firewalld Integration | Intermediate |
| [09](./09-custom-jails-and-filters.md) | Custom Jails & Filters | Intermediate |
| [10](./10-advanced-topics.md) | Advanced Topics | Advanced |
| [11](./11-systemd-and-journald.md) | Systemd & Journald | Advanced |
| [12](./12-healthchecks.md) | Healthchecks | Advanced |
| [13](./13-troubleshooting.md) | Troubleshooting | Advanced |

---

## Learning Path

```
[01 Intro] ──► [02 Install] ──► [03 Concepts] ──► [04 Config]
                                                        │
                                          ┌─────────────┼─────────────┐
                                          ▼             ▼             ▼
                                      [05 Jails]  [06 Filters] [07 Actions]
                                          │             │             │
                                          └─────────────┼─────────────┘
                                                        ▼
                                            [08 Firewalld Integration]
                                                        │
                                                        ▼
                                            [09 Custom Jails & Filters]
                                                        │
                                           ┌─────────────┼─────────────┐
                                           ▼             ▼             ▼
                                     [10 Advanced] [11 Systemd]  [12 Health]
                                           │             │             │
                                           └─────────────┼─────────────┘
                                                         ▼
                                                [13 Troubleshooting]
```

---

## Key Files & Paths Reference

| Path | Purpose |
|------|---------|
| `/etc/fail2ban/fail2ban.conf` | Global daemon settings |
| `/etc/fail2ban/fail2ban.local` | Your global overrides (never edit .conf) |
| `/etc/fail2ban/jail.conf` | Default jail definitions |
| `/etc/fail2ban/jail.local` | Your jail overrides |
| `/etc/fail2ban/jail.d/` | Additional jail drop-in files |
| `/etc/fail2ban/filter.d/` | Filter (regex) definitions |
| `/etc/fail2ban/action.d/` | Action definitions |
| `/var/log/fail2ban.log` | Fail2ban activity log |
| `/var/lib/fail2ban/fail2ban.sqlite3` | Ban persistence database |
| `/var/run/fail2ban/fail2ban.sock` | Unix socket for client comms |

---

## Quick Command Reference

```bash
# Service management
systemctl start fail2ban
systemctl stop fail2ban
systemctl restart fail2ban
systemctl reload fail2ban
systemctl status fail2ban

# Status checks
fail2ban-client status
fail2ban-client status sshd
fail2ban-client ping

# Ban management
fail2ban-client set sshd banip 1.2.3.4
fail2ban-client set sshd unbanip 1.2.3.4

# Config testing
fail2ban-client -t
fail2ban-regex /var/log/secure /etc/fail2ban/filter.d/sshd.conf

# Firewalld verification
firewall-cmd --list-rich-rules
firewall-cmd --info-ipset=fail2ban-sshd
```

---

## Course Status

| Module | Status |
|--------|--------|
| 01 — Introduction | ✅ Complete |
| 02 — Installation | ✅ Complete |
| 03 — Core Concepts | ✅ Complete |
| 04 — Configuration Basics | ✅ Complete |
| 05 — Jails | ✅ Complete |
| 06 — Filters | ✅ Complete |
| 07 — Actions | ✅ Complete |
| 08 — Firewalld Integration | ✅ Complete |
| 09 — Custom Jails & Filters | ✅ Complete |
| 10 — Advanced Topics | ✅ Complete |
| 11 — Systemd & Journald | ✅ Complete |
| 12 — Healthchecks | ✅ Complete |
| 13 — Troubleshooting | ✅ Complete |

---

*Course maintained for RHEL 10 — Last reviewed: 2026-02-26*

---

## License

This project is licensed under the
Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International (CC BY-NC-SA 4.0).

https://creativecommons.org/licenses/by-nc-sa/4.0/

---

© 2026 UncleJS — Licensed under CC BY-NC-SA 4.0
