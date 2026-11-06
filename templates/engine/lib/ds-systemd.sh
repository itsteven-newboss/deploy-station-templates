# systemd-service strategy: a systemd unit whose program lives under <appRoot>/current, run as a
# dedicated system user. Writes and enables the unit on first deployment; never changes an existing
# unit (that stays manual). With an "nginx" section, also creates a reverse-proxy site.

ds_systemd_name() { ds_m .service.serviceName; }
ds_systemd_unit_file() { echo "${DS_SYSTEMD_DIR:-/etc/systemd/system}/$(ds_systemd_name).service"; }

ds_systemd_stop() {
  local name
  name=$(ds_systemd_name)
  if [[ ! -f $(ds_systemd_unit_file) ]]; then
    ds_log "Service $name does not exist yet"
    return 0
  fi
  if systemctl is-active --quiet "$name"; then
    ds_log "Stopping service $name"
    $DS_SUDO systemctl stop "$name"
  fi
}

ds_systemd_write_unit() {
  local name unit user executable arguments description env_file
  name=$(ds_systemd_name)
  unit=$(ds_systemd_unit_file)
  user=$(ds_m .service.user)
  user=${user:-$APP_NAME}
  executable=$(ds_m .service.executable)
  arguments=$(ds_m .service.arguments)
  description=$(ds_m .service.displayName)
  env_file=$(ds_m .service.environmentFile)
  [[ $executable == /* ]] || executable="$CURRENT_LINK/$executable"

  if ! id -u "$user" > /dev/null 2>&1; then
    ds_log "Creating system user $user"
    $DS_SUDO useradd --system --no-create-home --shell /usr/sbin/nologin "$user"
  fi

  ds_log "Writing $unit"
  {
    echo '[Unit]'
    echo "Description=${description:-$name} (deployed by Deploy Station)"
    echo 'After=network.target'
    echo
    echo '[Service]'
    echo 'Type=simple'
    echo "User=$user"
    echo "WorkingDirectory=$CURRENT_LINK"
    echo "ExecStart=$executable${arguments:+ $arguments}"
    if [[ -n $env_file ]]; then
      echo "EnvironmentFile=-$CURRENT_LINK/$env_file"
    fi
    jq -r '.service.environment // {} | to_entries[] | "Environment=\"\(.key)=\(.value)\""' <<< "$DS_MANIFEST" | tr -d '\r'
    echo 'Restart=on-failure'
    echo 'RestartSec=5'
    echo
    echo '[Install]'
    echo 'WantedBy=multi-user.target'
  } | $DS_SUDO tee "$unit" > /dev/null
  $DS_SUDO systemctl daemon-reload
  $DS_SUDO systemctl enable "$name"
}

ds_systemd_start() {
  local name executable
  name=$(ds_systemd_name)
  executable=$(ds_m .service.executable)
  # Zip files may not carry the execute bit; a program inside the release must have it.
  if [[ $executable != /* && -f $CURRENT_LINK/$executable ]]; then
    chmod +x "$CURRENT_LINK/$executable"
  fi
  [[ -f $(ds_systemd_unit_file) ]] || ds_systemd_write_unit
  if [[ -n $(ds_m .nginx) ]]; then
    ds_nginx_ensure_site proxy
  fi
  ds_log "Starting service $name"
  $DS_SUDO systemctl start "$name"
}

ds_systemd_stays_active() {
  local seconds=$1 name i
  name=$(ds_systemd_name)
  for ((i = 0; i < seconds; i++)); do
    systemctl is-active --quiet "$name" || return 1
    sleep 1
  done
}
