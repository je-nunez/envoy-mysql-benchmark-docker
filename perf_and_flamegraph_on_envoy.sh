
envoy_mysql_port=1999

# FlameGraph installation directory (optional, if flame-graphs are desired
# on the envoy perf data).
# ( Install from https://github.com/brendangregg/FlameGraph )
flame_graph_dir=./FlameGraph

# finds Envoy pid even when it is invoked via getenvoy (another way could be
# done without using lsof). Even when Envoy is called through getenvoy,
# perf and flamegraph (below) obtain demangled symbol-names inside Envoy.
envoy_pid=$( lsof -t -i tcp:$envoy_mysql_port -s TCP:LISTEN )
if [[ $? -ne 0 ]]; then
   echo "No Envoy proxy seems to be listening at port TCP:$envoy_mysql_port"
   exit 1
fi

common_suffix=${envoy_pid}_$( date +%s )_$$

perf_file=envoy_${common_suffix}.data

# callgraph_opt=dwarf
callgraph_opt=fp

# perf_event=instructions
perf_event=cycles

trap '' INT       # ignore Ctrl-C for this (parent) bash script

echo "Starting PERF-EVENTS collection. Finish it by pressing with Ctrl-C..."
perf record -e "${perf_event}":u --branch-filter any_call,any_ret,u  \
       --call-graph $callgraph_opt --per-thread  \
       -o "$perf_file" --pid=${envoy_pid}

# Generating the flamegraph (if it is installed):

if [ ! -d "$flame_graph_dir" ]; then
    # FlameGraph doesn't seem to be installed in "$flame_graph_dir"
    exit 0
fi

perf script -i "$perf_file" |  \
       ${flame_graph_dir}/stackcollapse-perf.pl | \
       ${flame_graph_dir}/flamegraph.pl > envoy_flamegraph_${common_suffix}.svg

