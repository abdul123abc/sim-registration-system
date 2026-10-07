docker_startup() {
  if docker info >/dev/null 2>&1; then
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1; then
    printf '[startup] Starting Docker service.\n'
    if [ "$(id -u)" -eq 0 ]; then
      systemctl enable --now docker || true
    elif command -v sudo >/dev/null 2>&1; then
      sudo systemctl enable --now docker || true
    fi
  fi

  if docker info >/dev/null 2>&1; then
    return 0
  fi

  local docker_ready=false
  if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
      if sudo docker info >/dev/null 2>&1; then
        docker_ready=true
        break
      fi
      sleep 1
    done
  fi

  if [ "${docker_ready}" = true ]; then
    local username
    username="$(id -un)"

    if ! getent group docker >/dev/null 2>&1; then
      sudo groupadd docker || true
    fi
    if ! id -nG "${username}" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
      printf '[startup] Adding %s to the docker group.\n' "${username}"
      sudo usermod -aG docker "${username}" \
        || { printf '[startup] ERROR: Could not add %s to the docker group.\n' "${username}" >&2; return 1; }
    fi

    if [ -z "${DOCKER_GROUP_REEXEC:-}" ] && command -v sg >/dev/null 2>&1; then
      local command_line
      printf -v command_line '%q ' "$0" "$@"
      export DOCKER_GROUP_REEXEC=1
      printf '[startup] Activating Docker group permissions for this run.\n'
      exec sg docker -c "exec ${command_line}"
    fi

    printf '[startup] ERROR: Docker is running, but this session cannot access it. Log out and back in, then rerun this script.\n' >&2
    return 1
  fi

  printf '[startup] ERROR: Docker did not become ready. Check with: sudo systemctl status docker --no-pager\n' >&2
  return 1
}