#!/bin/bash
#
# Reads test/sse-probe.php through a vhost and checks that every event arrives
# as it is sent -- the first within a second, and none bunched up behind a
# buffer -- for the whole of a long stream.
#
#   test/sse-probe.sh <url> [seconds]
#
#   test/sse-probe.sh https://qa.example.com/sse-probe.php 180
#   test/sse-probe.sh 'http://localhost:8080/sse-probe.php' 30 -H 'Host: cust1.test'
#
# Anything after the seconds is passed to curl. The probe sends an event every
# 500 ms, so a stream of N seconds should deliver 2N events. Exits non-zero, and
# says FAIL, if the first event takes over a second, if any gap between two
# arrivals is over a second, or if fewer events arrive than were sent.

set -u

url=${1:?usage: $0 <url> [seconds] [curl options...]}
seconds=${2:-180}
shift; [ $# -gt 0 ] && shift

interval=500
events=$(( seconds * 1000 / interval ))
case $url in
    *\?*) url="$url&n=$events&interval=$interval" ;;
    *)    url="$url?n=$events&interval=$interval" ;;
esac

echo "Probing $url for ${seconds}s ($events events, one every ${interval} ms)"

start=$(date +%s.%N)

curl -N -s --max-time $(( seconds + 30 )) "$@" "$url" \
    | while IFS= read -r line; do
        case $line in
            data:*) printf '%s %s\n' "$(date +%s.%N)" "${line#data: }" ;;
        esac
    done \
    | awk -v start="$start" -v expected="$events" '
        function field(name,    m) {
            if (match($0, "\"" name "\":(\"[^\"]*\"|[^,}]*)")) {
                m = substr($0, RSTART + length(name) + 3, RLENGTH - length(name) - 3)
                gsub(/"/, "", m)
                return m
            }
            return ""
        }
        $2 == "{}" { next }   # the closing "done" event
        {
            n++
            gap = (n == 1) ? $1 - start : $1 - last
            if (n == 1) first = gap
            if (gap > maxgap) { maxgap = gap; maxat = n }
            if (n > 1 && gap > 1) late++
            last = $1
            if (n == 1) {
                sapi = field("sapi"); ob = field("output_buffering")
                met = field("max_execution_time"); zlib = field("zlib")
                rtt = field("request_terminate_timeout")
            }
            if (n % 20 == 0) printf "  %4d events, %6.1fs in, last gap %.3fs\n", n, $1 - start, gap
        }
        END {
            printf "\nSAPI %s; output_buffering=%s; zlib.output_compression=%s; max_execution_time=%s",
                sapi, ob == "" ? "(off)" : ob, zlib == "" ? "(off)" : zlib, met
            if (rtt != "") printf "; request_terminate_timeout=%s", rtt
            printf "\n"
            printf "events %d of %d; first after %.3fs; longest gap %.3fs (before event %d); gaps over 1s: %d\n",
                n, expected, first, maxgap, maxat, late

            fail = 0
            if (n == 0)        { print "FAIL: no events arrived"; exit 1 }
            if (first > 1)     { print "FAIL: the first event took more than 1s"; fail = 1 }
            if (late > 0)      { print "FAIL: events arrived bunched together (a gap over 1s)"; fail = 1 }
            if (n < expected)  { print "FAIL: fewer events arrived than were sent"; fail = 1 }
            if (!fail) print "PASS"
            exit fail
        }
    '
