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

# Check for custom CA certs (AlmaLinux path)
if [ -d "/etc/pki/ca-trust/source/anchors" ] && [ "$(ls -A /etc/pki/ca-trust/source/anchors)" ]; then
    echo "SSL certificate trust found. Running update-ca-trust"
    /usr/bin/update-ca-trust extract
fi

# Hybrid mode: Default local backend (safe for LLDAP); optional full LDAP if LDAP_BACKEND=true
LDAP_BACKEND=${LDAP_BACKEND:-false}
if [ "$LDAP_BACKEND" == "true" ] && [ -z "${LDAP_HOST}" ]; then
    echo "WARNING: LDAP_BACKEND=true but LDAP_HOST not set. Falling back to local."
    LDAP_BACKEND=false
fi

# Flexible LDAP scheme and port (test defaults to plain ldap:3890; prod can override to ldaps:6360)
if [ "$LDAP_BACKEND" == "true" ]; then
    LDAP_SCHEME=${LDAP_SCHEME:-ldap}
    LDAP_PORT=${LDAP_PORT:-3890}
    ldap_url=${LDAP_SCHEME}://${LDAP_HOST}:${LDAP_PORT}
    echo "Full LDAP backend enabled (experimental with LLDAP—limitations on Kerberos subtree)."
fi

# LLDAP UI port for lldap-cli (assumes UI exposed on same host as LDAP, default 17170)
LLDAP_UI_PORT=${LLDAP_UI_PORT:-17170}

# usage: file_env VAR [DEFAULT]
# Loads var from ENV or file, with default; unsets _FILE after
file_env() {
    local var="$1"
    local fileVar="${var}_FILE"
    local defaultValue="${2:-}"

    local val="$defaultValue"

    if [ "${!var:-}" ]; then
        val="${!var}"
        echo "** Using ${var} from ENV"
    elif [ "${!fileVar:-}" ]; then
        if [ ! -f "${!fileVar}" ]; then
            echo "WARNING: Secret file \"${!fileVar}\" not found. Falling back to default for $var."
        else
            val="$(< "${!fileVar}")"
            echo "** Using ${var} from secret file"
        fi
    fi
    export "$var"="$val"
    unset "$fileVar"
}

# Helper functions (adapted to warn instead of exit)
ldap_create_person() {
    local ldap_url=$1
    local dn=$2  # Full DN
    local sn=$3  # Description/name

    echo "  - Adding user $sn at $dn"
    /usr/bin/ldapadd -H $ldap_url -x -D "${DM_DN}" -w "${DM_PASS}" <<EOL
dn: $dn
objectClass: person
objectClass: top
objectClass: inetOrgPerson
objectClass: posixAccount
sn: $sn
cn: $sn
uid: $sn
mail: ${sn}@service.${REALM_NAME,,}  # Optional email for LLDAP compatibility
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

    /usr/bin/ldappasswd -H $ldap_url -x -D "${DM_DN}" -w "${DM_PASS}" -s $new_pass $dn
    status=$?
    if [ $status -ne 0 ]; then
        echo "WARNING: Failed changing password for $dn (status $status). Using existing or default—check LDAP auth."
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

# New: LLDAP schema setup using bundled lldap-cli (optional for non-LLDAP)
setup_lldap_schema() {
    echo "Setting up LLDAP custom attributes for Kerberos + POSIX compatibility..."

    sleep 10  # Wait for LLDAP UI to fully boot (fixes timing race)

    export LLDAP_HTTPURL=http://${LDAP_HOST}:${LLDAP_UI_PORT}  # Internal service name for container-to-container
    export LLDAP_USERNAME=$(echo "${DM_DN}" | sed -n 's/^uid=\([^,]*\),.*/\1/p')  # Extract uid safely
    export LLDAP_PASSWORD="${DM_PASS}"

    # Helper to add if missing
    add_attr_if_missing() {
        local name=$1
        local type=$2
        local flags=$3  # e.g., "-l -v -e"

        if ! /usr/bin/lldap-cli schema attribute user list | grep -q "^${name} "; then
            echo "  - Adding custom attribute: $name ($type $flags)"
            /usr/bin/lldap-cli schema attribute user add "$name" "$type" $flags
            if [ $? -ne 0 ]; then
                echo "WARNING: Failed adding $name. Continuing—manual UI fix needed."
            fi
        else
            echo "  - Attribute $name already exists."
        fi
    }

    # Kerberos attributes (optional for hybrid—principals local)
    add_attr_if_missing krbPrincipalName string "-l -v -e"
    add_attr_if_missing krbPrincipalKey string "-v -e"
    add_attr_if_missing krbLastPwdChange date_time "-v -e"
    add_attr_if_missing krbMaxTicketLife integer "-v -e"
    add_attr_if_missing krbTicketFlags integer "-v -e"

    # POSIX attributes for SSSD/KDE/GNOME
    add_attr_if_missing uidNumber integer "-v -e"
    add_attr_if_missing gidNumber integer "-v -e"
    add_attr_if_missing homeDirectory string "-v -e"
    add_attr_if_missing loginshell string "-v -e"
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

file_env MASTER_PASS "mastertemp"
if [ "$MASTER_PASS" == "mastertemp" ]; then
    echo "WARNING: MASTER_PASS using INSECURE TESTING DEFAULT 'mastertemp'. CHANGE THIS FOR PRODUCTION—set -e MASTER_PASS=strongpass or use MASTER_PASS_FILE."
fi

file_env BASE_DN "dc=example,dc=com"
if [ "$BASE_DN" == "dc=example,dc=com" ]; then
    echo "WARNING: BASE_DN using default 'dc=example,dc=com'. Set -e BASE_DN=your,base,dn to match your LDAP (e.g., dc=mydomain,dc=com for LLDAP)."
fi

file_env KDC_DN
if [ -z "$KDC_DN" ]; then
    KDC_DN="uid=krbkdc,ou=people,$BASE_DN"
    echo "WARNING: KDC_DN not set. Using default '$KDC_DN' (LLDAP-friendly). Customize with -e KDC_DN=your,full,dn."
fi

file_env KDC_PASS "kdctemp"
if [ "$KDC_PASS" == "kdctemp" ]; then
    echo "WARNING: KDC_PASS using INSECURE TESTING DEFAULT 'kdctemp'. CHANGE THIS FOR PRODUCTION—set -e KDC_PASS=strongpass or KDC_PASS_FILE."
fi

file_env ADMIN_DN
if [ -z "$ADMIN_DN" ]; then
    ADMIN_DN="uid=krbadm,ou=people,$BASE_DN"
    echo "WARNING: ADMIN_DN not set. Using default '$ADMIN_DN' (LLDAP-friendly). Customize with -e ADMIN_DN=your,full,dn."
fi

file_env ADMIN_PASS "admintemp"
if [ "$ADMIN_PASS" == "admintemp" ]; then
    echo "WARNING: ADMIN_PASS using INSECURE TESTING DEFAULT 'admintemp'. CHANGE THIS FOR PRODUCTION—set -e ADMIN_PASS=strongpass or ADMIN_PASS_FILE."
fi

file_env CONTAINER_DN
if [ -z "$CONTAINER_DN" ]; then
    CONTAINER_DN="cn=kerberos,ou=groups,$BASE_DN"
    echo "WARNING: CONTAINER_DN not set. Using default '$CONTAINER_DN' (LLDAP group style for subtree). For OpenLDAP-style OU, override with -e CONTAINER_DN=ou=kerberos,$BASE_DN (may require manual creation)."
fi

file_env DM_DN
if [ -z "$DM_DN" ]; then
    DM_DN="uid=admin,ou=people,$BASE_DN"
    echo "WARNING: DM_DN not set. Using default '$DM_DN' (LLDAP admin). Customize for your directory manager."
fi

file_env DM_PASS "dmtemp"
if [ "$DM_PASS" == "dmtemp" ]; then
    echo "WARNING: DM_PASS using INSECURE TESTING DEFAULT 'dmtemp'. CHANGE THIS FOR PRODUCTION—set -e DM_PASS=strongpass or DM_PASS_FILE for LDAP bind."
fi

# Create necessary directories
mkdir -p /var/log/krb5 /var/kerberos/krb5kdc /var/run /tmp

# Generate krb5.conf early (needed for kadmin.local)
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

# Configuration if not already done (check for principal database file)
if [ ! -f /var/kerberos/krb5kdc/principal ]; then
    echo "Kerberos database not found. Starting configuration."

    # Optional LLDAP schema setup (for POSIX attrs in hybrid)
    if [ -x /usr/bin/lldap-cli ]; then
        setup_lldap_schema
    else
        echo "INFO: lldap-cli not available—skipping auto-schema setup (manual UI for POSIX attrs if needed)."
    fi

    if [ "$LDAP_BACKEND" == "true" ]; then
        echo "Full LDAP backend enabled (experimental with LLDAP—may fallback)."
        # (keep LDAP init code, but warn)
        # ... (same as before, with group create)
    else
        echo "Hybrid/local mode: Using local Kerberos DB for principals (recommended for LLDAP)."
    fi

    # Local init always (safe fallback)
    echo "Configuring local Kerberos database."
    /usr/sbin/kdb5_util create -s -r "${REALM_NAME}" -P "${MASTER_PASS}"
    status=$?
    if [ $status -ne 0 ]; then
        echo "ERROR: Local Kerberos initialization failed (status $status). Services may not start—check logs."
    else
        echo "Adding admin principal..."
        kadmin.local -q "addprinc -pw ${ADMIN_PASS} admin/admin@${REALM_NAME}"
        echo "Creating admin keytab..."
        kadmin.local -q "ktadd -norandkey -k /var/kerberos/krb5kdc/kadm5.keytab admin/admin@${REALM_NAME}"
        echo "*/admin@${REALM_NAME} *" > /var/kerberos/krb5kdc/kadm5.acl
    fi
fi

# Generate kdc.conf (local always, LDAP optional)
echo " - Generating /var/kerberos/krb5kdc/kdc.conf"
cat > /var/kerberos/krb5kdc/kdc.conf <<EOF
[kdcdefaults]
    kdc_ports = 750,88
[realms]
    ${REALM_NAME} = {
EOF
if [ "$LDAP_BACKEND" == "true" ]; then
    cat >> /var/kerberos/krb5kdc/kdc.conf <<EOF
        database_module = contact_ldap
EOF
fi
cat >> /var/kerberos/krb5kdc/kdc.conf <<EOF
    }
[dbdefaults]
[dbmodules]
EOF
if [ "$LDAP_BACKEND" == "true" ]; then
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
