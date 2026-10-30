#!/bin/bash
set -euxo pipefail

echo "INC-EC2-005: Beginning application bootstrap"

mkdir -p /opt/ec2-lab05

# INTENTIONAL ERROR:
# mkdirr is not a valid Linux command.
mkdirr -p /opt/ec2-lab05/www

cat > /opt/ec2-lab05/www/index.html <<'HTML'
<!DOCTYPE html>
<html>
<body>
  <h1>EC2 Lab 05 - Application Running</h1>
  <p>Incident: INC-EC2-005</p>
  <p>Status: Healthy</p>
</body>
</html>
HTML

cat > /etc/systemd/system/ec2-lab05-web.service <<'SERVICE'
[Unit]
Description=EC2 Lab05 HTTP Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server 80 --bind 0.0.0.0 --directory /opt/ec2-lab05/www
Restart=on-failure
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now ec2-lab05-web.service

echo "INC-EC2-005: Bootstrap complete"
