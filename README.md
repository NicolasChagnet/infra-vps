# infra-vps

Two files turn a fresh VPS into a Dokku host with Caddy and automatic HTTPS. sshd stays at its image defaults on purpose, and one documented step hardens it after you confirmed access.

- `bootstrap.sh` does the stateful work: Dokku, Caddy, ufw, fail2ban. It is idempotent, so you can re-run it.
- `cloud-init.yaml` declares the admin user, updates the package list, writes the config file, and runs `bootstrap.sh` at server provisioning on Hetzner Cloud.

## What you get

- Dokku v0.38.31 with Caddy as the proxy. Caddy serves port 80 and 443 and gets Let's Encrypt certificates per app.
- An admin user with sudo and your SSH key. No account has a password, so access is key-based.
- ufw: deny incoming, allow 22, 80, and 443.
- fail2ban: sshd jail with your own IP addresses on the whitelist.
- sshd keeps the image defaults until you run the hardening step below, so the root key from Hetzner stays as a second way in.

## Prerequisites

1. An Ubuntu 22.04/24.04 or Debian 11+ server with at least 1 GB of memory. Dokku builds app images on this server.
2. A DNS zone you control (a Hetzner DNS zone works). Two records point at the server IP:
   - `A` for `example.com`.
   - `A` for `*.example.com`. The wildcard gives every app its own subdomain.
3. An SSH key pair. On the cloud-init path, paste the public key into `cloud-init.yaml`. On the script path, the script seeds the admin account from `/root/.ssh/authorized_keys`, which is where Hetzner puts the key you select at server creation.
4. The variables below. Put them in the env file, or pass them as environment variables.

| Variable | Required | Meaning |
| --- | --- | --- |
| `DOMAIN` | yes | Global Dokku domain, for example `example.com`. Apps answer on `<app>.example.com`. |
| `ADMIN_USER` | yes | The sudo user you log in as. The script creates it when it does not exist, so it must match the `users:` name in `cloud-init.yaml`. |
| `ACME_EMAIL` | yes | Let's Encrypt account email. TLS is off without it. |
| `ADMIN_IP` | no | IP or CIDR that fail2ban never bans. Space-separated for several. |
| `DOKKU_TAG` | no | Dokku release. Default `v0.38.31`. |
| `ADMIN_SSH_KEY_FILE` | no | Public key file for `ADMIN_USER`. Default `/root/.ssh/authorized_keys`. |

## Use cloud-init at server creation

1. Push this repository to a Git remote. The server downloads `bootstrap.sh` over HTTPS, so the raw URL must work without authentication.
2. Edit `cloud-init.yaml`: the user name and public key under `users:`, the variable values, and the raw URL of `bootstrap.sh`.
3. Create the server with the file as user data:

   ```shell
   hcloud server create --name app --type cx22 --image ubuntu-24.04 \
     --ssh-key mykey --user-data-from-file cloud-init.yaml
   ```

4. Read the progress on the server:

   ```shell
   ssh admin@SERVER 'sudo tail -f /var/log/cloud-init-output.log'
   ```

## Use the script on a running server

Pass the variables with the script, or copy an env file to the server first.

```shell
ssh admin@SERVER "sudo env DOMAIN=example.com ADMIN_USER=admin \
  ACME_EMAIL=you@example.com ADMIN_IP=203.0.113.7 bash -s" < bootstrap.sh
```

Or with an env file. Write the values into `bootstrap.env` first:

```shell
scp bootstrap.sh bootstrap.env admin@SERVER:/tmp/
ssh admin@SERVER 'sudo install -d -m 700 /etc/infra-vps && \
  sudo mv /tmp/bootstrap.env /etc/infra-vps/bootstrap.env && \
  sudo bash /tmp/bootstrap.sh /etc/infra-vps/bootstrap.env'
```

## Harden SSH after you confirmed access

The bootstrap leaves sshd alone, so it cannot lock you out of your first login. Run this once a normal login works. Keep that session open until the final step.

**1. Turn off root login and password authentication.** This does not change the port:

```shell
sudo tee /etc/ssh/sshd_config.d/00-hardening.conf >/dev/null <<'EOF'
# Managed by hand, see README.md
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
EOF
sudo sshd -t
```

The `00-` prefix is necessary. sshd takes the first value it reads, and Ubuntu cloud images ship `50-cloud-init.conf`, which sets `PasswordAuthentication yes`.

**2. Restart the right unit.** One of the two applies:

```shell
systemctl is-active ssh.socket        # active on Ubuntu 24.04
sudo systemctl restart ssh.socket     # that case
sudo systemctl restart ssh            # otherwise
```

**3. Optional: move off port 22.** On Ubuntu 24.04 the socket unit owns the listening port. sshd ignores the `Port` line in the config on its own:

```shell
sudo mkdir -p /etc/systemd/system/ssh.socket.d
printf '[Socket]\nListenStream=\nListenStream=2222\n' | sudo tee /etc/systemd/system/ssh.socket.d/override.conf
sudo sed -i '1i Port 2222' /etc/ssh/sshd_config.d/00-hardening.conf
sudo sshd -t && sudo systemctl daemon-reload && sudo systemctl restart ssh.socket
sudo ufw allow 2222/tcp comment 'ssh'
```

Also set `port = 2222` under `[sshd]` in `/etc/fail2ban/jail.local` and restart fail2ban, or the bans hit the wrong port.

**4. Confirm from a second terminal.** Do not close the session you have:

```shell
ssh -p 22 admin@example.com true      # or -p 2222 after step 3
```

When that works, close the old path:

```shell
sudo ufw delete allow 22/tcp          # only if you moved the port
sudo ufw status
sudo fail2ban-client status sshd
```

## Deploy an app

```shell
git remote add dokku dokku@example.com:myapp
git push dokku main
```

Dokku answers on `myapp.example.com`. Caddy reads Docker labels, so a change to a domain or a port needs a rebuild:

```shell
dokku ps:rebuild myapp
```

## Serve an app on the root domain

Dokku gives every app the name `<app>.<DOMAIN>`. To answer on `example.com` itself, change the app domains:

```shell
dokku domains:set myapp example.com   # example.com only, drops myapp.example.com
dokku domains:add myapp example.com   # example.com and myapp.example.com
```

Then rebuild, because Caddy routes from Docker labels:

```shell
dokku ps:rebuild myapp
dokku domains:report myapp
```

Only one app can own the root domain. The app must accept `Host: example.com`, so set the framework host variable as well, for example `dokku config:set myapp DJANGO_ALLOWED_HOSTS=example.com`.

Two conditions apply. Set the domain after the first deploy. The Dokku domain docs warn that a domain set before the first deploy fixes port mappings, which can misroute an app on a non-standard port. And `domains:set` replaces the whole list, so the subdomain stops working.

To redirect the app subdomain to the root domain, use a Caddy directive through `dokku caddy:labels:add`.

## Confirm the result

```shell
dokku caddy:report          # Caddy settings and the Let's Encrypt state
dokku domains:report        # the app domain
sudo ufw status             # open ports
sudo fail2ban-client status sshd
dokku logs myapp
```

## Things to remember

- **Caddy replaces nginx.** The script stops nginx because both bind port 80 and 443. Do not start nginx again.
- **TLS uses HTTP-01 challenges.** Port 80 stays open to the world. Each new app subdomain needs its own certificate, so the first request may take a few seconds.
- **ufw does not filter Docker ports.** A container published with `dokku ports:add` is reachable from the internet even when ufw denies the port.
- **cloud-init creates the admin user before the script runs.** The script seeds a key from `/root/.ssh/authorized_keys` only when the admin account has no usable key. The key from `cloud-init.yaml` therefore wins. If neither exists, the script stops with an error.
- **Re-running is safe.** The script skips the Dokku install when Dokku is present. To upgrade Dokku, use `apt-get install dokku` or `dokku-update`.
- **No automation touches sshd.** Root's key from Hetzner and your admin key both work until you run the hardening step. That is deliberate: a broken sshd change on a box you reach only by SSH costs you a rescue boot.
- **No account has a password.** SSH is key-only, and `sudo` never prompts. The Hetzner web console does prompt for a password, so set one before you depend on it: `sudo passwd admin`. When SSH is already broken, the rescue system in the Hetzner console is the way back in.
- **Secrets stay out of the repository.** `.env` is in `.gitignore`. `cloud-init.yaml` holds no secrets, but the env file on the server does. It has mode `0600`.
- **The fail2ban whitelist uses `ADMIN_IP`.** Add every network you work from, or you ban yourself after 5 failed logins.
