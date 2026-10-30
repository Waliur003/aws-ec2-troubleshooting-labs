#!/bin/bash
set -euxo pipefail

echo "INC-EC2-005: Starting corrected bootstrap"

mkdir -p /opt/ec2-lab05/www

cat > /opt/ec2-lab05/www/index.html <<'HTML'
<!DOCTYPE html>
<html>
<body>
  <h1>EC2 Lab 05 - Application Running</h1>
  <p>Incident: INC-EC2-005</p>
  <p>Status: Recovered</p>
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

echo "INC-EC2-005: Corrected bootstrap completed"
