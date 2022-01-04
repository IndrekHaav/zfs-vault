#!/bin/bash
url="$VAULT_ADDR/v1/auth/approle/login"
json=$(/bin/jq -n --arg r "$VAULT_ROLE_ID" --arg s "$VAULT_SECRET_ID" '{role_id:$r,secret_id:$s}')
token=$(/bin/curl -s -X POST -H Content-type:application/json -d "$json" "$url" | /bin/jq -r .auth.client_token)
if [ -z "$token" ]; then
    echo "Error fetching Vault token." | logger
    exit 1
fi

for dataset in $(/sbin/zfs list -Ho name,encryptionroot | awk -F "\t" '{ if ($2 != "-") { print $2 }}' | uniq); do
    keylocation=$(/sbin/zfs get -Ho value keylocation "$dataset")
    keystatus=$(/sbin/zfs get -Ho value keystatus "$dataset")
    if [ "$keylocation" = "prompt" ] && [ "$keystatus" = "unavailable" ]; then
        echo "Loading key for ZFS dataset $dataset" | logger
        url="$VAULT_ADDR/v1/secret/data/zfs/$(hostname)/$dataset"
        key=$(/bin/curl -s -H "X-Vault-Token:$token" "$url" | /bin/jq -r .data.data.key)
        if [ -n "$key" ]; then
            echo "$key" | /sbin/zfs load-key "$dataset"
        fi
    fi
done
