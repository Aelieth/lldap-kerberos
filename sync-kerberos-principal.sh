#!/bin/bash
# Real sync hook from LLDAP password change
# Args: $1 username, $2 obfuscated_pass (base64 of XOR with ENCODE_KEY)

USERNAME="$1"
OBFUSCATED_PASS="$2"
ENCODE_KEY="${ENCODE_KEY}"  # Shared from env
REALM="${REALM_NAME:-TESTLAB.COM}"  # Flexible—env override or fallback

if [ -z "$ENCODE_KEY" ]; then
    echo "ERROR: ENCODE_KEY missing—cannot deobfuscate"
    exit 1
fi

if [ -z "$OBFUSCATED_PASS" ]; then
    echo "ERROR: No obfuscated password"
    exit 1
fi

# Deobfuscate with Python (easy XOR + base64 decode)
PLAIN_PASS=$(python3 - <<EOF
import sys
import base64

obfuscated = "$OBFUSCATED_PASS"
key = "$ENCODE_KEY".encode('utf-8')
xored = base64.b64decode(obfuscated)

plain = bytes(x ^ key[i % len(key)] for i, x in enumerate(xored))
sys.stdout.buffer.write(plain)
EOF
)

echo "Syncing Kerberos principal $USERNAME@$REALM"

# Update principal (add if new, change if exists)
kadmin.local -q "addprinc -pw '$PLAIN_PASS' $USERNAME@$REALM" || \
kadmin.local -q "cpw -pw '$PLAIN_PASS' $USERNAME@$REALM"

if [ $? -eq 0 ]; then
    echo "Success: Principal $USERNAME@$REALM updated"
else
    echo "Failed to update principal $USERNAME@$REALM"
    exit 1
fi
