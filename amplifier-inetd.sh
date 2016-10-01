#!/bin/sh
#
# An inetd service which listens for messages of the format:
# `playing input`, where `input` is the name of the input,
# e.g., `playing coax1`. Access control must be done on the
# inetd level - anyone who can connect to this service can
# switch to any input.

if read message device; then
    if [ "$message" = "playing" ]; then
        /etc/rotel/amp-switch-to-input "$device" 2>/dev/null
    fi
fi
