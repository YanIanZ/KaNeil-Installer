#!/bin/bash
# KaNeil Fix - Vessel create timeout + schedules not running
# Usage: sudo bash fix-vessel.sh
set -e

PANEL_DIR="${PANEL_DIR:-/var/www/kaneil}"
GITHUB_URL="${GITHUB_URL:-https://raw.githubusercontent.com/YanIanZ/KaNeil-Installer/main}"

if [ "$EUID" -ne 0 ]; then
  echo "Run as root: sudo bash fix-vessel.sh"
  exit 1
fi

if [ ! -d "$PANEL_DIR" ]; then
  echo "Panel dir not found: $PANEL_DIR"
  exit 1
fi

WEB_USER="www-data"
if ! id -u www-data >/dev/null 2>&1; then
  WEB_USER="nginx"
fi

echo "=== 1. Install/repair kaneil queue worker unit ==="
NEED_UNIT=false
if [ ! -f /etc/systemd/system/kaneil.service ]; then
  NEED_UNIT=true
elif ! grep -q "queue:work" /etc/systemd/system/kaneil.service; then
  NEED_UNIT=true
fi

if [ "$NEED_UNIT" = true ]; then
  echo "Fetching kaneil.service..."
  curl -fSL -o /etc/systemd/system/kaneil.service "$GITHUB_URL"/configs/kaneil.service
  sed -i "s@<user>@$WEB_USER@g" /etc/systemd/system/kaneil.service
fi

systemctl daemon-reload
systemctl enable kaneil.service 2>/dev/null || true
systemctl restart kaneil 2>/dev/null || systemctl start kaneil
sleep 2

if systemctl is-active --quiet kaneil; then
  echo "kaneil queue worker: ACTIVE"
else
  echo "WARNING: kaneil queue worker NOT active. journalctl -u kaneil -n 50"
fi

echo ""
echo "=== 2. Ensure GUZZLE_TIMEOUT in .env ==="
if [ -f "$PANEL_DIR/.env" ]; then
  sed -i '/^GUZZLE_TIMEOUT=/d;/^GUZZLE_CONNECT_TIMEOUT=/d' "$PANEL_DIR/.env"
  echo "GUZZLE_TIMEOUT=60" >> "$PANEL_DIR/.env"
  echo "GUZZLE_CONNECT_TIMEOUT=10" >> "$PANEL_DIR/.env"
  echo ".env updated"
else
  echo "WARNING: $PANEL_DIR/.env not found"
fi

echo ""
echo "=== 3. Install cronjob (schedule:run) ==="
if crontab -l 2>/dev/null | grep -q "kaneil/artisan schedule:run"; then
  echo "Cronjob already present (root)."
else
  (crontab -l 2>/dev/null; echo "* * * * * php $PANEL_DIR/artisan schedule:run >> /dev/null 2>&1") | crontab -
  echo "Cronjob installed (root)."
fi

echo ""
echo "=== 3b. Hot-patch ServerDetailsController (eggConfigurationService -> mapConfigurationService) ==="
CTRL="$PANEL_DIR/app/Http/Controllers/Api/Remote/Servers/ServerDetailsController.php"
if [ -f "$CTRL" ] && grep -q "eggConfigurationService" "$CTRL"; then
  sed -i 's/eggConfigurationService/mapConfigurationService/g' "$CTRL"
  echo "Patched $CTRL"
else
  echo "Already patched or file missing."
fi

echo ""
echo "=== 4. Clear + rebuild panel config cache ==="
cd "$PANEL_DIR"
sudo -u "$WEB_USER" php artisan optimize:clear 2>&1 | tail -3 || php artisan optimize:clear 2>&1 | tail -3
sudo -u "$WEB_USER" php artisan config:cache 2>&1 | tail -3 || php artisan config:cache 2>&1 | tail -3
sudo -u "$WEB_USER" php artisan route:cache 2>&1 | tail -3 || true
sudo -u "$WEB_USER" php artisan view:cache 2>&1 | tail -3 || true

echo ""
echo "=== 5. Restart PHP-FPM ==="
for v in php8.5-fpm php8.4-fpm php8.3-fpm php8.2-fpm php-fpm; do
  if systemctl is-active --quiet "$v" 2>/dev/null; then
    systemctl restart "$v"
    echo "Restarted $v"
    break
  fi
done

echo ""
echo "=== 6. Reload nginx ==="
systemctl reload nginx 2>/dev/null || true

echo ""
echo "=== 6a0. Rewrite stale ghcr.io/kaneil-dev/* image URIs (registry doesn't exist) ==="
cd "$PANEL_DIR" && sudo -u "$WEB_USER" HOME=/tmp php artisan tinker --execute='
$mapFixed = 0; $svrFixed = 0;
$rewrite = function(string $u): string { return str_replace("ghcr.io/kaneil-dev/", "ghcr.io/parkervcp/", $u); };
foreach (\App\Models\Map::all() as $m) {
  $changed = false;
  $imgs = $m->docker_images ?? [];
  if (is_array($imgs)) {
    $new = [];
    foreach ($imgs as $k => $v) {
      $nk = is_string($k) ? $rewrite($k) : $k;
      $nv = is_string($v) ? $rewrite($v) : $v;
      $new[$nk] = $nv;
      if ($nk !== $k || $nv !== $v) $changed = true;
    }
    if ($changed) { $m->docker_images = $new; }
  }
  if (is_string($m->script_container) && str_contains($m->script_container, "kaneil-dev")) {
    $m->script_container = $rewrite($m->script_container); $changed = true;
  }
  if ($changed) { $m->save(); $mapFixed++; }
}
foreach (\App\Models\Server::all() as $s) {
  if (is_string($s->image) && str_contains($s->image, "kaneil-dev")) {
    $s->image = $rewrite($s->image); $s->save(); $svrFixed++;
  }
}
echo "Maps rewritten: $mapFixed, Vessels rewritten: $svrFixed\n";' 2>&1 | tail -5

echo ""
echo "=== 6a. Repair maps with reversed/invalid docker_images ==="
cd "$PANEL_DIR" && sudo -u "$WEB_USER" HOME=/tmp php artisan tinker --execute='
$bad = 0; $fixed = 0;
foreach (\App\Models\Map::all() as $m) {
  $imgs = $m->docker_images ?? [];
  if (!is_array($imgs) || empty($imgs)) continue;
  $new = [];
  foreach ($imgs as $k => $v) {
    $label = (string) $k; $uri = is_string($v) ? $v : "";
    // Detect reversed orientation: key looks like URI, value is human label
    $keyLooksUri = (str_contains($label, "/") || str_contains($label, ":")) && !preg_match("/\s/", $label) && !preg_match("/[A-Z][a-z]+ ?\d/", $label);
    $valLooksLabel = preg_match("/\s/", $uri) || preg_match("/^[A-Z][a-z]+ ?\d/", $uri);
    if ($keyLooksUri && $valLooksLabel) { $new[$uri] = $label; continue; }
    // Skip entries whose URI is plainly invalid
    if ($uri === "" || preg_match("/\s/", $uri) || preg_match("/[A-Z]/", explode(":", $uri, 2)[0] ?? "")) continue;
    $new[$label] = $uri;
  }
  if (empty($new)) $new = ["Java 21" => "ghcr.io/kaneil-dev/yolks:java_21"];
  if ($new !== $imgs) { $m->docker_images = $new; $m->save(); $fixed++; }
}
echo "Maps repaired: $fixed\n";' 2>&1 | tail -10

echo ""
echo "=== 6a2. Repair vessels with invalid image (e.g. \"Java 21\" literal) ==="
cd "$PANEL_DIR" && sudo -u "$WEB_USER" HOME=/tmp php artisan tinker --execute='
$fixed = 0;
foreach (\App\Models\Server::with("map")->get() as $s) {
  $img = (string) $s->image;
  $invalid = $img === "" || preg_match("/\s/", $img) || preg_match("/[A-Z]/", explode(":", $img, 2)[0] ?? "");
  if (!$invalid) continue;
  $available = $s->map?->docker_images ?? [];
  if (empty($available)) continue;
  $first = null;
  foreach ($available as $label => $uri) {
    if (is_string($uri) && !preg_match("/\s/", $uri) && !preg_match("/[A-Z]/", explode(":", $uri, 2)[0] ?? "")) { $first = $uri; break; }
  }
  if ($first) { $s->image = $first; $s->save(); $fixed++; echo "Vessel $s->id: image \"$img\" -> \"$first\"\n"; }
}
echo "Vessels repaired: $fixed\n";' 2>&1 | tail -20

echo ""
echo "=== 6a2b. Rename numeric-key startup_commands to {Default: ...} ==="
cd "$PANEL_DIR" && sudo -u "$WEB_USER" HOME=/tmp php artisan tinker --execute='
$fixed = 0;
foreach (\App\Models\Map::all() as $m) {
  $cmds = $m->startup_commands;
  if (!is_array($cmds) || empty($cmds)) continue;
  // already named (string keys) -> skip
  $hasStringKey = false;
  foreach (array_keys($cmds) as $k) { if (!is_int($k)) { $hasStringKey = true; break; } }
  if ($hasStringKey) continue;
  $new = [];
  foreach (array_values($cmds) as $i => $v) {
    $new[$i === 0 ? "Default" : ("Command " . ($i + 1))] = $v;
  }
  $m->startup_commands = $new;
  $m->save();
  $fixed++;
}
echo "Maps relabeled: $fixed\n";' 2>&1 | tail -5

echo ""
echo "=== 6a3. Backfill missing variables on existing maps from egg JSON ==="
for EGGS_DIR in "$PANEL_DIR/storage/eggs/game-wings" "$PANEL_DIR/storage/eggs/application-wings" "$PANEL_DIR/storage/eggs/game-eggs" "$PANEL_DIR/storage/eggs/application-eggs"; do
  [ -d "$EGGS_DIR" ] || continue
  echo "Scanning $EGGS_DIR"
  cd "$PANEL_DIR" && sudo -u "$WEB_USER" HOME=/tmp EGGS_DIR="$EGGS_DIR" php artisan tinker --execute='
$dir = getenv("EGGS_DIR");
$rii = new \RecursiveIteratorIterator(new \RecursiveDirectoryIterator($dir, \RecursiveDirectoryIterator::SKIP_DOTS));
$added = 0; $maps = 0;
foreach ($rii as $f) {
  if (!$f->isFile() || $f->getExtension() !== "json" || !str_starts_with($f->getFilename(), "egg-")) continue;
  $data = json_decode(file_get_contents($f->getPathname()), true);
  if (!$data || empty($data["name"])) continue;
  $map = \App\Models\Map::where("name", $data["name"])->first();
  if (!$map) continue;
  $vars = $data["variables"] ?? [];
  if (!is_array($vars) || empty($vars)) continue;
  $maps++;
  foreach ($vars as $sort => $var) {
    if (!is_array($var)) continue;
    $env = $var["env_variable"] ?? null;
    if (!$env || in_array($env, \App\Models\MapVariable::RESERVED_ENV_NAMES)) continue;
    if (\App\Models\MapVariable::where("map_id", $map->id)->where("env_variable", $env)->exists()) continue;
    $rules = $var["rules"] ?? "";
    if (is_string($rules)) $rules = array_values(array_filter(array_map("trim", explode("|", $rules))));
    if (!is_array($rules) || empty($rules)) $rules = ["nullable", "string"];
    try {
      \App\Models\MapVariable::create([
        "map_id" => $map->id,
        "sort" => $sort,
        "name" => (string)($var["name"] ?? $env),
        "description" => (string)($var["description"] ?? ""),
        "env_variable" => $env,
        "default_value" => (string)($var["default_value"] ?? ""),
        "user_viewable" => (bool)($var["user_viewable"] ?? true),
        "user_editable" => (bool)($var["user_editable"] ?? true),
        "rules" => $rules,
      ]);
      $added++;
    } catch (\Throwable $e) {}
  }
}
echo "Maps touched: $maps, vars added: $added\n";' 2>&1 | tail -5
done

echo ""
echo "=== 6a4. Backfill server variables for existing vessels (defaults from map) ==="
cd "$PANEL_DIR" && sudo -u "$WEB_USER" HOME=/tmp php artisan tinker --execute='
$added = 0;
foreach (\App\Models\Server::with("map.variables")->get() as $s) {
  if (!$s->map) continue;
  foreach ($s->map->variables as $mv) {
    $exists = \App\Models\ServerVariable::where("server_id", $s->id)->where("variable_id", $mv->id)->exists();
    if ($exists) continue;
    \App\Models\ServerVariable::create([
      "server_id" => $s->id,
      "variable_id" => $mv->id,
      "variable_value" => (string) $mv->default_value,
    ]);
    $added++;
  }
}
echo "Server variables added: $added\n";' 2>&1 | tail -5

echo ""
echo "=== 6b. Reinstall stuck vessels (status=installing/install_failed) ==="
cd "$PANEL_DIR" && sudo -u "$WEB_USER" HOME=/tmp php artisan tinker --execute='
$svc = app(\App\Services\Servers\ReinstallServerService::class);
$stuck = \App\Models\Server::whereIn("status", ["installing","install_failed"])->get();
if ($stuck->isEmpty()) { echo "No stuck vessels.\n"; exit; }
foreach ($stuck as $s) {
  try {
    echo "Reinstalling vessel id=$s->id uuid=$s->uuid\n";
    $svc->handle($s);
    echo "  triggered.\n";
  } catch (\Throwable $e) {
    echo "  FAILED: ".$e->getMessage()."\n";
  }
}' 2>&1 | tail -40

echo ""
echo "=== 6c. Restart ship to force config refetch (clears cached vessel images) ==="
if systemctl is-active --quiet ship; then
  systemctl restart ship
  sleep 3
  if systemctl is-active --quiet ship; then
    echo "ship restarted."
  else
    echo "WARNING: ship failed to restart - journalctl -u ship -n 50"
  fi
fi

echo ""
echo "=== 7. Verify ==="
TIMEOUT_LOADED=$(cd "$PANEL_DIR" && sudo -u "$WEB_USER" php artisan tinker --execute='echo config("panel.guzzle.timeout");' 2>/dev/null | tail -1)
echo "Effective GUZZLE_TIMEOUT: ${TIMEOUT_LOADED:-unknown}"
echo ".env GUZZLE_TIMEOUT line: $(grep ^GUZZLE_TIMEOUT= "$PANEL_DIR/.env" || echo MISSING)"

echo "kaneil:    $(systemctl is-active kaneil 2>/dev/null)"
echo "ship:      $(systemctl is-active ship 2>/dev/null)"
echo "nginx:     $(systemctl is-active nginx 2>/dev/null)"
echo "redis:     $(systemctl is-active redis-server 2>/dev/null || systemctl is-active redis 2>/dev/null)"
echo "Cron:      $(crontab -l 2>/dev/null | grep -c 'schedule:run') entry/entries"

echo ""
echo "DONE. Retry vessel create now."
echo "If still timeout: journalctl -u kaneil -u ship -f"
