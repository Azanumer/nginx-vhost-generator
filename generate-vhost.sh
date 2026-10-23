#!/usr/bin/env bash
#
# generate-vhost.sh — generate a production-ready Nginx server block.
#
# Presets: wordpress | php | static | proxy
#
# Examples:
#   ./generate-vhost.sh --domain example.com --root /var/www/example.com --type wordpress --php-sock /run/php/php8.3-fpm.sock
#   ./generate-vhost.sh --domain static.example.com --root /var/www/static --type static --write --test --reload
#   ./generate-vhost.sh --domain app.example.com --type proxy --proxy-upstream http://127.0.0.1:3000 --ssl
#
# Flags:
#   --domain D        server_name (required)
#   --root PATH       document root (default: /var/www/<domain>/public_html)
#   --type T          wordpress|php|static|proxy (default: wordpress)
#   --php-sock PATH   PHP-FPM socket (default: /run/php/php8.2-fpm.sock)
#   --proxy-upstream  upstream for proxy type (default: http://127.0.0.1:3000)
#   --ssl             add a 443 server block with a certificate placeholder + HTTP->HTTPS redirect
#   --cert PATH       fullchain cert path when --ssl (default: /etc/letsencrypt/live/<domain>/fullchain.pem)
#   --key PATH        private key path when --ssl (default: /etc/letsencrypt/live/<domain>/privkey.pem)
#   --write           write to /etc/nginx/sites-available/<domain> and symlink sites-enabled
#   --test            run `nginx -t` after writing
#   --reload          run `systemctl reload nginx` after a successful test
#   --out FILE        write config to FILE instead of stdout
#
set -euo pipefail

DOMAIN=""
ROOT=""
TYPE="wordpress"
PHP_SOCK="/run/php/php8.2-fpm.sock"
UPSTREAM="http://127.0.0.1:3000"
SSL=0
CERT=""
KEY=""
WRITE=0
TEST=0
RELOAD=0
OUT=""

usage() {
    grep '^#' "$0" | sed 's/^# \{0,1\}//'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)         DOMAIN="$2"; shift 2 ;;
        --root)           ROOT="$2"; shift 2 ;;
        --type)           TYPE="$2"; shift 2 ;;
        --php-sock)       PHP_SOCK="$2"; shift 2 ;;
        --proxy-upstream) UPSTREAM="$2"; shift 2 ;;
        --ssl)            SSL=1; shift ;;
        --cert)           CERT="$2"; shift 2 ;;
        --key)            KEY="$2"; shift 2 ;;
        --write)          WRITE=1; shift ;;
        --test)           TEST=1; shift ;;
        --reload)         RELOAD=1; shift ;;
        --out)            OUT="$2"; shift 2 ;;
        -h|--help)        usage ;;
        *) echo "Unknown flag: $1" >&2; usage ;;
    esac
done

[[ -z "$DOMAIN" ]] && { echo "ERROR: --domain is required" >&2; exit 1; }
case "$TYPE" in wordpress|php|static|proxy) ;; *) echo "ERROR: --type must be wordpress|php|static|proxy" >&2; exit 1 ;; esac

[[ -z "$ROOT" ]] && ROOT="/var/www/${DOMAIN}/public_html"
[[ -z "$CERT" ]] && CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
[[ -z "$KEY"  ]] && KEY="/etc/letsencrypt/live/${DOMAIN}/privkey.pem"

# ---- shared snippets ------------------------------------------------------

gzip_snippet() {
cat <<'EOF'

    # Compression
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript application/xml+rss application/rss+xml image/svg+xml;
EOF
}

security_headers_snippet() {
cat <<'EOF'

    # Security headers
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "geolocation=(), microphone=(), camera=()" always;
EOF
}

static_cache_snippet() {
cat <<'EOF'

    # Long cache for versioned/static assets
    location ~* \.(css|js|jpg|jpeg|png|gif|ico|svg|webp|avif|woff|woff2|ttf|eot)$ {
        expires 30d;
        add_header Cache-Control "public, immutable";
        access_log off;
    }
EOF
}

php_fpm_snippet() {
    local sock="$1"
cat <<EOF

    # PHP via PHP-FPM (path-info attack safe: try_files runs first)
    location ~ \\.php\$ {
        try_files \$uri =404;
        include fastcgi_params;
        fastcgi_pass unix:${sock};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO \$fastcgi_path_info;
        fastcgi_read_timeout 300;
    }
EOF
}

# ---- per-type server blocks ------------------------------------------------

wordpress_block() {
cat <<EOF
    root ${ROOT};
    index index.php index.html;

    # Pretty permalinks
    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
EOF
php_fpm_snippet "$PHP_SOCK"
cat <<'EOF'

    # Block sensitive WordPress files
    location ~* ^/(wp-config\.php|xmlrpc\.php|\.htaccess|\.git|\.env) { deny all; return 404; }
    location ~* /(readme\.html|license\.txt)$ { deny all; return 404; }
    location ~* /wp-content/uploads/.*\.php$ { deny all; return 404; }
EOF
static_cache_snippet
}

php_block() {
cat <<EOF
    root ${ROOT};
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }
EOF
php_fpm_snippet "$PHP_SOCK"
static_cache_snippet
}

static_block() {
cat <<EOF
    root ${ROOT};
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ =404;
    }
EOF
static_cache_snippet
}

proxy_block() {
cat <<EOF
    location / {
        proxy_pass ${UPSTREAM};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300;
    }
EOF
}

# ---- assemble ---------------------------------------------------------------

main_block() {
    local listen="$1"  # e.g. "80" or "443 ssl"
    echo "server {"
    echo "    listen ${listen};"
    echo "    listen [::]:${listen};"
    echo "    server_name ${DOMAIN};"
    if [[ "$TYPE" != "proxy" ]]; then
        echo "    access_log /var/log/nginx/${DOMAIN}.access.log;"
        echo "    error_log  /var/log/nginx/${DOMAIN}.error.log warn;"
    else
        echo "    access_log /var/log/nginx/${DOMAIN}.access.log;"
        echo "    error_log  /var/log/nginx/${DOMAIN}.error.log warn;"
    fi
    if [[ "$listen" == *"443"* ]]; then
        echo ""
        echo "    ssl_certificate ${CERT};"
        echo "    ssl_certificate_key ${KEY};"
        echo "    ssl_protocols TLSv1.2 TLSv1.3;"
        echo "    ssl_prefer_server_ciphers off;"
    fi
    gzip_snippet
    security_headers_snippet
    case "$TYPE" in
        wordpress) wordpress_block ;;
        php)       php_block ;;
        static)    static_block ;;
        proxy)     proxy_block ;;
    esac
    echo "}"
}

config="$(
if [[ $SSL -eq 1 ]]; then
    # 443 block + HTTP redirector
    main_block "443 ssl"
    echo ""
    echo "server {"
    echo "    listen 80;"
    echo "    listen [::]:80;"
    echo "    server_name ${DOMAIN};"
    echo "    return 301 https://\$host\$request_uri;"
    echo "}"
else
    main_block "80"
fi
)"

# ---- output / install ---------------------------------------------------------

if [[ -n "$OUT" ]]; then
    printf '%s\n' "$config" > "$OUT"
    echo "Wrote $OUT"
elif [[ $WRITE -eq 1 ]]; then
    dest="/etc/nginx/sites-available/${DOMAIN}"
    printf '%s\n' "$config" > "$dest"
    ln -sfn "$dest" "/etc/nginx/sites-enabled/${DOMAIN}"
    echo "Wrote $dest and enabled it."
    if [[ ! -d "$ROOT" && "$TYPE" != "proxy" ]]; then
        echo "NOTE: document root $ROOT does not exist yet — create it before going live."
    fi
else
    printf '%s\n' "$config"
fi

if [[ $TEST -eq 1 ]]; then
    nginx -t
fi

if [[ $RELOAD -eq 1 ]]; then
    if [[ $TEST -eq 0 ]]; then
        nginx -t   # always test before reload
    fi
    systemctl reload nginx
    echo "Nginx reloaded."
fi
