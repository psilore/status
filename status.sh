#!/usr/bin/env bash

set -e

OWNER=""
TEAM_SLUG=""

command_exists() {
  command -v "$@" >/dev/null 2>&1
}

format_error() {
  printf '%sERROR: %s%s\n' "${FMT_BOLD}${FMT_RED}" "$*" "$FMT_RESET" >&2
}

setup_colors(){
FMT_RED=$(printf '\033[31m')
FMT_BLUE=$(printf '\033[34m')
FMT_RESET=$(printf '\033[0m')
}

prompt_to_continue() {
  while true; do
      read -p "Do you wish to continue? " yn
      case $yn in
          [Yy]* ) break;;
          [Nn]* ) exit;;
          * ) echo "Please answer yes or no. [Yy]";;
      esac
  done
}

get_repo_names() {
  local OWNER="$1"
  local TEAM_SLUG="$2"
  local URL

  if [ -z "$TEAM_SLUG" ]; then
    URL="orgs/$OWNER/repos"
  else
    URL="orgs/$OWNER/teams/$TEAM_SLUG/repos"
  fi

  fetch_and_save_repo_names "$URL"
}

fetch_and_save_repo_names() {
  local URL="$1"
  local ACTIVE_REPOS
  local REPO_NAMES

  ACTIVE_REPOS=$(gh api "$URL" 2>&1)

  if [ $? -ne 0 ]; then
    format_error "Failed to fetch data from GitHub API:"
    echo "$ACTIVE_REPOS"
    exit 1
  fi

  REPO_NAMES=$(echo "$ACTIVE_REPOS" | jq -r '.[].name' 2>&1)

  if [ $? -ne 0 ]; then
    format_error "Failed to parse JSON with jq:"
    echo "$REPO_NAMES"
    exit 1
  fi

  echo "$REPO_NAMES" > "$REPO_LIST"
}

get_status() {

  local HAS_FAILURES=0
  if [ "$(tail -c 1 "$REPO_LIST")" ]; then
    echo "$REPO_LIST does not end with a newline character! Exiting..."
    exit 1
  fi

  REPOS=$(cat "$REPO_LIST")

  for REPO in $REPOS; do

    WORKFLOW_ID=$(gh api "repos/$OWNER/$REPO/actions/workflows" --jq ".workflows[] | .id")

    for WORKFLOW in $WORKFLOW_ID; do
      
      RUN_ID=$(gh api "repos/$OWNER/$REPO/actions/runs" | jq --arg WORKFLOW_ID "$WORKFLOW" '.workflow_runs[] | select(.workflow_id == ($WORKFLOW_ID | tonumber)) | .id' | head -n 1)
      if [ -z "$RUN_ID" ]; then
        continue
      fi

      RUN_STATUS=$(gh api "repos/$OWNER/$REPO/actions/runs/$RUN_ID" --jq '.status')
      RUN_CONCLUSION=$(gh api "repos/$OWNER/$REPO/actions/runs/$RUN_ID" --jq '.conclusion')

      if [ "$RUN_CONCLUSION" = "failure" ]; then
        HAS_FAILURES=1
        if [ -z "$FA_HEADER_PRINTED" ]; then
          printf "%-20s %-20s %-20s %-20s\n" "ID" "Status" "Conclusion" "Job" >> "$FAILURE_LIST"
          FA_HEADER_PRINTED=true
        fi
        printf "%-20s %-20s %-20s %-20s\n" "$WORKFLOW" "$RUN_STATUS" "$RUN_CONCLUSION" "$WORKFLOW_URL" >> "$FAILURE_LIST"
      fi

      if [ -z "$HEADER_PRINTED" ]; then
        printf "%-20s %-20s %-20s %-20s\n" "ID" "Status" "Conclusion" "Job" 
        HEADER_PRINTED=true
      fi
      WORKFLOW_URL="https://github.com/$OWNER/$REPO/actions/runs/$RUN_ID"
      printf "%-20s %-20s %-20s %-20s\n" "$WORKFLOW" "$RUN_STATUS" "$RUN_CONCLUSION" "$WORKFLOW_URL"
    
    done

  done

  return $HAS_FAILURES
}

setup() {
  setup_colors

  command_exists git || {
    format_error "git is not installed"
    exit 1
  }

  command_exists tail || {
    format_error "tail is not installed"
    exit 1
  }

  GIT_ROOT_DIR=$(git rev-parse --show-toplevel)
  REPO_LIST="$GIT_ROOT_DIR/active_repos.txt"
  FAILURE_LIST="$GIT_ROOT_DIR/failed_workflows.txt"
  LOGS_DIR="tmp/logs"
  LOG_FILE="$LOGS_DIR/status.log"

  mkdir -p "$LOGS_DIR"
  touch "$LOG_FILE"
  rm -f "$REPO_LIST"
  rm -f "$FAILURE_LIST"

  if [ -z "$TEAM_SLUG" ]; then
    printf '%s\n' "Fetching status for organisation: $OWNER workflows"
    prompt_to_continue
    get_repo_names "$OWNER"
    get_status
  else
    printf '%s\n' "Fetching status for team: $TEAM_SLUG workflows"
    get_repo_names "$OWNER" "$TEAM_SLUG"
    get_status
  fi

}

usage() {
  printf '%s\n' "Usage: $(basename "$0") [OPTIONS]"
  printf '\n'
  printf '%s\n' "Options:"
  printf '\n'
  printf '%s\n' "  -h               Show this help message"
  printf '\n'
  printf '%s\n' "  -o [Required]    Owner in GitHub"
  printf '\n'
  printf '%s\n' "  -t               Team name in GitHub, if no team name is provided,"
  printf '%s\n' "                   all workflows in the organizations repositories will be checked"
  printf '\n'
}

main() {
  while getopts "ho:t:" opt; do
    case $opt in
      h)
        usage
        exit 0
        ;;
      o)
        OWNER="$OPTARG"
        ;;
      t)
        TEAM_SLUG="$OPTARG"
        ;;
      \?)
        usage
        exit 1
        ;;
    esac
  done
  # Check required options
  if [[ -z $OWNER ]]; then
    format_error "Option [OWNER] is required"
    usage
    exit 1
  fi

  setup
    if [ $? -ne 0 ]; then
    format_error "One or more workflows have failed."
    exit 1
  fi
  exit 0
}


main "$@"
