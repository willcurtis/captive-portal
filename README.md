# Captive Portal for UDM / UniFi OS

A simple click-through WiFi captive portal for UniFi Dream Machine (UDM) / UniFi OS devices.  
No external PHP libraries required—uses PHP’s built-in cURL extension to log in and authorize guests via the UDM `/proxy/network` API.

## Features

- Click-through splash page (“Connect to WiFi”)  
- Authorize guest device MAC for a configurable duration  
- Modern, responsive styling with Google Fonts  
- Configuration via a simple PHP `config.php`  
- Served under Apache with a `/frontend` alias for assets  
- Supports UDM’s self-signed certificate by default (SSL verify disabled)

## Repository Structure

```
captive-portal/
├── backend/
│   └── php/
│       ├── config.php            ← Installer-generated UDM/API settings
│       ├── index.php             ← Captive portal logic & splash page
│       └── frontend/
│           ├── css/
│           │   └── styles.css     ← Modern splash page CSS
│           └── img/
│               └── background.jpg ← Your custom background image
└── install.sh                    ← Automated installer script
```

## Prerequisites

- Ubuntu 20.04+ or Debian 10+  
- Apache2 with `mod_rewrite` & `mod_headers`  
- PHP 7.4+ with `php-curl`  
- UDM / UniFi OS device reachable on your network  

## Installation

1. **Clone or copy** this repo to your server:
   ```bash
   git clone https://github.com/your-org/captive-portal.git /var/www/html/captive-portal
   cd /var/www/html/captive-portal
   ```

2. **Run the installer**:
   ```bash
   sudo chmod +x install.sh
   sudo ./install.sh
   ```
   You’ll be prompted for:
   - Portal domain or IP (e.g. `portal.example.com`)  
   - UDM host & port (e.g. `192.168.1.1`, port `443`)  
   - UniFi “Site” (usually `default`)  
   - UniFi API username & password  
   - Voucher duration in minutes (default `60`)  

3. **Add your background image**:
   ```bash
   sudo cp <your-image>.jpg backend/php/frontend/img/background.jpg
   sudo chown www-data:www-data backend/php/frontend/img/background.jpg
   ```

4. **Verify Apache**:
   ```bash
   sudo systemctl status apache2
   ```

5. **Configure UniFi Guest Control → External Portal URL**:
   ```
   http://<your-portal-domain>/guest/s/default/
   ```

## Customization

- **Background Image**: Replace `backend/php/frontend/img/background.jpg`.  
- **Styling**: Edit `backend/php/frontend/css/styles.css`.  
- **Voucher Duration**: Adjust the `duration` value in `backend/php/config.php`.  
- **SSL Verification**: Toggle `'verify_ssl'` in `backend/php/config.php`.

## How It Works

1. **Splash Page**  
   Visitor sees a “Welcome! Click Connect” page.  
2. **Click-Through**  
   On form submit, `index.php`:
   - Logs in via `/proxy/network/api/auth/login`  
   - Sends an `authorize-guest` command to  
     `/proxy/network/api/s/<site>/cmd/stamgr`  
   - Redirects back to the original URL  
3. **Session**  
   UDM grants network access for the configured duration.

## Security & Permissions

- All files under `/var/www/html/captive-portal` are owned by `www-data:www-data`.  
- CSS & image assets are `644`, directories `755`.  
- SSL verification disabled by default; enable by setting `'verify_ssl' => true` in `backend/php/config.php`.

## License

Released under the [MIT License](LICENSE).  

Enjoy your new captive portal! Contributions and issues are welcome.
