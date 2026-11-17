#!/bin/bash
#
# Reproduce the PHP 7.4/8.0 opcache file cache bug deterministically, as root in
# the CI image (development only):
#
#   docker run --rm --entrypoint bash -v "$PWD":/plugin ghcr.io/saygoweb/imscp-ci:bookworm \
#       -c 'for v in 7.4 8.0 8.1 8.3; do /plugin/test/opcache-file-cache/repro.sh $v; done'
#
#   repro.sh <php version> [file cache: yes|no]     (FCO=1 sets file_cache_only)
#
# Worker B loads x.php, too big for the shared memory, from the file cache into
# its own memory and calls its functions; meanwhile worker A stores the small
# y.php in shared memory. On 7.4 and 8.0 y()'s static variables then come from
# one of x.php's functions (CORRUPT) or the worker segfaults. See "Why not PHP
# 7.4 and 8.0" in the README.
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p /var/cache/det-master; chmod 700 /var/cache/det-master
v=$1; FCON=${2:-yes}; D=/srv/det-$v; FC=/var/cache/det-$v
rm -rf $D $FC; mkdir -p $D $FC
php8.3 -r '
$x = "<?php\n";
for ($i = 0; $i < 12000; $i++) $x .= "function x$i() { static \$sig = \"x$i\", \$a = 1, \$b = [1, 2, 3]; if (\$sig !== __FUNCTION__) echo \"CORRUPT \$sig in \", __FUNCTION__, \"\\n\"; return \$a + count(\$b); }\n";
file_put_contents("'$D'/x.php", $x);
file_put_contents("'$D'/y.php", "<?php\nfunction y() { static \$sig = \"y\"; static \$p = 0, \$q = 0, \$r = 0, \$s = 0, \$t = 0, \$u = 0, \$w = 0; if (\$sig !== __FUNCTION__) echo \"CORRUPT \$sig in y\\n\"; return 1; }\nfunction y2() { static \$sig = \"y2\"; if (\$sig !== __FUNCTION__) echo \"CORRUPT \$sig in y2\\n\"; return 1; }\n");
file_put_contents("'$D'/b.php", "<?php\nrequire \"x.php\"; \$t = 0; for (\$i = 0; \$i < 12000; \$i++) \$t += (\"x\$i\")(); usleep(1500000); require \"y.php\"; \$t += y() + y2(); echo \"B ok \$t\\n\";\n");
file_put_contents("'$D'/a.php", "<?php\nusleep(500000); require \"y.php\"; echo \"A ok \", y() + y2(), \"\\n\";\n");
file_put_contents("'$D'/prime.php", "<?php\nrequire \"x.php\"; echo \"primed\\n\";\n");
'
touch -d '-1 min' $D/*.php; chown -R www-data: $D $FC; chmod 700 $FC
cat > /tmp/det-$v.conf <<CONF
[global]
error_log = /tmp/det-$v.log
[app]
user = www-data
group = www-data
listen = /tmp/det-$v.sock
pm = static
pm.max_children = 2
catch_workers_output = yes
php_admin_value[opcache.file_cache] = $FC
CONF
[ $FCON = yes ] || sed -i "/opcache.file_cache/d" /tmp/det-$v.conf
: > /tmp/det-$v.log
run() { php-fpm$v -n -y /tmp/det-$v.conf -d zend_extension=opcache.so ${FCO:+-d opcache.file_cache_only=$FCO -d opcache.file_cache=/var/cache/det-master} -d opcache.memory_consumption=$1 -d opcache.interned_strings_buffer=4 -d opcache.file_update_protection=0 -d opcache.log_verbosity_level=2; sleep 1; }
# 1: prime the file cache with x.php (fits in a big SHM).
run 512; php8.3 $HERE/fcgi.php /tmp/det-$v.sock $D/prime.php ""; pkill -f "php-fpm: master"; sleep 1
rm -f $(find $FC -name 'y.php.bin' -o -name 'a.php.bin' -o -name 'b.php.bin')
echo "x.bin: $(find $FC -name x.php.bin -printf '%s bytes')"
# 2: small SHM: x.php no longer fits (but plenty else does), so B loads it from
# the file cache into process memory while A stores y.php into SHM.
run 16
for n in 1 2 3; do
  php8.3 $HERE/fcgi.php /tmp/det-$v.sock $D/b.php "" & sleep 0.2; php8.3 $HERE/fcgi.php /tmp/det-$v.sock $D/a.php "" & wait
  pkill -f "php-fpm: master"; sleep 1; run 16
done
pkill -f "php-fpm: master"; sleep 1
echo "== php$v $(php$v -r "echo PHP_VERSION;") file_cache=$FCON file_cache_only=${FCO:-0} segfaults: $(grep -c SIGSEGV /tmp/det-$v.log)"
