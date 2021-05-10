#!/bin/bash
#
# Global constants and variables for tests on an Envoy proxy with a MySQL
# upstream database.

declare -r DB_USER=root
declare -r DB_PASSWORD=

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

