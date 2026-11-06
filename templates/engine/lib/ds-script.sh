# script strategy: the package's own bash script stops and starts the app. It is called as
#   <script> stop|start <appRoot> <releaseDir> <version>
# with "stop" from the release being replaced and "start" from the new release.

ds_script_run() {
  local action=$1 path script
  path=$(ds_m .script.path)
  script="$CURRENT_LINK/$path"
  if [[ ! -f $script ]]; then
    if [[ $action == stop ]]; then
      ds_log "No previous release to stop"
      return 0
    fi
    ds_fail "Custom deploy script not found: $script"
  fi
  ds_log "Running $path $action"
  bash "$script" "$action" "$APP_ROOT" "$CURRENT_LINK" "$DS_VERSION"
}
