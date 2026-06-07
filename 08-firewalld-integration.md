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
5. [firewallcmd-rich-rules Action In Depth](#5-firewallcmd-rich-rules-action-in-depth)
6. [firewallcmd-allports Action In Depth](#6-firewallcmd-allports-action-in-depth)
7. [Zones and How Fail2ban Rules Relate to Them](#7-zones-and-how-fail2ban-rules-relate-to-them)
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
one rule per IP.

There are two ways to work with ipsets on RHEL 10:

```bash
# 1. firewalld-managed ipsets (what firewall-cmd creates and lists):
sudo firewall-cmd --permanent --new-ipset=myblock --type=hash:ip
sudo firewall-cmd --ipset=myblock --add-entry=185.220.101.5
sudo firewall-cmd --add-rich-rule='rule family=ipv4 source ipset=myblock drop'

# 2. Raw kernel ipsets (created with the ipset binary):
sudo ipset create myblock hash:ip
sudo ipset add myblock 185.220.101.5
sudo ipset list myblock
```

> **Important for fail2ban:** the `firewallcmd-ipset` action uses the **second**
> method — raw kernel ipsets named `f2b-<jail>` plus one `firewall-cmd --direct`
> rule that matches the set. These sets do **not** appear in
> `firewall-cmd --get-ipsets`; you inspect them with `ipset list`.

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
# Create the kernel ipset (raw ipset binary — not firewalld-managed)
ipset -exist create f2b-sshd hash:ip maxelem 65536

# Add ONE direct rule that rejects anything in the set
firewall-cmd --direct --add-rule ipv4 filter INPUT_direct 0 \
  -p tcp -m multiport --dports 22 \
  -m set --match-set f2b-sshd src -j REJECT --reject-with icmp-port-unreachable
```

2. **IP banned** → `actionban` runs:

```bash
ipset -exist add f2b-sshd 185.220.101.5
```

3. **Ban expires** → `actionunban` runs:

```bash
ipset -exist del f2b-sshd 185.220.101.5
```

4. **Jail stops** → `actionstop` runs:

```bash
firewall-cmd --direct --remove-rule ipv4 filter INPUT_direct 0 \
  -p tcp -m multiport --dports 22 \
  -m set --match-set f2b-sshd src -j REJECT --reject-with icmp-port-unreachable
ipset flush f2b-sshd
ipset destroy f2b-sshd
```

### And for the EPEL default (firewallcmd-rich-rules)

With the default action there is no setup at all — each ban simply adds one
rich rule, and each unban removes it:

```bash
# actionban:
firewall-cmd --add-rich-rule="rule family='ipv4' source address='185.220.101.5' port port='22' protocol='tcp' reject type='icmp-port-unreachable'"

# actionunban:
firewall-cmd --remove-rich-rule="rule family='ipv4' source address='185.220.101.5' port port='22' protocol='tcp' reject type='icmp-port-unreachable'"
```

### Why this matters for troubleshooting

If firewalld's D-Bus socket is unavailable or SELinux is blocking fail2ban from
executing `firewall-cmd`/`ipset`, bans will silently fail. Always check both
fail2ban logs AND firewalld status when bans are not working — and remember
which action a jail uses, because that decides *where* you look for the ban
(`ipset list` vs `firewall-cmd --list-rich-rules`).

[↑ Back to TOC](#table-of-contents)

---

## 4. firewallcmd-ipset Action In Depth

This is the recommended action for busy production RHEL 10 systems.

```bash
cat /etc/fail2ban/action.d/firewallcmd-ipset.conf
```

### Key characteristics

- Creates one kernel ipset per jail (e.g., `f2b-sshd`, `f2b-httpd-auth`)
  using the `ipset` binary
- Adds exactly **one** `firewall-cmd --direct` rule per jail (the set-match rule)
- Unban timing is managed by fail2ban itself (the set is created without a
  timeout by default; fail2ban removes entries when `bantime` expires)
- Ban/unban operations are **O(1)** regardless of how many IPs are in the set

> **Heads-up:** firewalld's `--direct` interface is deprecated upstream. It
> still works on RHEL 10, but this is why EPEL defaults to the rich-rules
> action. Use `firewallcmd-ipset` when ban volume justifies it.

### Performance advantage

```
Without ipset (one rich rule per IP):
  100 banned IPs = 100 firewall rules = O(n) packet checking

With ipset (hash table):
  100 banned IPs = 1 firewall rule + 1 hash lookup = O(1) packet checking
```

### Verify ipset configuration

```bash
# List all fail2ban ipsets (note: ipset binary, NOT firewall-cmd --get-ipsets)
sudo ipset list -n | grep f2b
```

```
f2b-sshd
f2b-httpd-auth
```

```bash
# Get detailed info about an ipset, including its entries
sudo ipset list f2b-sshd
```

```
Name: f2b-sshd
Type: hash:ip
Revision: 4
Header: family inet hashsize 1024 maxelem 65536
Size in memory: 376
References: 1
Number of entries: 2
Members:
185.220.101.5
45.33.32.156
```

```bash
# Check whether one specific IP is banned
sudo ipset test f2b-sshd 185.220.101.5
```

[↑ Back to TOC](#table-of-contents)

---

## 5. firewallcmd-rich-rules Action In Depth

This action adds individual rich rules per IP. It is the **EPEL default** on
RHEL 10 (set by `jail.d/00-firewalld.conf`) and is ideal for small and medium
environments.

```bash
cat /etc/fail2ban/action.d/firewallcmd-rich-rules.conf
cat /etc/fail2ban/jail.d/00-firewalld.conf
```

### The ban rule it creates

```
rule family="ipv4" source address="185.220.101.5" port port="22" protocol="tcp" reject type="icmp-port-unreachable"
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

### What it does under the hood

At jail start it creates a dedicated direct chain (`f2b-<jail>`) hooked into
the filter table; each ban adds one per-IP rule to that chain:

```bash
# actionstart (once):
firewall-cmd --direct --add-chain ipv4 filter f2b-sshd
firewall-cmd --direct --add-rule ipv4 filter f2b-sshd 1000 -j RETURN
firewall-cmd --direct --add-rule ipv4 filter INPUT_direct 0 -j f2b-sshd

# actionban (per IP):
firewall-cmd --direct --add-rule ipv4 filter f2b-sshd 0 -s 185.220.101.5 -j REJECT --reject-with icmp-port-unreachable
```

Note: no `port` match anywhere — this rejects ALL packets from the banned IP.

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

## 7. Zones and How Fail2ban Rules Relate to Them

Firewalld zones control which rules apply to which interfaces. How fail2ban's
bans interact with zones depends on the action:

| Action | Zone behaviour |
|--------|---------------|
| `firewallcmd-rich-rules` | Rich rules are added to the **default zone** |
| `firewallcmd-ipset` / `firewallcmd-allports` | `--direct` rules sit in the filter table **before** zone processing — they apply to **all interfaces**, regardless of zone |

### Check which zone your network interface is in

```bash
sudo firewall-cmd --get-active-zones
```

```
public
  interfaces: eth0
```

### Multiple interface scenarios

If your server has multiple interfaces (e.g., `eth0` for public, `eth1` for
private/management):

- With the **direct-rule actions** (`firewallcmd-ipset`, `firewallcmd-allports`),
  a banned IP is blocked on every interface. If internal hosts could ever match
  a filter (e.g., a misbehaving monitoring system), make sure their ranges are
  in `ignoreip`.
- With **rich rules**, bans land in the default zone only — if your service is
  reachable through an interface in a *different* zone, the ban will not cover
  it. Check with:

```bash
# Check zone for each interface
sudo firewall-cmd --get-zone-of-interface=eth0
sudo firewall-cmd --get-zone-of-interface=eth1
```

### REJECT vs DROP

By default the firewallcmd actions REJECT banned traffic (the attacker gets an
ICMP error). For strict environments you can switch to silently dropping
packets via the `blocktype` parameter:

```ini
# In jail.local — silently drop instead of reject
[sshd]
enabled   = true
banaction = firewallcmd-ipset[blocktype=DROP]
```

> **Warning:** Add your management IP to `ignoreip` before switching to DROP —
> dropped packets produce no error message, making debugging much harder.

[↑ Back to TOC](#table-of-contents)

---

## 8. Verifying Bans in Firewalld

After a ban fires, verify it is actually enforced at the firewall level.

### Method 1 — Check ipset entries (firewallcmd-ipset action)

```bash
# Quick check: any IPs banned? (entries appear under "Members:")
sudo ipset list f2b-sshd

# Check one specific IP
sudo ipset test f2b-sshd 185.220.101.5
```

### Method 2 — Check rich rules (firewallcmd-rich-rules action)

```bash
# All rich rules in the default zone
sudo firewall-cmd --list-rich-rules

# Rich rules for a specific zone
sudo firewall-cmd --zone=public --list-rich-rules
```

### Method 3 — Check direct rules (ipset/allports actions)

```bash
sudo firewall-cmd --direct --get-all-rules
```

```
ipv4 filter INPUT_direct 0 -p tcp -m multiport --dports 22 -m set --match-set f2b-sshd src -j REJECT --reject-with icmp-port-unreachable
```

### Method 4 — Full zone state (rich-rules bans show here)

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
        rule family="ipv4" source address="185.220.101.5" port port="22" protocol="tcp" reject type="icmp-port-unreachable"
```

### Method 5 — View nftables rules directly

```bash
# See the actual kernel-level rules (advanced) — works for every action
sudo nft list ruleset | grep -B2 -A2 "f2b"
```

### Cross-reference fail2ban with the firewall

```bash
echo "=== Fail2ban banned IPs ==="
sudo fail2ban-client status sshd | grep "Banned IP"

echo ""
echo "=== Kernel ipset entries ==="
sudo ipset list f2b-sshd | sed -n '/Members:/,$p'
```

These two lists should match. If they do not, see Module 13 Troubleshooting.

[↑ Back to TOC](#table-of-contents)

---

## 9. IPv6 Support

Fail2ban supports both IPv4 and IPv6. The `firewallcmd-ipset` action creates
separate ipsets for each address family:

- `f2b-sshd` for IPv4 addresses
- `f2b-sshd6` for IPv6 addresses (if IPv6 traffic triggers the jail)

### Check IPv6 ipsets

```bash
sudo ipset list -n | grep f2b
```

You may see:

```
f2b-sshd
f2b-sshd6
```

### Verify IPv6 bans

```bash
sudo ipset list f2b-sshd6
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

**Fail2ban never touches the permanent layer.** Everything it creates is
runtime-only:

- Rich rules (rich-rules action) — runtime only
- `--direct` rules (ipset / allports actions) — runtime only
- Kernel ipsets — live outside firewalld entirely (the `ipset` binary talks
  straight to the kernel)

This is deliberate: ban state lives in fail2ban's SQLite database, not in
firewalld's config. After a reboot, fail2ban re-creates everything and
re-applies unexpired bans from the database.

### The gap after a firewalld reload or restart

When firewalld is reloaded or restarted, it rebuilds the firewall from its
*permanent* configuration — and everything fail2ban added at runtime is
**wiped**:

1. `firewall-cmd --reload` or `systemctl restart firewalld` runs
2. All fail2ban rich rules and `--direct` rules are gone
3. Kernel ipsets survive (firewalld doesn't manage them) — but the rule that
   *matched* them is gone, so the bans are **no longer enforced**
4. Fail2ban does **not** detect this automatically — bans remain "active" in
   `fail2ban-client status` but nothing blocks the traffic

**Recovery:** restart fail2ban (or reload it) after any firewalld
reload/restart so it re-runs `actionstart` and re-applies bans from
the database:

```bash
sudo firewall-cmd --reload && sudo systemctl restart fail2ban
```

Module 13 (Scenario 3) walks through diagnosing exactly this failure mode, and
shows how a `PartOf=firewalld.service` drop-in can automate the recovery.

### Verify what is (not) in the permanent layer

```bash
# Fail2ban bans never appear in the permanent configuration:
sudo firewall-cmd --permanent --list-rich-rules
sudo firewall-cmd --permanent --direct --get-all-rules
```

[↑ Back to TOC](#table-of-contents)

---

## 11. Firewalld and Fail2ban Startup Order

Fail2ban **requires firewalld to be running** before it starts. If firewalld
starts after fail2ban, the `actionstart` commands will fail and no bans will
be enforced.

### Verify systemd ordering

```bash
grep After /usr/lib/systemd/system/fail2ban.service
```

Expected:

```ini
After=network.target iptables.service firewalld.service ip6tables.service ipset.service nftables.service
```

The `After=firewalld.service` entry ensures fail2ban starts after firewalld
**when both are started together** (e.g. at boot). Note that `After=` is only
an ordering hint — it does not restart fail2ban if firewalld is restarted
later (see Module 13).

### What happens at startup

1. `firewalld.service` starts — firewall daemon ready
2. `fail2ban.service` starts — reads config
3. For each enabled jail, fail2ban runs `actionstart`:
   - Creates the kernel ipset if it does not exist (ipset action)
   - Adds the direct rule / prepares rich-rule infrastructure
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

> **Prerequisite:** the lab assumes `banaction = firewallcmd-ipset` in your
> `jail.local` (Module 04). With the EPEL default rich-rules action, substitute
> `firewall-cmd --list-rich-rules` for the ipset commands.

### Step 1 — Baseline firewall state

```bash
echo "=== Baseline firewalld state ==="
sudo firewall-cmd --list-all
echo ""
echo "=== Current fail2ban kernel ipsets ==="
sudo ipset list -n | grep f2b
```

### Step 2 — Examine existing fail2ban ipsets

```bash
for s in $(sudo ipset list -n | grep f2b); do
  echo "=== ipset: $s ==="
  sudo ipset list "$s"
  echo ""
done
```

### Step 3 — Ban a test IP and trace every firewall change

Open two terminals:

**Terminal 1** — watch the ipset members:

```bash
watch -n 1 "sudo ipset list f2b-sshd 2>/dev/null | sed -n '/Members:/,\$p'"
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

# Kernel ipset layer
sudo ipset list f2b-sshd | sed -n '/Members:/,$p'

# Firewalld direct-rule layer (the rule that matches the set)
sudo firewall-cmd --direct --get-all-rules | grep f2b-sshd

# nftables kernel layer
sudo nft list ruleset 2>/dev/null | grep -B2 -A2 "f2b" | head -20
```

### Step 5 — Query a specific entry

```bash
sudo ipset test f2b-sshd 203.0.113.55
```

Expected: `203.0.113.55 is in set f2b-sshd.`

### Step 6 — Simulate a firewalld reload (and observe the enforcement gap)

```bash
echo "Direct rule before reload:"
sudo firewall-cmd --direct --get-all-rules | grep f2b-sshd

sudo firewall-cmd --reload

echo "Direct rule after reload:"
sudo firewall-cmd --direct --get-all-rules | grep f2b-sshd || echo "GONE — ban no longer enforced!"

echo "ipset entries after reload (set survives, but nothing matches it):"
sudo ipset list f2b-sshd | sed -n '/Members:/,$p'
```

The reload wiped fail2ban's runtime rule. The ipset and its entries survive,
but **no firewall rule references them anymore** — the ban is not enforced.
Recover by restarting fail2ban:

```bash
sudo systemctl restart fail2ban
sleep 3
sudo firewall-cmd --direct --get-all-rules | grep f2b-sshd
sudo ipset test f2b-sshd 203.0.113.55
```

The rule is back and the ban (restored from the SQLite database) is enforced
again.

### Step 7 — Clean up

```bash
sudo fail2ban-client set sshd unbanip 203.0.113.55
sudo ipset list f2b-sshd | sed -n '/Members:/,$p'
```

Expected: no members.

### Step 8 — Confirm fail2ban leaves the permanent config alone

```bash
echo "=== Permanent rich rules ==="
sudo firewall-cmd --permanent --list-rich-rules

echo ""
echo "=== Permanent direct rules ==="
sudo firewall-cmd --permanent --direct --get-all-rules
```

Both should be empty (unless you added permanent rules yourself) — everything
fail2ban manages is runtime-only.

### Lab Complete ✓

**Self-check — verify you can answer yes to each:**

- [ ] `ipset list -n` lists at least one `f2b-*` ipset
- [ ] `ipset list f2b-sshd` shows current bans under `Members:` (or none if no bans active)
- [ ] I can trace a ban all the way from fail2ban status → ipset entry → nftables rule using `nft list ruleset`
- [ ] I understand why fail2ban bans are *runtime* rules and what a firewalld reload does to them
- [ ] I know the performance difference between `firewallcmd-ipset` (O(1)) and `firewallcmd-rich-rules` (O(n))
- [ ] I demonstrated the reload gap in Step 6 and recovered with a fail2ban restart

[↑ Back to TOC](#table-of-contents)

---

## 13. Summary

In this module you learned:

- **Why firewalld** is used on RHEL 10: it manages nftables via a D-Bus API
- **Firewalld concepts**: zones, rich rules, and ipsets (firewalld-managed vs raw kernel)
- **How fail2ban enforces bans**: `firewall-cmd` rich rules (EPEL default) or
  raw `ipset` sets + one `--direct` rule (ipset action)
- **Three firewalld actions** compared:
  - `firewallcmd-rich-rules` — one rich rule per IP, EPEL default, easy inspection
  - `firewallcmd-ipset` — kernel ipset, O(1) performance, best at scale
  - `firewallcmd-allports` — per-IP direct rules blocking all ports
- **Zones**: rich rules land in the default zone; direct rules bypass zones entirely
- **Verifying bans** at every layer: fail2ban status, `ipset list`, rich rules, direct rules, nftables
- **IPv6 support** with separate `f2b-<jail>6` ipsets
- **Runtime-only enforcement**: a firewalld reload wipes fail2ban's rules —
  restart fail2ban to recover
- **Startup order**: firewalld must start before fail2ban (`After=` ordering at boot)

### Next Steps

Proceed to **[Module 09 — Custom Jails & Filters](./09-custom-jails-and-filters.md)**
to learn how to protect any service by writing your own jails and filters.

[↑ Back to TOC](#table-of-contents)

---

| <- Previous | Home | Next -> |
|-------------|------|---------|
| [07 — Actions](./07-actions.md) | [Course README](./README.md) | [09 — Custom Jails & Filters](./09-custom-jails-and-filters.md) |

---

*Licensed under [CC BY-NC-SA 4.0](LICENSE.md) · © 2026 UncleJS*