# About

A benchmark on the Envoy proxy with MySQL backend using SysBench

# WIP

This project is a *work in progress*. The implementation is *incomplete* and
subject to change. The documentation can be inaccurate.

# How:

1. Run the [test] MySQL server on localhost (according to this `envoy.yaml`)

2. Run the Envoy proxy to that MySQL server, like:

      getenvoy run standard:1.18.2 -- --config-path <path-to-this>/envoy.yaml 

Or if Envoy was compiled locally, then:

      <path-to>/envoy --config-path <path-to-this>/envoy.yaml

3. Prepare the Perf capture (and FlameGraph, if installed) in one terminal:

      bash x perf_and_flamegraph_on_envoy.sh

4. In another terminal, start the SysBench on the Envoy/MySQL setup:

      bash sysbench_envoy_mysql_load_test.sh

5. After the SysBench finished, then in the terminal with the Perf capture,
press Ctrl-C.

