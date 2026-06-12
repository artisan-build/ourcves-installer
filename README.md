# OurCVEs Agent Installer

Install the OurCVEs agent:

```sh
curl -fsSL https://raw.githubusercontent.com/artisan-build/ourcves-installer/main/ourcves-agent.sh | bash
```

Verify a downloaded copy before running it:

```sh
curl -fsSLO https://raw.githubusercontent.com/artisan-build/ourcves-installer/main/ourcves-agent.sh
curl -fsSLO https://raw.githubusercontent.com/artisan-build/ourcves-installer/main/ourcves-agent.sh.sig
cat > ourcves-agent.pub <<'EOF'
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAvLq+AMJA4zSySQGY6kIi
WlQzU31rMTyYT2zRPjiwqX5DdWiQRrT4l1K1QG+9sAqryDrcLXqZxPdKX9+wQhc6
fe/2ZDy4gQrdcJ/dKR+QebQkbSa/59T6gq8bNQmrdq9bQ5FP13iplU5EZ0pP4afh
Q74hIHVPuQL4orN6nqDUd47wVNriLYBvlsXrSn9VSBtgT29AHK/mSvNs0ZIiO4KI
eh1zJyroIDguYt58K87w34iI+yhyXwtBfJStR3yc9rJPuRUgAn7/5A7/AO5VVlN3
9VUW3GxpUxLB9pzSfwkZW5x7FtJBrdHailVnt5Bu3J8eJ9IBVMHsJwlZNpC4syVa
AwIDAQAB
-----END PUBLIC KEY-----
EOF
openssl dgst -sha256 -verify ourcves-agent.pub -signature ourcves-agent.sh.sig ourcves-agent.sh
sha256sum -c ourcves-agent.sh.sha256
```

This installer is published as version 2026.06.10 with automatic self-update disabled. To manually update an existing install, run:

```sh
bash ourcves-agent.sh --update
```
