# infra-vps

Two files turn a fresh VPS into a hardened Dokku host with Caddy and automatic HTTPS.

- `bootstrap.sh` does all the work. It is idempotent, so you can re-run it.
- `cloud-init.yaml` writes the config file and runs `bootstrap.sh` at server provisioning on Hetzner Cloud.

## What you get

- Dokku v0.38.31 with Caddy as the proxy. Caddy serves port 80 and 443 and gets Let's Encrypt certificates per app.
- An admin user with sudo, key-only SSH, and root login disabled.
- ufw: deny incoming, allow the SSH port, 80, and 443.
- fail2ban: sshd jail with your own IP addresses on the whitelist.

## Prerequisites

1. An Ubuntu 22.04/24.04 or Debian 11+ server with at least 1 GB of memory. Dokku builds app images on this server.
2. A DNS zone you control (a Hetzner DNS zone works). Two records point at the server IP:
   - `A` for `example.com`.
   - `A` for `*.example.com`. The wildcard gives every app its own subdomain.
3. An SSH key pair. On Hetzner, select the public key when you create the server. The script copies `/root/.ssh/authorized_keys` to the admin user.
4. The variables below. Put them in the env file, or pass them as environment variables.

| Variable | Required | Meaning |
| --- | --- | --- |
| `DOMAIN` | yes | Global Dokku domain, for example `example.com`. Apps answer on `<app>.example.com`. |
| `ADMIN_USER` | yes | The sudo user you log in as. The script creates it if it does not exist. |
| `ACME_EMAIL` | yes | Let's Encrypt account email. TLS is off without it. |
| `ADMIN_IP` | no | IP or CIDR that fail2ban never bans. Space-separated for several. |
| `SSH_PORT` | no | sshd port. Default `22`. |
| `DOKKU_TAG` | no | Dokku release. Default `v0.38.31`. |
| `ADMIN_SSH_KEY_FILE` | no | Public key file for `ADMIN_USER`. Default `/root/.ssh/authorized_keys`. |

## Use cloud-init at server creation

1. Push this repository to a Git remote. The server downloads `bootstrap.sh` over HTTPS, so the raw URL must work without authentication.
2. Edit `cloud-init.yaml`. Set the variable values and the raw URL of `bootstrap.sh`.
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

## Deploy an app

```shell
git remote add dokku dokku@example.com:myapp
git push dokku main
```

Dokku answers on `myapp.example.com`. Caddy reads Docker labels, so a change to a domain or a port needs a rebuild:

```shell
dokku ps:rebuild myapp
```

## Check the result

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
- **Re-running is safe.** The script skips the Dokku install when Dokku is present. To upgrade Dokku, use `apt-get install dokku` or `dokku-update`.
- **The script handles a changed `SSH_PORT`.** Ubuntu 24.04 activates sshd through `ssh.socket`, so the script writes a socket drop-in. The script then checks the listener. If nothing listens, it opens port 22 again and stops with an error.
- **Keep console access.** Hetzner gives you a console in the web interface. It is your way back in after a bad SSH change.
- **Secrets stay out of the repository.** `.env` is in `.gitignore`. `cloud-init.yaml` holds no secrets, but the env file on the server does. It has mode `0600`.
- **The fail2ban whitelist uses `ADMIN_IP`.** Add every network you work from, or you ban yourself after 5 failed logins.
