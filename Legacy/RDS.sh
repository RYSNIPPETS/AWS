#!/bin/bash
set -Eeuo pipefail

dnf install -y httpd php php-fpm php-mysqlnd
printf '%s\n' '<?php echo "PHP is ready."; ?>' > /var/www/html/index.php
systemctl enable --now php-fpm httpd
