# Module 08 — Firewalld Integration
[![CC BY-NC-SA 4.0](https://img.shields.io/badge/License-CC%20BY--NC--SA%204.0-lightgrey)](./LICENSE.md)
[![RHEL 10](https://img.shields.io/badge/platform-RHEL%2010-red)](https://access.redhat.com/products/red-hat-enterprise-linux)
[![fail2ban](https://img.shields.io/badge/fail2ban-RHEL%2010-red)](https://access.redhat.com/products/red-hat-enterprise-linux)

> **Level:** Intermediate  
> **Prerequisites:** [Module 07 — Actions](./07-actions.md)  
> **Time to complete:** ~75 minutes

---

## Table of Contents

1. [Why Firewalld on RHEL 10?](#1-why-firewalld-on-rhel-10)
2. [Firewalld Core Concepts](#2-firewalld-core-concepts)
3. [How Fail2ban Talks to Firewalld](#3-how-fail2ban-talks-to-firewalld)
4. [firewallcmd-ipset Action In Depth](#4-firewallcmd-ipset-action-in-depth)
5. [firewallcmd-new Action In Depth](#5-firewallcmd-new-action-in-depth)
6. [firewallcmd-allports Action In Depth](#6-firewallcmd-allports-action-in-depth)
7. [Choosing the Right Zone](#7-choosing-the-right-zone)
8. [Verifying Bans in Firewalld](#8-verifying-bans-in-firewalld)
9. [IPv6 Support](#9-ipv6-support)
10. [Permanent vs Runtime Rules](#10-permanent-vs-runtime-rules)
11. [Firewalld and Fail2ban Startup Order](#11-firewalld-and-fail2ban-startup-order)
12. [Lab 08 — Deep Firewalld Integration Inspection](#12-lab-08--deep-firewalld-integration-inspection)
13. [Summary](#13-summary)

---

## 1. Why Firewalld on RHEL 10?

RHEL 10 uses **firewalld** as its default firewall management layer. Firewalld
is a dynamic firewall daemon that:

- Manages the underlying nftables rules
- Provides a D-Bus API for runtime rule management
- Supports **zones** (named rule sets for different trust levels)
- Supports **ipsets** (kernel hash tables for efficient multi-IP blocking)
- Allows rule changes **without restarting** the firewall service

Fail2ban integrates with firewalld via the `firewall-cmd` CLI tool, which
communicates with the firewalld D-Bus interface.

```
fail2ban-server
      |
      |  Calls firewall-cmd (CLI)
      v
firewall-cmd  --> D-Bus --> firewalld daemon
                                    |
                                    v
                              nftables rules
                              (kernel level)
```

[↑ Back to TOC](#table-of-contents)

---

## 2. Firewalld Core Concepts

### Zones

A **zone** is a named collection of firewall rules. Each network interface is
assigned to a zone. The default zone on RHEL 10 is usually `public`.

```bash
# List all zones
sudo firewall-cmd --list-all-zones | grep "^[a-z]"

# Get the default zone
sudo firewall-cmd --get-default-zone

# Get the active zones (zones with interfaces assigned)
sudo firewall-cmd --get-active-zones
```

Common zones:

| Zone | Trust Level | Typical Use |
|------|------------|-------------|
| `drop` | No trust — drop everything | Maximum security, no inbound |
| `block` | No trust — reject everything | Reject with ICMP messages |
| `public` | Low trust | Internet-facing servers (default) |
| `dmz` | Partial trust | DMZ servers |
| `trusted` | Full trust | Internal management networks |

### Rich Rules

A **rich rule** is a fully expressive firewall rule. Syntax:

```
rule family="ipv4" source address="<ip>" [port port="<n>" protocol="tcp"] drop|reject|accept
```

Examples:

```bash
# Block all traffic from an IP
sudo firewall-cmd --add-rich-rule='rule family=ipv4 source address="185.220.101.5" drop'

# Block specific port from an IP
sudo firewall-cmd --add-rich-rule='rule family=ipv4 source address="185.220.101.5" port port="22" protocol="tcp" reject'
```

### ipsets

An **ipset** is a named collection of IP addresses stored in a kernel hash
table. Blocking an entire ipset with one rule is far more efficient than
one rich rule per IP.

```bash
# Create an ipset
sudo firewall-cmd --permanent --new-ipset=myblock --type=hash:ip

# Add an IP to the ipset
sudo firewall-cmd --ipset=myblock --add-entry=185.220.101.5

# Block the entire ipset with one rich rule
sudo firewall-cmd --add-rich-rule='rule family=ipv4 source ipset=myblock drop'
```

**Performance benefit:** 10,000 IP lookups in an ipset takes microseconds vs
milliseconds for 10,000 individual rules. This matters on busy servers.

[↑ Back to TOC](#table-of-contents)

---

## 3. How Fail2ban Talks to Firewalld

Fail2ban uses `firewall-cmd` shell commands (not the D-Bus API directly). Each
ban/unban action calls `firewall-cmd` with appropriate arguments.

### The call sequence for a ban (firewallcmd-ipset)

1. **Jail starts** → `actionstart` runs:

```bash
firewall-cmd --permanent --new-ipset=fail2ban-sshd --type=hash:ip \
  --option=maxelem=65536 --option=hashsize=4096 --option=timeout=86400
firewall-cmd --permanent --zone=public \
  --add-rich-rule='rule family=ipv4 source ipset=fail2ban-sshd drop'
firewall-cmd --reload
```

2. **IP banned** → `actionban` runs:

```bash
firewall-cmd --ipset=fail2ban-sshd --add-entry=185.220.101.5
```

3. **Ban expires** → `actionunban` runs:

```bash
firewall-cmd --ipset=fail2ban-sshd --remove-entry=185.220.101.5
```

4. **Jail stops** → `actionstop` runs:

```bash
firewall-cmd --permanent --zone=public \
  --remove-rich-rule='rule family=ipv4 source ipset=fail2ban-sshd drop'
firewall-cmd --permanent --delete-ipset=fail2ban-sshd
firewall-cmd --reload
```

### Why this matters for troubleshooting

If firewalld's D-Bus socket is unavailable or SELinux is blocking fail2ban from
executing `firewall-cmd`, bans will silently fail. Always check both fail2ban
logs AND firewalld status when bans are not working.

[↑ Back to TOC](#table-of-contents)

---

## 4. firewallcmd-ipset Action In Depth

This is the recommended action for production RHEL 10 systems.

```bash
cat /etc/fail2ban/action.d/firewallcmd-ipset.conf
```

### Key characteristics

- Creates one ipset per jail (e.g., `fail2ban-sshd`, `fail2ban-httpd-auth`)
- Each ipset has a **timeout** parameter equal to `bantime` (IPs auto-expire)
- The `--permanent` flag makes the ipset persist across firewalld reloads
- Only one rich rule is added per jail (the ipset membership rule)
- Ban/unban operations are **O(1)** regardless of how many IPs are in the set

### Performance advantage

```
Without ipset (one rich rule per IP):
  100 banned IPs = 100 firewall rules = O(n) packet checking

With ipset (hash table):
  100 banned IPs = 1 firewall rule + 1 hash lookup = O(1) packet checking
```

### Verify ipset configuration

```bash
# List all fail2ban ipsets
sudo firewall-cmd --get-ipsets | tr ' ' '\n' | grep fail2ban
```

```
fail2ban-sshd
fail2ban-httpd-auth
```

```bash
# Get detailed info about an ipset
sudo firewall-cmd --info-ipset=fail2ban-sshd
```

```
fail2ban-sshd
  type: hash:ip
  options: maxelem=65536 hashsize=4096 timeout=86400
  entries:
  185.220.101.5
  45.33.32.156
```

```bash
# Get just the entries
sudo firewall-cmd --ipset=fail2ban-sshd --get-entries
```

[↑ Back to TOC](#table-of-contents)

---

## 5. firewallcmd-new Action In Depth

This action adds individual rich rules per IP. Useful for testing and small
environments.

```bash
cat /etc/fail2ban/action.d/firewallcmd-new.conf
```

### The ban rule it creates

```
rule family="ipv4" source address="185.220.101.5" port port="22" protocol="tcp" reject
```

### Listing all rich rules

```bash
sudo firewall-cmd --list-rich-rules
```

```
rule family="ipv4" source address="185.220.101.5" port port="22" protocol="tcp" reject type="icmp-port-unreachable"
rule family="ipv4" source address="45.33.32.156" port port="22" protocol="tcp" reject type="icmp-port-unreachable"
```

### Counting rich rules

```bash
sudo firewall-cmd --list-rich-rules | wc -l
```

> **Warning:** If you have thousands of bans, this becomes thousands of rich
> rules. firewalld and the kernel slow down significantly. Switch to
> `firewallcmd-ipset` for any production system with significant attack volume.

[↑ Back to TOC](#table-of-contents)

---

## 6. firewallcmd-allports Action In Depth

This action blocks ALL ports from the banned IP, not just the service port:

```bash
cat /etc/fail2ban/action.d/firewallcmd-allports.conf
```

### The ban rule it creates

```
rule family="ipv4" source ipset="fail2ban-sshd" drop
```

Note: no `port` specification — this drops ALL packets from the banned IP.

### When to use this

```ini
[sshd-aggressive]
enabled    = true
port       = any
banaction  = firewallcmd-allports
bantime    = 7d
maxretry   = 3

# For the recidive jail (repeat offenders)
[recidive]
enabled    = true
banaction  = firewallcmd-allports
bantime    = 4w
maxretry   = 5
```

[↑ Back to TOC](#table-of-contents)

---

## 7. Choosing the Right Zone

By default, fail2ban uses the firewalld **default zone** (usually `public`).
You can override this per jail or globally.

### Check which zone your network interface is in

```bash
sudo firewall-cmd --get-active-zones
```

```
public
  interfaces: eth0
```

### Override zone in action file

```bash
sudo tee /etc/fail2ban/action.d/firewallcmd-ipset.local << 'EOF'
[INCLUDES]
before = firewallcmd-ipset.conf

[Init]
zone = public
EOF
```

### Multiple interface scenarios

If your server has multiple interfaces (e.g., `eth0` for public, `eth1` for
private), make sure fail2ban only applies bans to the public-facing zone:

```bash
# Check zone for each interface
sudo firewall-cmd --get-zone-of-interface=eth0
sudo firewall-cmd --get-zone-of-interface=eth1
```

### Using the drop zone for maximum security

The firewalld `drop` zone silently drops all incoming packets (unlike `public`
which uses `reject`). This prevents port scanning:

```ini
# In jail.local for strict environments
[sshd]
enabled   = true
action    = firewallcmd-ipset[name=%(name)s, port="%(port)s", protocol="%(protocol)s", zone=drop]
```

> **Warning:** Add your management IP to `ignoreip` before enabling the `drop`
> zone — dropped packets produce no error message, making debugging much harder.

[↑ Back to TOC](#table-of-contents)

---

## 8. Verifying Bans in Firewalld

After a ban fires, verify it is actually enforced at the firewall level.

### Method 1 — Check ipset entries

```bash
# Quick check: any IPs banned?
sudo firewall-cmd --ipset=fail2ban-sshd --get-entries

# Verbose ipset info with entry count
sudo firewall-cmd --info-ipset=fail2ban-sshd
```

### Method 2 — Check rich rules

```bash
# All rich rules in the default zone
sudo firewall-cmd --list-rich-rules

# Rich rules for a specific zone
sudo firewall-cmd --zone=public --list-rich-rules
```

### Method 3 — Full firewall state

```bash
sudo firewall-cmd --list-all
```

```
public (active)
  target: default
  icmp-block-inversion: no
  interfaces: eth0
  sources:
  services: cockpit dhcpv6-client ssh
  ports:
  protocols:
  forward: yes
  masquerade: no
  forward-ports:
  source-ports:
  icmp-blocks:
  rich rules:
        rule family="ipv4" source ipset="fail2ban-sshd" drop
        rule family="ipv4" source ipset="fail2ban-httpd-auth" drop
```

### Method 4 — Query a specific IP

```bash
IP="185.220.101.5"
sudo firewall-cmd --ipset=fail2ban-sshd --query-entry=$IP
```

Output: `yes` if the IP is banned, `no` if not.

### Method 5 — View nftables rules directly

```bash
# See the actual kernel-level rules (advanced)
sudo nft list ruleset | grep -A 5 "fail2ban"
```

### Cross-reference fail2ban with firewalld

```bash
echo "=== Fail2ban banned IPs ==="
sudo fail2ban-client status sshd | grep "Banned IP"

echo ""
echo "=== Firewalld ipset entries ==="
sudo firewall-cmd --ipset=fail2ban-sshd --get-entries
```

These two lists should match. If they do not, see Module 13 Troubleshooting.

[↑ Back to TOC](#table-of-contents)

---

## 9. IPv6 Support

Fail2ban supports both IPv4 and IPv6. The `firewallcmd-ipset` action creates
separate ipsets for each:

- `fail2ban-sshd` for IPv4 addresses
- `fail2ban-sshd6` for IPv6 addresses (if configured)

### Check IPv6 ipsets

```bash
sudo firewall-cmd --get-ipsets | tr ' ' '\n' | grep fail2ban
```

You may see:

```
fail2ban-sshd
fail2ban-sshd6
```

### Verify IPv6 bans

```bash
sudo firewall-cmd --ipset=fail2ban-sshd6 --get-entries
```

### IPv6 in ignoreip

```ini
[DEFAULT]
ignoreip = 127.0.0.1/8
           ::1
           ::ffff:0:0/96
           2001:db8::/32
```

[↑ Back to TOC](#table-of-contents)

---

## 10. Permanent vs Runtime Rules

Firewalld has two rule layers:

- **Runtime**: Active immediately, lost on firewalld restart or reload
- **Permanent**: Written to disk, survive restarts (loaded at startup)

### How fail2ban uses these layers

The `firewallcmd-ipset` action uses:

- `--permanent` for ipset **creation** and the rich **rule referencing it**
- No `--permanent` for ipset **entries** (individual banned IPs)

This means:
- The ipset infrastructure (creation + rich rule) **survives** firewalld restarts
- Individual IP entries in the ipset are **runtime only** — fail2ban restores
  them from the SQLite database after any restart

### The brief gap after firewalld restarts

When firewalld is restarted:
1. Permanent config loads (ipset definition + rich rule are present)
2. Runtime ipset entries are gone (no IPs in the set yet)
3. For a few seconds, previously banned IPs can connect again
4. Fail2ban detects the issue and re-applies all active bans from the database

```bash
# Prefer reload over restart to minimise disruption
sudo firewall-cmd --reload
```

### Verify permanent rules

```bash
# Check what is in the permanent configuration
sudo firewall-cmd --permanent --list-rich-rules
sudo firewall-cmd --permanent --get-ipsets
```

[↑ Back to TOC](#table-of-contents)

---

## 11. Firewalld and Fail2ban Startup Order

Fail2ban **requires firewalld to be running** before it starts. If firewalld
starts after fail2ban, the `actionstart` commands will fail and no bans will
be enforced.

### Verify systemd ordering

```bash
cat /usr/lib/systemd/system/fail2ban.service | grep After
```

Expected:

```ini
After=network.target iptables.service firewalld.service nftables.service
```

The `After=firewalld.service` line ensures fail2ban starts after firewalld.

### What happens at startup

1. `firewalld.service` starts — firewall daemon ready
2. `fail2ban.service` starts — reads config
3. For each enabled jail, fail2ban runs `actionstart`:
   - Creates the ipset if it does not exist
   - Adds the rich rule if it does not exist
   - Reloads firewalld to activate permanent rules
4. Fail2ban reads the SQLite database and re-applies unexpired bans

### If fail2ban starts before firewalld

```
ERROR   Failed to execute ban jail 'sshd' action 'firewallcmd-ipset' ...
ERROR   firewall-cmd: FirewallD is not running.
```

Fix:

```bash
sudo systemctl restart fail2ban
```

[↑ Back to TOC](#table-of-contents)

---

## 12. Lab 08 — Deep Firewalld Integration Inspection

### Step 1 — Baseline firewalld state

```bash
echo "=== Baseline firewalld state ==="
sudo firewall-cmd --list-all
echo ""
echo "=== Current ipsets ==="
sudo firewall-cmd --get-ipsets
```

### Step 2 — Examine existing fail2ban ipsets

```bash
for ipset in $(sudo firewall-cmd --get-ipsets | tr ' ' '\n' | grep fail2ban); do
  echo "=== ipset: $ipset ==="
  sudo firewall-cmd --info-ipset=$ipset
  echo ""
done
```

### Step 3 — Ban a test IP and trace every firewalld change

Open two terminals:

**Terminal 1** — watch firewalld state:

```bash
watch -n 1 "sudo firewall-cmd --ipset=fail2ban-sshd --get-entries 2>/dev/null"
```

**Terminal 2** — trigger the ban:

```bash
sudo fail2ban-client set sshd banip 203.0.113.55
```

Watch Terminal 1 update — you should see `203.0.113.55` appear.

### Step 4 — Verify at every layer

```bash
# Fail2ban layer
sudo fail2ban-client status sshd | grep "Banned IP"

# Firewalld ipset layer
sudo firewall-cmd --ipset=fail2ban-sshd --get-entries

# Firewalld rich rule layer
sudo firewall-cmd --list-rich-rules

# nftables kernel layer
sudo nft list ruleset 2>/dev/null | grep -A3 "fail2ban" | head -20
```

### Step 5 — Query a specific entry

```bash
sudo firewall-cmd --ipset=fail2ban-sshd --query-entry=203.0.113.55
```

Expected: `yes`

### Step 6 — Simulate a firewalld reload

```bash
echo "Before reload:"
sudo firewall-cmd --ipset=fail2ban-sshd --get-entries

sudo firewall-cmd --reload

echo "Immediately after reload:"
sudo firewall-cmd --ipset=fail2ban-sshd --get-entries

sleep 10

echo "10 seconds after reload:"
sudo firewall-cmd --ipset=fail2ban-sshd --get-entries
```

Observe how fail2ban re-applies the ban after the reload.

### Step 7 — Clean up

```bash
sudo fail2ban-client set sshd unbanip 203.0.113.55
sudo firewall-cmd --ipset=fail2ban-sshd --get-entries
```

Expected: empty list.

### Step 8 — Check permanent vs runtime config

```bash
echo "=== Permanent rich rules ==="
sudo firewall-cmd --permanent --list-rich-rules

echo ""
echo "=== Runtime rich rules ==="
sudo firewall-cmd --list-rich-rules
```

Both should show the same `fail2ban-sshd` ipset rule.

### Lab Complete ✓

**Self-check — verify you can answer yes to each:**

- [ ] `firewall-cmd --get-ipsets` lists at least one `f2b-*` ipset
- [ ] `firewall-cmd --ipset=f2b-sshd --get-entries` shows current bans (or empty if none active)
- [ ] I can trace a ban all the way from fail2ban status → ipset entry → nftables rule using `nft list ruleset`
- [ ] I understand why fail2ban bans are *runtime* rules (they are cleared on firewalld restart — that is intentional)
- [ ] I know the performance difference between `firewallcmd-ipset` (O(1)) and `firewallcmd-new` (O(n))
- [ ] `systemctl list-dependencies fail2ban` shows `firewalld` as a dependency

[↑ Back to TOC](#table-of-contents)

---

## 13. Summary

In this module you learned:

- **Why firewalld** is used on RHEL 10: it manages nftables via a D-Bus API
- **Firewalld concepts**: zones, rich rules, and ipsets
- **How fail2ban communicates** with firewalld via `firewall-cmd` shell calls
- **Three firewalld actions** compared:
  - `firewallcmd-ipset` — ipset-based, O(1) performance, production-ready
  - `firewallcmd-new` — one rich rule per IP, easy inspection, testing only
  - `firewallcmd-allports` — block all ports from banned IP
- **Zone selection**: default is `public`, use `drop` for strict environments
- **Verifying bans** at every layer: fail2ban status, ipset entries, rich rules, nftables
- **IPv6 support** with separate ipsets per jail
- **Permanent vs runtime** rules: why fail2ban uses runtime entries for bans
- **Startup order**: firewalld must start before fail2ban (enforced by systemd)

### Next Steps

Proceed to **[Module 09 — Custom Jails & Filters](./09-custom-jails-and-filters.md)**
to learn how to protect any service by writing your own jails and filters.

---

| <- Previous | Home | Next -> |
|-------------|------|---------|
| [07 — Actions](./07-actions.md) | [Course README](./README.md) | [09 — Custom Jails & Filters](./09-custom-jails-and-filters.md) |

---

*Licensed under [CC BY-NC-SA 4.0](LICENSE.md) · © 2026 UncleJS*