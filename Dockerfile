FROM almalinux:9-minimal

LABEL maintainer="Aelieth <shaiaelieth@gmail.com>"
LABEL description="Custom Kerberos container for LLDAP and Keycloak integration"

# Update system and install Kerberos/LDAP packages
RUN microdnf update -y && \
    microdnf install -y krb5-server krb5-libs krb5-workstation krb5-server-ldap openldap-clients cyrus-sasl-gssapi && \
    microdnf clean all

# Copy and set up start script
COPY start.sh /usr/bin/
RUN chmod +x /usr/bin/start.sh

# Expose Kerberos ports
EXPOSE 88/tcp 88/udp 749/tcp

# Persistent volume for Kerberos data
VOLUME /var/kerberos/krb5kdc

# Entry point to run the script
ENTRYPOINT ["/usr/bin/start.sh"]
