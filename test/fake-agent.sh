#!/usr/bin/env bash
# fake-agent.sh --- Stand-in agentic CLI for the healr sandbox.
# Prints a prompt, echoes input, exits on /quit.
printf 'fake-agent ready\n> '
while IFS= read -r line; do
  case "$line" in
    /quit) printf 'bye\n'; exit 0 ;;
    *) printf 'you said: %s\n> ' "$line" ;;
  esac
done
