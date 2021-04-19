
# The present script assumes that permissions have been granted inside the
# test MySQL server, something like:
#
# CREATE USER 'root'@'%' IDENTIFIED BY '<choose-your-MySQL-root-passwd>';
# GRANT ALL ON *.* TO 'root'@'%';
# FLUSH PRIVILEGES;

DB_USER=root
DB_PASSWORD='<choose-your-MySQL-root-passwd>'

# The MySQL database for the SysBench test (below) is dropped and re-created
# directly through the MySQL port (3306), not through the Envoy proxy, which
# only receives the SysBench test.
MYSQLADMIN_ARGS="--host=127.0.0.1 --port=3306 --user=$DB_USER --password=$DB_PASSWORD"
mysqladmin $MYSQLADMIN_ARGS --force drop my_envoy_test
mysqladmin $MYSQLADMIN_ARGS create my_envoy_test
unset MYSQLADMIN_ARGS

ENVOY_MYSQL_HOST=127.0.0.1
ENVOY_MYSQL_PORT=1999

# This is according to your local SysBench installation, where the SysBench
# Lua scripts are located:
SBTEST_SCRIPTDIR=/usr/share/sysbench/

# This is the SysBench script to use for this test on Envoy/MySQL:
# OLTP_SCRIPT_PATH=${OLTP_SCRIPT_PATH}/oltp_read_only.lua
OLTP_SCRIPT_PATH=${SBTEST_SCRIPTDIR}/oltp_read_write.lua

# Prepare the cmd-line arguments to call SysBench
SBTEST_MYSQL_ARGS="--mysql-db=my_envoy_test
 --mysql-host=$ENVOY_MYSQL_HOST --mysql-port=$ENVOY_MYSQL_PORT
 --mysql-user=$DB_USER --mysql-password=$DB_PASSWORD
 --tables=8 --table_size=100000 --simple_ranges=1000
 --range_selects=on --distinct_ranges=0 --auto_inc=on"

DB_DRIVER_ARGS="--db-driver=mysql $SBTEST_MYSQL_ARGS"

# Run the SysBench during 30 seconds, and show the load database debug
# SB_EXTRA_ARGS="--threads=2 --time=30 --events=0 --percentile=95"
SB_EXTRA_ARGS="--threads=2 --time=30 --events=0 --percentile=0 --db-debug=on"

ARGS="${OLTP_SCRIPT_PATH} ${DB_DRIVER_ARGS} ${SB_EXTRA_ARGS}"

# Run the SysBench test on the Envoy proxy to MySQL:

sysbench $ARGS prepare

sysbench $ARGS prewarm

sysbench $ARGS run

# Optional: clean up all the tables in MySQL used by the SysBench test:
sysbench $ARGS cleanup

