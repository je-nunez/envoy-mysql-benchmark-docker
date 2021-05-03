#!/bin/bash
#
# Run Sysbench tests on an Envoy proxy with a MySQL upstream database.

declare -r RESULTS_DIR=/results

declare -r DRIVER=mysql
declare -r DB_USER=root
declare -r DB_PASSWORD=

declare -r ENVOY_HOST=127.0.0.1
declare -r ENVOY_PROXY_PORT=1999

declare -r CONTAINER_ID=$( /bin/cat /proc/sys/kernel/hostname )
declare -r COMMON_FNAME_SUFFIX="container_${CONTAINER_ID}_ts_$( date +%s )"

declare -r DURATION_ONE_SB_TEST=30

# Where the SysBench Lua tests scripts are located:
declare -r SBTEST_SCRIPTDIR=/usr/share/sysbench

# These are the SysBench scripts to use to test on Envoy: add custom
# SysBench tests below to increase filter-coverage testing.
# (Note: not all Lua files under $SBTEST_SCRIPTDIR need to be tests
# properly, for, e.g., "oltp_common.lua" is a common library used by
# the other tests -SysBench should fail trying to run it directly.)
declare -ar SB_TESTS_TO_RUN=(
    "${SBTEST_SCRIPTDIR}/oltp_read_write.lua"
    "${SBTEST_SCRIPTDIR}/bulk_insert.lua"
    "${SBTEST_SCRIPTDIR}/oltp_delete.lua"
    "${SBTEST_SCRIPTDIR}/oltp_insert.lua"
    "${SBTEST_SCRIPTDIR}/oltp_point_select.lua"
    "${SBTEST_SCRIPTDIR}/oltp_read_only.lua"
    "${SBTEST_SCRIPTDIR}/oltp_update_index.lua"
    "${SBTEST_SCRIPTDIR}/oltp_update_non_index.lua"
    "${SBTEST_SCRIPTDIR}/oltp_write_only.lua"
    "${SBTEST_SCRIPTDIR}/select_random_points.lua"
    "${SBTEST_SCRIPTDIR}/select_random_ranges.lua"
  )

# Prepare the cmd-line arguments to call SysBench
declare -r SBTEST_DB_MIN_REQ_ARGS="--${DRIVER}-db=my_envoy_test
                                   --${DRIVER}-host=${ENVOY_HOST}
                                   --${DRIVER}-port=${ENVOY_PROXY_PORT}
                                   --${DRIVER}-user=${DB_USER}
                                   --${DRIVER}-password=${DB_PASSWORD}"

declare -r DB_DRIVER_ARGS="--db-driver=${DRIVER} ${SBTEST_DB_MIN_REQ_ARGS}"

# These are determined latter on
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
  local full_envoy_logf="${RESULTS_DIR}/${fname}"
  # Allow the collection of coredumps (externally, docker's --ulimit core=-1
  # need to be set, and something like
  # echo '/results/core.%e.%p' | sudo tee /proc/sys/kernel/core_pattern
  # to save the cores under the ${RESULTS_DIR} persistent volume.)
  ulimit -c unlimited
  /usr/local/bin/envoy -c /etc/envoy.yaml -l debug \
                       --log-path "${full_envoy_logf}" --enable-core-dump &
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


function wait_till_backend_db_is_up() {
  # The Envoy port ${ENVOY_PROXY_PORT} can be up but the backend db server
  # upstream doesn't need to be up yet.
  cat > /tmp/test_sql_connection.lua <<EOF
        function cmd_testconn()
           io.write("Checking if database is up... ")
           local drv = sysbench.sql.driver()
           local con = drv:connect()

           local n = con:query_row(
                           "SELECT count(*) FROM INFORMATION_SCHEMA.COLUMNS"
                     )

           -- If it reaches here, the connection was established and query ok
           io.write("done\n")
        end

        sysbench.cmdline.commands = {
           testconn = {cmd_testconn, sysbench.cmdline.PARALLEL_COMMAND}
        }
EOF

  local test_args="/tmp/test_sql_connection.lua  ${DB_DRIVER_ARGS}
                   --threads=1 --events=1 --verbosity=0"

  while true; do
    sysbench ${test_args} testconn
    if (( $? == 0 )); then break; fi

    log "Waiting 5 more seconds for ${DRIVER}"
    sleep 5
  done

  /bin/rm -f /tmp/test_sql_connection.lua
  log "Upstream ${DRIVER} db is also ready. Sysbench tests can start"
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

  /usr/bin/perf record -e "${perf_event}":u  \
                   --branch-filter any_call,any_ret,u  \
                   --call-graph "${callgraph_opt}" --per-thread  \
                   -o "${PERF_FILE}" --pid="${ENVOY_PID}"  &
}


function run_sysbench_db_test() {
  local test_lua_file="${1?Full filepath of the the Lua test necessary}"

  # If the intention is to do a load-test and not merely a coverage
  # flame-graph, then change sb_extra_args and sb_driver_extra_args below

  local sb_extra_args="--threads=2 --time=${DURATION_ONE_SB_TEST} --events=0
                       --percentile=95 --db-debug=on"

  local sb_driver_extra_args="--tables=8 --table_size=100000
                              --simple_ranges=1000 --range_selects=on
                              --distinct_ranges=0 --auto_inc=on"

  local args="${test_lua_file}  ${DB_DRIVER_ARGS}
              ${sb_driver_extra_args}  ${sb_extra_args}"

  log "Running SB test with $test_lua_file\nArgs:\n$(tr '\n' ' ' <<< $args)"

  # set -x

  sysbench ${args} prepare

  [[ "${DRIVER}" == "mysql" ]] && sysbench ${args} prewarm

  sysbench ${args} run

  sysbench ${args} cleanup

  # set +x
}


function run_all_combined_envoy_tests() {
  # This is where all combined Envoy tests (not merely connectivity tests,
  # like in wait_till_backend_db_is_up()) are run

  local num_sb_tests=${#SB_TESTS_TO_RUN[@]}

  get_all_envoy_stats "Envoy stats before all tests"

  for (( i=0; i<num_sb_tests; i++ )); do
    local sysbench_test_script="${SB_TESTS_TO_RUN[$i]}"

    run_sysbench_db_test "${sysbench_test_script}"

    get_all_envoy_stats "Envoy stats after ${sysbench_test_script}"
  done
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

log Done

exit 0
