#!/usr/bin/env bash
# Checks and fixes the Fun Math server. Run as root on the Linode:
#   cd /var/www/fun-math && git pull && bash tools/server-setup.sh
set -u
SITE_DIR=/var/www/fun-math
DOMAIN=ana-nessa.com
ok(){ printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad(){ printf '  \033[31mFIX\033[0m  %s\n' "$*"; }
note(){ printf '  ..   %s\n' "$*"; }

echo "1) Site code"
cd "$SITE_DIR" || { bad "folder $SITE_DIR not found"; exit 1; }
if git pull -q; then ok "up to date: $(git log --oneline -1)"; else bad "git pull failed (message above)"; fi

echo "2) Auto-update every 5 minutes"
LINE="*/5 * * * * cd $SITE_DIR && git pull -q >> /var/log/fun-math-pull.log 2>&1"
# Replace any old fun-math pull line with one that also logs errors
(crontab -l 2>/dev/null | grep -v "fun-math && git pull"; echo "$LINE") | crontab - && ok "scheduled (errors go to /var/log/fun-math-pull.log)"
if systemctl is-active --quiet cron || systemctl enable --now cron >/dev/null 2>&1; then ok "cron is running"; else bad "cron is not running"; fi

echo "3) Domain"
SERVER_IP=$(curl -s -4 --max-time 5 https://ifconfig.me || true)
[ -z "$SERVER_IP" ] && SERVER_IP=$(hostname -I | awk '{print $1}')
DNS_IP=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}')
WWW_IP=$(getent ahostsv4 "www.$DOMAIN" | awk 'NR==1{print $1}')
DOMAIN_OK=no
CLOUDFLARE=no
curl -sI --max-time 10 "http://$DOMAIN/" | grep -qi '^server: cloudflare' && CLOUDFLARE=yes
if [ "$CLOUDFLARE" = yes ]; then ok "$DOMAIN goes through Cloudflare, which provides HTTPS"
elif [ -z "$DNS_IP" ]; then bad "$DOMAIN doesn't point anywhere. At your domain company, add an A record: @ -> $SERVER_IP"
elif [ "$DNS_IP" != "$SERVER_IP" ]; then bad "$DOMAIN points to $DNS_IP, but this server is $SERVER_IP. Change the A record to $SERVER_IP"
else ok "$DOMAIN points to this server ($SERVER_IP)"; DOMAIN_OK=yes; fi
NAMES="$DOMAIN"; [ "$WWW_IP" = "$SERVER_IP" ] && NAMES="$DOMAIN www.$DOMAIN"

echo "4) Web server (nginx)"
CONF=$(grep -lE "^\s*root\s+$SITE_DIR/?;" /etc/nginx/sites-enabled/* 2>/dev/null | head -1)
if [ -z "$CONF" ]; then bad "no nginx site serves $SITE_DIR (check /etc/nginx/sites-enabled)"
else
  ok "nginx serves $SITE_DIR ($CONF)"
  if ! grep -qE "^\s*server_name[^;]*\b$DOMAIN\b" "$CONF"; then
    # certbot needs the domain in server_name to set up HTTPS
    cp "$CONF" "/root/$(basename "$CONF").bak"
    sed -i -E "s/^(\s*)server_name\s+[^;]*;/\1server_name $NAMES;/" "$CONF"
    if nginx -t -q 2>/dev/null && systemctl reload nginx; then ok "set server_name to $NAMES (backup in /root)"
    else cp "/root/$(basename "$CONF").bak" "$CONF"; bad "couldn't set server_name, so the change was undone"; fi
  fi
fi
if nginx -t -q 2>/dev/null; then ok "nginx config is valid"; else bad "nginx config has errors: run  nginx -t"; fi

echo "5) HTTPS"
if [ "$CLOUDFLARE" = yes ]; then ok "handled by Cloudflare (certbot not needed)"
elif [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then ok "certificate installed"
elif [ "$DOMAIN_OK" = yes ]; then
  # Free Let's Encrypt certificate; renews automatically
  ARGS=(); for n in $NAMES; do ARGS+=(-d "$n"); done
  if certbot --nginx "${ARGS[@]}" --non-interactive --agree-tos --register-unsafely-without-email --redirect; then ok "HTTPS is on"
  else bad "certbot failed (message above)"; fi
else note "skipped until $DOMAIN points to this server"; fi

echo "6) Pages"
for f in "" about.html privacy.html robots.txt fonts/fredoka.woff2 icons/icon-192.png; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/$f")
  if [ "$code" = 200 ]; then ok "https://$DOMAIN/$f"; else bad "https://$DOMAIN/$f -> ${code/000/no answer}"; fi
  case "$code" in 52[0-6]) note "Cloudflare can't reach this server: in Cloudflare, SSL/TLS -> set mode to Flexible";; esac
done
if curl -s --max-time 10 "https://$DOMAIN/" | grep -q 'class="site-foot"'; then ok "visitors get the newest version of the site"
else bad "visitors get an old or different page (Cloudflare: Caching -> Purge Everything)"; fi
if [ "$CLOUDFLARE" = yes ]; then note "In Cloudflare, keep Security -> Bots -> Bot Fight Mode OFF so school filters can read the site"; fi
