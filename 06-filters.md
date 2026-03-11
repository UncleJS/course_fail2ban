# Module 06 — Filters
[![CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey)](./LICENSE.md)
[![RHEL 10](https://img.shields.io/badge/platform-RHEL%2010-red)](https://access.redhat.com/products/red-hat-enterprise-linux)
[![fail2ban](https://img.shields.io/badge/fail2ban-RHEL%2010-red)](https://access.redhat.com/products/red-hat-enterprise-linux)

> **Level:** Intermediate  
> **Prerequisites:** [Module 05 — Jails](./05-jails.md)  
> **Time to complete:** ~60 minutes

---

## Table of Contents

1. [What Is a Filter?](#1-what-is-a-filter)
2. [Filter File Structure](#2-filter-file-structure)
3. [The failregex Syntax](#3-the-failregex-syntax)
4. [The HOST Placeholder](#4-the-host-placeholder)
5. [The ignoreregex Directive](#5-the-ignoreregex-directive)
6. [Common Built-in Filters Explained](#6-common-built-in-filters-explained)
7. [RHEL 10 Log Format Differences](#7-rhel-10-log-format-differences)
8. [Testing Filters with fail2ban-regex](#8-testing-filters-with-fail2ban-regex)
9. [Overriding a Filter with a .local File](#9-overriding-a-filter-with-a-local-file)
10. [Regex Anchoring and Performance](#10-regex-anchoring-and-performance)
11. [Lab 06 — Test and Tune the SSHD Filter](#11-lab-06--test-and-tune-the-sshd-filter)
12. [Summary](#12-summary)

---

## 1. What Is a Filter?

A **filter** is a file in `/etc/fail2ban/filter.d/` containing one or more
regular expressions. These regexes are tested against incoming log lines to
detect malicious behaviour and extract the offending IP address.

```
Log line arrives
      │
      ▼
Test against failregex patterns
      │
      ├─► No match   → ignored
      │
      └─► Match      → extract <HOST> IP → increment fail counter
```

Filters are referenced by jail configuration using the `filter = <name>`
parameter, where `<name>` is the filename without the `.conf` extension.

[↑ Back to TOC](#table-of-contents)

---

## 2. Filter File Structure

Every filter file follows this structure:

```ini
# /etc/fail2ban/filter.d/example.conf

[INCLUDES]
# Optional: include shared definitions
before = common.conf

[DEFAULT]
# Optional: define reusable variables
_daemon = sshd
__prefix_line = ...

[Definition]
# REQUIRED: regex patterns that match failure events
failregex = <pattern1>
            <pattern2>

# OPTIONAL: regex patterns to explicitly ignore (whitelist certain matches)
ignoreregex =

# OPTIONAL: hint about which log lines to pre-filter (performance)
journalmatch = _SYSTEMD_UNIT=sshd.service + _COMM=sshd
```

### The sections explained

| Section | Purpose |
|---------|---------|
| `[INCLUDES]` | Load shared variable definitions from other files |
| `[DEFAULT]` | Define reusable variables for this filter |
| `[Definition]` | The actual `failregex`, `ignoreregex`, `journalmatch` |

[↑ Back to TOC](#table-of-contents)

---

## 3. The failregex Syntax

`failregex` is a Python regular expression with fail2ban-specific extensions.

### Basic structure

```
failregex = <prefix> <message containing HOST>
```

### Multiple patterns

Each line is a separate regex pattern. Any one match triggers the filter:

```ini
failregex = ^.*Failed password for .* from <HOST>.*$
            ^.*Invalid user .* from <HOST>.*$
            ^.*authentication failure.*rhost=<HOST>.*$
```

### The `%(__prefix_line)s` variable

This special variable matches the common syslog prefix format:

```
Jan 10 10:15:42 server sshd[1234]:
└─────────────────────────────────┘
      matched by %(__prefix_line)s
```

Using this makes your regex work regardless of the specific timestamp or
hostname format:

```ini
failregex = ^%(__prefix_line)sFailed password for .* from <HOST>.*$
```

### Regex special characters recap

| Character | Meaning |
|-----------|---------|
| `.` | Any single character |
| `.*` | Any sequence of characters (greedy) |
| `.*?` | Any sequence of characters (non-greedy) |
| `\s` | Whitespace |
| `\d` | Digit |
| `\S+` | One or more non-whitespace characters |
| `(?:...)` | Non-capturing group |
| `(?P<name>...)` | Named capture group |
| `^` | Start of line |
| `$` | End of line |
| `\b` | Word boundary |

[↑ Back to TOC](#table-of-contents)

---

## 4. The HOST Placeholder

`<HOST>` is the most important element in any failregex. It is a **special
placeholder** that fail2ban replaces with a regex matching both IPv4 and IPv6
addresses. The IP that matches at this position is the one that gets banned.

### What `<HOST>` expands to

```
<HOST> → (?:::f{4,6}:)?(?P<host>[\w\-.^_]+)
```

In practice it matches:
- IPv4: `192.168.1.100`
- IPv6: `2001:db8::1`
- IPv4-mapped IPv6: `::ffff:192.168.1.100`
- Hostnames: `attacker.example.com`

### `<HOST>` must appear exactly once per pattern

```ini
# CORRECT — <HOST> appears once
failregex = Failed password for .* from <HOST> port \d+

# WRONG — <HOST> appears twice (fail2ban error)
failregex = Failed password for <HOST> from <HOST> port \d+

# WRONG — <HOST> is missing (no IP extracted, fail2ban can't ban)
failregex = Failed password for root
```

### Testing HOST extraction

Use `fail2ban-regex` to verify the IP is being extracted correctly:

```bash
echo "Jan 10 10:15:42 server sshd[1234]: Failed password for root from 185.220.101.5 port 44312 ssh2" | \
  sudo fail2ban-regex - /etc/fail2ban/filter.d/sshd.conf
```

[↑ Back to TOC](#table-of-contents)

---

## 5. The ignoreregex Directive

`ignoreregex` defines patterns that should **not** trigger a ban even if they
match a `failregex`. Lines matching `ignoreregex` are silently discarded.

### Use cases

```ini
ignoreregex = for user root from 127\.0\.0\.1
              from ::1
              .*internal-health-check.*
```

### Order of processing

```
1. Test line against failregex
   - If no match: IGNORE
   - If match: proceed to step 2

2. Test matched line against ignoreregex
   - If match: IGNORE (override the failregex match)
   - If no match: EXTRACT IP and increment counter
```

### Example: ignore health check failures

If your monitoring system's health checks produce log entries that look like
failed logins but aren't:

```ini
[Definition]
failregex   = authentication failure for .* from <HOST>
ignoreregex = authentication failure for healthcheck from <HOST>
```

[↑ Back to TOC](#table-of-contents)

---

## 6. Common Built-in Filters Explained

### sshd filter

```bash
cat /etc/fail2ban/filter.d/sshd.conf
```

Key patterns it matches:
```
Failed password for root from 185.220.101.5 port 44312 ssh2
Failed password for invalid user admin from 45.33.32.156
Invalid user postgres from 103.99.0.122 port 39456
authentication failure; logname= uid=0 rhost=194.165.16.72
```

### httpd-auth filter

```bash
cat /etc/fail2ban/filter.d/httpd-auth.conf
```

Key patterns:
```
[error] [client 185.220.101.5] user admin: authentication failure
[error] [client 185.220.101.5] Authorization Required
```

### apache-badbots filter

Uses a list of known bad bot User-Agent strings:
```
GET /index.php HTTP/1.1 200 - "libwww-perl/5.805"
POST /wp-login.php HTTP/1.1 200 - "masscan/1.0"
```

### postfix filter

```bash
cat /etc/fail2ban/filter.d/postfix.conf
```

Key patterns:
```
SASL LOGIN authentication failed: authentication failure
warning: unknown[185.220.101.5]: SASL LOGIN authentication failed
```

### recidive filter

Reads fail2ban's OWN log to catch repeat offenders:
```
2026-01-10 10:15:45,004 fail2ban.actions [12346]: NOTICE  [sshd] Ban 185.220.101.5
```

[↑ Back to TOC](#table-of-contents)

---

## 7. RHEL 10 Log Format Differences

RHEL 10 (and Fedora) log formats differ from Debian/Ubuntu. This is important
when writing or troubleshooting filters.

### RHEL 10 syslog format (in `/var/log/secure`)

```
Jan 10 10:15:42 hostname sshd[1234]: Failed password for root from 185.220.101.5 port 44312 ssh2
```

### RHEL 10 journald format (what systemd backend reads)

```
-- Journal begins at ...
Jan 10 10:15:42 hostname sshd[1234]: Failed password for root from 185.220.101.5 port 44312 ssh2
```

The journald format is similar to syslog but with additional metadata fields
(like `_SYSTEMD_UNIT`, `_COMM`) that can be used for pre-filtering.

### Key RHEL 10 log file paths

| Service | Log Location | Backend |
|---------|-------------|---------|
| SSH | journald / `/var/log/secure` | `systemd` |
| Apache httpd | `/var/log/httpd/error_log` | `auto` |
| Nginx | `/var/log/nginx/error.log` | `auto` |
| Postfix | journald / `/var/log/maillog` | `systemd` |
| Dovecot | journald / `/var/log/maillog` | `systemd` |
| Firewalld | journald | `systemd` |
| Fail2ban itself | `/var/log/fail2ban.log` | `auto` |

### Why filters from other distros may not work

Debian/Ubuntu log some services to `/var/log/auth.log` with a slightly different
format. If you copy a filter written for Ubuntu, test it with your actual RHEL 10
log lines before deploying.

[↑ Back to TOC](#table-of-contents)

---

## 8. Testing Filters with fail2ban-regex

`fail2ban-regex` is the primary tool for developing and debugging filters.
**Always test before deploying.**

### Basic usage

```bash
fail2ban-regex <log-file-or-line> <filter-file>
```

### Test against a live log file

```bash
sudo fail2ban-regex /var/log/secure /etc/fail2ban/filter.d/sshd.conf
```

**Output:**
```
Running tests
=============

Use   failregex filter file : sshd, basedir: /etc/fail2ban
Use         log file : /var/log/secure
Use         encoding : UTF-8


Results
=======

Failregex: 47 total
|-  #) [# of hits] regular expression
|   1) [32] ^%(__prefix_line)sFailed \S+ for .* from <HOST>( port \d+)?(?: ssh\d*)?(\s|$)
|   2) [8]  ^%(__prefix_line)s(?:error: PAM: )?[aA]uthentication (?:failure|error|failed) for .*
|   3) [7]  ^%(__prefix_line)sROOT LOGIN REFUSED from <HOST>\s*$

Ignoreregex: 0 total

Date template hits:
|- [# of hits] date template
`-  [47] {^LN-BEG}(?:DAY )?MON Day(?::Hour:Minute:Second)?(?:\.Microseconds)? \[Year\]

Lines: 2847 lines, 0 ignored, 47 matched, 2800 missed
```

### Test a single log line

```bash
echo "Jan 10 10:15:42 server sshd[1234]: Failed password for root from 185.220.101.5 port 44312 ssh2" | \
  fail2ban-regex - /etc/fail2ban/filter.d/sshd.conf
```

### Test against the systemd journal

```bash
sudo fail2ban-regex \
  --journalmatch "_SYSTEMD_UNIT=sshd.service" \
  systemd-journal \
  /etc/fail2ban/filter.d/sshd.conf
```

### Verbose mode — see every line tested

```bash
sudo fail2ban-regex -v /var/log/secure /etc/fail2ban/filter.d/sshd.conf 2>&1 | tail -30
```

### Test a custom regex directly

```bash
# Test a regex string directly (no filter file needed)
sudo fail2ban-regex /var/log/secure \
  "Failed password for .* from <HOST> port \d+"
```

### Understanding the output

| Field | Meaning |
|-------|---------|
| `Failregex: N total` | Total number of lines matched across all patterns |
| `[# of hits] pattern` | How many times each specific pattern matched |
| `Lines: X lines, Y ignored, Z matched, W missed` | Summary |
| `missed` | Lines that did NOT match (could be real attacks you're missing) |

### Investigating missed lines

```bash
# See which lines were NOT matched (potential gaps in your filter)
sudo fail2ban-regex -v /var/log/secure /etc/fail2ban/filter.d/sshd.conf 2>&1 | \
  grep "^MISS" | head -20
```

[↑ Back to TOC](#table-of-contents)

---

## 9. Overriding a Filter with a .local File

To modify a built-in filter without editing the `.conf` file, create a
corresponding `.local` file:

```bash
# Create a .local override for the sshd filter
sudo tee /etc/fail2ban/filter.d/sshd.local << 'EOF'
[INCLUDES]
# Include the original filter first
before = sshd.conf

[Definition]
# Add an ADDITIONAL failregex pattern to catch a specific attack
# This appends to the patterns in sshd.conf
failregex = %(known/failregex)s
            ^%(__prefix_line)sUser .+ from <HOST> not allowed because not listed in AllowUsers\s*$

# Add to ignoreregex to suppress known false positives
ignoreregex = %(known/ignoreregex)s
EOF
```

### The `%(known/failregex)s` pattern

When overriding in a `.local` file, use `%(known/failregex)s` to **include**
the existing patterns from the `.conf` file and add your patterns on top.
Without it, your `.local` file would completely replace the original patterns.

```ini
# This REPLACES all original patterns (usually wrong):
failregex = ^my new pattern from <HOST>$

# This APPENDS to original patterns (usually correct):
failregex = %(known/failregex)s
            ^my new pattern from <HOST>$
```

[↑ Back to TOC](#table-of-contents)

---

## 10. Regex Anchoring and Performance

Poorly written regexes can slow down fail2ban, especially on busy servers
processing thousands of log lines per minute.

### Always anchor your regexes

```ini
# GOOD — anchored with ^ (start) reduces backtracking
failregex = ^%(__prefix_line)sFailed password for .* from <HOST>

# BAD — unanchored, regex engine tests every position in every line
failregex = Failed password for .* from <HOST>
```

### Use specific patterns instead of `.*`

```ini
# GOOD — specific pattern
failregex = ^%(__prefix_line)sFailed \S+ for \S+ from <HOST> port \d+

# LESS GOOD — .* is greedy and slow
failregex = ^%(__prefix_line)sFailed .* from <HOST>.*
```

### Avoid catastrophic backtracking

Nested quantifiers can cause exponential regex performance:

```ini
# DANGEROUS — can cause catastrophic backtracking
failregex = ^(.+)*Failed from <HOST>

# SAFE — no nested quantifiers
failregex = ^%(__prefix_line)sFailed from <HOST>
```

### ReDoS (Regex Denial of Service)

A poorly written regex can be exploited: if an attacker can control log content
(e.g., crafting a username with special characters), they might cause fail2ban's
regex engine to hang, defeating its purpose. Always:
- Anchor regexes with `^`
- Avoid `(.+)+` nested quantifier patterns
- Test with `fail2ban-regex` to measure performance

[↑ Back to TOC](#table-of-contents)

---

## 11. Lab 06 — Test and Tune the SSHD Filter

### Step 1 — Examine the sshd filter

```bash
cat /etc/fail2ban/filter.d/sshd.conf
```

Count the number of `failregex` patterns. Note each one.

### Step 2 — Generate test data from your journal

```bash
sudo journalctl -u sshd --since "24 hours ago" \
  | grep -E "Failed|Invalid user|authentication failure" \
  | head -20
```

Copy one of these lines for step 3.

### Step 3 — Test a single line

```bash
# Replace the line below with one from your actual journal
echo "Jan 10 10:15:42 server sshd[1234]: Failed password for root from 185.220.101.5 port 44312 ssh2" | \
  fail2ban-regex - /etc/fail2ban/filter.d/sshd.conf
```

Expected: `Failregex: 1 total`

### Step 4 — Test against the full journal

```bash
sudo fail2ban-regex \
  --journalmatch "_SYSTEMD_UNIT=sshd.service" \
  systemd-journal \
  /etc/fail2ban/filter.d/sshd.conf
```

Note the total match count and match breakdown per pattern.

### Step 5 — Find "missed" lines (potential gaps)

```bash
sudo fail2ban-regex -v \
  --journalmatch "_SYSTEMD_UNIT=sshd.service" \
  systemd-journal \
  /etc/fail2ban/filter.d/sshd.conf 2>&1 | grep "^MISS" | head -10
```

Are there any SSH failure patterns not being caught?

### Step 6 — Create a filter override (optional)

If you found unmatched attack patterns in step 5, add them:

```bash
sudo tee /etc/fail2ban/filter.d/sshd.local << 'EOF'
[INCLUDES]
before = sshd.conf

[Definition]
failregex = %(known/failregex)s
# Add any additional patterns you discovered here:
# ^%(__prefix_line)sYOUR_PATTERN from <HOST>.*$

ignoreregex = %(known/ignoreregex)s
EOF
```

### Step 7 — Test the override

```bash
sudo fail2ban-regex \
  --journalmatch "_SYSTEMD_UNIT=sshd.service" \
  systemd-journal \
  /etc/fail2ban/filter.d/sshd.local
```

### Step 8 — Reload and verify

```bash
sudo fail2ban-client -t && sudo fail2ban-client reload sshd
sudo fail2ban-client status sshd
```

### Lab Complete ✓

**Self-check — verify you can answer yes to each:**

- [ ] `fail2ban-regex` matched the expected number of failures in the SSH log sample
- [ ] I can identify the `failregex` line(s) in `/etc/fail2ban/filter.d/sshd.conf`
- [ ] I know how to test a filter with `fail2ban-regex <logfile> <filtername>`
- [ ] I added a custom `failregex` to `jail.d/sshd-local.conf` (not the shipped file) and reloaded
- [ ] `fail2ban-client -t` passes after my filter changes
- [ ] I understand the difference between `failregex` (match = bad) and `ignoreregex` (match = skip)

[↑ Back to TOC](#table-of-contents)

---

## 12. Summary

In this module you learned:

- What a **filter** is: a file of regex patterns that detect bad log entries
- **Filter file structure**: `[INCLUDES]`, `[DEFAULT]`, `[Definition]`
- The **`failregex` syntax** and how multiple patterns work
- The **`<HOST>` placeholder**: the single most important element in any filter
- **`ignoreregex`**: how to suppress known false positives
- Common **built-in filters** and what attack patterns they detect
- **RHEL 10 log format differences** compared to other distros
- How to **test filters** with `fail2ban-regex` — your most important debugging tool
- How to **override a filter** with a `.local` file without touching the original
- **Regex anchoring** and performance considerations to avoid ReDoS

### Next Steps

Proceed to **[Module 07 — Actions](./07-actions.md)** to understand how fail2ban
tells firewalld to block offending IPs.

[↑ Back to TOC](#table-of-contents)

---

| ← Previous | Home | Next → |
|-----------|------|--------|
| [05 — Jails](./05-jails.md) | [Course README](./README.md) | [07 — Actions](./07-actions.md) |

---

*Licensed under [CC BY-NC-SA 4.0](LICENSE.md) · © 2026 UncleJS*