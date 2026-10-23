# Nginx Vhost Generator

`generate-vhost.sh` prints (or installs) a production-ready Nginx server block for a new site in seconds — no more copy-pasting configs and hoping you didn't miss a semicolon.

## Presets

| Type | What you get |
|---|---|
| `wordpress` | Pretty permalinks, PHP-FPM with path-info protection, blocked `wp-config.php`/`xmlrpc.php`/`.git`/`.env`, static-asset caching |
| `php` | Generic PHP app with front-controller fallback + PHP-FPM |
| `static` | Plain static site with long asset caching |
| `proxy` | Reverse proxy with `X-Forwarded-*` headers + websocket upgrade support |

Every block includes gzip, security headers (nosniff, SAMEORIGIN, Referrer-Policy, Permissions-Policy), and access/error logs per domain.

## Usage

```bash
# Print to stdout
./generate-vhost.sh --domain example.com --type wordpress

# SSL variant (cert paths default to the certbot layout)
./generate-vhost.sh --domain example.com --type wordpress --ssl

# Write straight into Nginx, test and reload
sudo ./generate-vhost.sh --domain example.com --type php \
    --root /var/www/example.com --php-sock /run/php/php8.3-fpm.sock \
    --write --test --reload

# Reverse proxy for a Node app
./generate-vhost.sh --domain app.example.com --type proxy \
    --proxy-upstream http://127.0.0.1:3000 --ssl --out /etc/nginx/sites-available/app.example.com
```

With `--ssl` you get a 443 block plus an HTTP→HTTPS redirector; point certbot at the domain afterwards (`certbot --nginx -d example.com`) to fill the certificate paths.

## Flags

`--domain` (required), `--root`, `--type`, `--php-sock`, `--proxy-upstream`, `--ssl`, `--cert`, `--key`, `--write`, `--test`, `--reload`, `--out`.

## License

MIT — see [LICENSE](LICENSE).
