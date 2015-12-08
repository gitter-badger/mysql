#!/bin/bash
set -e

PID=

# set up environment and render my.cnf config
config() {

    # replace innodb_buffer_pool_size value from environment
    # or use a sensible default (70% of available physical memory)
    local default=$(awk '/MemTotal/{printf "%.0f\n", ($2 / 1024) * 0.7}' /proc/meminfo)M
    local buffer=$(printf 's/^innodb_buffer_pool_size = 128M/innodb_buffer_pool_size = %s/' \
                          ${INNODB_BUFFER_POOL_SIZE:-${default}})
    sed -i "${buffer}" /etc/my.cnf

    # replace server-id with ID derived from hostname
    # ref https://dev.mysql.com/doc/refman/5.7/en/replication-configuration.html
    local id=$(hostname | python -c 'import sys; print(int(str(sys.stdin.read())[:4], 16))')
    sed -i $(printf 's/^server-id=.*$/server-id=%s/' $id) /etc/my.cnf
    sed -i $(printf 's/^report-host=.*$/report-host=%s/' $(hostname)) /etc/my.cnf

    # hypothetically we could start the container with `--datadir` set
    # but there's no reason to jump thru those hoops in this environment
    # and it complicates the entrypoint greatly
    DATADIR=$(mysqld --verbose --help --log-bin-index=/tmp/tmp.index | awk '$1 == "datadir" { print $2 }')

}

# make sure we have all required environment variables
checkConfig() {
    if [ -z "$MYSQL_ROOT_PASSWORD" -a -z "$MYSQL_ALLOW_EMPTY_PASSWORD" -a -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
        echo >&2 'error: database is uninitialized and password option is not specified '
        echo >&2 '  You need to specify one of MYSQL_ROOT_PASSWORD, MYSQL_ALLOW_EMPTY_PASSWORD and MYSQL_RANDOM_ROOT_PASSWORD'
        exit 1
    fi
}

# clean up the temporary mysqld service
cleanup() {
    if [ -n $PID ]; then
        echo 'Shutting down temporary bootstrap mysqld:' $PID
        if ! kill -s TERM "$PID" || ! wait "$PID"; then
            echo >&2 'MySQL init process failed.'
            exit 1
        fi
    fi
}

# ---------------------------------------------------------
# Initialization

initializeDb() {
    mkdir -p "${DATADIR}"
    chown -R mysql:mysql "${DATADIR}"

    echo 'Initializing database...'
    mysqld --initialize-insecure=on --user=mysql --datadir="${DATADIR}"
    echo 'Database initialized.'

    mysqld --user=mysql --datadir="${DATADIR}" --skip-networking &
    PID="$!"
    echo 'Running temporary bootstrap mysqld PID:' $PID
}

waitForConnection() {
    mysql=( mysql --protocol=socket -uroot )
    echo 'Waiting for bootstrap mysqld to start...'
    for i in {30..0}; do
        if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
            break
        fi
        echo -ne '.'
        sleep 1
    done
    if [ "$i" = 0 ]; then
        echo >&2 'MySQL init process failed.'
        exit 1
    fi
    echo
}

setupRootUser() {
    if [ ! -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
        MYSQL_ROOT_PASSWORD="$(pwmake 128)"
        echo "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
    fi

    "${mysql[@]}" <<-EOSQL
		SET @@SESSION.SQL_LOG_BIN=0;
		DELETE FROM mysql.user where user != 'mysql.sys';
		CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
		GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION ;
		DROP DATABASE IF EXISTS test ;
		FLUSH PRIVILEGES ;
EOSQL
    if [ ! -z "$MYSQL_ROOT_PASSWORD" ]; then
        mysql+=( -p"${MYSQL_ROOT_PASSWORD}" )
    fi
}

createDb() {
    if [ "$MYSQL_DATABASE" ]; then
        echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" | "${mysql[@]}"
        mysql+=( "$MYSQL_DATABASE" )
    fi
}

createDefaultUser() {
    if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
        echo "CREATE USER '"$MYSQL_USER"'@'%' IDENTIFIED BY '"$MYSQL_PASSWORD"' ;" \
            | "${mysql[@]}"
        if [ "$MYSQL_DATABASE" ]; then
            echo "GRANT ALL ON \`"$MYSQL_DATABASE"\`.* TO '"$MYSQL_USER"'@'%' ;" | "${mysql[@]}"
        fi
        echo 'FLUSH PRIVILEGES ;' | "${mysql[@]}"
    fi
}

createReplUser() {
    if [ "$MYSQL_REPL_USER" -a "$MYSQL_REPL_PASSWORD" ]; then
        "${mysql[@]}" <<-EOSQL
			CREATE USER '$MYSQL_REPL_USER'@'%' IDENTIFIED BY '$MYSQL_REPL_PASSWORD';
			GRANT REPLICATION SLAVE ON *.* TO '$MYSQL_REPL_USER'@'%';
			GRANT REPLICATION CLIENT ON *.* TO '$MYSQL_REPL_USER'@'%';
			FLUSH PRIVILEGES ;
EOSQL
    fi
}

# borrowed from Oracle-provided Docker image:
# https://github.com/mysql/mysql-docker/blob/mysql-server/5.7/docker-entrypoint.sh
init() {

    if [ ! -d "${DATADIR}/mysql" ]; then
        checkConfig        # make sure we have all required environment variables
        initializeDb       # sets $PID for temporary mysqld while we bootstrap
        waitForConnection  # sets $mysql[] which we'll use for all future conns

        mysql_tzinfo_to_sql /usr/share/zoneinfo | "${mysql[@]}" mysql

        setupRootUser      # creates root user
        createDb           # create the default DB
        createDefaultUser  # create the default DB user
        createReplUser     # create the replication user

        # run user-defined files added to /etc/initdb.d in a child Docker image
        for f in /etc/initdb.d/*; do
            case "$f" in
                *.sh)  echo "$0: running $f"; . "$f" ;;
                *.sql) echo "$0: running $f"; "${mysql[@]}" < "$f" && echo ;;
                *)     echo "$0: ignoring $f" ;;
            esac
        done

        # remove the one-time root password (default behavior)
        if [ ! -z "$MYSQL_ONETIME_PASSWORD" ]; then
            "${mysql[@]}" <<-EOSQL
                ALTER USER 'root'@'%' PASSWORD EXPIRE;
EOSQL
        fi

        echo
        echo 'MySQL init process done. Ready for start up.'
        echo
    fi
}


# ---------------------------------------------------------
# Replication


# poll the discovery service until we find the primary node
getPrimary() {
    PRIMARY_HOST=
    while true
    do
        PRIMARY_HOST=$(curl -Ls --fail http://consul:8500/v1/catalog/service/mysql \
                         | jq -r '.[0].ServiceAddress')
        if [[ ${PRIMARY_HOST} != "null" ]] && [[ -n ${PRIMARY_HOST} ]]; then
            break
        fi
        # no primary nodes up yet, so wait and retry
        sleep 1.7
    done
}

dataDump() {
    mysqldump --all-databases --master-data > dbdump.db
}

# TODO: need to make sure $mysql is populated
setPrimaryForReplica() {

    if [ -e "${DATADIR}/master.status" ]; then
        local primary_log_file=$(tail -n 1 "${DATADIR}/master.status" | cut -f 1)
        local primary_log_pos=$(tail -n 1 "${DATADIR}/master.status" | cut -f 2)
        primary_log_pos=${primary_log_pos:-0}
    fi

    "${mysql[@]}" <<-EOSQL
		CHANGE MASTER TO
		MASTER_HOST           = '$PRIMARY_HOST',
		MASTER_USER           = '$MYSQL_REPL_USER',
		MASTER_PASSWORD       = '$MYSQL_REPL_PASSWORD',
		MASTER_PORT           = 3306,
		MASTER_CONNECT_RETRY  = 60,
		MASTER_LOG_FILE       = '$primary_log_file',
		MASTER_LOG_POS        = $primary_log_pos,
		MASTER_SSL            = 0;
EOSQL

}

# TODO
health() {
    echo 'Doing health check'
}

# TODO
onChange() {
    echo 'Doing onChange handler'
}

# TODO
replica() {
    init
    echo 'Setting up replication'
    getPrimary
    setPrimaryForReplica
    cleanup
}


# ---------------------------------------------------------
# default behavior will be to start mysqld, running the
# initialization if required

# write config file, even if we've previously initialized the DB,
# so that we can account for changed hostnamed, resized containers, etc.
config

# make sure that if we've pulled in an external data volume that
# the mysql user can read it
chown -R mysql:mysql "${DATADIR}"


# if command starts with an option, prepend mysqld
if [ "${1:0:1}" = '-' ]; then
    set -- mysqld "$@"
fi

# here's where we'll divert from running mysqld if we want
# to set up replication, perform backups, etc.
cmd=$1
if [ ! -z "$cmd" ]; then
    if ! type $cmd > /dev/null; then
        # whatever we're trying to run is external to this script
        exec "$@"
    else
        shift 1
        $cmd "$@"
    fi
    exit
fi

# default behavior: set up the DB
init
cleanup