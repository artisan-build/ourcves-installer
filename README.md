# OurCVEs Agent Installer

Copy your install token from the OurCVEs dashboard, then download, verify, and run the installer:

```sh
curl -fsSLO https://raw.githubusercontent.com/artisan-build/ourcves-installer/main/ourcves-agent.sh
curl -fsSLO https://raw.githubusercontent.com/artisan-build/ourcves-installer/main/ourcves-agent.sh.sig
curl -fsSLO https://raw.githubusercontent.com/artisan-build/ourcves-installer/main/ourcves-agent.sh.sha256
cat > ourcves-agent.pub <<'EOF'
-----BEGIN PUBLIC KEY-----
MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAxfpN/Co4onZwl5J3Wnjo
ZXyHYWCLh7qxaieanmLy+EaMA5ZsdDJWhfBIWgVdw4GVYMDItMf6YHv7/uuNyCU0
hPtCac6olLciX6FrxNKzSvlxe7KqUjJYFwlzAaR0/azRLr5FI/EA63uaRqKKKWM+
bW8phoP1jJwYX3xBKRHAqCELqki6bB/mKIy51hiMPN8W7xok3M8YPu+GMcbrgV7U
bZDZa3EyGWv5dYlCon/eVQvZRlZ5WhfQrLhlP9OuwKtdJDeAsR11Xv+ZdBH7sp6W
M28zROx9Y6azzbufBno96/nkAWXhDl6eLZqRm7Z/YXpRnjXzZwIeaioOxotDlxwc
7PKoq13iMwVlM/qsHfMgw5zDJVw9GHNfbrGZ4DmnQmL1clYs4CulLBsLDJdBSKB0
v9PWc7/nZDmAeKSYwP4Wm2TYi/aMvGRcUKAv420NMxUg8Cj9rQQsJ/bMiIL6pZMM
jP0kxW0A+/8OLw1fq8CcjCGAoZQsjxSZj/4Lnuum9cbsvyX7m1/5B0gtvJ6OjCq1
P0xkYbf6d6c/ONsxOw5UJ+KOfP8VAWpC2Yly7QcPJOAMf/qjJJA3r1GmcMNE1cjt
+I5rELHbQ4Bgxvl15OSCxz0qlH6IskyXoxe8UQVJfYY7tzTTrN9Hl2wMSUXYJv9C
ThApemiExYpJs1HxTD3tBm0CAwEAAQ==
-----END PUBLIC KEY-----
EOF
openssl dgst -sha256 -verify ourcves-agent.pub -signature ourcves-agent.sh.sig ourcves-agent.sh
sha256sum -c ourcves-agent.sh.sha256
sudo bash ourcves-agent.sh --token <YOUR_INSTALL_TOKEN>
```

This installer is published as version 2026.06.15.1 with automatic self-update disabled. To manually update an existing install after verifying the downloaded script, run:

```sh
bash ourcves-agent.sh --update
```
