#!/bin/bash

if ! [ -x "$(command -v docker-compose)" ]; then
  echo 'Error: docker-compose is not installed.' >&2
  exit 1
fi

data_path="$(pwd)/data"

domains=(example.org www.example.org)
rsa_key_size=4096

email="" # Adding a valid address is strongly recommended
staging=0 # Set to 1 if you're testing your setup to avoid hitting request limits

if [ -d "$data/init" ]; then
    echo "### Creating 'init' directory..."
    mkdir "$data/init" >/dev/null 2>&1
    chmod -R +x "$data/init"
fi

echo "### Generate MySQL schema initialization script"
docker run --rm guacamole/guacamole /opt/guacamole/bin/initdb.sh --mysql > "$data/init/initdb.sql"

if [ -d "$data_path/ssl" ]; then
  read -p "Existing data found for $domains. Continue and replace existing certificate? (y/N) " decision
  if [ "$decision" != "Y" ] && [ "$decision" != "y" ]; then
    exit
  fi
else
    echo "### Creating directory for SSL certificates"
    mkdir -p "$data_path/ssl" >/dev/null 2>&1
fi

<<COMMENT
if [ ! -e "$data_path/conf/options-ssl-nginx.conf" ] || [ ! -e "$data_path/conf/ssl-dhparams.pem" ]; then
  echo "### Downloading recommended TLS parameters ..."
  mkdir -p "$data_path/conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf > "$data_path/conf/options-ssl-nginx.conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot/certbot/ssl-dhparams.pem > "$data_path/conf/ssl-dhparams.pem"
  echo
fi
COMMENT

echo "### Creating dummy certificate for $domains ..."
certpath="/etc/letsencrypt/ssl"
docker run --rm -v "$data_path/ssl":$path --entrypoint "/usr/bin/openssl" \
    certbot/certbot req -x509 -nodes \
    -newkey rsa:1024 -days 1 \
    -keyout "$certpath/letsencrypt.crt" \
    -out "$certpath/letsencrypt.key" \
    -subj "/CN=localhost" >/dev/null 2>&1
echo

echo "### Starting nginx ..."
docker-compose up --force-recreate -d --no-deps nginx
echo

echo "### Deleting dummy certificate for $domains ..."
docker-compose run --rm --entrypoint "\
  rm -Rf /etc/letsencrypt/live/$domains && \
  rm -Rf /etc/letsencrypt/archive/$domains && \
  rm -Rf /etc/letsencrypt/renewal/$domains.conf" certbot
echo

echo "### Requesting Let's Encrypt certificate for $domains ..."
#Join $domains to -d args
domain_args=""
for domain in "${domains[@]}"; do
  domain_args="$domain_args -d $domain"
done

# Select appropriate email arg
case "$email" in
  "") email_arg="--register-unsafely-without-email" ;;
  *) email_arg="--email $email" ;;
esac

# Enable staging mode if needed
if [ $staging != "0" ]; then staging_arg="--staging"; fi

docker-compose run --rm --entrypoint "\
  certbot certonly --webroot -w /var/www/certbot \
    $staging_arg \
    $email_arg \
    $domain_args \
    --rsa-key-size $rsa_key_size \
    --agree-tos \
    --force-renewal" certbot
echo

echo "### Reloading nginx ..."
docker-compose exec nginx nginx -s reload