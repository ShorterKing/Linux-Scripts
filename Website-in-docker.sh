#!/bin/bash

# Check if domain name is provided as an argument
if [ $# -ne 1 ]; then
    echo "Usage: $0 <domain>"
    echo "Example: $0 akshatcraft.ddns.net"
    exit 1
fi

DOMAIN=$1
CERT_DIR="/etc/letsencrypt/live/$DOMAIN"

# Verify that the certificate directory exists
if [ ! -d "$CERT_DIR" ]; then
    echo "Error: Certificate directory $CERT_DIR does not exist."
    echo "Please ensure Certbot has generated certificates for $DOMAIN."
    exit 1
fi

# Create Dockerfile to enable SSL module
cat > Dockerfile << 'EOF'
FROM httpd:2.4

# Enable SSL module
RUN sed -i '/#LoadModule ssl_module/s/^#//' /usr/local/apache2/conf/httpd.conf

# Enable SSL configuration
RUN sed -i '/#Include conf\/extra\/httpd-ssl.conf/s/^#//' /usr/local/apache2/conf/httpd.conf

# Copy custom SSL configuration
COPY httpd-ssl.conf /usr/local/apache2/conf/extra/httpd-ssl.conf
EOF

# Create custom httpd-ssl.conf
cat > httpd-ssl.conf << EOF
Listen 443
<VirtualHost *:443>
    ServerName $DOMAIN
    DocumentRoot "/usr/local/apache2/htdocs"
    SSLEngine on
    SSLCertificateFile "/usr/local/apache2/conf/server.crt"
    SSLCertificateKeyFile "/usr/local/apache2/conf/server.key"
    SSLCipherSuite HIGH:!aNULL
    <Directory "/usr/local/apache2/htdocs">
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF

# Build Docker image
docker build -t custom-httpd:2.4 .

# Run Docker container
docker run -d \
    -p 80:80 \
    -p 443:443 \
    -v /var/www/html:/usr/local/apache2/htdocs \
    -v "$CERT_DIR/fullchain.pem:/usr/local/apache2/conf/server.crt" \
    -v "$CERT_DIR/privkey.pem:/usr/local/apache2/conf/server.key" \
    --name apache-container \
    custom-httpd:2.4

if [ $? -eq 0 ]; then
    echo "Docker container started successfully for $DOMAIN on ports 80 and 443."
    echo "Container name: apache-container"
else
    echo "Error: Failed to start Docker container. Check Docker logs for details with:"
    echo "docker logs apache-container"
    exit 1
fi
