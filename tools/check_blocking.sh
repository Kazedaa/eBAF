#!/bin/bash

# Simple script to check if the blocker is working

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 <domain_to_test>"
    echo "Example: $0 google.com"
    exit 1
fi

DOMAIN=$1

echo "Testing blocking for domain: $DOMAIN"
echo "--------------------------------"

# Try to resolve domain
echo -n "DNS resolution: "
if host $DOMAIN > /dev/null 2>&1; then
    echo "RESOLVED (adblocker might not be blocking DNS)"
    IP=$(host $DOMAIN | grep "has address" | head -1 | awk '{print $4}')
    echo "Resolved to IP: $IP"
else
    echo "FAILED (this is good if adblocker is blocking DNS)"
fi

# Try ping
echo -n "Ping test: "
if ping -c 1 -W 2 $DOMAIN > /dev/null 2>&1; then
    echo "REACHABLE (adblocker not blocking ICMP)"
else
    echo "BLOCKED (adblocker might be blocking ICMP)"
fi

# Try HTTP
echo -n "HTTP test: "
if curl -s --connect-timeout 3 http://$DOMAIN > /dev/null 2>&1; then
    echo "REACHABLE (adblocker not blocking HTTP)"
else
    echo "BLOCKED (adblocker might be blocking HTTP)"
fi

echo -n "HTTPS test: "
if curl -s --connect-timeout 3 https://$DOMAIN > /dev/null 2>&1; then
    echo "REACHABLE (adblocker not blocking HTTPS)"
else
    echo "BLOCKED (adblocker might be blocking HTTPS)"
fi

echo "--------------------------------"
echo "Note: If the domain is being blocked at the IP level,"
echo "all tests should show BLOCKED except possibly DNS resolution"
echo "which depends on whether you're blocking DNS queries too."

chmod +x "$0"
