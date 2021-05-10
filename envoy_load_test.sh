#!/bin/bash
#
# Run Sysbench tests on an Envoy proxy with a MySQL upstream database.
# This script connects only to Envoy, so it is agnostic to where the upstream
# database is located.

declare -r RESULTS_DIR=/results

declare -r DRIVER=mysql

declare -r ENVOY_HOST=127.0.0.1
declare -r ENVOY_PROXY_PORT=1999

declare -r CONTAINER_ID=$( /bin/cat /proc/sys/kernel/hostname )
declare -r COMMON_FNAME_SUFFIX="container_${CONTAINER_ID}_ts_$( date +%s )"

declare -r PERF_SAMPLING_FREQ=997

# Load the test's global variables and constants

. /root/test_global_vars.sh

# Load the test's actual definitions (at least two functions,
# wait_till_backend_db_is_up() and run_all_combined_envoy_tests(),
# need to be defined). 

. /root/test_actual_functions.sh

# These are determined latter on
declare ENVOY_LOG_FILE
declare ENVOY_PID
declare PERF_FILE=""


function log() {
  echo -e "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*"
}


function capture_stdout_err() {
  local fname="script_${DRIVER}_trace_${COMMON_FNAME_SUFFIX}.log"
  local full_script_logf="${RESULTS_DIR}/${fname}"
  exec >"${full_script_logf}" 2>&1
}


function log_envoy_version() {
  log "Testing version:"
  /usr/local/bin/envoy --version
}


function launch_envoy_backgr() {
  local fname="envoy_${DRIVER}_log_${COMMON_FNAME_SUFFIX}.log"
  ENVOY_LOG_FILE="${RESULTS_DIR}/${fname}"
  readonly ENVOY_LOG_FILE
  # Allow the collection of coredumps (externally, docker's --ulimit core=-1
  # need to be set, and something like
  # echo '/results/core.%e.%p' | sudo tee /proc/sys/kernel/core_pattern
  # to save the cores under the ${RESULTS_DIR} persistent volume.)
  ulimit -c unlimited
  /usr/local/bin/envoy -c /etc/envoy.yaml -l debug \
                       --log-path "${ENVOY_LOG_FILE}" --enable-core-dump &
  ENVOY_PID=$!
}


function wait_till_envoy_tcp_up() {
  # Wait till it listens at the TCP port ${ENVOY_PROXY_PORT} in /proc/net/tcp.
  local port_hexad=$( printf "%04X" "${ENVOY_PROXY_PORT}" )

  while true; do
    awk -v phex="${port_hexad}"  '
          BEGIN {
                  listen_port= "00000000:" phex;
                  exit_val=1      # default exit-value: not listening yet
          }
          ( $2 == listen_port ) && ( $3 == "00000000:0000" ) {
                   exit_val=0;
                   exit(exit_val)
          }
          END { exit(exit_val) }
       '   /proc/net/tcp

    if (( $? == 0 )); then break; fi

    log "Waiting 5 more seconds for Envoy"
    sleep 5
  done
}


function start_perf_record_on_envoy() {
  # check that Envoy is still running at this point
  local real_envoy_pid
  real_envoy_pid=$( /usr/bin/pgrep -x envoy )
  if (( $? != 0 )); then
    log "Error: No Envoy proxy seems to be still running"
    exit 1
  elif (( "${real_envoy_pid}" != "${ENVOY_PID}" )); then
    log "Notice: Envoy changed pid: ${real_envoy_pid} != ${ENVOY_PID}"
    ENVOY_PID=${real_envoy_pid}
  fi

  local fname="envoy_${DRIVER}_perf_${COMMON_FNAME_SUFFIX}.data"
  PERF_FILE="${RESULTS_DIR}/${fname}"

  # callgraph_opt=dwarf
  local callgraph_opt=fp

  # perf_event=instructions
  local perf_event=cycles

  log "Starting perf-record on Envoy pid = ${ENVOY_PID}"

  /usr/bin/perf record -e "${perf_event}" --freq="${PERF_SAMPLING_FREQ}" \
                   --call-graph "${callgraph_opt}" --per-thread  \
                   -o "${PERF_FILE}" --pid="${ENVOY_PID}"  &

}


function get_all_envoy_stats() {

  local stats_mssg="${1:-Final}"

  local fname="envoy_${DRIVER}_stats_${COMMON_FNAME_SUFFIX}.log"
  local full_stats_logf="${RESULTS_DIR}/${fname}"

  log "${stats_mssg}\n" >> "${full_stats_logf}"

  /usr/bin/curl -s http://localhost:8001/stats >> "${full_stats_logf}"
}


function end_envoy_proxy() {
  # check that Envoy is still running at this point
  local real_envoy_pid
  real_envoy_pid=$( /usr/bin/pgrep -x envoy )
  if (( $? != 0 )); then
    log "Error: No Envoy proxy seems to be still running"
    return
  elif (( "${real_envoy_pid}" != "${ENVOY_PID}" )); then
    log "Notice: Envoy changed pid: ${real_envoy_pid} != ${ENVOY_PID}"
    ENVOY_PID=${real_envoy_pid}
  fi
  # clean-up: the perf capture should also close after some delay:
  /bin/kill -SIGINT "${ENVOY_PID}"
}


function wait_till_perf_record_ends_cleanly() {
  # Give time to perf to close its "perf.data" file, to avoid
  # that it has "file's data size field is 0 which is unexpected"

  if [[ -z "${PERF_FILE}" ]]; then
    log "Error: No perf-record file was set: '${PERF_FILE}'"
    exit 3
  fi

  while true; do
    if ! /usr/bin/pgrep -x perf > /dev/null
    then      # perf does not appear running
      # is the perf.data file still open?
      /bin/ls -lR /proc/*/fd/ | /bin/grep -- " -> ${PERF_FILE}\$"
      if (( $? != 0 )); then break; fi
    fi

    log "Waiting for perf-record to finish..."
    sleep 1
  done
}


function obtain_perf_script_with_symbol_names() {
  # Obtain the symbol names in the generated perf.data from the current
  # /usr/local/bin/envoy, otherwise the symbol names could be lost for a
  # flame-graph (having only unresolved symbol addresses).

  log "Obtaining a perf-script to capture symbol names for flamegraph..."

  if [[ -z "${PERF_FILE}" ]]; then
      log "Error: No perf-record file was set: '${PERF_FILE}'"
      exit 4
  elif [[ ! -s "${PERF_FILE}" ]]; then
      log "Error: Perf file does not exist or is empty: '${PERF_FILE}'"
      exit 5
  fi

  /usr/bin/perf script -i "${PERF_FILE}" | \
         /usr/bin/xz -9 > "${PERF_FILE/.data/.script.txt.xz}"
}


function compress_some_result_files() {
  # Some result files can be very big

  if [[ -s "${PERF_FILE}" ]]; then
      log "Compressing perf-data file: ${PERF_FILE}"
      /usr/bin/xz -9 "${PERF_FILE}"
  fi

  if [[ -s "${ENVOY_LOG_FILE}" ]]; then
      log "Compressing Envoy log file: ${ENVOY_LOG_FILE}"
      /usr/bin/xz -9 "${ENVOY_LOG_FILE}"
  fi

}


# Main:

capture_stdout_err

log_envoy_version

launch_envoy_backgr

wait_till_envoy_tcp_up

wait_till_backend_db_is_up

start_perf_record_on_envoy

run_all_combined_envoy_tests

end_envoy_proxy

wait_till_perf_record_ends_cleanly

obtain_perf_script_with_symbol_names

compress_some_result_files

log Done

exit 0
