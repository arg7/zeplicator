#!/bin/bash
# sim.sh — simulator pane convenience wrappers
# Sourced automatically in tzepcon pane 3

SDIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
export PS1='\[\e[36m\]sim>\[\e[0m\] '
SESSION="${ZEP_SESSION:-zep-test}"

test() {
    case "${1:-}" in
        stop)
            tmux send-keys -t "${SESSION}:0.0" C-c
            sleep 0.4
            local pid pane_pid child
            pane_pid=$(tmux list-panes -t "${SESSION}:0.0" -F '#{pane_pid}' 2>/dev/null)
            if [[ -n "$pane_pid" ]]; then
                child=$(pgrep -P "$pane_pid" -f "zep_replication_tests" | head -1)
                [[ -n "$child" ]] && kill "$child" 2>/dev/null && echo "  Killed PID $child"
            fi
            echo "  Test run stopped."
            ;;
        start)
            shift
            tmux send-keys -t "${SESSION}:0.0" C-c
            sleep 0.4
            tmux send-keys -t "${SESSION}:0.0" "clear" C-m
            sleep 0.1
            local args="$*"
            tmux send-keys -t "${SESSION}:0.0" "${SDIR}/zep_replication_tests.sh ${args}" C-m
            echo "  Started: zep_replication_tests.sh ${args}"
            ;;
        '')
            echo "Usage: test {start|stop}"
            echo "  test start [--test N ...]   Run tests (no args = all)"
            echo "  test stop                   Abort running test suite"
            ;;
        *)
            echo "Unknown: test $1"
            echo "Usage: test {start|stop}"
            ;;
    esac
}

keystroke() {
    local pane="${ZEP_PANE:-0.2}"
    tmux send-keys -t "${SESSION}:${pane}" "$*" C-m
    echo "  Sent to pane ${pane}: $*"
}
