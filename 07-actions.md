# Module 07 — Actions
[![CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey)](./LICENSE.md)
[![RHEL 10](https://img.shields.io/badge/platform-RHEL%2010-red)](https://access.redhat.com/products/red-hat-enterprise-linux)
[![fail2ban](https://img.shields.io/badge/fail2ban-RHEL%2010-red)](https://access.redhat.com/products/red-hat-enterprise-linux)

> **Level:** Intermediate  
> **Prerequisites:** [Module 06 — Filters](./06-filters.md)  
> **Time to complete:** ~60 minutes

---

## Table of Contents

1. [What Is an Action?](#1-what-is-an-action)
2. [Action File Structure](#2-action-file-structure)
3. [The Four Action Hooks](#3-the-four-action-hooks)
4. [firewalld Actions on RHEL 10](#4-firewalld-actions-on-rhel-10)
5. [firewallcmd-ipset — The Recommended Action](#5-firewallcmd-ipset--the-recommended-action)
6. [firewallcmd-new — Rich Rules Action](#6-firewallcmd-new--rich-rules-action)
7. [firewallcmd-allports — Block Everything](#7-firewallcmd-allports--block-everything)
8. [Action Parameters and Variables](#8-action-parameters-and-variables)
9. [Email Notification Actions](#9-email-notification-actions)
10. [Combining Multiple Actions](#10-combining-multiple-actions)
11. [The action_ Shortcut Variables](#11-the-action_-shortcut-variables)
12. [Writing a Custom Action](#12-writing-a-custom-action)
13. [Lab 07 — Observe Action Execution](#13-lab-07--observe-action-execution)
14. [Summary](#14-summary)

---

## 1. What Is an Action?

An **action** defines the commands fail2ban executes when:
- The fail2ban service starts
- An IP is banned
- An IP is unbanned
- The fail2ban service stops

Actions live in `/etc/fail2ban/action.d/` as `.conf` files.

### The action lifecycle

```
fail2ban starts
      │
      ▼ actionstart (runs once per jail)
   Setup ipset, firewall rules, etc.
      │
      │  (while running...)
      │
      ├─► IP reaches maxretry
      │         │
      │         ▼ actionban
      │      Add IP to firewall block
      │         │
      │         ▼ (after bantime...)
      │      actionunban
      │      Remove IP from firewall block
      │
      ▼ actionstop (runs once per jail)
   Cleanup: remove ipset, etc.
```

[↑ Back to TOC](#table-of-contents)

---

## 2. Action File Structure

```ini
# /etc/fail2ban/action.d/example.conf

[INCLUDES]
# Optional: include another action file's definitions
before = iptables-common.conf

[Definition]
# Shell commands executed at each lifecycle stage

# Run when the jail starts (setup)
actionstart = <command>

# Run when an IP is banned
actionban   = <command using <ip>, <port>, <protocol> variables>

# Run when an IP is unbanned
actionunban = <command using <ip>, <port>, <protocol> variables>

# Run when the jail stops (cleanup)
actionstop  = <command>

# Run to check the status/health of the action
actioncheck = <command>

[Init]
# Default parameter values that can be overridden per-jail
name      = default
port      = ssh
protocol  = tcp
```

[↑ Back to TOC](#table-of-contents)

---

## 3. The Four Action Hooks

### actionstart

Runs **once** when fail2ban starts (or the jail is activated). Used to:
- Create firewalld ipsets
- Add firewall rules that reference the ipset
- Set up any required infrastructure

```bash
# Example: creates an ipset and adds it to firewalld
actionstart = firewall-cmd --permanent --new-ipset=<ipsetname> --type=hash:ip \
                --option=maxelem=65536 --option=hashsize=4096 \
                --option=timeout=<bantime>
              firewall-cmd --permanent --zone=<zone> \
                --add-rich-rule='rule family=ipv4 source ipset=<ipsetname> drop'
              firewall-cmd --reload
```

### actionban

Runs **every time an IP is banned**. Receives `<ip>` as a variable.

```bash
# Example: add IP to the existing ipset
actionban = firewall-cmd --ipset=<ipsetname> --add-entry=<ip>
```

### actionunban

Runs **every time a ban expires** (or is manually lifted).

```bash
# Example: remove IP from ipset
actionunban = firewall-cmd --ipset=<ipsetname> --remove-entry=<ip>
```

### actionstop

Runs **once** when fail2ban stops (or the jail is deactivated). Used to:
- Remove firewall rules
- Delete ipsets

```bash
# Example: remove the firewall rule and ipset
actionstop = firewall-cmd --permanent --zone=<zone> \
               --remove-rich-rule='rule family=ipv4 source ipset=<ipsetname> drop'
             firewall-cmd --permanent --delete-ipset=<ipsetname>
             firewall-cmd --reload
```

[↑ Back to TOC](#table-of-contents)

---

## 4. firewalld Actions on RHEL 10

On RHEL 10, avoid any action file that references `iptables` or `ip6tables`
directly. The correct action files are in the `firewallcmd-*` family:

```bash
ls /etc/fail2ban/action.d/firewallcmd*
```

```
/etc/fail2ban/action.d/firewallcmd-allports.conf
/etc/fail2ban/action.d/firewallcmd-ipset.conf
/etc/fail2ban/action.d/firewallcmd-new.conf
/etc/fail2ban/action.d/firewallcmd-rich-logging.conf
```

### Comparison

| Action | Ban Method | Scales To | Best For |
|--------|-----------|-----------|---------|
| `firewallcmd-ipset` | IP added to named ipset | 100,000+ IPs | **Production — recommended** |
| `firewallcmd-new` | One rich rule per IP | ~1,000 IPs | Dev/testing, easy inspection |
| `firewallcmd-allports` | All-port block via ipset | 100,000+ IPs | Maximum blocking of attackers |
| `firewallcmd-rich-logging` | Rich rule + logging | ~1,000 IPs | Audit trail environments |

[↑ Back to TOC](#table-of-contents)

---

## 5. firewallcmd-ipset — The Recommended Action

This is the **recommended action for RHEL 10**. It uses a firewalld-managed
ipset (a kernel-level hash table of IPs) which performs much better than
individual rich rules when many IPs are banned.

```bash
cat /etc/fail2ban/action.d/firewallcmd-ipset.conf
```

### How it works

1. **actionstart**: Creates a firewalld ipset named `fail2ban-<jailname>` and
   adds a rich rule to drop traffic from that ipset.
2. **actionban**: Adds the offending IP to the ipset.
3. **actionunban**: Removes the IP from the ipset.
4. **actionstop**: Removes the rich rule and deletes the ipset.

### Verifying ipset bans

```bash
# List all fail2ban ipsets
sudo firewall-cmd --get-ipsets | tr ' ' '\n' | grep fail2ban

# Inspect a specific ipset
sudo firewall-cmd --info-ipset=fail2ban-sshd

# List IPs in the ipset
sudo firewall-cmd --ipset=fail2ban-sshd --get-entries
```

### Setting this as the default in jail.local

```ini
# In jail.local [DEFAULT] section (already set by 00-firewalld.conf)
banaction = firewallcmd-ipset
```

[↑ Back to TOC](#table-of-contents)

---

## 6. firewallcmd-new — Rich Rules Action

This action creates **one individual rich rule per banned IP** in firewalld.
It's simpler to inspect but does not scale well.

```ini
# In a specific jail, to use rich rules instead of ipset:
[sshd]
enabled   = true
banaction = firewallcmd-new
```

### Verifying rich rule bans

```bash
# List all rich rules (includes fail2ban rules)
sudo firewall-cmd --list-rich-rules
```

```
rule family="ipv4" source address="185.220.101.5" port port="22" protocol="tcp" reject
rule family="ipv4" source address="45.33.32.156" port port="22" protocol="tcp" reject
```

### When to use firewallcmd-new

- During development and testing (easier to see exactly what's blocked)
- When you have very few active bans (<100)
- When you need to inspect individual ban rules easily

[↑ Back to TOC](#table-of-contents)

---

## 7. firewallcmd-allports — Block Everything

This action blocks ALL ports from a banned IP, not just the port associated
with the triggering jail.

```ini
# Apply to a specific jail
[sshd]
enabled   = true
port      = any
banaction = firewallcmd-allports
bantime   = 7d
maxretry  = 3
```

### When to use firewallcmd-allports

- For your most sensitive services (SSH, administrative interfaces)
- When you want a "one strike and you're completely blocked" policy
- Combined with the recidive jail for persistent offenders

### How it differs from firewallcmd-ipset

`firewallcmd-ipset` blocks the banned IP only on the specific `port` defined in
the jail. `firewallcmd-allports` creates a rule that drops ALL traffic from the
IP regardless of destination port.

[↑ Back to TOC](#table-of-contents)

---

## 8. Action Parameters and Variables

Action files use placeholder variables that fail2ban substitutes at runtime:

| Variable | Value | Example |
|----------|-------|---------|
| `<ip>` | The IP being banned/unbanned | `185.220.101.5` |
| `<port>` | Port(s) from the jail config | `22` or `80,443` |
| `<protocol>` | `tcp` or `udp` | `tcp` |
| `<name>` | The jail name | `sshd` |
| `<ipsetname>` | Auto-generated: `fail2ban-<name>` | `fail2ban-sshd` |
| `<bantime>` | Ban duration in seconds | `86400` |
| `<zone>` | Firewalld zone | `public` |
| `<blocktype>` | Block type (reject/drop) | `drop` |

### Customising action parameters

You can override these in your jail definition:

```ini
[sshd]
enabled   = true
banaction = firewallcmd-ipset
# Override the firewalld zone for this jail
firewallcmd-ipset[zone=drop]
```

Or set them in an `[Init]` section of a custom action file:

```ini
[Init]
zone     = public
blocktype = drop
```

[↑ Back to TOC](#table-of-contents)

---

## 9. Email Notification Actions

Fail2ban can send email notifications when IPs are banned. On RHEL 10 this
requires a working MTA (mail transfer agent).

### Install a local MTA

```bash
# Install postfix as a local MTA
sudo dnf install -y postfix mailx

# Start and enable postfix
sudo systemctl enable --now postfix
```

### Configure email in jail.local

```ini
[DEFAULT]
# Email settings
destemail  = admin@example.com
sender     = fail2ban@your-server.example.com
mta        = sendmail

# Use action with email (ban + whois lookup + log lines)
action = %(action_mwl)s
```

### Email action presets

| Preset | What it does |
|--------|-------------|
| `%(action_)s` | Ban only (default, no email) |
| `%(action_mw)s` | Ban + email with whois info |
| `%(action_mwl)s` | Ban + email with whois info + matching log lines |

### Per-jail email override

```ini
[sshd]
enabled = true
# Send emails only for SSH bans
action  = %(action_mwl)s
```

### Test email manually

```bash
echo "Test email from fail2ban" | mail -s "Fail2ban Test" admin@example.com
```

[↑ Back to TOC](#table-of-contents)

---

## 10. Combining Multiple Actions

A single jail can trigger multiple actions simultaneously using the `action`
parameter with newlines:

```ini
[sshd]
enabled = true
action  = firewallcmd-ipset[name=sshd, port=ssh, protocol=tcp]
          sendmail-whois[name=sshd, dest=admin@example.com]
```

Or using the preset shortcut:

```ini
[sshd]
enabled    = true
destemail  = admin@example.com
action     = %(action_mwl)s
```

Where `%(action_mwl)s` expands to:
```ini
action_ = firewallcmd-ipset[...]
action_mwl = %(action_)s
             sendmail-whois-lines[...]
```

[↑ Back to TOC](#table-of-contents)

---

## 11. The action_ Shortcut Variables

Fail2ban defines convenient shortcut variables in `jail.conf` that expand to
commonly used action combinations:

```ini
# Defined in jail.conf [DEFAULT]:

# Ban only
action_ = %(banaction)s[name=%(__name__)s, bantime="%(bantime)s", port="%(port)s",
           protocol="%(protocol)s", chain="%(chain)s"]

# Ban + email with whois
action_mw = %(action_)s
            %(mta)s-whois[name=%(__name__)s, sender="%(sender)s",
            dest="%(destemail)s", protocol="%(protocol)s", chain="%(chain)s"]

# Ban + email with whois + matching log lines  
action_mwl = %(action_)s
             %(mta)s-whois-lines[name=%(__name__)s, sender="%(sender)s",
             dest="%(destemail)s", logpath=%(logpath)s,
             chain="%(chain)s"]
```

Set which one to use in `[DEFAULT]` or per-jail:

```ini
[DEFAULT]
action = %(action_)s     # Ban only (recommended default)
```

[↑ Back to TOC](#table-of-contents)

---

## 12. Writing a Custom Action

Sometimes you need a completely custom response to a ban — for example, calling
a webhook or writing to a database.

### Example: webhook notification action

```bash
sudo tee /etc/fail2ban/action.d/webhook-notify.conf << 'EOF'
[Definition]
actionban = curl -s -X POST \
              -H "Content-Type: application/json" \
              -d '{"event":"ban","jail":"<name>","ip":"<ip>","time":"$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ)"}' \
              https://your-webhook.example.com/fail2ban

actionunban = curl -s -X POST \
                -H "Content-Type: application/json" \
                -d '{"event":"unban","jail":"<name>","ip":"<ip>"}' \
                https://your-webhook.example.com/fail2ban

[Init]
name = default
EOF
```

### Enable it in your jail

```ini
[sshd]
enabled = true
action  = firewallcmd-ipset[name=sshd, port=ssh, protocol=tcp]
          webhook-notify[name=sshd]
```

### Example: log bans to a custom file

```bash
sudo tee /etc/fail2ban/action.d/custom-log.conf << 'EOF'
[Definition]
actionban   = echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) BAN   <name> <ip>" \
                >> /var/log/fail2ban-custom.log

actionunban = echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) UNBAN <name> <ip>" \
                >> /var/log/fail2ban-custom.log

[Init]
name = default
EOF
```

[↑ Back to TOC](#table-of-contents)

---

## 13. Lab 07 — Observe Action Execution

### Step 1 — Inspect the firewallcmd-ipset action

```bash
cat /etc/fail2ban/action.d/firewallcmd-ipset.conf
```

Identify: `actionstart`, `actionban`, `actionunban`, `actionstop`.

### Step 2 — Check what ipsets currently exist

```bash
sudo firewall-cmd --get-ipsets
```

You should see `fail2ban-sshd` if the sshd jail is running.

### Step 3 — Inspect the sshd ipset

```bash
sudo firewall-cmd --info-ipset=fail2ban-sshd
```

```
fail2ban-sshd
  type: hash:ip
  options: timeout=86400 maxelem=65536
  entries:
```

### Step 4 — Trigger a test ban and watch the action

In one terminal, tail the fail2ban log:
```bash
sudo tail -f /var/log/fail2ban.log
```

In another terminal, trigger a manual ban:
```bash
sudo fail2ban-client set sshd banip 203.0.113.1
```

### Step 5 — Verify the action ran

```bash
# Check ipset contains the banned IP
sudo firewall-cmd --ipset=fail2ban-sshd --get-entries
```

```
203.0.113.1
```

```bash
# Check the rich rule that references the ipset
sudo firewall-cmd --list-rich-rules
```

```
rule family="ipv4" source ipset="fail2ban-sshd" drop
```

### Step 6 — Unban and verify cleanup

```bash
sudo fail2ban-client set sshd unbanip 203.0.113.1

# Verify IP is gone from ipset
sudo firewall-cmd --ipset=fail2ban-sshd --get-entries
```

### Step 7 — Check the log for action entries

```bash
sudo grep "203.0.113.1" /var/log/fail2ban.log
```

```
2026-01-10 10:30:00,001 fail2ban.actions  [12346]: NOTICE  [sshd] Ban 203.0.113.1
2026-01-10 10:30:15,002 fail2ban.actions  [12346]: NOTICE  [sshd] Unban 203.0.113.1
```

### Lab Complete ✓

**Self-check — verify you can answer yes to each:**

- [ ] I can identify which action file is used by a jail with `fail2ban-client get sshd action`
- [ ] I viewed the `actionban` and `actionunban` commands in the action file and understand what they do
- [ ] I observed a `Ban` and `Unban` log line and matched them to the action's `actionban`/`actionunban` commands
- [ ] I understand the difference between `action_` (ban only), `action_mw` (ban + email), and `action_mwl` (ban + email + log)
- [ ] I know how to change the action for a specific jail in `jail.local` without editing the action file

[↑ Back to TOC](#table-of-contents)

---

## 14. Summary

In this module you learned:

- What an **action** is: commands executed at ban/unban lifecycle events
- **Action file structure**: `actionstart`, `actionban`, `actionunban`, `actionstop`
- The **firewalld action files** available on RHEL 10:
  - `firewallcmd-ipset` (recommended — scales to 100k+ IPs)
  - `firewallcmd-new` (simple rich rules, good for testing)
  - `firewallcmd-allports` (blocks ALL ports from banned IP)
- **Action variables**: `<ip>`, `<port>`, `<name>`, `<ipsetname>`, etc.
- How to configure **email notifications** with MTA integration
- How to **combine multiple actions** per jail
- The **action_ shortcut presets** (`action_`, `action_mw`, `action_mwl`)
- How to write a **custom action** for webhooks or custom logging

### Next Steps

Proceed to **[Module 08 — Firewalld Integration](./08-firewalld-integration.md)**
for a deep dive into how fail2ban interacts with firewalld zones, ipsets, and
rich rules.

---

| ← Previous | Home | Next → |
|-----------|------|--------|
| [06 — Filters](./06-filters.md) | [Course README](./README.md) | [08 — Firewalld Integration](./08-firewalld-integration.md) |

---

*Licensed under [CC BY-NC-SA 4.0](LICENSE.md) · © 2026 UncleJS*