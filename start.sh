#!/bin/bash

# Script trace mode
if [ "${DEBUG_MODE:-false}" == "true" ]; then
    set -o xtrace
fi

# If requested, perform a healthcheck and exit
if [[ ${1,,} == "healthcheck" ]]; then
    ps -p $(cat /var/run/krb5kdc.pid) | grep "krb5kdc" > /dev/null
    krb5kdc_status=$?
    ps -p $(cat /var/run/kadmind.pid) | grep "kadmind" > /dev/null
    kadmin_status=$?
    if [ $krb5kdc_status -ne 0 ] || [ $kadmin_status -ne 0 ]; then
        echo "Error: krb5kdc and/or kadmind service are no longer running. Healthcheck failed."
        exit 1
    fi
    exit 0
fi

echo "Starting Kerberos KDC/KADMIN container"

# Check for custom CA certs
if [ "$(ls -A /etc/pki/trust/anchors)" ]; then
    echo "SSL certificate trust found. Running update-ca-trust"
    /usr/sbin/update-ca-trust extract
fi

# Determine if using LDAP (based on LDAP_HOST; fallback to local if not fully set)
if [ -z "${LDAP_HOST}" ]; then
    echo "WARNING: LDAP_HOST not set. Disabling LDAP integration and using local Kerberos database. To enable LDAP (e.g., for LLDAP or Keycloak), run with -e LDAP_HOST=your-ldap-host (e.g., ldap://lldap:389)."
    USE_LDAP=false
else
    USE_LDAP=true
fi
LDAP_PORT=${LDAP_PORT:-636}
ldap_url=ldaps://$$ {LDAP_HOST}: $${LDAP_PORT}

# usage: file_env VAR [DEFAULT]
# Loads var from ENV or file, with default; unsets _FILE after
file_env() {
    local var="$1"
    local fileVar="${var}_FILE"
    local defaultValue="${2:-}"

    if [ "$$ {!var:-}" ] && [ " $${!fileVar:-}" ]; then
        echo "WARNING: Both $var and $fileVar are set (exclusive). Using $var value."
    fi

    local val="$defaultValue"

    if [ "${!var:-}" ]; then
        val="${!var}"
        echo "** Using ${var} from ENV"
    elif [ "${!fileVar:-}" ]; then
        if [ ! -f "${!fileVar}" ]; then
            echo "WARNING: Secret file \"${!fileVar}\" not found. Falling back to default for $var."
        else
            val="$$ (< " $${!fileVar}")"
            echo "** Using ${var} from secret file"
        fi
    fi
    export "$var"="$val"
    unset "$fileVar"
}

# Helper functions (adapted to warn instead of exit)
ldap_create_person() {
    local ldap_url=$1
    local dn=$2  # Now full DN
    local sn=$3  # Description/name

    echo "  - Adding user $sn at $dn"
    /usr/bin/ldapadd -H $$ ldap_url -x -D " $${DM_DN}" -w "${DM_PASS}" <<EOL
dn: $dn
objectClass: person
objectClass: top
sn: $sn
EOL
    status=$?
    if [ $status -ne 0 ] && [ $status -ne 68 ]; then
        echo "WARNING: Failed adding user $sn at $dn (status $status). LDAP integration may not work. Check LDAP server logs and schema."
        return 1
    fi
    return 0
}

ldap_change_password() {
    local ldap_url=$1
    local dn=$2
    local new_pass=$3

    /usr/bin/ldappasswd -H $$ ldap_url -x -D " $${DM_DN}" -w "${DM_PASS}" -s $new_pass $dn
    status=$?
    if [ $status -ne 0 ]; then
        echo "WARNING: Failed changing password for $dn (status $status). Using existing or default—check LDAP auth."
        return 1
    fi
    return 0
}

ldap_aci_allow_modify() {
    local ldap_url=$1
    local dn=$2
    local rule_nickname=$3
    local user_dn=$4

    /usr/bin/ldapmodify -H $$ ldap_url -x -D " $${DM_DN}" -w "${DM_PASS}" <<EOL
dn: $dn
changetype: modify
add: aci
aci: (target="ldap:///$dn")(targetattr=*)
     (version 3.0; acl "$rule_nickname"; allow (all)
     userdn = "ldap:///$user_dn";)
EOL
    status=$?
    if [ $status -ne 0 ]; then
        echo "WARNING: Failed to modify directory permissions for $dn (status $status). Kerberos may not have write access—manual ACI setup needed."
        return 1
    fi
    return 0
}

save_password_into_file() {
    local dn=$1
    local pass=$2
    local file_path=$3

    /usr/sbin/kdb5_ldap_util stashsrvpw -f $file_path -w "$pass" "$dn" <<EOL
$pass
$pass

EOL
    if [ $? -ne 0 ]; then
        echo "WARNING: Failed to stash password for $dn in $file_path. LDAP auth may fail—check permissions."
        return 1
    fi
    return 0
}

# Set defaults and warnings for all vars (adaptive, no forced structures)
DESTROY_AND_RECREATE=${DESTROY_AND_RECREATE:-false}
if [ "$DESTROY_AND_RECREATE" == "false" ]; then
    echo "INFO: DESTROY_AND_RECREATE not set or false. Existing realm preserved. Set -e DESTROY_AND_RECREATE=true to recreate (careful, destructive!)."
fi

file_env REALM_NAME "EXAMPLE.COM"
if [ "$REALM_NAME" == "EXAMPLE.COM" ]; then
    echo "WARNING: REALM_NAME using default 'EXAMPLE.COM'. Set -e REALM_NAME=YOUR.REALM (e.g., HOME.LAN) for production."
fi

file_env MASTER_PASS
if [ -z "$MASTER_PASS" ]; then
    MASTER_PASS=$(openssl rand -base64 12)
    echo "WARNING: MASTER_PASS not set. Generated random: $MASTER_PASS. Set -e MASTER_PASS=strongpass or use MASTER_PASS_FILE for security."
fi

file_env BASE_DN "dc=example,dc=com"
if [ "$BASE_DN" == "dc=example,dc=com" ]; then
    echo "WARNING: BASE_DN using default 'dc=example,dc=com'. Set -e BASE_DN=your,base,dn to match your LDAP (e.g., dc=mydomain,dc=com for LLDAP)."
fi

file_env KDC_DN
if [ -z "$KDC_DN" ]; then
    KDC_DN="uid=krbkdc,ou=system,$BASE_DN"
    echo "WARNING: KDC_DN not set. Using default '$KDC_DN'. Customize with -e KDC_DN=your,full,dn (e.g., uid=krbkdc,ou=people,dc=mydomain,dc=com for LLDAP compatibility)."
fi

file_env KDC_PASS
if [ -z "$KDC_PASS" ]; then
    KDC_PASS=$(openssl rand -base64 12)
    echo "WARNING: KDC_PASS not set. Generated random: $KDC_PASS. Set -e KDC_PASS=strongpass or KDC_PASS_FILE."
fi

file_env ADMIN_DN
if [ -z "$ADMIN_DN" ]; then
    ADMIN_DN="uid=krbadm,ou=system,$BASE_DN"
    echo "WARNING: ADMIN_DN not set. Using default '$ADMIN_DN'. Customize with -e ADMIN_DN=your,full,dn."
fi

file_env ADMIN_PASS
if [ -z "$ADMIN_PASS" ]; then
    ADMIN_PASS=$(openssl rand -base64 12)
    echo "WARNING: ADMIN_PASS not set. Generated random: $ADMIN_PASS. Set -e ADMIN_PASS=strongpass or ADMIN_PASS_FILE."
fi

file_env CONTAINER_DN
if [ -z "$CONTAINER_DN" ]; then
    CONTAINER_DN="cn=kerberos,$BASE_DN"
    echo "WARNING: CONTAINER_DN not set. Using default '$CONTAINER_DN' for Kerberos entries subtree. Customize with -e CONTAINER_DN=your,container,dn (e.g., ou=kerberos,dc=mydomain,dc=com)."
fi

file_env DM_DN
if [ -z "$DM_DN" ]; then
    DM_DN="cn=Directory Manager"
    echo "WARNING: DM_DN not set. Using default '$DM_DN'. Customize with -e DM_DN=your,directory,manager,dn (e.g., uid=admin,ou=people,dc=mydomain,dc=com for LLDAP)."
fi

file_env DM_PASS
if [ -z "$DM_PASS" ]; then
    DM_PASS=$(openssl rand -base64 12)
    echo "WARNING: DM_PASS not set. Generated random: $DM_PASS. Set -e DM_PASS=strongpass or DM_PASS_FILE for LDAP bind."
fi

# Configuration if not already done (marker file for LDAP or local principal)
if [ ! -f /var/kerberos/krb5kdc/configured ]; then
    echo "Kerberos server not configured. Starting configuration."

    if [ "$USE_LDAP" == "true" ]; then
        echo "Configuring with LDAP backend."

        # Create users and passwords in LDAP (with fallbacks)
        ldap_create_person "$ldap_url" "$KDC_DN" "Kerberos KDC Connection" || USE_LDAP=false
        ldap_change_password "$ldap_url" "$$ KDC_DN" " $${KDC_PASS}" || USE_LDAP=false
        ldap_create_person "$ldap_url" "$ADMIN_DN" "Kerberos Administration Connection" || USE_LDAP=false
        ldap_change_password "$ldap_url" "$$ ADMIN_DN" " $${ADMIN_PASS}" || USE_LDAP=false

        pass_file_path=/var/kerberos/krb5kdc/ldap.creds
        echo " - Generating KRBADM/KDC Passwords to $pass_file_path"
        save_password_into_file "$$ KDC_DN" " $${KDC_PASS}" $pass_file_path || USE_LDAP=false
        save_password_into_file "$$ ADMIN_DN" " $${ADMIN_PASS}" $pass_file_path || USE_LDAP=false

        if [ "${DESTROY_AND_RECREATE}" == "true" ]; then
            echo " - Destroying existing realm from Directory server"
            /usr/sbin/kdb5_ldap_util -H $$ ldap_url -D " $${DM_DN}" -w "$$ {DM_PASS}" destroy -f -r " $${REALM_NAME}" || echo "WARNING: Destroy failed—continuing."
        fi

        echo " - Initialize Directory server for Kerberos operation"
        /usr/sbin/kdb5_ldap_util -H $$ ldap_url -D " $${DM_DN}" -w "$$ {DM_PASS}" create -r " $${REALM_NAME}" -subtrees "$$ {CONTAINER_DN}" -s -P " $${MASTER_PASS}"
        status=$?
        if [ $status -ne 0 ]; then
            echo "WARNING: Kerberos LDAP initialization failed (status $status). Falling back to local database."
            USE_LDAP=false
        fi

        if [ "$USE_LDAP" == "true" ]; then
            echo " - Give kerberos rights to modify directory"
            ldap_aci_allow_modify "$$ ldap_url" " $${CONTAINER_DN}" "kerberos-admin" "$ADMIN_DN" || echo "WARNING: ACI for admin failed."
            ldap_aci_allow_modify "$$ ldap_url" " $${CONTAINER_DN}" "kerberos-kdc" "$KDC_DN" || echo "WARNING: ACI for KDC failed."
        fi
    fi

    # If LDAP failed or disabled, configure local
    if [ "$USE_LDAP" == "false" ]; then
        echo "Configuring local Kerberos database (no LDAP)."
        /usr/sbin/kdb5_util create -s -r "$$ {REALM_NAME}" -P " $${MASTER_PASS}"
        status=$?
        if [ $status -ne 0 ]; then
            echo "ERROR: Local Kerberos initialization failed (status $status). Services may not start—check logs."
        else
            # Add basic admin principal for local
            kadmin.local -q "addprinc -pw $$ {ADMIN_PASS} admin/admin@ $${REALM_NAME}"
            echo "*/admin@${REALM_NAME} *" > /var/kerberos/krb5kdc/kadm5.acl
        fi
    fi

    # Mark as configured
    touch /var/kerberos/krb5kdc/configured
fi

# Generate krb5.conf
echo " - Generating /etc/krb5.conf"
cat > /etc/krb5.conf <<EOF
[libdefaults]
    dns_canonicalize_hostname = false
    rdns = false
    default_realm = ${REALM_NAME}
    default_ccache_name = FILE:/tmp/krb5cc_%{uid}
[realms]
    ${REALM_NAME} = {
            kdc = localhost
            admin_server = localhost
    }
[domain_realm]
    .${REALM_NAME,,} = ${REALM_NAME}
    ${REALM_NAME,,} = ${REALM_NAME}
[logging]
    kdc = FILE:/var/log/krb5/krb5kdc.log
    admin_server = FILE:/var/log/krb5/kadmind.log
    default = FILE:/var/log/krb5libs.log
EOF

# Generate kdc.conf (adapt for LDAP or local)
echo " - Generating /var/kerberos/krb5kdc/kdc.conf"
cat > /var/kerberos/krb5kdc/kdc.conf <<EOF
[kdcdefaults]
    kdc_ports = 750,88
[realms]
    ${REALM_NAME} = {
EOF
if [ "$USE_LDAP" == "true" ]; then
    cat >> /var/kerberos/krb5kdc/kdc.conf <<EOF
        database_module = contact_ldap
EOF
fi
cat >> /var/kerberos/krb5kdc/kdc.conf <<EOF
    }
[dbdefaults]
[dbmodules]
EOF
if [ "$USE_LDAP" == "true" ]; then
    cat >> /var/kerberos/krb5kdc/kdc.conf <<EOF
    contact_ldap = {
            db_library = kldap
            ldap_kdc_dn = "${KDC_DN}"
            ldap_kadmind_dn = "${ADMIN_DN}"
            ldap_kerberos_container_dn = "${CONTAINER_DN}"
            ldap_service_password_file = /var/kerberos/krb5kdc/ldap.creds
            ldap_servers = $ldap_url
    }
EOF
fi
cat >> /var/kerberos/krb5kdc/kdc.conf <<EOF
[logging]
    kdc = FILE:/var/log/krb5/krb5kdc.log
    admin_server = FILE:/var/log/krb5/kadmind.log
EOF

# Check LDAP reachability if enabled
if [ "$USE_LDAP" == "true" ]; then
    echo "Checking if LDAP server is reachable..."
    retries=0
    until [ $retries -eq 5 ] || /usr/bin/ldapsearch -H $ldap_url -x -b '' -LLL -s base vendorVersion; do
        sleep $(( retries++ ))
    done
    if [ $retries -ge 5 ]; then
        echo "WARNING: Failed connecting to $ldap_url after retries. Disabling LDAP and falling back to local."
        USE_LDAP=false
    fi
fi

# Start Kerberos services
echo "Starting kadmind..."
/usr/sbin/kadmind -P /var/run/kadmind.pid
echo "Starting krb5kdc..."
/usr/sbin/krb5kdc -P /var/run/krb5kdc.pid

# Show kdc logging as output. Tail will exit when receiving SIGTERM.
tail -f /var/log/krb5/krb5kdc.log &
tail_pid=$!
trap 'kill $tail_pid' TERM INT
wait $tail_pid

# Shutdown
echo "Shutting down krb5kdc..."
kill $(cat /var/run/krb5kdc.pid)
echo "Shutting down kadmind..."
kill $(cat /var/run/kadmind.pid)

# Wait for clean shutdown
while true; do
    ps -p $(cat /var/run/krb5kdc.pid) | grep "/usr/sbin/krb5kdc" > /dev/null
    krb5kdc_status=$?
    ps -p $(cat /var/run/kadmind.pid) | grep "/usr/sbin/kadmind" > /dev/null
    kadmin_status=$?
    if [ $krb5kdc_status -ne 0 ] && [ $kadmin_status -ne 0 ]; then
        exit 0
    fi
    sleep 1
done
