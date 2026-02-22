#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_COMPOSE_FILE="$ROOT_DIR/docker-compose.yml"
STATE_DIR="${OPENCLAW_INSTANCES_DIR:-$HOME/.openclaw/docker-instances}"
DEFAULT_BASE_IMAGE="openclaw:local"
DEFAULT_CUSTOM_IMAGE="openclaw:local-custom"
CUSTOM_DOCKERFILE="$ROOT_DIR/Dockerfile.custom"
DEFAULT_BIND="${OPENCLAW_GATEWAY_BIND:-lan}"
DEFAULT_TZ="${OPENCLAW_TZ:-Asia/Shanghai}"

resolve_default_image() {
  if [[ -n "${OPENCLAW_IMAGE:-}" ]]; then
    printf '%s' "${OPENCLAW_IMAGE}"
    return
  fi
  if [[ -f "$CUSTOM_DOCKERFILE" ]]; then
    printf '%s' "$DEFAULT_CUSTOM_IMAGE"
    return
  fi
  printf '%s' "$DEFAULT_BASE_IMAGE"
}

DEFAULT_IMAGE="$(resolve_default_image)"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing dependency: $1" >&2
    exit 1
  fi
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

grep_file_lines() {
  local pattern="$1"
  local file="$2"
  if has_cmd rg; then
    rg -n "$pattern" "$file"
  else
    grep -En "$pattern" "$file" || true
  fi
}

file_has_pattern() {
  local pattern="$1"
  local file="$2"
  if has_cmd rg; then
    rg -q "$pattern" "$file"
  else
    grep -Eq "$pattern" "$file"
  fi
}

read_instance_env_value() {
  local env_file="$1"
  local key="$2"
  if [[ ! -f "$env_file" ]]; then
    return
  fi
  grep -E "^${key}=" "$env_file" | tail -n 1 | cut -d= -f2-
}

resolve_instance_gateway_token() {
  local instance="$1"
  local env_file config_dir config_file token

  env_file="$(instance_env_file "$instance")"
  config_dir="$(read_instance_env_value "$env_file" "OPENCLAW_CONFIG_DIR")"
  config_file="$config_dir/openclaw.json"
  token=""

  if [[ -f "$config_file" ]]; then
    if has_cmd jq; then
      token="$(jq -r '.gateway.auth.token // empty' "$config_file" 2>/dev/null || true)"
    elif has_cmd node; then
      token="$(node -e 'const fs=require("fs");try{const c=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));process.stdout.write((c?.gateway?.auth?.token||"").trim());}catch{}' "$config_file" 2>/dev/null || true)"
    fi
  fi

  if [[ -z "$token" ]]; then
    token="$(read_instance_env_value "$env_file" "OPENCLAW_GATEWAY_TOKEN")"
  fi
  printf '%s' "$token"
}

resolve_instance_gateway_listen_port() {
  local instance="$1"
  local env_file network_mode gateway_port listen_port

  env_file="$(instance_env_file "$instance")"
  network_mode="$(read_instance_env_value "$env_file" "OPENCLAW_DOCKER_NETWORK_MODE")"
  gateway_port="$(read_instance_env_value "$env_file" "OPENCLAW_GATEWAY_PORT")"
  listen_port="$(read_instance_env_value "$env_file" "OPENCLAW_GATEWAY_LISTEN_PORT")"

  if [[ -n "$listen_port" ]]; then
    printf '%s' "$listen_port"
    return
  fi
  if [[ "$network_mode" == "host" && -n "$gateway_port" ]]; then
    printf '%s' "$gateway_port"
    return
  fi
  printf '%s' "18789"
}

resolve_instance_timezone() {
  local instance="$1"
  local env_file tz
  env_file="$(instance_env_file "$instance")"
  tz="$(read_instance_env_value "$env_file" "OPENCLAW_TZ")"
  if [[ -n "$tz" ]]; then
    printf '%s' "$tz"
    return
  fi
  printf '%s' "$DEFAULT_TZ"
}

ensure_docker_ready() {
  require_cmd docker
  if ! docker compose version >/dev/null 2>&1; then
    echo "Docker Compose not available (try: docker compose version)" >&2
    exit 1
  fi
}

usage() {
  cat <<'EOF'
Usage:
  ./docker-instance-manager.sh [--instances-dir <dir>] <command> [args...]
  ./docker-instance-manager.sh build [--image <image>] [--apt-packages "<pkg1 pkg2>"] [--with-base-build]
  ./docker-instance-manager.sh create <name> [options]
  ./docker-instance-manager.sh up <name> [--verbose]
  ./docker-instance-manager.sh down <name>
  ./docker-instance-manager.sh restart <name>
  ./docker-instance-manager.sh status [name]
  ./docker-instance-manager.sh logs <name> [-f] [--verbose]
  ./docker-instance-manager.sh onboard <name>
  ./docker-instance-manager.sh cli <name> -- <openclaw-cli args...>
  ./docker-instance-manager.sh devices <name> -- <devices args...>
  ./docker-instance-manager.sh plugin-install <name> <path-or-spec> [options]
  ./docker-instance-manager.sh plugin-uninstall <name> <plugin-id> [options]
  ./docker-instance-manager.sh list

Create options:
  --gateway-port <port>      Host port for gateway (container 18789)
  --bridge-port <port>       Host port for bridge (container 18790, implies expose)
  --expose-bridge-port       Expose bridge port mapping (default: off)
  --no-bridge-port           Force disable bridge port mapping
  --config-dir <dir>         Host config directory (default: ~/.openclaw/instances/<name>/config)
  --workspace-dir <dir>      Host workspace directory (default: ~/.openclaw/instances/<name>/workspace)
  --image <image>            Docker image (default: OPENCLAW_IMAGE or auto)
  --bind <lan|loopback>      Gateway bind mode (default: lan)
  --token <token>            Gateway token (default: auto generated)
  --home-volume <name|path>  Mount to /home/node (named volume or host path)
  --apt-packages "<pkgs>"    Stored for optional build convenience
  --mount <host:container>   Extra mount, repeatable
  --verbose                  Default gateway verbose mode for this instance (stored)
  --http-proxy <url>         HTTP proxy URL (default: http://127.0.0.1:10871)
  --https-proxy <url>        HTTPS proxy URL (default: same as --http-proxy)
  --no-proxy <csv>           NO_PROXY value (default: localhost,127.0.0.1,::1,host.docker.internal)
  --network-mode <mode>      Docker network mode: bridge|host (default: host)
  --tz <iana-tz>             Timezone (default: Asia/Shanghai)

Global options:
  --instances-dir <dir>      Instance state dir (default: ~/.openclaw/docker-instances)

Logs options:
  -f, --follow               Follow log output
  --verbose                  Show instance metadata and logs for all services

Plugin install options:
  --link                     Link local plugin path instead of copying
  --set-json <file>          Apply JSON file entries via:
                             openclaw config set <key> '<json-value>' --json
  --restart                  Restart gateway after install/config

Plugin uninstall options:
  --keep-files               Keep installed files on disk
  --dry-run                  Preview removal only
  --no-force                 Ask for confirmation (default: force)
  --restart                  Restart gateway after uninstall

Examples:
  ./docker-instance-manager.sh build --image openclaw:v2026.2.15
  ./docker-instance-manager.sh create prod-a --gateway-port 28789 --bridge-port 28790
  ./docker-instance-manager.sh create prod-a --network-mode host
  ./docker-instance-manager.sh up prod-a --verbose
  ./docker-instance-manager.sh cli prod-a -- channels status --probe
  ./docker-instance-manager.sh devices prod-a -- list
  ./docker-instance-manager.sh plugin-install prod-a @openclaw/zalo --set-json ./plugin-config.json --restart
  ./docker-instance-manager.sh plugin-uninstall prod-a zalo --restart
EOF
}

instance_env_file() {
  echo "$STATE_DIR/$1.env"
}

instance_compose_file() {
  echo "$STATE_DIR/$1.compose.yml"
}

instance_project_name() {
  echo "openclaw-$1"
}

validate_instance_name() {
  local name="$1"
  if [[ ! "$name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "Invalid instance name: $name (allowed: letters, numbers, ., _, -)" >&2
    exit 1
  fi
}

generate_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
    return
  fi
  echo "Missing dependency: openssl or python3 (needed to generate token)" >&2
  exit 1
}

is_port_reserved() {
  local port="$1"
  local file
  for file in "$STATE_DIR"/*.env; do
    [[ -e "$file" ]] || continue
    if file_has_pattern "^OPENCLAW_GATEWAY_PORT=${port}$|^OPENCLAW_BRIDGE_PORT=${port}$" "$file"; then
      return 0
    fi
  done
  return 1
}

is_port_in_use() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi
  if command -v ss >/dev/null 2>&1; then
    ss -ltn "( sport = :$port )" 2>/dev/null | awk 'NR>1{found=1} END{exit !found}'
    return $?
  fi
  return 1
}

next_available_port() {
  local start="$1"
  local port="$start"
  while is_port_reserved "$port" || is_port_in_use "$port"; do
    port=$((port + 1))
  done
  echo "$port"
}

write_extra_compose() {
  local file="$1"
  local expose_bridge="$2"
  local home_volume="$3"
  local config_dir="$4"
  local workspace_dir="$5"
  local network_mode="$6"
  shift 6

  local has_extra_volumes=false
  if [[ -n "$home_volume" || "$#" -gt 0 ]]; then
    has_extra_volumes=true
  fi

  cat >"$file" <<'YAML'
services:
  openclaw-gateway:
YAML

  if [[ "$network_mode" == "host" ]]; then
    cat >>"$file" <<'YAML'
    network_mode: host
    ports: []
YAML
  else
    cat >>"$file" <<'YAML'
    ports:
      - ${OPENCLAW_GATEWAY_PORT:-18789}:18789
YAML
    if [[ "$expose_bridge" == "1" ]]; then
      cat >>"$file" <<'YAML'
      - ${OPENCLAW_BRIDGE_PORT:-18790}:18790
YAML
    fi
  fi

  if [[ "$has_extra_volumes" == true ]]; then
    cat >>"$file" <<'YAML'
    volumes:
YAML
    if [[ -n "$home_volume" ]]; then
      printf '      - %s:/home/node\n' "$home_volume" >>"$file"
      printf '      - %s:/home/node/.openclaw\n' "$config_dir" >>"$file"
      printf '      - %s:/home/node/.openclaw/workspace\n' "$workspace_dir" >>"$file"
    fi

    local mount
    for mount in "$@"; do
      printf '      - %s\n' "$mount" >>"$file"
    done

    cat >>"$file" <<'YAML'
  openclaw-cli:
YAML
    if [[ "$network_mode" == "host" ]]; then
      cat >>"$file" <<'YAML'
    network_mode: host
YAML
    fi
    cat >>"$file" <<'YAML'
    volumes:
YAML
    if [[ -n "$home_volume" ]]; then
      printf '      - %s:/home/node\n' "$home_volume" >>"$file"
      printf '      - %s:/home/node/.openclaw\n' "$config_dir" >>"$file"
      printf '      - %s:/home/node/.openclaw/workspace\n' "$workspace_dir" >>"$file"
    fi

    for mount in "$@"; do
      printf '      - %s\n' "$mount" >>"$file"
    done
  elif [[ "$network_mode" == "host" ]]; then
    cat >>"$file" <<'YAML'
  openclaw-cli:
    network_mode: host
YAML
  fi

  if [[ -n "$home_volume" && "$home_volume" != *"/"* ]]; then
    cat >>"$file" <<YAML
volumes:
  ${home_volume}:
YAML
  fi
}

run_compose() {
  local instance="$1"
  shift

  local env_file compose_file
  local -a args
  env_file="$(instance_env_file "$instance")"
  compose_file="$(instance_compose_file "$instance")"
  args=(--env-file "$env_file" -p "$(instance_project_name "$instance")" -f "$BASE_COMPOSE_FILE")
  if [[ -f "$compose_file" ]]; then
    args+=(-f "$compose_file")
  fi
  docker compose "${args[@]}" "$@"
}

ensure_instance_exists() {
  local instance="$1"
  local env_file
  env_file="$(instance_env_file "$instance")"
  if [[ ! -f "$env_file" ]]; then
    echo "Instance '$instance' not found. Run: ./docker-instance-manager.sh create $instance" >&2
    exit 1
  fi
}

cmd_build() {
  ensure_docker_ready
  local image="$DEFAULT_IMAGE"
  local apt_packages="${OPENCLAW_DOCKER_APT_PACKAGES:-}"
  local use_custom=0
  local with_base_build=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image)
        image="$2"
        shift 2
        ;;
      --apt-packages)
        apt_packages="$2"
        shift 2
        ;;
      --with-base-build)
        with_base_build=1
        shift
        ;;
      *)
        echo "Unknown option for build: $1" >&2
        exit 1
        ;;
    esac
  done

  if [[ -f "$CUSTOM_DOCKERFILE" ]]; then
    use_custom=1
  fi

  if [[ "$use_custom" == "1" ]]; then
    if [[ "$with_base_build" == "1" ]]; then
      echo "==> Detected Dockerfile.custom; building base image: $DEFAULT_BASE_IMAGE"
      docker build \
        --build-arg "OPENCLAW_DOCKER_APT_PACKAGES=$apt_packages" \
        -t "$DEFAULT_BASE_IMAGE" \
        -f "$ROOT_DIR/Dockerfile" \
        "$ROOT_DIR"
    else
      echo "==> Detected Dockerfile.custom; skipping base build (use --with-base-build to build $DEFAULT_BASE_IMAGE)"
    fi

    echo "==> Building custom image: $image"
    docker build \
      --build-arg "OPENCLAW_DOCKER_APT_PACKAGES=$apt_packages" \
      -t "$image" \
      -f "$CUSTOM_DOCKERFILE" \
      "$ROOT_DIR"
    return
  fi

  echo "==> Building image: $image"
  docker build \
    --build-arg "OPENCLAW_DOCKER_APT_PACKAGES=$apt_packages" \
    -t "$image" \
    -f "$ROOT_DIR/Dockerfile" \
    "$ROOT_DIR"
}

cmd_create() {
  if [[ $# -lt 1 ]]; then
    echo "Missing instance name" >&2
    usage
    exit 1
  fi

  local instance="$1"
  shift
  validate_instance_name "$instance"
  mkdir -p "$STATE_DIR"

  local env_file compose_file
  local gateway_port bridge_port
  local config_dir workspace_dir
  local image bind token apt_packages home_volume expose_bridge gateway_verbose network_mode
  local gateway_listen_port
  local timezone
  local http_proxy https_proxy no_proxy
  local -a extra_mounts

  env_file="$(instance_env_file "$instance")"
  compose_file="$(instance_compose_file "$instance")"
  gateway_port=""
  bridge_port=""
  config_dir="$HOME/.openclaw/instances/$instance/config"
  workspace_dir="$HOME/.openclaw/instances/$instance/workspace"
  image="$DEFAULT_IMAGE"
  bind="$DEFAULT_BIND"
  token="${OPENCLAW_GATEWAY_TOKEN:-}"
  apt_packages="${OPENCLAW_DOCKER_APT_PACKAGES:-}"
  home_volume="${OPENCLAW_HOME_VOLUME:-}"
  expose_bridge="${OPENCLAW_EXPOSE_BRIDGE_PORT:-0}"
  gateway_verbose="${OPENCLAW_GATEWAY_VERBOSE:-}"
  timezone="${OPENCLAW_TZ:-$DEFAULT_TZ}"
  network_mode="${OPENCLAW_DOCKER_NETWORK_MODE:-host}"
  http_proxy="${OPENCLAW_HTTP_PROXY:-http://127.0.0.1:10871}"
  https_proxy="${OPENCLAW_HTTPS_PROXY:-$http_proxy}"
  no_proxy="${OPENCLAW_NO_PROXY:-localhost,127.0.0.1,::1,host.docker.internal}"
  extra_mounts=()
  gateway_listen_port="${OPENCLAW_GATEWAY_LISTEN_PORT:-18789}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --gateway-port)
        gateway_port="$2"
        shift 2
        ;;
      --bridge-port)
        bridge_port="$2"
        expose_bridge="1"
        shift 2
        ;;
      --expose-bridge-port)
        expose_bridge="1"
        shift
        ;;
      --no-bridge-port)
        expose_bridge="0"
        shift
        ;;
      --config-dir)
        config_dir="$2"
        shift 2
        ;;
      --workspace-dir)
        workspace_dir="$2"
        shift 2
        ;;
      --image)
        image="$2"
        shift 2
        ;;
      --bind)
        bind="$2"
        shift 2
        ;;
      --token)
        token="$2"
        shift 2
        ;;
      --home-volume)
        home_volume="$2"
        shift 2
        ;;
      --apt-packages)
        apt_packages="$2"
        shift 2
        ;;
      --mount)
        extra_mounts+=("$2")
        shift 2
        ;;
      --verbose)
        gateway_verbose="1"
        shift
        ;;
      --http-proxy)
        http_proxy="$2"
        shift 2
        ;;
      --https-proxy)
        https_proxy="$2"
        shift 2
        ;;
      --no-proxy)
        no_proxy="$2"
        shift 2
        ;;
      --network-mode)
        network_mode="$2"
        shift 2
        ;;
      --tz)
        timezone="$2"
        shift 2
        ;;
      *)
        echo "Unknown option for create: $1" >&2
        exit 1
        ;;
    esac
  done

  if [[ "$network_mode" != "bridge" && "$network_mode" != "host" ]]; then
    echo "Invalid --network-mode: $network_mode (allowed: bridge|host)" >&2
    exit 1
  fi

  if [[ -z "$gateway_port" ]]; then
    gateway_port="$(next_available_port 18789)"
  fi
  if [[ "$network_mode" == "host" ]]; then
    gateway_listen_port="$gateway_port"
  else
    gateway_listen_port="18789"
  fi
  if [[ "$expose_bridge" == "1" ]]; then
    if [[ -z "$bridge_port" ]]; then
      bridge_port="$(next_available_port "$((gateway_port + 1))")"
      if [[ "$bridge_port" == "$gateway_port" ]]; then
        bridge_port="$(next_available_port "$((bridge_port + 1))")"
      fi
    fi
  else
    bridge_port=""
  fi
  if [[ -z "$token" ]]; then
    token="$(generate_token)"
  fi

  mkdir -p "$config_dir" "$workspace_dir"

  cat >"$env_file" <<EOF
OPENCLAW_CONFIG_DIR=$config_dir
OPENCLAW_WORKSPACE_DIR=$workspace_dir
OPENCLAW_GATEWAY_PORT=$gateway_port
OPENCLAW_GATEWAY_LISTEN_PORT=$gateway_listen_port
OPENCLAW_BRIDGE_PORT=$bridge_port
OPENCLAW_EXPOSE_BRIDGE_PORT=$expose_bridge
OPENCLAW_GATEWAY_BIND=$bind
OPENCLAW_GATEWAY_VERBOSE=$gateway_verbose
OPENCLAW_TZ=$timezone
OPENCLAW_GATEWAY_TOKEN=$token
OPENCLAW_IMAGE=$image
OPENCLAW_DOCKER_APT_PACKAGES=$apt_packages
OPENCLAW_HOME_VOLUME=$home_volume
OPENCLAW_EXTRA_MOUNTS=$(IFS=,; echo "${extra_mounts[*]}")
OPENCLAW_HTTP_PROXY=$http_proxy
OPENCLAW_HTTPS_PROXY=$https_proxy
OPENCLAW_NO_PROXY=$no_proxy
OPENCLAW_DOCKER_NETWORK_MODE=$network_mode
EOF

  write_extra_compose \
    "$compose_file" \
    "$expose_bridge" \
    "$home_volume" \
    "$config_dir" \
    "$workspace_dir" \
    "$network_mode" \
    "${extra_mounts[@]}"

  echo "Instance '$instance' created."
  echo "  env file: $env_file"
  echo "  image: $image"
  echo "  network mode: $network_mode"
  echo "  timezone: $timezone"
  echo "  gateway port: $gateway_port"
  echo "  gateway listen port: $gateway_listen_port"
  if [[ "$expose_bridge" == "1" ]]; then
    echo "  bridge port: $bridge_port"
  else
    echo "  bridge port: disabled"
  fi
  echo "  config dir: $config_dir"
  echo "  workspace dir: $workspace_dir"
  if [[ -n "$home_volume" ]]; then
    echo "  home volume: $home_volume"
  fi
  if [[ -n "$http_proxy" || -n "$https_proxy" ]]; then
    echo "  http proxy: ${http_proxy:-off}"
    echo "  https proxy: ${https_proxy:-off}"
    echo "  no_proxy: ${no_proxy:-off}"
  fi
  if [[ ${#extra_mounts[@]} -gt 0 ]]; then
    echo "  extra mounts: $(IFS=', '; echo "${extra_mounts[*]}")"
  fi
  echo ""
  echo "Next steps:"
  echo "  ./docker-instance-manager.sh build --image $image --apt-packages \"$apt_packages\""
  echo "  ./docker-instance-manager.sh onboard $instance"
  echo "  ./docker-instance-manager.sh up $instance"
}

cmd_up() {
  ensure_docker_ready
  local instance="$1"
  local listen_port timezone
  local gateway_verbose=""
  shift
  ensure_instance_exists "$instance"
  listen_port="$(resolve_instance_gateway_listen_port "$instance")"
  timezone="$(resolve_instance_timezone "$instance")"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --verbose)
        gateway_verbose="1"
        shift
        ;;
      *)
        echo "Unknown option for up: $1" >&2
        exit 1
        ;;
    esac
  done

  if [[ -n "$gateway_verbose" ]]; then
    OPENCLAW_GATEWAY_VERBOSE="$gateway_verbose" OPENCLAW_GATEWAY_LISTEN_PORT="$listen_port" OPENCLAW_TZ="$timezone" run_compose "$instance" up -d openclaw-gateway
    return
  fi
  OPENCLAW_GATEWAY_LISTEN_PORT="$listen_port" OPENCLAW_TZ="$timezone" run_compose "$instance" up -d openclaw-gateway
}

cmd_down() {
  ensure_docker_ready
  local instance="$1"
  ensure_instance_exists "$instance"
  run_compose "$instance" down
}

cmd_restart() {
  ensure_docker_ready
  local instance="$1"
  local timezone
  ensure_instance_exists "$instance"
  timezone="$(resolve_instance_timezone "$instance")"
  OPENCLAW_TZ="$timezone" run_compose "$instance" restart openclaw-gateway
}

cmd_status() {
  if [[ $# -eq 0 ]]; then
    cmd_list
    return
  fi
  ensure_docker_ready
  local instance="$1"
  ensure_instance_exists "$instance"
  run_compose "$instance" ps
}

cmd_logs() {
  ensure_docker_ready
  local instance="$1"
  shift
  ensure_instance_exists "$instance"
  local env_file verbose image gateway_port bridge_port bind_mode
  local timezone
  local -a log_args

  verbose=false
  log_args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --verbose)
        verbose=true
        shift
        ;;
      *)
        log_args+=("$1")
        shift
        ;;
    esac
  done

  if [[ "$verbose" == true ]]; then
    env_file="$(instance_env_file "$instance")"
    image="$(read_instance_env_value "$env_file" "OPENCLAW_IMAGE")"
    gateway_port="$(read_instance_env_value "$env_file" "OPENCLAW_GATEWAY_PORT")"
    bridge_port="$(read_instance_env_value "$env_file" "OPENCLAW_BRIDGE_PORT")"
    bind_mode="$(read_instance_env_value "$env_file" "OPENCLAW_GATEWAY_BIND")"
    timezone="$(read_instance_env_value "$env_file" "OPENCLAW_TZ")"
    echo "Instance: $instance"
    echo "  image: ${image:-unknown}"
    echo "  bind: ${bind_mode:-unknown}"
    echo "  timezone: ${timezone:-$DEFAULT_TZ}"
    echo "  gateway port: ${gateway_port:-unknown}"
    echo "  bridge port: ${bridge_port:-disabled}"
    run_compose "$instance" ps
    run_compose "$instance" logs "${log_args[@]}"
    return
  fi

  run_compose "$instance" logs "${log_args[@]}" openclaw-gateway
}

cmd_onboard() {
  ensure_docker_ready
  local instance="$1"
  local env_file gateway_port bind token
  ensure_instance_exists "$instance"
  env_file="$(instance_env_file "$instance")"
  gateway_port="$(read_instance_env_value "$env_file" "OPENCLAW_GATEWAY_PORT")"
  bind="$(read_instance_env_value "$env_file" "OPENCLAW_GATEWAY_BIND")"
  token="$(read_instance_env_value "$env_file" "OPENCLAW_GATEWAY_TOKEN")"
  run_compose "$instance" run --rm openclaw-cli onboard \
    --gateway-port "${gateway_port:-18789}" \
    --gateway-bind "${bind:-lan}" \
    --gateway-auth token \
    --gateway-token "$token" \
    --no-install-daemon
}

cmd_cli() {
  ensure_docker_ready
  local instance="$1"
  local token listen_port
  local first_arg second_arg
  local has_port_arg="0"
  local arg
  local -a run_args
  local -a cli_args
  shift
  ensure_instance_exists "$instance"
  if [[ $# -gt 0 && "$1" == "--" ]]; then
    shift
  fi
  if [[ $# -eq 0 ]]; then
    echo "Missing cli args. Example: ./docker-instance-manager.sh cli <name> -- channels status --probe" >&2
    exit 1
  fi

  token="$(resolve_instance_gateway_token "$instance")"
  listen_port="$(resolve_instance_gateway_listen_port "$instance")"
  run_args=(
    run
    --rm
    -e "OPENCLAW_GATEWAY_PORT=${listen_port}"
    -e "OPENCLAW_GATEWAY_LISTEN_PORT=${listen_port}"
  )
  if [[ -n "$token" ]]; then
    run_args+=(-e "OPENCLAW_GATEWAY_TOKEN=${token}")
  fi

  cli_args=("$@")
  first_arg="${cli_args[0]:-}"
  second_arg="${cli_args[1]:-}"
  if [[ "$first_arg" == "gateway" ]]; then
    for arg in "${cli_args[@]}"; do
      if [[ "$arg" == "--port" || "$arg" == --port=* ]]; then
        has_port_arg="1"
        break
      fi
    done
    if [[ "$has_port_arg" == "0" && ( -z "$second_arg" || "$second_arg" == "run" ) ]]; then
      cli_args+=(--port "$listen_port")
    fi
  fi

  run_compose "$instance" "${run_args[@]}" openclaw-cli "${cli_args[@]}"
}

cmd_devices() {
  ensure_docker_ready
  local instance="$1"
  local token listen_port
  local has_auth_arg=false
  local has_url_arg=false
  local arg
  local -a device_args
  shift
  ensure_instance_exists "$instance"
  if [[ $# -gt 0 && "$1" == "--" ]]; then
    shift
  fi
  if [[ $# -eq 0 ]]; then
    echo "Missing devices args. Example: ./docker-instance-manager.sh devices <name> -- list" >&2
    exit 1
  fi

  device_args=("$@")
  for arg in "${device_args[@]}"; do
    if [[ "$arg" == "--token" || "$arg" == "--password" ]]; then
      has_auth_arg=true
    fi
    if [[ "$arg" == "--url" ]]; then
      has_url_arg=true
    fi
  done
  if [[ "$has_auth_arg" == false ]]; then
    token="$(resolve_instance_gateway_token "$instance")"
    if [[ -n "$token" ]]; then
      device_args+=(--token "$token")
    fi
  fi
  if [[ "$has_url_arg" == false ]]; then
    listen_port="$(resolve_instance_gateway_listen_port "$instance")"
    device_args+=(--url "ws://127.0.0.1:${listen_port}")
  fi

  # Run against the running gateway container to avoid loopback resolution issues
  # from one-shot CLI containers.
  run_compose "$instance" exec openclaw-gateway node dist/index.js devices "${device_args[@]}"
}

cmd_plugin_install() {
  ensure_docker_ready
  if [[ $# -lt 2 ]]; then
    echo "Usage: ./docker-instance-manager.sh plugin-install <name> <path-or-spec> [--link] [--set-json <file>] [--restart]" >&2
    exit 1
  fi

  local instance="$1"
  local plugin_spec="$2"
  local link=false
  local restart=false
  local set_json_file=""
  local key json_value line
  local -a json_pairs
  shift 2

  ensure_instance_exists "$instance"
  json_pairs=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --link)
        link=true
        shift
        ;;
      --set-json)
        [[ $# -ge 2 ]] || { echo "Missing value for --set-json (expected: <file>)" >&2; exit 1; }
        set_json_file="$2"
        if [[ ! -f "$set_json_file" ]]; then
          echo "JSON file not found: $set_json_file" >&2
          exit 1
        fi
        shift 2
        ;;
      --restart)
        restart=true
        shift
        ;;
      *)
        echo "Unknown option for plugin-install: $1" >&2
        exit 1
        ;;
    esac
  done

  echo "==> Installing plugin '$plugin_spec' for instance '$instance'"
  if [[ "$link" == true ]]; then
    run_compose "$instance" run --rm openclaw-cli plugins install --link "$plugin_spec"
  else
    run_compose "$instance" run --rm openclaw-cli plugins install "$plugin_spec"
  fi

  if [[ -n "$set_json_file" ]]; then
    if ! has_cmd node; then
      echo "Missing dependency: node (needed to parse --set-json file)" >&2
      exit 1
    fi
    mapfile -t json_pairs < <(
      node -e '
const fs = require("fs");
const file = process.argv[1];
const raw = fs.readFileSync(file, "utf8");
const data = JSON.parse(raw);
if (!data || Array.isArray(data) || typeof data !== "object") {
  throw new Error("--set-json file must be a JSON object: {\"config.path\": value}");
}
for (const [k, v] of Object.entries(data)) {
  if (!k || !k.trim()) continue;
  process.stdout.write(`${k}\t${JSON.stringify(v)}\n`);
}
' "$set_json_file"
    )
    for line in "${json_pairs[@]}"; do
      key="${line%%$'\t'*}"
      json_value="${line#*$'\t'}"
      echo "==> Applying JSON config: $key <- $set_json_file"
      run_compose "$instance" run --rm openclaw-cli config set "$key" "$json_value" --json
    done
  fi

  if [[ "$restart" == true ]]; then
    echo "==> Restarting gateway for instance '$instance'"
    run_compose "$instance" restart openclaw-gateway
  fi
}

cmd_plugin_uninstall() {
  ensure_docker_ready
  if [[ $# -lt 2 ]]; then
    echo "Usage: ./docker-instance-manager.sh plugin-uninstall <name> <plugin-id> [--keep-files] [--dry-run] [--no-force] [--restart]" >&2
    exit 1
  fi

  local instance="$1"
  local plugin_id="$2"
  local keep_files=false
  local dry_run=false
  local force=true
  local restart=false
  local -a uninstall_args
  shift 2

  ensure_instance_exists "$instance"
  uninstall_args=(plugins uninstall "$plugin_id")

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keep-files)
        keep_files=true
        shift
        ;;
      --dry-run)
        dry_run=true
        shift
        ;;
      --no-force)
        force=false
        shift
        ;;
      --restart)
        restart=true
        shift
        ;;
      *)
        echo "Unknown option for plugin-uninstall: $1" >&2
        exit 1
        ;;
    esac
  done

  if [[ "$keep_files" == true ]]; then
    uninstall_args+=(--keep-files)
  fi
  if [[ "$dry_run" == true ]]; then
    uninstall_args+=(--dry-run)
  fi
  if [[ "$force" == true ]]; then
    uninstall_args+=(--force)
  fi

  echo "==> Uninstalling plugin '$plugin_id' for instance '$instance'"
  run_compose "$instance" run --rm openclaw-cli "${uninstall_args[@]}"

  if [[ "$restart" == true && "$dry_run" == false ]]; then
    echo "==> Restarting gateway for instance '$instance'"
    run_compose "$instance" restart openclaw-gateway
  fi
}

cmd_list() {
  local file name
  local found=false
  for file in "$STATE_DIR"/*.env; do
    [[ -e "$file" ]] || continue
    found=true
    name="$(basename "$file" .env)"
    printf '%s\n' "[$name]"
    grep_file_lines '^(OPENCLAW_IMAGE|OPENCLAW_GATEWAY_PORT|OPENCLAW_GATEWAY_LISTEN_PORT|OPENCLAW_BRIDGE_PORT|OPENCLAW_CONFIG_DIR|OPENCLAW_WORKSPACE_DIR)=' "$file" \
      | sed 's/^[0-9]\+://'
    grep_file_lines '^(OPENCLAW_EXPOSE_BRIDGE_PORT|OPENCLAW_DOCKER_NETWORK_MODE|OPENCLAW_HOME_VOLUME|OPENCLAW_EXTRA_MOUNTS)=' "$file" \
      | sed 's/^[0-9]\+://'
    echo ""
  done
  if [[ "$found" == false ]]; then
    echo "No instances yet. Run: ./docker-instance-manager.sh create <name>"
  fi
}

main() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --instances-dir)
        [[ $# -ge 2 ]] || { echo "Missing value for --instances-dir" >&2; exit 1; }
        STATE_DIR="$2"
        shift 2
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  local cmd="$1"
  shift

  case "$cmd" in
    build)
      cmd_build "$@"
      ;;
    create)
      cmd_create "$@"
      ;;
    up)
      [[ $# -ge 1 ]] || { echo "Usage: ./docker-instance-manager.sh up <name> [--verbose]" >&2; exit 1; }
      cmd_up "$@"
      ;;
    down)
      [[ $# -eq 1 ]] || { echo "Usage: ./docker-instance-manager.sh down <name>" >&2; exit 1; }
      cmd_down "$1"
      ;;
    restart)
      [[ $# -eq 1 ]] || { echo "Usage: ./docker-instance-manager.sh restart <name>" >&2; exit 1; }
      cmd_restart "$1"
      ;;
    status)
      [[ $# -le 1 ]] || { echo "Usage: ./docker-instance-manager.sh status [name]" >&2; exit 1; }
      cmd_status "$@"
      ;;
    logs)
      [[ $# -ge 1 ]] || { echo "Usage: ./docker-instance-manager.sh logs <name> [-f] [--verbose]" >&2; exit 1; }
      cmd_logs "$@"
      ;;
    onboard)
      [[ $# -eq 1 ]] || { echo "Usage: ./docker-instance-manager.sh onboard <name>" >&2; exit 1; }
      cmd_onboard "$1"
      ;;
    cli)
      [[ $# -ge 1 ]] || { echo "Usage: ./docker-instance-manager.sh cli <name> -- <args...>" >&2; exit 1; }
      cmd_cli "$@"
      ;;
    devices)
      [[ $# -ge 1 ]] || { echo "Usage: ./docker-instance-manager.sh devices <name> -- <args...>" >&2; exit 1; }
      cmd_devices "$@"
      ;;
    plugin-install)
      [[ $# -ge 2 ]] || {
        echo "Usage: ./docker-instance-manager.sh plugin-install <name> <path-or-spec> [--link] [--set-json <file>] [--restart]" >&2
        exit 1
      }
      cmd_plugin_install "$@"
      ;;
    plugin-uninstall)
      [[ $# -ge 2 ]] || {
        echo "Usage: ./docker-instance-manager.sh plugin-uninstall <name> <plugin-id> [--keep-files] [--dry-run] [--no-force] [--restart]" >&2
        exit 1
      }
      cmd_plugin_uninstall "$@"
      ;;
    list)
      [[ $# -eq 0 ]] || { echo "Usage: ./docker-instance-manager.sh list" >&2; exit 1; }
      cmd_list
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo "Unknown command: $cmd" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
