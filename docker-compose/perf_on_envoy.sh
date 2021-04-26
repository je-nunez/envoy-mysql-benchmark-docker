#!/bin/bash

RESULTS_DIR=/results

# this container only has one Envoy pid
envoy_pid=$( pgrep -x envoy )
if [[ $? -ne 0 ]]; then
   echo "No Envoy proxy seems to be running"
   exit 1
fi

perf_file="$RESULTS_DIR/envoy_mysql_perf_$( date +%s )_${envoy_pid}_$$.data"

# callgraph_opt=dwarf
callgraph_opt=fp

# perf_event=instructions
perf_event=cycles

exec /usr/bin/perf record -e "${perf_event}":u  \
                 --branch-filter any_call,any_ret,u  \
                 --call-graph $callgraph_opt --per-thread  \
                 -o "$perf_file" --pid=${envoy_pid}

