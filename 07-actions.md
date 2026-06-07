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
6. [firewallcmd-rich-rules — The EPEL Default](#6-firewallcmd-rich-rules--the-epel-default)
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
- Create the kernel ipset for the jail
- Add the firewall rule that matches against the ipset
- Set up any required infrastructure

```bash
# Example (simplified from firewallcmd-ipset.conf):
# create the set, then one rule matching everything in it
actionstart = ipset -exist create <ipmset> hash:ip maxelem <maxelem>
              firewall-cmd --direct --add-rule ipv4 filter <chain> 0 \
                -p <protocol> -m multiport --dports <port> \
                -m set --match-set <ipmset> src -j <blocktype>
```

### actionban

Runs **every time an IP is banned**. Receives `<ip>` as a variable.

```bash
# Example: add IP to the existing ipset
actionban = ipset -exist add <ipmset> <ip>
```

### actionunban

Runs **every time a ban expires** (or is manually lifted).

```bash
# Example: remove IP from ipset
actionunban = ipset -exist del <ipmset> <ip>
```

### actionstop

Runs **once** when fail2ban stops (or the jail is deactivated). Used to:
- Remove firewall rules
- Delete ipsets

```bash
# Example: remove the firewall rule, then flush and destroy the ipset
actionstop = firewall-cmd --direct --remove-rule ipv4 filter <chain> 0 \
               -p <protocol> -m multiport --dports <port> \
               -m set --match-set <ipmset> src -j <blocktype>
             ipset flush <ipmset>
             ipset destroy <ipmset>
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
/etc/fail2ban/action.d/firewallcmd-common.conf
/etc/fail2ban/action.d/firewallcmd-ipset.conf
/etc/fail2ban/action.d/firewallcmd-multiport.conf
/etc/fail2ban/action.d/firewallcmd-new.conf
/etc/fail2ban/action.d/firewallcmd-rich-logging.conf
/etc/fail2ban/action.d/firewallcmd-rich-rules.conf
```

### Comparison

| Action | Ban Method | Scales To | Best For |
|--------|-----------|-----------|---------|
| `firewallcmd-rich-rules` | One rich rule per IP | ~1,000 IPs | **EPEL default** — easy inspection |
| `firewallcmd-ipset` | IP added to a kernel ipset | 100,000+ IPs | **Production at scale — recommended** |
| `firewallcmd-allports` | Per-IP rule in a dedicated chain, all ports | ~1,000 IPs | Maximum blocking (recidive) |
| `firewallcmd-rich-logging` | Rich rule + logging | ~1,000 IPs | Audit trail environments |
| `firewallcmd-multiport` / `-new` | Per-IP `--direct` rules | ~1,000 IPs | Legacy — prefer the ones above |

[↑ Back to TOC](#table-of-contents)

---

## 5. firewallcmd-ipset — The Recommended Action

This is the **recommended action for busy RHEL 10 servers**. It uses a kernel
ipset (a hash table of IPs, managed with the `ipset` binary) which performs
much better than individual rich rules when many IPs are banned.

```bash
cat /etc/fail2ban/action.d/firewallcmd-ipset.conf
```

### How it works

1. **actionstart**: Creates a kernel ipset named `f2b-<jailname>` with
   `ipset create`, then adds **one** `firewall-cmd --direct` rule that rejects
   traffic from any IP in that set.
2. **actionban**: Adds the offending IP to the ipset (`ipset add`).
3. **actionunban**: Removes the IP from the ipset (`ipset del`).
4. **actionstop**: Removes the firewall rule, flushes and destroys the ipset.

> **Note:** The set is created with the `ipset` binary, *not* with
> `firewall-cmd --new-ipset` — so it will **not** appear in
> `firewall-cmd --get-ipsets`. Inspect it with `ipset list` instead. Also note
> that firewalld's `--direct` interface is deprecated (it still works on
> RHEL 10); the rich-rules action in section 6 avoids it.

### Verifying ipset bans

```bash
# List all fail2ban ipsets
sudo ipset list -n | grep f2b

# Inspect a specific ipset (header + members)
sudo ipset list f2b-sshd

# Check whether one specific IP is in the set
sudo ipset test f2b-sshd 185.220.101.5

# See the firewall rule that matches the set
sudo firewall-cmd --direct --get-all-rules | grep f2b-sshd
```

### Setting this as the default in jail.local

```ini
# In jail.local [DEFAULT] section — overrides the EPEL default
# (firewallcmd-rich-rules, set by 00-firewalld.conf)
banaction = firewallcmd-ipset
```

[↑ Back to TOC](#table-of-contents)

---

## 6. firewallcmd-rich-rules — The EPEL Default

This action creates **one individual rich rule per banned IP** in firewalld.
It is what `jail.d/00-firewalld.conf` configures as the default on RHEL 10.
It's simple to inspect but does not scale as well as the ipset action.

```ini
# In a specific jail, to use rich rules instead of ipset:
[sshd]
enabled   = true
banaction = firewallcmd-rich-rules
```

### Verifying rich rule bans

```bash
# List all rich rules (includes fail2ban rules)
sudo firewall-cmd --list-rich-rules
```

```
rule family="ipv4" source address="185.220.101.5" port port="22" protocol="tcp" reject type="icmp-port-unreachable"
rule family="ipv4" source address="45.33.32.156" port port="22" protocol="tcp" reject type="icmp-port-unreachable"
```

### When to use firewallcmd-rich-rules

- When the EPEL defaults are good enough (most small/medium servers)
- When you have relatively few active bans (hundreds, not thousands)
- When you need to inspect individual ban rules easily
- When you want to avoid the deprecated `--direct` interface entirely

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
| `<ipmset>` | Auto-generated ipset name: `f2b-<name>` | `f2b-sshd` |
| `<bantime>` | Ban duration in seconds | `86400` |
| `<maxelem>` | Max entries in the ipset | `65536` |
| `<blocktype>` | Block type (REJECT/DROP) | `REJECT --reject-with icmp-port-unreachable` |

### Customising action parameters

You can pass parameters in square brackets on the `banaction` line:

```ini
[sshd]
enabled   = true
# Raise the ipset capacity for this jail
banaction = firewallcmd-ipset[maxelem=131072]
```

Or set them in an `[Init]` section of a `.local` override for the action file:

```ini
# /etc/fail2ban/action.d/firewallcmd-ipset.local
[Init]
maxelem = 131072
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
actionban   = echo "$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ) BAN   <name> <ip>" \
                >> /var/log/fail2ban-custom.log

actionunban = echo "$(date -u +%%Y-%%m-%%dT%%H:%%M:%%SZ) UNBAN <name> <ip>" \
                >> /var/log/fail2ban-custom.log

[Init]
name = default
EOF
```

> **Note the `%%`:** literal `%` characters must be doubled in fail2ban
> config files, otherwise the `%(...)s` interpolation parser chokes on them
> (same rule as the webhook example above).

[↑ Back to TOC](#table-of-contents)

---

## 13. Lab 07 — Observe Action Execution

### Step 1 — Inspect the firewallcmd-ipset action

```bash
cat /etc/fail2ban/action.d/firewallcmd-ipset.conf
```

Identify: `actionstart`, `actionban`, `actionunban`, `actionstop`.

> **Prerequisite:** the lab assumes `banaction = firewallcmd-ipset` in your
> `jail.local` (set up in Module 04). If you are still on the EPEL default
> (`firewallcmd-rich-rules`), use `firewall-cmd --list-rich-rules` wherever a
> step inspects the ipset.

### Step 2 — Check what fail2ban ipsets currently exist

```bash
sudo ipset list -n | grep f2b
```

You should see `f2b-sshd` if the sshd jail is running.

### Step 3 — Inspect the sshd ipset

```bash
sudo ipset list f2b-sshd
```

```
Name: f2b-sshd
Type: hash:ip
Revision: 4
Header: family inet hashsize 1024 maxelem 65536 timeout 0
Size in memory: 208
References: 1
Number of entries: 0
Members:
```

### Step 4 — Trigger a test ban and watch the action

In one terminal, follow the fail2ban log:
```bash
sudo journalctl -u fail2ban -f
```

In another terminal, trigger a manual ban:
```bash
sudo fail2ban-client set sshd banip 203.0.113.1
```

### Step 5 — Verify the action ran

```bash
# Check the ipset contains the banned IP
sudo ipset list f2b-sshd | grep -A5 "Members:"
```

```
Members:
203.0.113.1
```

```bash
# Check the firewall rule that matches the ipset
sudo firewall-cmd --direct --get-all-rules | grep f2b-sshd
```

```
ipv4 filter INPUT_direct 0 -p tcp -m multiport --dports 22 -m set --match-set f2b-sshd src -j REJECT --reject-with icmp-port-unreachable
```

### Step 6 — Unban and verify cleanup

```bash
sudo fail2ban-client set sshd unbanip 203.0.113.1

# Verify IP is gone from ipset
sudo ipset test f2b-sshd 203.0.113.1
```

```
203.0.113.1 is NOT in set f2b-sshd.
```

### Step 7 — Check the log for action entries

```bash
sudo journalctl -u fail2ban --no-pager | grep "203.0.113.1"
```

```
Jan 10 10:30:00 server fail2ban-server[12346]: fail2ban.actions  [12346]: NOTICE  [sshd] Ban 203.0.113.1
Jan 10 10:30:15 server fail2ban-server[12346]: fail2ban.actions  [12346]: NOTICE  [sshd] Unban 203.0.113.1
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
  - `firewallcmd-rich-rules` (EPEL default — one rich rule per IP, easy to inspect)
  - `firewallcmd-ipset` (recommended at scale — kernel ipset, 100k+ IPs)
  - `firewallcmd-allports` (blocks ALL ports from banned IP)
- **Action variables**: `<ip>`, `<port>`, `<name>`, `<ipmset>`, etc.
- How to configure **email notifications** with MTA integration
- How to **combine multiple actions** per jail
- The **action_ shortcut presets** (`action_`, `action_mw`, `action_mwl`)
- How to write a **custom action** for webhooks or custom logging

### Next Steps

Proceed to **[Module 08 — Firewalld Integration](./08-firewalld-integration.md)**
for a deep dive into how fail2ban interacts with firewalld zones, ipsets, and
rich rules.

[↑ Back to TOC](#table-of-contents)

---

| ← Previous | Home | Next → |
|-----------|------|--------|
| [06 — Filters](./06-filters.md) | [Course README](./README.md) | [08 — Firewalld Integration](./08-firewalld-integration.md) |

---

*Licensed under [CC BY-NC-SA 4.0](LICENSE.md) · © 2026 UncleJS*