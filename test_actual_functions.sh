#!/bin/bash
#
# Run Sysbench tests on an Envoy proxy with a MySQL upstream database.

# This file needs to define at least two functions:
#
# wait_till_backend_db_is_up(): it waits till the backend (upstream) db is up
#
# run_all_combined_envoy_tests(): it runs all the tests on Envoy that are
#                                 recorded by perf-record.

# The functions log() and get_all_envoy_stats(), both receiving an optional
# parameter with a message to print in the log before the envoy stats, are
# available in the environment to be called by the functions in this file.

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

           -- If it reaches here, the connection was established and the query
           -- executed
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


function run_sysbench_db_test() {
  local test_lua_file="${1?Full filepath of the Lua test necessary}"

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

  # Iterate over each test in the array SB_TESTS_TO_RUN and execute it serially
  local num_sb_tests=${#SB_TESTS_TO_RUN[@]}

  get_all_envoy_stats "Envoy stats before all tests"

  for (( i=0; i<num_sb_tests; i++ )); do
    local sysbench_test_script="${SB_TESTS_TO_RUN[$i]}"

    run_sysbench_db_test "${sysbench_test_script}"

    get_all_envoy_stats "Envoy stats after ${sysbench_test_script}"
  done

}

