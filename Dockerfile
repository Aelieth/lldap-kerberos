FROM almalinux:9-minimal

LABEL maintainer="Aelieth <shaiaelieth@gmail.com>"
LABEL description="Custom Kerberos container for LLDAP and Keycloak integration"

# Update system and install Kerberos/LDAP packages + jq
RUN microdnf update -y && \
    microdnf install -y krb5-server krb5-libs krb5-workstation krb5-server-ldap openldap-clients cyrus-sasl-gssapi procps-ng jq python3 && \
    microdnf clean all  # python3 for deobfuscate in script

# Copy scripts
COPY start.sh /usr/bin/start.sh
COPY sync-kerberos-principal.sh /usr/bin/sync-kerberos-principal.sh

# Make executable
RUN chmod +x /usr/bin/start.sh /usr/bin/sync-kerberos-principal.sh

# Expose Kerberos ports
EXPOSE 88/tcp 88/udp 749/tcp

# Persistent volume for Kerberos data
VOLUME /var/kerberos/krb5kdc

# Entry point
ENTRYPOINT ["/usr/bin/start.sh"]
