#!/bin/sh
# Fixed source for an explicitly started U3/D12 trial; invoke with /bin/sh, do not source it.
# The source may be kept on read-only media. Runtime fixture values are not saved by this script.
# CSI 3J requests scrollback clearing, but its actual effect needs the person's Terminal UI check.
# Closing/changing this view is not a guarantee about OS/Terminal saving, restoration or full erasure.

printf '%s\n' 'PURPOSE U3/D12 disposable fiction: Return replaces the before view with the after view.'

# Check before clearing the view or generating an identifier. Also reject redirected stdout so
# this script cannot put runtime fixture content into a file/pipe through its normal invocation.
if [ ! -t 0 ] || [ ! -t 1 ]; then
    printf '%s\n' 'NOT_RUN INTERACTIVE_TERMINAL_REQUIRED NO_UUID_GENERATED'
    exit 0
fi
if [ ! -x /usr/bin/uuidgen ]; then
    printf '%s\n' 'NOT_RUN UUIDGEN_UNAVAILABLE NO_UUID_GENERATED'
    exit 1
fi

clear_view() {
    printf '\033[3J\033[2J\033[H'
}

wait_for_return() {
    if ! IFS= read -r fixture_reply; then
        unset fixture_reply
        printf '%s\n' 'FIXTURE_INTERRUPTED INPUT_ENDED'
        exit 1
    fi
    # Input is never interpreted, printed, copied into fixture content or saved.
    unset fixture_reply
}

clear_view
printf '%s\n' \
    'U3/D12 disposable fiction. Capture only the intended fixture text.' \
    'Press Return only after the before image has been captured.' \
    '' \
    'oneclip u3 - disposable before' \
    'endpoint local.example.test' \
    'timeout 3 s' \
    'retry OFF' \
    'before-only id'
# Direct stdout only: no command substitution, variable, shell argument or history expansion
# contains the generated value. Do not copy its exact value into trial notes or logs.
if ! /usr/bin/uuidgen; then
    printf '%s\n' 'FIXTURE_INTERRUPTED UUID_GENERATION_FAILED'
    exit 1
fi
wait_for_return

clear_view
printf '%s\n' \
    'U3/D12 disposable fiction. Capture only the intended fixture text.' \
    'Press Return only after the after image has been captured, to finish.' \
    '' \
    'oneclip u3 - disposable after' \
    'endpoint local.example.test' \
    'timeout 10 s' \
    'retry ON' \
    'old-before-removed'
wait_for_return
printf '%s\n' 'FIXTURE_FINISHED UI_AND_U3_D12_RESULTS_REQUIRE_SEPARATE_CONFIRMATION'
