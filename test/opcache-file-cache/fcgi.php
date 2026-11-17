<?php
// Minimal FastCGI client: fcgi.php <socket> <script> <query> ; prints status line.
function rec($t, $id, $c) { return pack('CCnnCx', 1, $t, $id, strlen($c), 0) . $c; }
function nv($k, $v) { $l = fn($s) => strlen($s) < 128 ? chr(strlen($s)) : pack('N', strlen($s) | 0x80000000); return $l($k) . $l($v) . $k . $v; }
[$_, $sock, $script, $query] = $argv;
$s = @stream_socket_client("unix://$sock", $en, $es, 30);
if (!$s) { echo "CONNECT-FAIL $es\n"; exit(1); }
stream_set_timeout($s, 60);
$p = ['SCRIPT_FILENAME' => $script, 'SCRIPT_NAME' => '/' . basename($script), 'REQUEST_METHOD' => 'GET', 'QUERY_STRING' => $query, 'SERVER_PROTOCOL' => 'HTTP/1.1', 'GATEWAY_INTERFACE' => 'CGI/1.1', 'REQUEST_URI' => '/?' . $query, 'SERVER_NAME' => 'x', 'REMOTE_ADDR' => '127.0.0.1'];
$params = ''; foreach ($p as $k => $v) $params .= nv($k, $v);
fwrite($s, rec(1, 1, pack('nCx5', 1, 0)) . rec(4, 1, $params) . rec(4, 1, '') . rec(5, 1, ''));
$out = ''; $end = false;
while (!feof($s)) { $h = fread($s, 8); if (strlen($h) < 8) break; $r = unpack('Cv/Ct/nid/nlen/Cpad', $h); $c = $r['len'] ? fread($s, $r['len']) : ''; if ($r['pad']) fread($s, $r['pad']); if ($r['t'] == 6) $out .= $c; if ($r['t'] == 3) { $end = true; break; } }
echo $end ? "OK " . substr(strip_tags(substr($out, strpos($out, "\r\n\r\n") + 4)), 0, 150) : 'BROKEN (no END_REQUEST)', "\n";
