#!/usr/bin/env bash
#
# Turn a fresh Debian/Ubuntu VPS into a Dokku host (Caddy proxy) and lock it down.
# Idempotent: safe to re-run.
#
# sshd keeps the image defaults on purpose, so a way in always exists. Harden it
# as a separate step once you confirmed access. README.md has the commands.
#
# Usage:
#   sudo ./bootstrap.sh                          # variables from the environment
#   sudo ./bootstrap.sh /etc/infra-vps/bootstrap.env
#
# Variables:
#   DOMAIN              global Dokku domain, e.g. example.com       (required)
#   ADMIN_USER          the sudo user you log in as                 (required)
#   ACME_EMAIL          Let's Encrypt account email, enables TLS    (required)
#   ADMIN_IP            IP/CIDR(s) whitelisted in fail2ban          (recommended)
#   DOKKU_TAG           Dokku release to install                    (default v0.38.31)
#   ADMIN_SSH_KEY_FILE  key seeded for ADMIN_USER when it has no key     (default /root/.ssh/authorized_keys)
set -euo pipefail

ENV_FILE=${1:-}
if [[ -n $ENV_FILE ]]; then
  [[ -r $ENV_FILE ]] || { echo "ERROR: cannot read $ENV_FILE" >&2; exit 1; }
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

: "${DOMAIN:?set DOMAIN, e.g. example.com}"
: "${ADMIN_USER:?set ADMIN_USER, e.g. admin}"
: "${ACME_EMAIL:?set ACME_EMAIL, the ACME account email}"
ADMIN_IP=${ADMIN_IP:-}
DOKKU_TAG=${DOKKU_TAG:-v0.38.31}
ADMIN_SSH_KEY_FILE=${ADMIN_SSH_KEY_FILE:-/root/.ssh/authorized_keys}

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root: sudo $0"
# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == ubuntu || ${ID:-} == debian ]] || die "unsupported distro: ${PRETTY_NAME:-unknown}"

export DEBIAN_FRONTEND=noninteractive

log "Installing firewall and fail2ban packages"
apt-get update -qq
apt-get install -y -qq ufw fail2ban >/dev/null

log "Admin user $ADMIN_USER"
id -u "$ADMIN_USER" >/dev/null 2>&1 || adduser --disabled-password --gecos "" "$ADMIN_USER"
usermod -aG sudo "$ADMIN_USER"
ADMIN_HOME=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
ADMIN_KEYS="$ADMIN_HOME/.ssh/authorized_keys"
install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$ADMIN_HOME/.ssh"

# Seed the key from ADMIN_SSH_KEY_FILE when the account has no usable key.
# cloud-init writes its own key (hybrid setup), and that key must win.
if ! ssh-keygen -lf "$ADMIN_KEYS" >/dev/null 2>&1 && [[ -s $ADMIN_SSH_KEY_FILE ]]; then
  install -m 600 -o "$ADMIN_USER" -g "$ADMIN_USER" "$ADMIN_SSH_KEY_FILE" "$ADMIN_KEYS"
fi
chown "$ADMIN_USER:$ADMIN_USER" "$ADMIN_KEYS" 2>/dev/null || true
chmod 600 "$ADMIN_KEYS" 2>/dev/null || true
ssh-keygen -lf "$ADMIN_KEYS" >/dev/null 2>&1 ||
  die "no valid public key for $ADMIN_USER in $ADMIN_KEYS: fill in the key or set ADMIN_SSH_KEY_FILE"

SUDOERS=/etc/sudoers.d/90-infra-vps
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$ADMIN_USER" >"$SUDOERS.tmp"
visudo -cf "$SUDOERS.tmp" >/dev/null || die "generated sudoers file is invalid"
chmod 440 "$SUDOERS.tmp"
mv "$SUDOERS.tmp" "$SUDOERS"

log "Firewall: deny incoming, allow 22, 80, 443"
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp comment 'ssh' >/dev/null
ufw allow 80/tcp comment 'http' >/dev/null
ufw allow 443/tcp comment 'https' >/dev/null
ufw --force enable >/dev/null
# Note: ufw does not filter ports published by Docker containers. Dokku only
# publishes 80/443, but anything you expose with `dokku ports:add` bypasses ufw.

log "Leaving sshd at its image defaults: your current access keeps working"

log "fail2ban: sshd jail, whitelisted: ${ADMIN_IP:-none}"
cat >/etc/fail2ban/jail.local <<EOF
# Managed by infra-vps/bootstrap.sh
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1 ${ADMIN_IP}
backend  = systemd
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
EOF
systemctl enable fail2ban >/dev/null 2>&1 || true
systemctl restart fail2ban

if command -v dokku >/dev/null 2>&1; then
  log "Dokku already installed ($(dokku version)), skipping install"
else
  log "Installing Dokku $DOKKU_TAG"
  hostname -f >/dev/null 2>&1 || echo "127.0.1.1 $(hostname)" >>/etc/hosts
  curl -fsSL "https://dokku.com/install/$DOKKU_TAG/bootstrap.sh" -o /tmp/dokku-bootstrap.sh
  DOKKU_TAG="$DOKKU_TAG" DOKKU_KEY_FILE="$ADMIN_KEYS" bash /tmp/dokku-bootstrap.sh
fi

log "Configuring Dokku: domain $DOMAIN, caddy proxy, TLS for $ACME_EMAIL"
dokku domains:set-global "$DOMAIN" >/dev/null
dokku proxy:set --global type caddy >/dev/null

FP=$(ssh-keygen -lf "$ADMIN_KEYS" | head -1 | awk '{print $2}')
if ! dokku ssh-keys:list 2>/dev/null | grep -q "$FP"; then
  dokku ssh-keys:add admin "$ADMIN_KEYS" >/dev/null ||
    log "warning: could not register the admin key, run: dokku ssh-keys:add admin $ADMIN_KEYS"
fi

dokku caddy:set --global letsencrypt-email "$ACME_EMAIL" >/dev/null
dokku nginx:stop >/dev/null 2>&1 || true # nginx and caddy cannot share port 80/443
dokku caddy:stop >/dev/null 2>&1 || true  # restart so changed caddy properties apply
dokku caddy:start >/dev/null

log "Bootstrap complete"
cat <<EOF
  dokku     $(dokku version)
  domains   $DOMAIN, apps are served on <app>.$DOMAIN with automatic TLS
  ssh       port 22, unchanged: $ADMIN_USER (sudo) and the root key still work
  firewall  ufw: deny incoming, allow 22, 80, 443
  fail2ban  sshd jail, whitelist: 127.0.0.1/8 ::1 ${ADMIN_IP}

  Next:
    1. point $DOMAIN and *.$DOMAIN (A/AAAA) at this server
    2. log in as $ADMIN_USER once, from a second terminal, before you log out
    3. harden sshd: README.md, "Harden SSH after you confirmed access"
    4. git remote add dokku dokku@$DOMAIN:myapp && git push dokku main
EOF
