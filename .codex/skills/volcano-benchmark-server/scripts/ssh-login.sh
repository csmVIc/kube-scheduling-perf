#!/usr/bin/env bash

set -euo pipefail

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

: "${BENCHMARK_SERVER:?BENCHMARK_SERVER not set}"
: "${BENCHMARK_SERVER_SECRET:?BENCHMARK_SERVER_SECRET not set}"

SSH_HOST="${BENCHMARK_SERVER}"
SSH_USER="${BENCHMARK_SERVER_USER:-root}"
SSH_PASSWORD="${BENCHMARK_SERVER_SECRET}"
unset BENCHMARK_SERVER_SECRET

if [[ "${SSH_HOST}" == *@* ]]; then
    if [[ -z "${BENCHMARK_SERVER_USER:-}" ]]; then
        SSH_USER="${SSH_HOST%%@*}"
    fi
    SSH_HOST="${SSH_HOST#*@}"
fi

command -v expect >/dev/null 2>&1 || fail "expect is required but not installed"
command -v ssh >/dev/null 2>&1 || fail "ssh is required but not installed"
command -v mktemp >/dev/null 2>&1 || fail "mktemp is required but not installed"
[[ -t 0 && -t 1 ]] || fail "an interactive terminal is required"

export SSH_HOST SSH_USER SSH_PASSWORD
SOCKET_PARENT="${TMPDIR:-/tmp}"
SOCKET_PARENT="${SOCKET_PARENT%/}"
SESSION_DIR="$(mktemp -d "${SOCKET_PARENT}/volcano-ssh.XXXXXX")" ||
    fail "could not create a temporary SSH session directory"
CONTROL_SOCKET="${SESSION_DIR}/control.sock"
export SSH_CONTROL_SOCKET="${CONTROL_SOCKET}"

cleanup_session() {
    if [[ -S "${CONTROL_SOCKET}" ]]; then
        ssh -S "${CONTROL_SOCKET}" -O exit "${SSH_USER}@${SSH_HOST}" >/dev/null 2>&1 || true
    fi
    if [[ -e "${CONTROL_SOCKET}" || -L "${CONTROL_SOCKET}" ]]; then
        rm -f -- "${CONTROL_SOCKET}" >/dev/null 2>&1 || true
    fi
    rmdir "${SESSION_DIR}" >/dev/null 2>&1 || true
}
trap cleanup_session EXIT

if ! expect <<'EXPECT_EOF'
set timeout 30
log_user 0
set host $env(SSH_HOST)
set user $env(SSH_USER)
set password $env(SSH_PASSWORD)
set control_socket $env(SSH_CONTROL_SOCKET)
unset env(SSH_PASSWORD)

spawn ssh \
    -o StrictHostKeyChecking=accept-new \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    -o NumberOfPasswordPrompts=1 \
    -o ConnectTimeout=15 \
    -o ConnectionAttempts=1 \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -M -S "${control_socket}" -fN \
    -- "${user}@${host}"

expect {
    -re "(?i)password:" {
        send -- "${password}\r"
    }
    timeout {
        puts stderr "Timed out waiting for the SSH password prompt"
        exit 124
    }
    eof {
        set wait_result [wait]
        exit [lindex $wait_result 3]
    }
}

expect {
    eof {}
    timeout {
        puts stderr "Timed out while establishing the SSH control connection"
        exit 124
    }
}

set wait_result [wait]
exit [lindex $wait_result 3]
EXPECT_EOF
then
    fail "could not authenticate to ${SSH_USER}@${SSH_HOST}"
fi

unset SSH_PASSWORD
ssh -S "${CONTROL_SOCKET}" -O check "${SSH_USER}@${SSH_HOST}" >/dev/null 2>&1 ||
    fail "SSH authentication succeeded, but the control connection is unavailable"

ssh -S "${CONTROL_SOCKET}" -tt -- "${SSH_USER}@${SSH_HOST}"
