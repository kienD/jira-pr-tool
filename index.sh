#!/bin/bash
set -e

SCRIPT_DIR=$(dirname "${BASH_SOURCE[0]}")
source "${SCRIPT_DIR}/config"

# Requires jq

# Check to see if jq is installed
function check_if_jq_exists() {
  if [[ -z $(command -v jq) ]]; then
    echo "jq package is missing. Please install it via your package manager."

    exit 1
  fi
}

# Get the branches name
function get_branch_name() {
  git rev-parse --abbrev-ref HEAD
}

# Get the repos name
function get_repo_name() {
  basename "$(git rev-parse --show-toplevel)"
}

# Get the github user
function get_github_user() {
  git config github.user
}

# Check if cookies currently exist. If not then request user to log in to obtain cookies
function check_cookies() {
  if [[ ! -f "${COOKIE}" ]]; then
    save_cookies
  fi

  local error_message
  error_message=$(curl -s -b "$COOKIE" "https://issues.liferay.com/rest/auth/1/session" | jq -r '.errorMessages[0]')

  if [[ "$error_message" != "null" ]]; then
    echo "$error_message"
    echo " "

    rm "$COOKIE"

    save_cookies
  else
    echo "Cookie is still valid"
    echo "Proceeding with pull request submission"
  fi
}

# Save cookies to $COOKIE location
function save_cookies() {
  echo "Jira Credentials Required"

  read -rp "Username: " username

  curl -s -u "$username" -c "$COOKIE" "https://issues.liferay.com/rest/auth/1/session" >/dev/null
}

function check_for_errors() {
  local json_response="$1"

  local error_message
  error_message=$(jq -r '.message' <<<"$json_response")

  if [[ "$error_message" != "null" ]]; then
    local detailed_error_message
    detailed_error_message=$(jq -r '.errors[0].message' <<<"$json_response")

    if [[ "$detailed_error_message" != "null" ]]; then
      echo "Error: $detailed_error_message"
    else
      echo "Error: $error_message"
    fi
  fi
}

# Fetch the jira issue based on the branch name
function fetch_jira_issue() {
  local branch_name
  branch_name=$(get_branch_name)

  local response
  response=$(curl -s -b "$COOKIE" "${JIRA_ISSUES_API}/${branch_name}?fields=summary,issuetype")

  echo "$response"
}

# Add assignees and labels to the pull request after the pull request has been made
function add_assignees_and_labels_to_pr() {
  local base_user="$1"
  local pr_id="$2"
  local assignees="$3"
  local labels="$4"

  local repo_name
  repo_name=$(get_repo_name)

  local endpoint="https://api.github.com/repos/${base_user}/${repo_name}/issues/${pr_id}"
  local data="{\"assignees\": [${assignees}],\"labels\": [${labels}]}"

  local response
  response=$(curl -s -X PATCH -H "Authorization: token ${GITHUB_TOKEN}" -d "$data" "$endpoint")

  echo "$response"
}

# Create the pull request  with the title and message provided by jira
function create_gh_pull_request() {
  local base_user="$1"
  local base_branch="$2"
  local head="$3"

  local repo_name
  repo_name=$(get_repo_name)

  local response
  response=$(fetch_jira_issue)

  local issue_number
  issue_number=$(echo "$response" | jq -r '.key')
  local title
  title=$(echo "$response" | jq -r '(.key + " " + .fields.summary)')

  local endpoint="https://api.github.com/repos/${base_user}/${repo_name}/pulls"
  local data="{\"title\": \"${title}\", \"body\": \"Jira Issue: [${issue_number}](https://issues.liferay.com/browse/${issue_number})\", \"head\": \"${head}\", \"base\": \"${base_branch}\"}"

  local gh_pr_response
  gh_pr_response=$(curl -s -X POST -H "Authorization: token ${GITHUB_TOKEN}" -d "$data" "$endpoint")

  echo "${gh_pr_response}"
}

# Takes a string of comma separated words and wraps each individual word in double quotes
function wrap_words_in_quotes() {
  IFS=','

  local words="$1"
  local wrapped_words

  for word in $words; do
    if [[ -n "$wrapped_words" ]]; then
      wrapped_words="$wrapped_words,\"$word\""
    else
      wrapped_words="\"$word\""
    fi
  done

  unset IFS

  echo "$wrapped_words"
}

function main() {
  check_if_jq_exists

  # Check for cookies & Prompt for Jira login info if no cookies available
  local assignees
  local base_branch
  local base_user
  local head
  head="$(get_github_user):$(get_branch_name)"
  local labels

  # Grab flag values and provide them to variables
  while getopts 'h a:b:l:H:' flag; do
    case "$flag" in
    h)
      echo "jira-pr-tool"
      echo " "

      echo "jpt [options]"
      echo " "

      echo "OPTIONS"
      echo "    -h"
      echo "        Show help tips"
      echo " "

      echo "    -a <assignees>"
      echo "        Add assigness for pull request"
      echo "        e.g. \"-a user1,user2\""
      echo " "
      echo "    -b <branch>"
      echo "        Set branch to send pull request to."
      echo "        e.g. \"-b liferay:7.1.x\""
      echo " "

      echo "    -H <head>"
      echo "        Set the name of the branch where your changes are implemented"
      echo "        e.g. \"-H user1:LRAC-0\""

      echo "    -l <labels>"
      echo "        Set label to add to pull request"
      echo "        e.g. \"-l reviewRequired\""

      exit 0
      ;;
    a)
      assignees=$(wrap_words_in_quotes "$OPTARG")
      ;;
    b)
      IFS=':'

      local -a branch

      read -r -a branch < <(echo "$OPTARG")

      local base_user=${branch[0]}
      local base_branch=${branch[1]}

      unset IFS
      ;;
    H)
      if [[ -n "$OPTARG" ]]; then
        head="$OPTARG"
      fi
      ;;
    l)
      labels=$(wrap_words_in_quotes "$OPTARG")
      ;;
    *)
      echo "Invalid flag provided: -$OPTARG"
      ;;
    esac
  done

  if [[ -z "$base_user" || -z "$base_branch" ]]; then
    echo "Branch is required: e.g. -b liferay:7.1.x"

    exit 0
  fi

  check_cookies

  local pr_response
  pr_response=$(create_gh_pull_request "$base_user" "$base_branch" "$head")

  local pr_error_message
  pr_error_message=$(check_for_errors "$pr_response")

  if [[ -n "$pr_error_message" ]]; then
    echo "$pr_error_message"
  else
    local pr_id
    pr_id=$(jq -r '.number' <<<"$pr_response")
    local pr_url
    pr_url=$(jq -r '.html_url' <<<"$pr_response")
    local pr_title
    pr_title=$(jq -r '.title' <<<"$pr_response")

    echo "Pull request successfully submitted"
    echo "$pr_title"
    echo "$pr_url"

    local issue_response
    issue_response=$(add_assignees_and_labels_to_pr "$base_user" "$pr_id" "$assignees" "$labels")

    local issue_error_message
    issue_error_message=$(check_for_errors "$issue_response")

    if [[ -n "$issue_error_message" ]]; then
      echo "$issue_error_message"
    else
      echo "Done!"
      # TODO: Add labels & assignees added here.
    fi
  fi
}

main "$@"
