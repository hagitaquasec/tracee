#!/bin/bash

#
# This test is executed by github workflows inside the action runners
#

TRACEE_STARTUP_TIMEOUT=30
TRACEE_SHUTDOWN_TIMEOUT=30
TRACEE_RUN_TIMEOUT=60
SCRIPT_TMP_DIR=/tmp
TRACEE_TMP_DIR=/tmp/tracee

info_exit() {
    echo -n "INFO: "
    echo "$@"
    exit 0
}

info() {
    echo -n "INFO: "
    echo "$@"
}

error_exit() {
    echo -n "ERROR: "
    echo "$@"
    exit 1
}

if [[ $UID -ne 0 ]]; then
    error_exit "need root privileges"
fi

if [[ ! -d ./signatures ]]; then
    error_exit "need to be in tracee root directory"
fi

KERNEL=$(uname -r)
KERNEL_MAJ=$(echo "$KERNEL" | cut -d'.' -f1)

if [[ $KERNEL_MAJ -lt 5 && "$KERNEL" != *"el8"* ]]; then
    info_exit "skip test in kernels < 5.0 (and not RHEL)"
fi

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
SIG_DIR="$SCRIPT_DIR/../dist/e2e-inst-signatures"

# run CO-RE VFS_WRITE test only by default
TESTS=${INSTTESTS:=VFS_WRITE}

# startup needs
rm -rf ${TRACEE_TMP_DIR:?}/* || error_exit "could not delete $TRACEE_TMP_DIR"
git config --global --add safe.directory "*"

info
info "= ENVIRONMENT ================================================="
info
info "KERNEL: $(uname -r)"
info "CLANG: $(clang --version)"
info "GO: $(go version)"
info
info "= COMPILING TRACEE ============================================"
info
# make clean # if you want to be extra cautious
set -e
make -j"$(nproc)" all
make e2e-inst-signatures
set +e
if [[ ! -x ./dist/tracee ]]; then
    error_exit "could not find tracee executable"
fi

# if any test has failed
anyerror=""

# run tests
for TEST in $TESTS; do

    info
    info "= TEST: $TEST =============================================="
    info

    rm -f $SCRIPT_TMP_DIR/build-$$
    rm -f $SCRIPT_TMP_DIR/tracee-log-$$

    ./dist/tracee \
        --install-path $TRACEE_TMP_DIR \
        --cache cache-type=mem \
        --cache mem-cache-size=512 \
        --proctree source=both \
        --output option:sort-events \
        --output json:$SCRIPT_TMP_DIR/build-$$ \
        --output option:parse-arguments \
        --log file:$SCRIPT_TMP_DIR/tracee-log-$$ \
        --signatures-dir "$SIG_DIR" \
        --scope comm=echo,mv,ls,tracee,proctreetester \
        --events "$TEST" &

    # wait tracee-ebpf to be started (30 sec most)
    times=0
    timedout=0
    while true; do
        times=$((times + 1))
        sleep 1
        if [[ -f $TRACEE_TMP_DIR/out/tracee.pid ]]; then
            info
            info "UP AND RUNNING"
            info
            break
        fi

        if [[ $times -gt $TRACEE_STARTUP_TIMEOUT ]]; then
            timedout=1
            break
        fi
    done

    # tracee-ebpf could not start for some reason, check stderr
    if [[ $timedout -eq 1 ]]; then
        info
        info "$TEST: FAILED. ERRORS:"
        info
        cat $SCRIPT_TMP_DIR/tracee-log-$$

        anyerror="${anyerror}$TEST,"
        continue
    fi

    # give some time for tracee to settle
    sleep 3

    # run test scripts
    timeout --preserve-status $TRACEE_RUN_TIMEOUT \
        ./tests/e2e-inst-signatures/scripts/"${TEST,,}".sh

    # so event can be processed and detected
    sleep 3

    ## cleanup at EXIT

    logfile=$SCRIPT_TMP_DIR/tracee-log-$$

    found=0
    cat $SCRIPT_TMP_DIR/build-$$ | jq .eventName | grep -q "$TEST" && found=1
    errors=$(cat $logfile | wc -l 2>/dev/null)

    if [[ $TEST == "BPF_ATTACH" ]]; then
        errors=0
    fi

    info
    if [[ $found -eq 1 && $errors -eq 0 ]]; then
        info "$TEST: SUCCESS"
    else
        anyerror="${anyerror}$TEST,"
        info "$TEST: FAILED, stderr from tracee:"
        cat $SCRIPT_TMP_DIR/tracee-log-$$
        info "$TEST: FAILED, events from tracee:"
        cat $SCRIPT_TMP_DIR/build-$$
        info
    fi
    info

    rm -f $SCRIPT_TMP_DIR/build-$$
    rm -f $SCRIPT_TMP_DIR/tracee-log-$$

    # make sure we exit to start it again

    pid_tracee=$(pidof tracee | cut -d' ' -f1)

    kill -2 "$pid_tracee"

    sleep $TRACEE_SHUTDOWN_TIMEOUT

    # make sure tracee is exited with SIGKILL
    kill -9 "$pid_tracee" >/dev/null 2>&1

    # give a little break for OS noise to reduce
    sleep 3

    # cleanup leftovers
    rm -rf $TRACEE_TMP_DIR
done

info
if [[ $anyerror != "" ]]; then
    info "ALL TESTS: FAILED: ${anyerror::-1}"
    exit 1
fi

info "ALL TESTS: SUCCESS"

exit 0
