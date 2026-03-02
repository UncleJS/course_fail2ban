# Module 09 — Custom Jails and Filters
[![CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey)](./LICENSE.md)
[![RHEL 10](https://img.shields.io/badge/platform-RHEL%2010-red)](https://access.redhat.com/products/red-hat-enterprise-linux)
[![fail2ban](https://img.shields.io/badge/fail2ban-RHEL%2010-red)](https://access.redhat.com/products/red-hat-enterprise-linux)

> **Level:** Intermediate  
> **Prerequisites:** [Module 08 — Firewalld Integration](./08-firewalld-integration.md)  
> **Time to complete:** ~90 minutes

---

## Table of Contents

1. [Why Write Custom Jails and Filters?](#1-why-write-custom-jails-and-filters)
2. [The Development Workflow](#2-the-development-workflow)
3. [Anatomy of a Custom Filter File](#3-anatomy-of-a-custom-filter-file)
4. [Writing a failregex from Scratch](#4-writing-a-failregex-from-scratch)
5. [The HOST Placeholder Explained](#5-the-host-placeholder-explained)
6. [Using fail2ban-regex to Test Your Filter](#6-using-fail2ban-regex-to-test-your-filter)
7. [Common Regex Patterns and Pitfalls](#7-common-regex-patterns-and-pitfalls)
8. [Placing Your Filter File](#8-placing-your-filter-file)
9. [Anatomy of a Custom Jail](#9-anatomy-of-a-custom-jail)
10. [Flat-File vs. Systemd-Journal Jails](#10-flat-file-vs-systemd-journal-jails)
11. [Writing a Custom Action](#11-writing-a-custom-action)
12. [Chaining Multiple Actions](#12-chaining-multiple-actions)
13. [Testing the Full Pipeline End-to-End](#13-testing-the-full-pipeline-end-to-end)
14. [Real-World Example: Custom Web App](#14-real-world-example-custom-web-app)
15. [Real-World Example: Custom SSH Wrapper](#15-real-world-example-custom-ssh-wrapper)
16. [Lab 09 — Build and Test a Custom Jail from Scratch](#lab-09--build-and-test-a-custom-jail-from-scratch)

---

## 1. Why Write Custom Jails and Filters?

Fail2ban ships with filters for the most common services: sshd, Apache, Nginx, Postfix, Dovecot, and dozens more. But real production environments often run:

- **Custom web applications** with proprietary log formats
- **Internal APIs** that log authentication failures differently
- **Legacy applications** whose log patterns do not match any shipped filter
- **Services that log via systemd journal** with structured fields (not flat files)

In all these cases, you need a **custom filter** — a set of regular expressions that teach fail2ban what a failure event looks like — and a matching **custom jail** that ties the filter to a log source, timing policy, and ban action.

### What custom means

| Component | What you define |
|-----------|----------------|
| **Filter** | Which log lines signal a failure (regex) |
| **Jail** | Which log source, how many failures trigger a ban, how long |
| **Action** | What to do when a ban threshold is crossed |

You only need to write what does not already exist. Most of the time, you write a new filter and a new jail, and reuse existing firewalld actions.

[↑ Back to TOC](#table-of-contents)

---

## 2. The Development Workflow

Follow this sequence every time you build a new filter:

```
1. Collect sample log lines
       ↓
2. Identify the failure pattern and the attacker IP
       ↓
3. Write failregex (use HOST placeholder for IP)
       ↓
4. Test with fail2ban-regex against real log file or sample
       ↓
5. Tune until hit rate is 100% and false-positive rate is 0%
       ↓
6. Write filter file → /etc/fail2ban/filter.d/myapp.conf
       ↓
7. Write jail config → /etc/fail2ban/jail.d/myapp.conf
       ↓
8. Reload fail2ban: fail2ban-client reload
       ↓
9. Verify jail is active: fail2ban-client status myapp
       ↓
10. Trigger a real failure → confirm ban fires
```

Never skip step 4. Testing your regex against real log data before deploying saves hours of frustration.

[↑ Back to TOC](#table-of-contents)

---

## 3. Anatomy of a Custom Filter File

A fail2ban filter file is an INI-format file with a single required section `[Definition]` and optional `[INCLUDES]` and `[Init]` sections.

### Minimal structure

```ini

[↑ Back to TOC](#table-of-contents)

# /etc/fail2ban/filter.d/myapp.conf

[Definition]

# Lines matching failregex increment the failure counter for the source IP.
failregex = ^<HOST> - - \[.*\] "POST /login HTTP/1\.\d" 401

# Lines matching ignoreregex are silently dropped even if they match failregex.
ignoreregex =
```

### Full structure with all options

```ini
# /etc/fail2ban/filter.d/myapp.conf

[INCLUDES]
# Inherit definitions from another filter (optional)
before = common.conf

[Definition]

# One or more regex patterns. Each on its own line, indented if continued.
failregex = ^<HOST> - - \[.*\] "POST /login HTTP/1\.\d" 401
            ^<HOST> - - \[.*\] "GET /admin HTTP/1\.\d" 403

# Patterns to exclude (whitelist specific lines)
ignoreregex = ^127\.0\.0\.1

# journalmatch: used ONLY when backend = systemd
# journalmatch = _SYSTEMD_UNIT=myapp.service

[Init]
# Optional: set default values for variables used in failregex
# datepattern = %%Y-%%m-%%d %%H:%%M:%%S
```

### Key rules

- **One regex per conceptual failure type** — split into multiple `failregex` lines
- **Each continued line must be indented** at least one space
- **Do not use** `^.*` at the start — it makes regex O(n²) and causes ReDoS
- **Always anchor** to `<HOST>` or a known log prefix

---

## 4. Writing a failregex from Scratch

### Step 1 — Collect real log lines

```bash

[↑ Back to TOC](#table-of-contents)

# View last 50 lines of your application log
sudo tail -50 /var/log/myapp/access.log

# Or from journald
sudo journalctl -u myapp.service -n 50 --no-pager
```

Sample lines from a custom web app:

```
2026-02-15 14:22:01 [WARN] Login failed for user 'admin' from 203.0.113.45
2026-02-15 14:22:03 [WARN] Login failed for user 'root' from 203.0.113.45
2026-02-15 14:22:05 [INFO] Login succeeded for user 'alice' from 10.0.0.5
2026-02-15 14:22:10 [WARN] Login failed for user 'test' from 198.51.100.7
```

### Step 2 — Identify the constant parts

Looking at the failure lines:

```
2026-02-15 14:22:01 [WARN] Login failed for user 'admin' from 203.0.113.45
│                   │      │                              │    │
│                   │      │                              │    └─ IP (attacker)
│                   │      │                              └─ variable username
│                   │      └─ constant: "Login failed for user '"
│                   └─ constant: "[WARN] "
└─ timestamp (handled by fail2ban automatically)
```

### Step 3 — Write the regex

```
\[WARN\] Login failed for user '[^']+' from <HOST>
```

Breaking it down:

| Piece | Meaning |
|-------|---------|
| `\[WARN\]` | Literal `[WARN]` — brackets must be escaped |
| ` Login failed for user '` | Literal constant string |
| `[^']+` | One or more characters that are NOT a single-quote (the username) |
| `'` | Closing quote |
| ` from ` | Literal constant |
| `<HOST>` | Fail2ban's IP placeholder |

### Step 4 — Handle the timestamp

Fail2ban **automatically strips the timestamp** from the beginning of each line before applying your regex. You do **not** need to match it unless the timestamp is in a non-standard format.

For non-standard timestamps, set `datepattern` in `[Init]`:

```ini
[Init]
# Match: 2026-02-15 14:22:01
datepattern = %%Y-%%m-%%d %%H:%%M:%%S
```

Note: In `.conf` files, `%` must be doubled to `%%`. In `.local` files it does not need doubling — this is a common source of confusion.

---

## 5. The HOST Placeholder Explained

`<HOST>` is a **special macro** that fail2ban expands into a regex pattern that matches both IPv4 and IPv6 addresses, hostnames, and CIDR notation.

### What `<HOST>` expands to

At runtime, `<HOST>` becomes approximately:

```
(?:::f{4,6}:)?(?P<host>[\w\-.^_]+)
```

This captures:
- IPv4: `203.0.113.45`
- IPv6: `2001:db8::1`
- IPv4-mapped IPv6: `::ffff:203.0.113.45`
- Hostnames: `attacker.example.com`

### Named capture alternative

If your log format has the IP in a non-obvious position, you can use a named capture group instead of `<HOST>`:

```ini
failregex = Authentication failure.*addr=(?P<host>\S+)
```

The capture group **must** be named `host` (lowercase).

### When there is no IP in the log line

Some services log a session ID or username, not an IP. In this case you need to join log lines from multiple sources, which is outside fail2ban's standard scope. A workaround is to pre-process logs with a script that adds the IP to each line.

[↑ Back to TOC](#table-of-contents)

---

## 6. Using fail2ban-regex to Test Your Filter

`fail2ban-regex` is the most important tool in your development workflow. It applies your filter against a log file or string and reports matches.

### Basic syntax

```bash
fail2ban-regex <log-file-or-string> <filter-file-or-regex>
```

### Test against a log file

```bash
sudo fail2ban-regex /var/log/myapp/access.log /etc/fail2ban/filter.d/myapp.conf
```

### Test with an inline regex (no filter file needed)

```bash
sudo fail2ban-regex /var/log/myapp/access.log \
  '\[WARN\] Login failed for user .* from <HOST>'
```

### Test against a single log line string

```bash
sudo fail2ban-regex \
  '2026-02-15 14:22:01 [WARN] Login failed for user '"'"'admin'"'"' from 203.0.113.45' \
  '\[WARN\] Login failed for user .* from <HOST>'
```

### Understanding the output

```
Running tests
=============

Use   failregex filter file : myapp, basedir: /etc/fail2ban
Use         log file : /var/log/myapp/access.log
Use         encoding : UTF-8


Results
=======

Failregex: 47 total
|-  #) [# of hits] regular expression
|   1) [47] \[WARN\] Login failed for user '[^']+' from <HOST>
`-

Ignoreregex: 0 total

Date template hits:
|- [# of hits] date format
|  [47] {^LN-BEG}Year(?P<_sep>[-/.])Month(?P=_sep)Day[T ]24hour:Minute:Second
`-

Lines: 200 lines, 0 ignored, 47 matched, 153 missed     ← key metrics
```

### Interpreting key metrics

| Metric | Meaning |
|--------|---------|
| `matched` | Lines that triggered a failure counter (good for attack lines) |
| `missed` | Lines that did NOT match (should be success/normal lines) |
| `ignored` | Lines that matched `ignoreregex` and were skipped |

**Goal:** All failure/attack lines should be in `matched`. All normal lines should be in `missed`.

### Verbose mode — see exactly which lines matched

```bash
sudo fail2ban-regex --print-all-matched /var/log/myapp/access.log /etc/fail2ban/filter.d/myapp.conf
```

### Debug mode — see timestamp parsing

```bash
sudo fail2ban-regex -D /var/log/myapp/access.log /etc/fail2ban/filter.d/myapp.conf 2>&1 | head -40
```

[↑ Back to TOC](#table-of-contents)

---

## 7. Common Regex Patterns and Pitfalls

### Useful character class patterns

| Pattern | Matches |
|---------|---------|
| `\S+` | Any non-whitespace sequence |
| `\w+` | Word characters (letters, digits, underscore) |
| `[^ ]+` | Any sequence without a space |
| `[^\]]+` | Any sequence without a closing bracket |
| `\d+` | One or more digits |
| `.*?` | Any characters (non-greedy — prefer this over `.*`) |
| `(?:foo\|bar)` | Either "foo" or "bar" (non-capturing group) |

### Common log field patterns

```ini

[↑ Back to TOC](#table-of-contents)

# Apache/Nginx style: IP - - [timestamp] "METHOD /path HTTP/x.x" STATUS
failregex = ^<HOST> - \S+ \[.*?\] "\w+ \S+ HTTP/\d\.\d" 40[13]

# Key=value style: key="value" ... ip=203.0.113.45
failregex = .*ip=<HOST>.*event=login_failed

# Bracket-wrapped IP: [203.0.113.45]
failregex = \[<HOST>\] Failed login

# Syslog style with hostname: Feb 15 14:22:01 myhost myapp: Login failed from 203.0.113.45
failregex = \w{3} [ \d]\d \d\d:\d\d:\d\d \S+ myapp: Login failed from <HOST>
```

### Critical pitfalls

**1. Catastrophic backtracking (ReDoS)**

```ini
# BAD — nested quantifiers cause catastrophic backtracking
failregex = .*(failed|error).*from <HOST>.*

# GOOD — anchor to something specific
failregex = (?:failed|error) from <HOST>
```

**2. Forgetting to escape special characters**

```ini
# BAD — [ is a special regex char, must be escaped
failregex = [ERROR] Login failed from <HOST>

# GOOD
failregex = \[ERROR\] Login failed from <HOST>
```

**3. Not accounting for IPv6**

`<HOST>` handles IPv6 automatically. If you write your own IP pattern, ensure it covers both:

```ini
# RISKY — only matches IPv4
failregex = from (\d{1,3}\.){3}\d{1,3}

# BETTER — use <HOST> which handles both
failregex = from <HOST>
```

**4. Timestamp in the regex**

```ini
# BAD — timestamp is stripped by fail2ban before regex is applied
failregex = 2026-\d\d-\d\d \d\d:\d\d:\d\d \[WARN\] Login failed from <HOST>

# GOOD — skip the timestamp entirely
failregex = \[WARN\] Login failed from <HOST>
```

**5. Case sensitivity**

Fail2ban regex is case-sensitive by default. Use `(?i)` for case-insensitive matching:

```ini
failregex = (?i)login failed from <HOST>
```

---

## 8. Placing Your Filter File

### Directory structure

```
/etc/fail2ban/filter.d/
├── sshd.conf              ← shipped by package (never edit)
├── apache-auth.conf       ← shipped by package (never edit)
├── myapp.conf             ← your custom filter ✓
└── myapp.local            ← your overrides to a shipped filter ✓
```

### Rules

| Scenario | File to create |
|----------|---------------|
| Brand new filter for custom service | `filter.d/myapp.conf` |
| Override/extend a shipped filter | `filter.d/sshd.local` |
| Temporary experiment | Use `fail2ban-regex` inline — no file needed |

### File naming

- Use lowercase
- Use hyphens, not underscores (convention matches shipped filters)
- Name it after the service: `myapp.conf`, `internal-api.conf`

### Verify fail2ban can read your filter

```bash

[↑ Back to TOC](#table-of-contents)

# Reload and check for errors
sudo fail2ban-client reload

# Check the log for parse errors
sudo journalctl -u fail2ban.service -n 20 --no-pager
```
 
---

---

## ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Part 2 — Custom Jails, Actions & Full Pipelines

> **Navigation shortcut:** Jump to [Part 1 — Custom Filters](#1-why-write-custom-jails-and-filters)
> (Sections 1–8) or continue below into Part 2 (Sections 9–15).

| Part | Sections | Topics |
|------|----------|--------|
| **Part 1** | 1–8 | Writing and testing custom filters: anatomy, failregex, HOST placeholder, fail2ban-regex, common pitfalls |
| **Part 2** | 9–15 | Custom jails, custom actions, chaining, full pipeline testing, real-world examples |

---

## 9. Anatomy of a Custom Jail

A jail ties together:
- **Which log to watch** (`logpath` or `journalmatch`)
- **Which filter to use** (`filter`)
- **Timing policy** (`bantime`, `findtime`, `maxretry`)
- **Which action to take** (`action` or `banaction`)
- **Whether it is enabled** (`enabled`)

### Minimal custom jail

```ini

[↑ Back to TOC](#table-of-contents)

# /etc/fail2ban/jail.d/myapp.conf

[myapp]
enabled   = true
filter    = myapp
logpath   = /var/log/myapp/access.log
maxretry  = 5
findtime  = 10m
bantime   = 1h
```

This inherits `banaction` from `[DEFAULT]` (which on RHEL 10 is `firewallcmd-ipset`).

### Full custom jail with all options

```ini
# /etc/fail2ban/jail.d/myapp.conf

[myapp]
enabled     = true

# Filter to use (name of file in filter.d/, without .conf extension)
filter      = myapp

# Log file to monitor (flat file)
logpath     = /var/log/myapp/access.log

# Backend: auto, polling, pyinotify, systemd
# Use 'auto' for flat files; 'systemd' for journald-only sources
backend     = auto

# Encoding of the log file
encoding    = UTF-8

# Failures within findtime trigger a ban
maxretry    = 5
findtime    = 10m

# How long to ban (suffix: s, m, h, d, w — or -1 for permanent)
bantime     = 1h

# Override ban action (optional — default from [DEFAULT] is firewallcmd-ipset)
banaction   = firewallcmd-ipset

# Which firewalld zone to ban in (optional — default: public)
# banaction_allports = firewallcmd-allports

# Port(s) to block (optional — limits ban scope to these ports)
port        = http,https

# IPs to never ban regardless of failures
ignoreip    = 127.0.0.1/8 ::1 10.0.0.0/8
```

---

## 10. Flat-File vs. Systemd-Journal Jails

On RHEL 10, many services log exclusively to systemd journal with **no flat log file**. Your jail config must reflect this.

### Flat-file jail (Apache, Nginx, custom apps)

```ini
[myapp]
enabled  = true
filter   = myapp
logpath  = /var/log/myapp/access.log
backend  = auto          # auto-detects inotify or polling
```

### Systemd-journal jail (sshd, Postfix, Dovecot on RHEL 10)

```ini
[myapp-systemd]
enabled       = true
filter        = myapp-systemd
backend       = systemd  # MUST be set to systemd

[↑ Back to TOC](#table-of-contents)

# No logpath — reads from journald
```

And the matching filter must use `journalmatch`:

```ini
# /etc/fail2ban/filter.d/myapp-systemd.conf

[Definition]
# journalmatch tells fail2ban which systemd unit/fields to subscribe to
journalmatch = _SYSTEMD_UNIT=myapp.service

failregex = Login failed for user \S+ from <HOST>
```

### How to discover journalmatch fields

```bash
# List all journal fields for a unit
sudo journalctl -u myapp.service -o json | head -5 | python3 -m json.tool | grep -E '"_|"SYSLOG'

# Common fields to match on:
# _SYSTEMD_UNIT=myapp.service     — exact unit
# _COMM=myapp                     — process name
# SYSLOG_IDENTIFIER=myapp         — syslog tag
# _UID=1001                       — process UID
```

### Combining journal + flat file in one jail

Not directly supported. Create two jails with different names that share the same filter, or pre-process the journal to a flat file with a systemd service.

---

## 11. Writing a Custom Action

Most of the time you will reuse `firewallcmd-ipset` or `firewallcmd-allports`. But if you need a custom response — sending an alert, calling a webhook, writing to a database — you write a custom action file.

### Action file anatomy

```ini

[↑ Back to TOC](#table-of-contents)

# /etc/fail2ban/action.d/mywebhook.conf

[Definition]

# actionstart: runs once when the jail starts
actionstart = curl -s -X POST https://hooks.example.com/alert \
              -d '{"event":"jail_started","jail":"<name>"}'

# actionstop: runs once when the jail stops
actionstop  = curl -s -X POST https://hooks.example.com/alert \
              -d '{"event":"jail_stopped","jail":"<name>"}'

# actioncheck: runs periodically to verify the ban mechanism is working
actioncheck =

# actionban: runs when an IP is banned  ← MOST IMPORTANT
actionban   = curl -s -X POST https://hooks.example.com/alert \
              -d '{"event":"ban","jail":"<name>","ip":"<ip>","failures":"<failures>"}'

# actionunban: runs when an IP is unbanned
actionunban = curl -s -X POST https://hooks.example.com/alert \
              -d '{"event":"unban","jail":"<name>","ip":"<ip>"}'

[Init]
# Default values for variables referenced in the action
name = default
```

### Variables available in actions

| Variable | Value |
|----------|-------|
| `<ip>` | The IP address being banned/unbanned |
| `<name>` | The jail name |
| `<failures>` | Number of failures that triggered the ban |
| `<time>` | Unix timestamp of the ban |
| `<matches>` | Newline-separated log lines that triggered the ban |
| `<bantime>` | Duration of the ban in seconds |

### Chaining firewalld + custom action in a jail

```ini
# /etc/fail2ban/jail.d/myapp.conf

[myapp]
enabled   = true
filter    = myapp
logpath   = /var/log/myapp/access.log
banaction = firewallcmd-ipset
# Run a second action in addition to the firewall ban:
action    = %(banaction)s[name=%(__name__)s, bantime="%(bantime)s", port="%(port)s", protocol="%(protocol)s", chain="%(chain)s"]
            mywebhook[name=%(__name__)s]
```

---

## 12. Chaining Multiple Actions

The `action` parameter in a jail accepts **multiple action entries**, one per line (each indented):

```ini
[myapp]
enabled   = true
filter    = myapp
logpath   = /var/log/myapp/access.log

action    = firewallcmd-ipset[name=%(__name__)s, bantime="%(bantime)s",
                               port="%(port)s", protocol="%(protocol)s"]
            sendmail-whois[name=%(__name__)s, dest="%(destemail)s",
                           sender="%(sender)s"]
            mywebhook[name=%(__name__)s]
```

### Action shortcut macros

Fail2ban provides shortcut macros in `jail.conf` for common combinations. These are defined in the `[DEFAULT]` section:

```ini

[↑ Back to TOC](#table-of-contents)

# These are defined in jail.conf [DEFAULT]:
action_     = %(banaction)s[...]                  # ban only
action_mw   = %(banaction)s[...] + sendmail-whois # ban + email with whois
action_mwl  = %(banaction)s[...] + sendmail-whois-lines # ban + email with log lines
```

To use a shortcut:

```ini
[myapp]
action = %(action_mw)s
```

> **RHEL 10 note:** Email actions require a working MTA (Postfix). Confirm with `echo "test" | mail -s test root` before relying on email notifications.

---

## 13. Testing the Full Pipeline End-to-End

After writing filter + jail, test the complete pipeline before relying on it.

### Step 1 — Reload and verify jail is active

```bash
sudo fail2ban-client reload
sudo fail2ban-client status myapp
```

Expected output:

```
Status for the jail: myapp
|- Filter
|  |- Currently failed: 0
|  |- Total failed:     0
|  `- File list:        /var/log/myapp/access.log
`- Actions
   |- Currently banned: 0
   |- Total banned:     0
   `- Banned IP list:
```

If the jail does not appear, check for errors:

```bash
sudo journalctl -u fail2ban.service -n 30 --no-pager
```

### Step 2 — Inject a test failure

```bash

[↑ Back to TOC](#table-of-contents)

# Write a fake failure line to the log
sudo bash -c 'echo "2026-02-15 14:22:01 [WARN] Login failed for user '"'"'admin'"'"' from 203.0.113.1" >> /var/log/myapp/access.log'
```

Repeat until `maxretry` is exceeded (default 5):

```bash
for i in {1..6}; do
  sudo bash -c "echo \"$(date '+%Y-%m-%d %H:%M:%S') [WARN] Login failed for user 'admin' from 203.0.113.1\" >> /var/log/myapp/access.log"
  sleep 1
done
```

### Step 3 — Verify the ban fired

```bash
# Check jail status
sudo fail2ban-client status myapp

# Check firewalld ipset
sudo firewall-cmd --ipset=f2b-myapp --get-entries

# Or use fail2ban-client directly
sudo fail2ban-client get myapp banned
```

### Step 4 — Manual unban (cleanup)

```bash
sudo fail2ban-client set myapp unbanip 203.0.113.1
```

### Step 5 — Check the fail2ban log

```bash
sudo journalctl -u fail2ban.service --since "5 minutes ago" --no-pager
```

Look for lines like:

```
fail2ban.actions[...]: NOTICE  [myapp] Ban 203.0.113.1
fail2ban.actions[...]: NOTICE  [myapp] Unban 203.0.113.1
```

---

## 14. Real-World Example: Custom Web App

### Scenario

A custom Python/Flask web app logs to `/var/log/webapp/app.log` with this format:

```
2026-02-15 14:22:01 ERROR Authentication failed: user=admin ip=203.0.113.45 path=/api/login
2026-02-15 14:22:03 ERROR Authentication failed: user=root ip=203.0.113.45 path=/api/login
2026-02-15 14:22:05 INFO  Authentication succeeded: user=alice ip=10.0.0.5 path=/api/login
```

### Filter file

```ini

[↑ Back to TOC](#table-of-contents)

# /etc/fail2ban/filter.d/webapp.conf

[Definition]

# Match: ERROR Authentication failed: ... ip=<IP>
failregex = ERROR Authentication failed:.*\bip=<HOST>\b

ignoreregex =
```

### Test the filter

```bash
sudo fail2ban-regex /var/log/webapp/app.log /etc/fail2ban/filter.d/webapp.conf
```

Expected: all `Authentication failed` lines matched, `Authentication succeeded` lines missed.

### Jail file

```ini
# /etc/fail2ban/jail.d/webapp.conf

[webapp]
enabled   = true
filter    = webapp
logpath   = /var/log/webapp/app.log
backend   = auto
maxretry  = 10
findtime  = 5m
bantime   = 30m
port      = http,https
```

### Deploy

```bash
sudo fail2ban-client reload
sudo fail2ban-client status webapp
```

---

## 15. Real-World Example: Custom SSH Wrapper

### Scenario

A company uses a custom PAM module that logs to systemd journal under identifier `sshwrapper`:

```bash
sudo journalctl SYSLOG_IDENTIFIER=sshwrapper -n 10 --no-pager
```

```
Feb 15 14:22:01 server sshwrapper[1234]: DENY user=admin from=203.0.113.45 reason=bad_password
Feb 15 14:22:05 server sshwrapper[1234]: ALLOW user=alice from=10.0.0.5
```

### Filter file

```ini

[↑ Back to TOC](#table-of-contents)

# /etc/fail2ban/filter.d/sshwrapper.conf

[Definition]

journalmatch = SYSLOG_IDENTIFIER=sshwrapper

failregex = DENY user=\S+ from=<HOST>

ignoreregex =
```

### Jail file

```ini
# /etc/fail2ban/jail.d/sshwrapper.conf

[sshwrapper]
enabled   = true
filter    = sshwrapper
backend   = systemd
maxretry  = 3
findtime  = 5m
bantime   = 2h
port      = ssh
```

### Deploy and test

```bash
sudo fail2ban-client reload
sudo fail2ban-client status sshwrapper
```

Inject a test journal entry:

```bash
sudo systemd-cat -t sshwrapper echo "DENY user=testuser from=192.0.2.1"
```

---

## Lab 09 — Build and Test a Custom Jail from Scratch

### Objective

Write a complete custom filter and jail for a simulated web application. Inject test failures and verify the ban fires correctly through firewalld.

### Prerequisites

- Fail2ban running (verify: `sudo fail2ban-client ping` → `pong`)
- firewalld running (verify: `sudo firewall-cmd --state` → `running`)

[↑ Back to TOC](#table-of-contents)

---

### Part A — Set Up the Simulated Application

**1. Create a log directory and file:**

```bash
sudo mkdir -p /var/log/labapp
sudo touch /var/log/labapp/auth.log
sudo chmod 640 /var/log/labapp/auth.log
```

**2. Write a helper script that simulates failures:**

```bash
sudo tee /usr/local/bin/labapp-fail.sh > /dev/null << 'EOF'
#!/bin/bash
IP="${1:-198.51.100.99}"
COUNT="${2:-6}"
for i in $(seq 1 $COUNT); do
  echo "$(date '+%Y-%m-%d %H:%M:%S') [AUTH_FAIL] Invalid credentials for user 'admin' source_ip=${IP}" \
    >> /var/log/labapp/auth.log
  sleep 0.5
done
echo "Wrote $COUNT failure lines for IP $IP"
EOF
sudo chmod +x /usr/local/bin/labapp-fail.sh
```

**3. Write a success line helper:**

```bash
sudo tee /usr/local/bin/labapp-ok.sh > /dev/null << 'EOF'
#!/bin/bash
IP="${1:-10.0.0.5}"
echo "$(date '+%Y-%m-%d %H:%M:%S') [AUTH_OK] Login successful for user 'alice' source_ip=${IP}" \
  >> /var/log/labapp/auth.log
echo "Wrote success line for IP $IP"
EOF
sudo chmod +x /usr/local/bin/labapp-ok.sh
```

---

### Part B — Write the Filter

**4. Create the filter file:**

```bash
sudo tee /etc/fail2ban/filter.d/labapp.conf > /dev/null << 'EOF'
[Definition]

# Match lines like:
# 2026-02-15 14:22:01 [AUTH_FAIL] Invalid credentials for user '...' source_ip=<IP>
failregex = \[AUTH_FAIL\] Invalid credentials for user '\S+' source_ip=<HOST>

ignoreregex =
EOF
```

**5. Test the filter against an empty log (should show 0 matches):**

```bash
sudo fail2ban-regex /var/log/labapp/auth.log /etc/fail2ban/filter.d/labapp.conf
```

Expected:
```
Lines: 0 lines, 0 ignored, 0 matched, 0 missed
```

**6. Write some test lines and test again:**

```bash
sudo labapp-fail.sh 203.0.113.10 3
sudo labapp-ok.sh 10.0.0.5
sudo fail2ban-regex /var/log/labapp/auth.log /etc/fail2ban/filter.d/labapp.conf
```

Expected:
```
Failregex: 3 total
...
Lines: 4 lines, 0 ignored, 3 matched, 1 missed
```

The success line (`[AUTH_OK]`) should be in `missed` — this is correct.

---

### Part C — Write the Jail

**7. Create the jail configuration:**

```bash
sudo tee /etc/fail2ban/jail.d/labapp.conf > /dev/null << 'EOF'
[labapp]
enabled   = true
filter    = labapp
logpath   = /var/log/labapp/auth.log
backend   = auto
maxretry  = 5
findtime  = 2m
bantime   = 10m
port      = http,https
EOF
```

**8. Reload fail2ban:**

```bash
sudo fail2ban-client reload
```

**9. Verify the jail is active:**

```bash
sudo fail2ban-client status labapp
```

Expected:
```
Status for the jail: labapp
|- Filter
|  |- Currently failed: 3      ← lines from step 6 already counted
|  |- Total failed:     3
|  `- File list:        /var/log/labapp/auth.log
`- Actions
   |- Currently banned: 0
   |- Total banned:     0
   `- Banned IP list:
```

---

### Part D — Trigger a Ban

**10. Clear the log and trigger 6 failures (exceeds maxretry=5):**

```bash
sudo truncate -s 0 /var/log/labapp/auth.log
sleep 2
sudo labapp-fail.sh 192.0.2.55 6
```

**11. Verify the ban:**

```bash
# In fail2ban
sudo fail2ban-client status labapp
```

Expected:
```
|- Currently banned: 1
`- Banned IP list:   192.0.2.55
```

```bash
# In firewalld
sudo firewall-cmd --ipset=f2b-labapp --get-entries
```

Expected:
```
192.0.2.55
```

---

### Part E — Verify Blocked and Clean Up

**12. Confirm the firewalld rule:**

```bash
sudo nft list ruleset | grep -A5 "f2b-labapp"
```

**13. Manual unban:**

```bash
sudo fail2ban-client set labapp unbanip 192.0.2.55
```

**14. Verify removal from firewalld:**

```bash
sudo firewall-cmd --ipset=f2b-labapp --get-entries
```

Expected: empty output.

**15. Check the full ban/unban cycle in the log:**

```bash
sudo journalctl -u fail2ban.service --since "10 minutes ago" --no-pager | grep labapp
```

Expected:
```
fail2ban.actions[...]: NOTICE  [labapp] Ban 192.0.2.55
fail2ban.actions[...]: NOTICE  [labapp] Unban 192.0.2.55
```

---

### Lab Summary

| Step | What you did | What you verified |
|------|-------------|-------------------|
| A | Created log infrastructure | Log directory and test scripts |
| B | Wrote filter + tested with fail2ban-regex | 3 failures matched, 1 success missed |
| C | Wrote jail configuration | Jail active in fail2ban status |
| D | Triggered ban with 6 failures | IP appeared in fail2ban status and firewalld ipset |
| E | Unbanned manually | IP removed from ipset |

**You have successfully built a custom jail and filter from scratch.**

### Lab Complete ✓

**Self-check — verify you can answer yes to each:**

- [ ] My custom filter file passes `fail2ban-regex` with the correct match count
- [ ] `fail2ban-client status labapp` shows the jail as active with `backend = auto`
- [ ] After 6 failures (over 4 triggers), the test IP appeared in `fail2ban-client status labapp`
- [ ] The ban appeared in `firewall-cmd --ipset=f2b-labapp --get-entries`
- [ ] `fail2ban-client set labapp unbanip <IP>` successfully cleared the ban
- [ ] I know where to put custom filters (`filter.d/`) and jail configs (`jail.d/`) and why I use `.local` overrides

### Next Steps

Proceed to **[Module 10 — Advanced Topics](./10-advanced-topics.md)**
to learn recidive jails, incremental ban time, GeoIP blocking, and rate-limiting.

---

| ← Previous | Home | Next → |
|-------------|------|---------|
| [08 — Firewalld Integration](./08-firewalld-integration.md) | [Course README](./README.md) | [10 — Advanced Topics](./10-advanced-topics.md) |

---

*Licensed under [CC BY-NC-SA 4.0](LICENSE.md) · © 2026 UncleJS*