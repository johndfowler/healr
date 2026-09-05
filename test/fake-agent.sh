#!/usr/bin/env bash
# fake-agent.sh --- Stand-in agentic CLI for the healr sandbox.
# Prints a prompt, echoes input, blocks on /block until y/n, /quit exits.
printf 'fake-agent ready\n> '
blocked=0
while IFS= read -r line; do
  if [ "$blocked" = 1 ]; then
    case "$line" in
      y|n) printf '\033[2J\033[Hproceeding\n> '; blocked=0 ;;
      *) : ;;
    esac
    continue
  fi
  case "$line" in
    /quit) printf 'bye\n'; exit 0 ;;
    /block) printf 'Do you want to proceed? (y/n) '; blocked=1 ;;
    *) printf 'you said: %s\n> ' "$line" ;;
  esac
done
