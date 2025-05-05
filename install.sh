#!/usr/bin/env bash
set -euo pipefail

# 1) Must be run as root
if [[ "$(id -u)" -ne 0 ]]; then
  echo "❗ Please run as root or via sudo."
  exit 1
fi

# 2) Prompt for configuration
read -p "Portal domain or IP (e.g. portal.example.com): " SERVER_NAME
read -p "UDM/UniFi OS Host (IP or hostname, e.g. 192.168.1.1): " UNIFI_HOST
read -p "UDM/UniFi OS Port [443]: " UNIFI_PORT
UNIFI_PORT=${UNIFI_PORT:-443}
read -p "UniFi Site [default]: " UNIFI_SITE
UNIFI_SITE=${UNIFI_SITE:-default}
read -p "UniFi API username: " UNIFI_USER
read -s -p "UniFi API password: " UNIFI_PASS; echo
read -p "Voucher duration (minutes) [60]: " VOUCHER_DURATION
VOUCHER_DURATION=${VOUCHER_DURATION:-60}

# 3) Install PHP & Apache
echo "📦 Installing system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y apache2 php php-cli php-curl libapache2-mod-php curl

# 4) Enable Apache rewrite & headers
echo "🔧 Enabling Apache modules..."
a2enmod rewrite headers

# 5) Create project structure
PROJECT_DIR="/var/www/html/captive-portal"
echo "📁 Creating project directory at $PROJECT_DIR"
mkdir -p "$PROJECT_DIR"/backend/php/frontend/{css,img}
chown -R www-data:www-data "$PROJECT_DIR"
chmod 750 "$PROJECT_DIR"

# 6) Write config.php
cat > "$PROJECT_DIR/backend/php/config.php" <<EOF
<?php
return [
  'host'     => '$UNIFI_HOST',
  'port'     => $UNIFI_PORT,
  'site'     => '$UNIFI_SITE',
  'user'     => '$UNIFI_USER',
  'pass'     => '$UNIFI_PASS',
  'duration' => $VOUCHER_DURATION,
  'verify_ssl' => false,
];
EOF

# 7) Write index.php (no external libs)
cat > "$PROJECT_DIR/backend/php/index.php" <<'EOF'
<?php
ini_set('display_errors',1);
ini_set('display_startup_errors',1);
error_reporting(E_ALL);

// load config
$config = require __DIR__ . '/config.php';

// helper: POST JSON via cURL
function curl_json(string $url, array $data, string $cookieFile, bool $verifySsl): void {
    $ch = curl_init($url);
    curl_setopt($ch, CURLOPT_POST, true);
    curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($data));
    curl_setopt($ch, CURLOPT_HTTPHEADER, ['Content-Type: application/json']);
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_HEADER, false);
    curl_setopt($ch, CURLOPT_SSL_VERIFYPEER, $verifySsl);
    curl_setopt($ch, CURLOPT_COOKIEJAR, $cookieFile);
    curl_setopt($ch, CURLOPT_COOKIEFILE, $cookieFile);
    $resp = curl_exec($ch);
    if (curl_errno($ch)) {
        error_log('cURL Error: ' . curl_error($ch));
    }
    curl_close($ch);
}

// build UDM proxy endpoints
$baseUrl      = "https://{$config['host']}:{$config['port']}/proxy/network";
$loginUrl     = "$baseUrl/api/auth/login";
$authorizeUrl = "$baseUrl/api/s/{$config['site']}/cmd/stamgr";

// handle click-through
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $mac    = filter_input(INPUT_POST, 'client_mac', FILTER_SANITIZE_FULL_SPECIAL_CHARS) ?? '';
    $orig   = filter_input(INPUT_POST, 'orig_url',    FILTER_SANITIZE_URL)              ?? '/';
    $cookie = sys_get_temp_dir() . '/unifi_cookie.txt';

    // 1) login
    curl_json($loginUrl, ['username' => $config['user'], 'password' => $config['pass']], $cookie, $config['verify_ssl']);

    // 2) authorize
    curl_json($authorizeUrl, ['cmd' => 'authorize-guest', 'mac' => $mac, 'minutes' => $config['duration']], $cookie, $config['verify_ssl']);

    header('Location: ' . $orig);
    exit;
}

// on GET, show splash
$mac  = $_GET['id']  ?? '';
$orig = $_GET['url'] ?? '/';
?>
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Welcome to WiFi</title>
  <link rel="stylesheet" href="/frontend/css/styles.css">
</head>
<body>
  <div class="splash">
    <h1>Welcome!</h1>
    <p>Click “Connect” to accept terms and access the network.</p>
    <form method="POST">
      <input type="hidden" name="client_mac" value="<?= htmlspecialchars($mac) ?>">
      <input type="hidden" name="orig_url"   value="<?= htmlspecialchars($orig) ?>">
      <button type="submit">Connect</button>
    </form>
  </div>
</body>
</html>
EOF

# 8) Write modern CSS
cat > "$PROJECT_DIR/backend/php/frontend/css/styles.css" <<'EOF'
@import url('https://fonts.googleapis.com/css2?family=Roboto:wght@400;500;700&display=swap');

html, body {
  margin: 0; padding: 0;
  height: 100%;
  font-family: 'Roboto', sans-serif;
  background: url('/frontend/img/background.jpg') no-repeat center center fixed;
  background-size: cover;
  color: #333;
}

.splash {
  position: absolute; top: 50%; left: 50%;
  transform: translate(-50%, -50%);
  background: rgba(255,255,255,0.85);
  border-radius: 12px;
  box-shadow: 0 4px 20px rgba(0,0,0,0.15);
  padding: 2.5rem 3rem;
  max-width: 360px;
  width: 90%;
  text-align: center;
}

.splash h1 {
  margin: 0 0 1rem;
  font-size: 1.75rem; font-weight: 700;
  color: #222;
}

.splash p {
  margin: 0 0 1.5rem;
  line-height: 1.4; color: #555;
}

.splash button {
  background-color: #0073e6;
  color: #fff; border: none;
  border-radius: 6px;
  padding: 0.75rem;
  font-size: 1rem; font-weight: 500;
  cursor: pointer;
  transition: background-color 0.2s, transform 0.1s;
}

.splash button:hover   { background-color: #005bb5; }
.splash button:active  { transform: scale(0.98); }

@media (max-width: 400px) {
  .splash { padding: 2rem 1.5rem; }
  .splash h1 { font-size: 1.5rem; }
}
EOF

# placeholder background
touch "$PROJECT_DIR/backend/php/frontend/img/background.jpg"
chown -R www-data:www-data "$PROJECT_DIR/backend/php/frontend"

# 9) Configure Apache VirtualHost
echo "🖥 Configuring Apache VirtualHost..."
cat > /etc/apache2/sites-available/captive-portal.conf <<EOF
Alias /frontend $PROJECT_DIR/backend/php/frontend

<VirtualHost *:80>
    ServerName $SERVER_NAME
    DocumentRoot $PROJECT_DIR/backend/php

    DirectoryIndex index.php
    <Directory "$PROJECT_DIR/backend/php">
        Options +FollowSymLinks
        Require all granted
        RewriteEngine On
        RewriteCond %{REQUEST_FILENAME} !-f
        RewriteRule ^ index.php [L,QSA]
    </Directory>

    <Directory "$PROJECT_DIR/backend/php/frontend">
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/captive-portal-error.log
    CustomLog \${APACHE_LOG_DIR}/captive-portal-access.log combined
</VirtualHost>
EOF

# enable & reload
a2ensite captive-portal
systemctl reload apache2

echo
echo "🎉 Installation complete!"
echo "👉 Point UniFi Guest Control → External Portal URL at:"
echo "   http://$SERVER_NAME/guest/s/default/"