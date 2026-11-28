#!/bin/bash
set -Eeuo pipefail

dnf install -y httpd
printf '%s\n' '<!doctype html><title>Apache sample</title><h1>Hello World!</h1>' \
  > /var/www/html/index.html
systemctl enable --now httpd
