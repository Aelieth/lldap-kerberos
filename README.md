# lldap-kerberos: Custom Kerberos KDC for LLDAP Integration

A modern, lightweight Kerberos KDC container designed to work seamlessly with LLDAP for user management while providing reliable Kerberos ticket issuance for SSO.

This project extends the original work from RobinR1/containers-kerberos with:

- AlmaLinux 9-minimal base for excellent multi-arch support (x86_64 and ARM64, including ZimaOS on ZimaBlade).
- Hybrid operation mode: Local Kerberos database for principals (fast and reliable) with automatic extension of LLDAP's schema for POSIX attributes used by SSSD (KDE/GNOME desktop SSO).
- Automated schema extension using the community lldap-cli tool.
- Full environment-variable configurability for easy deployment in test or home-lab environments.
- Graceful fallbacks and detailed warnings for safe debugging.

The container is intended to sit between LLDAP (user directory) and applications like Keycloak, Nextcloud, Jellyfin, or desktop environments requiring Kerberos tickets.

## Features

- Local Kerberos database by default (recommended for LLDAP due to schema limitations).
- Optional full LDAP backend (experimental with LLDAP; works well with OpenLDAP).
- Automatic addition of required custom attributes to LLDAP for POSIX/SSSD compatibility.
- Flexible DN configuration – defaults optimized for LLDAP, fully overrideable for other LDAP servers.
- Persistent volume for Kerberos data.
- Healthcheck support.
- Multi-arch builds (amd64/arm64).

## Credits

- Base container and LDAP bootstrap logic: RobinR1/containers-kerberos
- LLDAP server: lldap/lldap
- lldap-cli tool: Zepmann/lldap-cli
- Keycloak integration inspiration: keycloak/keycloak

Thank you to these projects for making secure, open-source identity management possible.

## Usage

Build the image locally (recommended during development):

docker build -t lldap-kerberos:latest .

Run the container (basic example – replace environment variables as needed):

docker run -d --name kerberos-test \
  -p 88:88/tcp -p 88:88/udp -p 749:749/tcp \
  -v kerberos-data:/var/kerberos/krb5kdc \
  -e REALM_NAME=TESTLAB.COM \
  -e MASTER_PASS=strong-master-password \
  -e ADMIN_PASS=strong-admin-password \
  lldap-kerberos:latest

For production-like setups, use strong passwords and consider Docker secrets or _FILE variants.

### Persistent Volume

- /var/kerberos/krb5kdc – Stores Kerberos database, configuration, and credentials. Mount a named volume for persistence.

### Exposed Ports

- 88/tcp and 88/udp – Kerberos KDC
- 749/tcp – Kerberos admin server (kadmin)

### Healthcheck

The container supports healthchecks:

docker run ... --health-cmd "/usr/bin/start.sh healthcheck" ...

## Environment Variables

All variables are optional unless noted. Testing defaults are intentionally insecure and will generate warnings – change them for any real use.

| Variable         | Description                                                                | Default / Example                     | Notes / Warning                          |
|------------------|----------------------------------------------------------------------------|---------------------------------------|------------------------------------------|
| REALM_NAME       | Kerberos realm name                                                        | EXAMPLE.COM                           | Warning if default used                  |
| MASTER_PASS      | Master password for Kerberos database                                      | mastertemp (insecure)                 | **CHANGE FOR PRODUCTION**                |
| BASE_DN          | LDAP base DN                                                               | dc=example,dc=com                     | Warning if default used                  |
| KDC_DN           | Full DN for KDC service account (LLDAP-friendly default)                   | uid=krbkdc,ou=people,$BASE_DN         | Customize for your schema                |
| KDC_PASS         | Password for KDC service account                                           | kdctemp (insecure)                    | **CHANGE FOR PRODUCTION**                |
| ADMIN_DN         | Full DN for admin principal account                                        | uid=krbadm,ou=people,$BASE_DN         | Customize for your schema                |
| ADMIN_PASS       | Password for admin principal                                               | admintemp (insecure)                  | **CHANGE FOR PRODUCTION**                |
| CONTAINER_DN     | Kerberos container/subtree DN                                              | cn=kerberos,ou=groups,$BASE_DN (LLDAP group) | Override for OpenLDAP OU style (may require manual creation) |
| DM_DN            | Directory manager/bind DN for LDAP operations                              | uid=admin,ou=people,$BASE_DN          | LLDAP admin default                      |
| DM_PASS          | Password for directory manager                                             | dmtemp (insecure)                     | **CHANGE FOR PRODUCTION**                |
| LDAP_HOST        | Hostname/IP of LDAP server (enables LDAP mode if set)                      | (none – local mode)                   | e.g., lldap-test or external IP          |
| LDAP_SCHEME      | LDAP scheme (ldap or ldaps)                                                | ldap                                  |                                          |
| LDAP_PORT        | LDAP port                                                                  | 3890 (test default)                   | Override for production (636 for ldaps)  |
| LLDAP_UI_PORT    | LLDAP web UI port (for schema tool)                                        | 17170                                 |                                          |
| DESTROY_AND_RECREATE | If true, destroy existing realm on LDAP before recreating             | false                                 | Destructive – use carefully              |
| DEBUG_MODE       | If true, enable script trace output                                        | false                                 | Useful for troubleshooting               |

Secrets can also be provided via _FILE variants (e.g., MASTER_PASS_FILE=/run/secrets/master_pass).

## Operation Modes

### Hybrid/Local Mode (Default & Recommended for LLDAP)

- Kerberos principals and database stored locally (fast, reliable, no LLDAP schema limitations).
- LLDAP extended with custom POSIX attributes (uidNumber, gidNumber, homeDirectory, loginshell) for SSSD compatibility.
- Desktop SSO: SSSD authenticates users against LLDAP and obtains Kerberos tickets from this container.

### Full LDAP Backend (Experimental with LLDAP)

- Set LDAP_HOST (and optionally LDAP_BACKEND=true in future versions).
- Principals stored in LLDAP subtree (group style).
- Works best with OpenLDAP; LLDAP has schema limitations.

## First Run / Bootstrap

On first run (no existing data volume), the container will:

- Extend LLDAP schema with required custom attributes (if lldap-cli bundled).
- Configure local Kerberos database.
- Create admin principal and keytab.

All configuration is saved to the persistent volume.

## Contributing & Development

This repository is under active development. Contributions, issues, and feature requests are welcome!

Git commands reminder:

- Stage changes: git add <file>
- Commit: git commit -m "Your message"
- Push: git push origin master

Happy authenticating!
