#!/usr/bin/env bash

project_name_is_valid() {
  local project="${1:-}"
  [[ "$project" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]
}

project_state_root() {
  printf '%s/.infra/projects\n' "$BASE_DIR"
}

project_state_dir() {
  local project="${1:-}"
  project_name_is_valid "$project" || return 1
  printf '%s/%s\n' "$(project_state_root)" "$project"
}

project_env_file() {
  local project="${1:-}"
  printf '%s/.env\n' "$(project_state_dir "$project")"
}

legacy_env_file() {
  printf '%s/.env\n' "$BASE_DIR"
}

ensure_project_state_dir() {
  local project="${1:-}"
  mkdir -p "$(project_state_dir "$project")"
}

resolve_project_env_file() {
  local project="${1:-}"
  local env_file
  local legacy_file

  env_file="$(project_env_file "$project")"
  legacy_file="$(legacy_env_file)"

  if [ -f "$env_file" ]; then
    echo "$env_file"
    return 0
  fi

  if [ -f "$legacy_file" ]; then
    echo "$legacy_file"
    return 0
  fi

  echo "$env_file"
}

migrate_legacy_env_to_project() {
  local project="${1:-}"
  local env_file
  local legacy_file

  ensure_project_state_dir "$project"
  env_file="$(project_env_file "$project")"
  legacy_file="$(legacy_env_file)"

  if [ ! -f "$env_file" ] && [ -f "$legacy_file" ]; then
    cp "$legacy_file" "$env_file"
  fi

  echo "$env_file"
}
