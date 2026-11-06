# nginx-site strategy (static sites under <appRoot>/current) and the reverse-proxy site used by
# systemd-service when ds.json has an "nginx" section. The site is written on first deployment and
# never changed afterwards (certificates and custom settings stay manual).

ds_nginx_site_name() {
  local site
  site=$(ds_m .nginx.siteName)
  echo "${site:-$APP_NAME}"
}

ds_nginx_reload() {
  $DS_SUDO nginx -t || ds_fail "nginx rejected its configuration"
  $DS_SUDO systemctl reload nginx
}

# $1 = static | proxy
ds_nginx_ensure_site() {
  local mode=$1 dir site available enabled listen server_name root spa proxy_pass
  dir=${DS_NGINX_DIR:-/etc/nginx}
  site=$(ds_nginx_site_name)
  available="$dir/sites-available/$site.conf"
  enabled="$dir/sites-enabled/$site.conf"
  if [[ -f $available ]]; then
    return 0
  fi
  listen=$(ds_m .nginx.listen)
  server_name=$(ds_m .nginx.serverName)
  ds_log "Writing nginx site $available"
  if [[ $mode == static ]]; then
    root=$(ds_m .nginx.root)
    spa=$(ds_m .nginx.spa)
    {
      echo 'server {'
      echo "    listen ${listen:-80};"
      echo "    server_name ${server_name:-_};"
      echo "    root $CURRENT_LINK/${root:-.};"
      echo '    index index.html;'
      echo '    location / {'
      if [[ $spa == true ]]; then
        echo "        try_files \$uri \$uri/ /index.html;"
      else
        echo "        try_files \$uri \$uri/ =404;"
      fi
      echo '    }'
      echo '}'
    } | $DS_SUDO tee "$available" > /dev/null
  else
    proxy_pass=$(ds_m .nginx.proxyPass)
    [[ -n $proxy_pass ]] || ds_fail "ds.json: nginx.proxyPass is required when a systemd-service has an nginx section"
    {
      echo 'server {'
      echo "    listen ${listen:-80};"
      echo "    server_name ${server_name:-_};"
      echo '    location / {'
      echo "        proxy_pass $proxy_pass;"
      echo '        proxy_http_version 1.1;'
      echo "        proxy_set_header Host \$host;"
      echo "        proxy_set_header X-Real-IP \$remote_addr;"
      echo "        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"
      echo "        proxy_set_header X-Forwarded-Proto \$scheme;"
      echo "        proxy_set_header Upgrade \$http_upgrade;"
      echo "        proxy_set_header Connection \"upgrade\";"
      echo '    }'
      echo '}'
    } | $DS_SUDO tee "$available" > /dev/null
  fi
  $DS_SUDO mkdir -p "$dir/sites-enabled"
  $DS_SUDO ln -sfn "$available" "$enabled"
  ds_nginx_reload
}

ds_nginx_start() {
  ds_nginx_ensure_site static
  ds_nginx_reload
}
