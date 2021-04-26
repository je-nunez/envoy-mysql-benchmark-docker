# About

A docker-compose version of the benchmark on the Envoy proxy with MySQL backend
using SysBench.

# WIP

This project is a *work in progress*. The implementation is *incomplete* and
subject to change. The documentation can be inaccurate.

# How:

In this `docker-compose` directory, run:

1. mkdir ./proxy_results 2>/dev/null

2. docker-compose pull

3. docker-compose up --build -d

The results of the tests will be left in the `proxy_results` directory.
(If another directory is needed, please modify `docker-compose.yaml`.) The
files left in each run of the test containers are (`timestamp` and `extra`
below are the epoch timestamp and some extra temporary numbers):

- envoy_mysql_stats_timestamp_extra.log

The Envoy stats at the end of the tests, from `http://localhost:8001/stats`

- envoy_mysql_log_timestamp.log

The Envoy debug logs.

- script_mysql_trace_timestamp_extra.log

The test script logs itself (contains Perf and SysBench messages).

- envoy_mysql_perf_timestamp_extra.data

The Perf-Record file during the Sysbench tests.

- envoy_mysql_perf_timestamp_extra.script.txt.xz

The Perf-Script text file generated (with symbol names) from the Perf-Record
file above.

