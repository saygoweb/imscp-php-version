#!/bin/sh
# Move each of a customer's vhosts onto a different PHP version and check that
# the running version really changed, one vhost at a time.
#
# What the unit tests cannot cover is whether i-MSCP, pointed at another
# version, actually builds a vhost and a pool that work together: the proxy
# socket in the vhost has to be the socket the pool listens on, and the FPM
# service for that version has to be up and to have been told about the pool.
# This drives the whole path and reads the answer off the running site.
#
# Run inside the box as root:
#   /usr/local/src/imscp-php-version/test/switch-matrix.sh <admin_id> <version>...
#
# e.g. switch-matrix.sh 9 8.1 8.3

set -e

ADMIN_ID=${1:?usage: switch-matrix.sh <admin_id> <version>...}
shift
[ $# -gt 0 ] || { echo "give at least one version to try" >&2; exit 1; }

MYSQL="mysql imscp -N -B"
PROBE=phpver.php

[ "$(id -u)" -eq 0 ] || { echo "$0: must be run as root" >&2; exit 1; }

# Every vhost of the customer, as "type id name" triples, in the same shape the
# plugin keys its rows by.
vhosts() {
    $MYSQL -e "
        SELECT 'dmn', d.domain_id, d.domain_name FROM domain AS d
        WHERE d.domain_admin_id = $ADMIN_ID AND IFNULL(d.url_forward,'no') = 'no'
        UNION ALL
        SELECT 'sub', s.subdomain_id, CONCAT(s.subdomain_name,'.',d.domain_name)
        FROM subdomain AS s JOIN domain AS d USING(domain_id)
        WHERE d.domain_admin_id = $ADMIN_ID AND IFNULL(s.subdomain_url_forward,'no') = 'no'
        UNION ALL
        SELECT 'als', a.alias_id, a.alias_name
        FROM domain_aliasses AS a JOIN domain AS d USING(domain_id)
        WHERE d.domain_admin_id = $ADMIN_ID AND IFNULL(a.url_forward,'no') = 'no'
        UNION ALL
        SELECT 'alssub', sa.subdomain_alias_id,
            CONCAT(sa.subdomain_alias_name,'.',a.alias_name)
        FROM subdomain_alias AS sa
        JOIN domain_aliasses AS a USING(alias_id)
        JOIN domain AS d USING(domain_id)
        WHERE d.domain_admin_id = $ADMIN_ID AND IFNULL(sa.subdomain_alias_url_forward,'no') = 'no'
    "
}

# The probe has to exist under each document root before anything is measured.
seed_probes() {
    vhosts | while read -r type id name; do
        root=$(apache2ctl -S 2>/dev/null | awk -v n="$name" '$0 ~ "namevhost "n" " {print}' >/dev/null; \
            awk '/DocumentRoot/ {gsub(/"/,"",$2); print $2; exit}' \
            "/etc/apache2/sites-available/$name.conf" 2>/dev/null)
        [ -n "$root" ] && [ -d "$root" ] || continue
        printf '<?php echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' > "$root/$PROBE"
        chown --reference="$root" "$root/$PROBE"
    done
}

# The version the site is actually running, cache-busted: a caching plugin in
# front of the vhost would otherwise answer with the previous version's page.
running() {
    curl -s -H "Host: $1" "http://127.0.0.1/$PROBE?cachebust=$$-$(date +%s%N)"
}

apply() {
    type=$1 id=$2 name=$3 version=$4

    $MYSQL -e "
        INSERT INTO php_version
            (admin_id, domain_type, domain_id, domain_name, php_version, applied_version, status)
        VALUES ($ADMIN_ID, '$type', $id, '$name', '$version', '', 'toadd')
        ON DUPLICATE KEY UPDATE php_version = '$version', status = 'tochange';
    "

    case $type in
        dmn)    $MYSQL -e "UPDATE domain SET domain_status='tochange' WHERE domain_id=$id" ;;
        sub)    $MYSQL -e "UPDATE subdomain SET subdomain_status='tochange' WHERE subdomain_id=$id" ;;
        als)    $MYSQL -e "UPDATE domain_aliasses SET alias_status='tochange' WHERE alias_id=$id" ;;
        alssub) $MYSQL -e "UPDATE subdomain_alias SET subdomain_alias_status='tochange' WHERE subdomain_alias_id=$id" ;;
    esac

    perl /var/www/imscp/engine/imscp-rqst-mngr >/dev/null 2>&1 || true

    # An FPM graceful reload finishes on its own schedule, and i-MSCP skips the
    # Apache reload altogether when some unrelated server failed earlier in the
    # same run, so both are waited on rather than assumed.
    sleep 5
    systemctl reload apache2
    sleep 1
}

seed_probes

fail=0
for version in "$@"; do
    vhosts | while read -r type id name; do
        apply "$type" "$id" "$name" "$version"
        got=$(running "$name")

        if [ "$got" = "$version" ]; then
            printf 'ok    %-24s %-6s -> %s\n' "$name" "$version" "$got"
        else
            printf 'FAIL  %-24s %-6s -> %s\n' "$name" "$version" "${got:-no answer}"
            fail=1
        fi
    done
done

# Leave every vhost following the panel default again, so a repeat run starts
# from the same place.
vhosts | while read -r type id name; do
    apply "$type" "$id" "$name" ''
done

exit $fail
