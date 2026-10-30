#!/bin/bash
set -euxo pipefail

mkdir -p /opt/ec2-lab04

cat > /opt/ec2-lab04/index.html <<'HTML'
<!DOCTYPE html>
<html>
<head>
  <title>EC2 Security Group Lab</title>
</head>
<body>
  <h1>EC2 Lab 04 - Web Server Running</h1>
  <p>Status: Healthy</p>
  <p>Incident: INC-EC2-004</p>
</body>
</html>
HTML

cat > /etc/systemd/system/ec2-lab04-web.service <<'SERVICE'
[Unit]
Description=EC2 Lab04 Python HTTP Server
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server 80 --bind 0.0.0.0 --directory /opt/ec2-lab04
Restart=on-failure
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now ec2-lab04-web.service
