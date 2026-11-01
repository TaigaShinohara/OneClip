#!/bin/bash
# Withdrawn diagnostic: retain the entry point without building or launching it.
set -euo pipefail
printf '%s\n' '{"state":"NOT_ESTABLISHED","reason":"observer_withdrawn","childLaunches":0,"resourceAcceptance":false}'
exit 2
