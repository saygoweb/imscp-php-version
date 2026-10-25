<?php
/**
 * i-MSCP SGW_PhpVersion plugin
 * Copyright (C) 2026 Cambell Prince <cambell.prince@gmail.com>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */

/*
 * A Server-Sent Events stream for checking that a vhost passes each event on
 * as PHP flushes it, rather than holding it back somewhere between PHP-FPM and
 * the client. Development only: copy it into a vhost's document root, and read
 * it with test/sse-probe.sh.
 *
 *   ?n=360       events to send (default 360, i.e. three minutes)
 *   ?interval=500  milliseconds between them
 *
 * Each event reports what the request actually ran with, so the probe can show
 * the pool's settings without a second request. A client that goes away is
 * noticed at the next write and logged to sse-probe.log beside this script.
 */

header('Content-Type: text/event-stream');
header('Cache-Control: no-cache');
header('X-Accel-Buffering: no');

if (function_exists('apache_setenv')) {
    apache_setenv('no-gzip', '1');
}

while (ob_get_level()) {
    ob_end_flush();
}

// No set_time_limit(): i-MSCP locks max_execution_time with php_admin_value, and
// the probe should run under exactly what an application in the pool gets. On
// Linux that limit counts CPU time, which a stream spends almost none of.
ignore_user_abort(true);

$events = isset($_GET['n']) ? max(1, (int)$_GET['n']) : 360;
$interval = isset($_GET['interval']) ? max(10, (int)$_GET['interval']) : 500;

// request_terminate_timeout is FPM's, not an ini setting: PHP cannot read it,
// so it is only reported when the pool passes it in, e.g. with
// env[REQUEST_TERMINATE_TIMEOUT] = 300s.
$terminate = getenv('REQUEST_TERMINATE_TIMEOUT');

// Padding past any 4096-byte buffer would hide exactly the buffering this is
// here to find, so there is none: each event is a few hundred bytes.
echo "retry: 60000\n\n";
flush();

for ($seq = 1; $seq <= $events; $seq++) {
    $data = array(
        'seq'                => $seq,
        'sent'               => microtime(true),
        'sapi'               => php_sapi_name(),
        'output_buffering'   => ini_get('output_buffering'),
        'max_execution_time' => ini_get('max_execution_time'),
        'zlib'               => ini_get('zlib.output_compression')
    );

    if (false !== $terminate) {
        $data['request_terminate_timeout'] = $terminate;
    }

    echo 'data: ' . json_encode($data) . "\n\n";
    flush();

    if (connection_aborted()) {
        // Into a file beside this script as well as the usual error log: the
        // usual one is FastCGI's stderr, and Apache has stopped reading that
        // by the time the client has gone.
        $message = sprintf(
            "%s sse-probe: client went away after event %d of %d\n", date('c'), $seq, $events
        );
        error_log($message);
        @file_put_contents(__DIR__ . '/sse-probe.log', $message, FILE_APPEND);
        exit;
    }

    if ($seq < $events) {
        usleep($interval * 1000);
    }
}

echo "event: done\ndata: {}\n\n";
flush();
