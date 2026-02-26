# configs/ — Ready-to-use Fail2ban Configuration Templates

This directory contains standalone, production-ready configuration templates
for fail2ban on RHEL 10. Each file is heavily commented explaining every
setting and how it relates to the course material.

## Files

| File | Install path | Purpose |
|------|-------------|---------|
| `fail2ban.local` | `/etc/fail2ban/fail2ban.local` | Global daemon overrides (log level, logtarget, dbpurgeage) |
| `jail.local` | `/etc/fail2ban/jail.local` | Baseline jail configuration with sshd enabled |
| `filter.d/recidive-systemd.conf` | `/etc/fail2ban/filter.d/recidive-systemd.conf` | Custom recidive filter for journald (RHEL 10 default) |
| `jail.d/recidive.conf` | `/etc/fail2ban/jail.d/recidive.conf` | Recidive jail (Option A: systemd, Option B: flat-file) |

## Quick Start

### Minimal setup (SSH protection only)

```bash
# 1. Edit jail.local — replace YOUR_MANAGEMENT_IP_HERE
#    with your actual management IP before copying!
nano configs/jail.local

# 2. Copy configs into place
sudo cp configs/fail2ban.local /etc/fail2ban/fail2ban.local
sudo cp configs/jail.local     /etc/fail2ban/jail.local

# 3. Test syntax
sudo fail2ban-client -t

# 4. Reload (or start if not running)
sudo fail2ban-client reload
# or: sudo systemctl enable --now fail2ban

# 5. Verify
sudo fail2ban-client status
sudo fail2ban-client status sshd
```

### Adding recidive (repeat-offender banning)

```bash
# 1. Check your logtarget
sudo fail2ban-client get fail2ban logtarget
#  SYSLOG or SYSTEMD-JOURNAL → use Option A (default in recidive.conf)
#  /var/log/fail2ban.log      → use Option B (edit recidive.conf first)

# 2. Install the systemd filter (Option A only)
sudo cp configs/filter.d/recidive-systemd.conf /etc/fail2ban/filter.d/

# 3. Install the recidive jail
sudo cp configs/jail.d/recidive.conf /etc/fail2ban/jail.d/

# 4. Test and reload
sudo fail2ban-client -t
sudo fail2ban-client reload

# 5. Verify recidive is active
sudo fail2ban-client status recidive
```

## Important Notes

- **Never edit `.conf` files directly** — always use `.local` overrides.
- **Replace `YOUR_MANAGEMENT_IP_HERE`** in `jail.local` before deploying.
- **`dbpurgeage`** in `fail2ban.local` must be ≥ `findtime` in `recidive.conf`
  (both default to at least 24h, so the 7d setting here is safe).
- See **Module 04** for configuration hierarchy details.
- See **Module 10** for recidive jail deep-dive.
