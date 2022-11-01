#!/bin/bash

# build up flags passed to this file on run + env flag for additional flags
# e.g. docker run ... -e "PURE_FTPD_CUSTOM_FLAGS=--tls=2" ...
PURE_FTPD_FLAGS="$@"
[ -z "$PURE_FTPD_CUSTOM_FLAGS" ] || \
    PURE_FTPD_FLAGS="$PURE_FTPD_FLAGS $PURE_FTPD_CUSTOM_FLAGS"

# start rsyslog
if [[ "$PURE_FTPD_FLAGS" == *" -d"* ]] || [[ "$PURE_FTPD_FLAGS" == *"--verboselog"* ]]
then
    echo "Log enabled, see /var/log/messages"
    rm -rf /var/log/pure-ftpd/pureftpd.log
    rsyslogd
    tail --pid $$ -F /var/log/pure-ftpd/pureftpd.log &
fi

PASSWD_FILE="/etc/pure-ftpd/passwd/pureftpd.passwd"
DB_FILE="/etc/pure-ftpd/puredb/pureftpd.pdb"

# Load in any existing db from volume store
if [ -e "$PASSWD_FILE" ] && [ ! -s "$DB_FILE" ]
then
    pure-pw mkdb "$DB_FILE" -f "$PASSWD_FILE"
fi

if [ -s "$DB_FILE" ] && [[ "$PURE_FTPD_FLAGS" != *"--login=puredb:"* ]] && [[ "$PURE_FTPD_FLAGS" != *" -l puredb:"* ]]
then
    PURE_FTPD_FLAGS="$PURE_FTPD_FLAGS --login=puredb:\"$DB_FILE\""
fi

# detect if using TLS (from volumed in file) but no flag set, set one
if [ -e /etc/ssl/private/pure-ftpd.pem ] && [[ "$PURE_FTPD_FLAGS" != *"--tls="* ]] && [[ "$PURE_FTPD_FLAGS" != *"-Y "* ]]
then
    echo "TLS Enabled"
    PURE_FTPD_FLAGS="$PURE_FTPD_FLAGS --tls=1"
fi

# If TLS flag is set and cert and key are given are given as two files, merge them into one cert
if [ -e /etc/ssl/private/pure-ftpd-cert.pem ] && [ -e /etc/ssl/private/pure-ftpd-key.pem ] && [[ "$PURE_FTPD_FLAGS" == *"--tls="* || "$PURE_FTPD_FLAGS" != *"-Y "* ]]
then
    echo "Merging certificate and key"
    cat /etc/ssl/private/pure-ftpd-cert.pem /etc/ssl/private/pure-ftpd-key.pem > /etc/ssl/private/pure-ftpd.pem
fi

# If TLS flag is set and no certificate exists, generate it
if [ ! -e /etc/ssl/private/pure-ftpd.pem ] && [[ "$PURE_FTPD_FLAGS" == *"--tls="* || "$PURE_FTPD_FLAGS" != *"-Y "* ]] && \
   [ ! -z "$TLS_CN" ] && [ ! -z "$TLS_ORG" ] && [ ! -z "$TLS_C" ]
then
    echo "Generating self-signed certificate"
    mkdir -p /etc/ssl/private
    if [[ "$TLS_USE_DSAPRAM" == "true" ]]; then
        openssl dhparam -dsaparam -out /etc/ssl/private/pure-ftpd-dhparams.pem 2048
    else
        openssl dhparam -out /etc/ssl/private/pure-ftpd-dhparams.pem 2048
    fi
    openssl req -subj "/CN=${TLS_CN}/O=${TLS_ORG}/C=${TLS_C}" -days 1826 \
        -x509 -nodes -newkey rsa:2048 -sha256 -keyout \
        /etc/ssl/private/pure-ftpd.pem \
        -out /etc/ssl/private/pure-ftpd.pem
    chmod 600 /etc/ssl/private/*.pem
fi

# Add user
if [ ! -z "$FTP_USER_NAME" ] && [ ! -z "$FTP_USER_PASS" ] && [ ! -z "$FTP_USER_HOME" ]
then
    echo "Creating user"

    # make sure the home folder exists
    mkdir -p "$FTP_USER_HOME"

    # Generate the file that will be used to inject in the password prompt stdin
    PWD_FILE="$(mktemp)"
    echo "$FTP_USER_PASS
$FTP_USER_PASS" > "$PWD_FILE"

    # Set uid/gid
    PURE_PW_ADD_FLAGS=""
    if [ ! -z "$FTP_USER_UID" ]
    then
        PURE_PW_ADD_FLAGS="$PURE_PW_ADD_FLAGS -u $FTP_USER_UID"
    else
        PURE_PW_ADD_FLAGS="$PURE_PW_ADD_FLAGS -u ftp"
    fi
    if [ ! -z "$FTP_USER_GID" ]
    then
        PURE_PW_ADD_FLAGS="$PURE_PW_ADD_FLAGS -g $FTP_USER_GID"
    fi

    pure-pw useradd "$FTP_USER_NAME" -f "$PASSWD_FILE" -m -d "$FTP_USER_HOME" $PURE_PW_ADD_FLAGS < "$PWD_FILE"

    if [ ! -z "$FTP_USER_HOME_PERMISSION" ]
    then
        chmod "$FTP_USER_HOME_PERMISSION" "$FTP_USER_HOME"
        echo " root user give \"$FTP_USER_NAME\" ftp user at $FTP_USER_HOME directory has $FTP_USER_HOME_PERMISSION permission"
    fi

    if [ ! -z "$FTP_USER_UID" ]
    then
        if ! [[ $(ls -ldn $FTP_USER_HOME | awk '{print $3}') = $FTP_USER_UID ]]
        then
            chown $FTP_USER_UID "$FTP_USER_HOME"
            echo " root user give $FTP_USER_HOME directory \"$FTP_USER_UID\" owner"
        fi
    else
        if ! [[ $(ls -ld $FTP_USER_HOME | awk '{print $3}') = 'ftp' ]]
        then
            chown ftpuser "$FTP_USER_HOME"
            echo " root user give $FTP_USER_HOME directory \"ftp\" owner"
        fi
    fi

    rm "$PWD_FILE"
    echo "Created user"
fi

# Set a default value to the env var FTP_PASSIVE_PORTS
if [ -z "$FTP_PASSIVE_PORTS" ]
then
    FTP_PASSIVE_PORTS=38801:38864
fi

# Set passive port range in pure-ftpd options if not already existent
if [[ $PURE_FTPD_FLAGS != *" -p "* ]] && [[ $PURE_FTPD_FLAGS != *"--passiveportrange="* ]]
then
    echo "Setting default port range to: $FTP_PASSIVE_PORTS"
    PURE_FTPD_FLAGS="$PURE_FTPD_FLAGS --passiveportrange=$FTP_PASSIVE_PORTS"
fi

# Set a default value to the env var FTP_MAX_CLIENTS
if [ -z "$FTP_MAX_CLIENTS" ]
then
    FTP_MAX_CLIENTS=16
fi

# Set max clients in pure-ftpd options if not already existent
if [[ $PURE_FTPD_FLAGS != *" -c "* ]] && [[ $PURE_FTPD_FLAGS != *"--maxclientsnumber="* ]]
then
    echo "Setting default max clients to: $FTP_MAX_CLIENTS"
    PURE_FTPD_FLAGS="$PURE_FTPD_FLAGS --maxclientsnumber=$FTP_MAX_CLIENTS"
fi

# Set a default value to the env var FTP_MAX_LOGINS (per user)
if [ -z "$FTP_MAX_LOGINS" ]
then
    FTP_MAX_LOGINS=3:$FTP_MAX_CLIENTS
fi

# Set max connections per user in pure-ftpd options if not already existent
if [[ $PURE_FTPD_FLAGS != *" -y "* ]] && [[ $PURE_FTPD_FLAGS != *"--peruserlimits="* ]]
then
    echo "Setting default max connections per user to: $FTP_MAX_LOGINS"
    PURE_FTPD_FLAGS="$PURE_FTPD_FLAGS --peruserlimits=$FTP_MAX_LOGINS"
fi

# let users know what flags we've ended with (useful for debug)
echo "Starting Pure-FTPd:"
echo "  pure-ftpd $PURE_FTPD_FLAGS"

# start pureftpd with requested flags
exec /usr/sbin/pure-ftpd $PURE_FTPD_FLAGS
