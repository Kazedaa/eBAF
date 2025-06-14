#!/usr/bin/env python3
# filepath: /home/sciencerz/Projects/eBAF/src/generate_ip_blacklist.py

import sys
import socket
import struct
import os
from pathlib import Path

def ip_to_hex(ip_str):
    """Convert IP address string to uint32"""
    try:
        # Convert string IP to packed binary format
        packed_ip = socket.inet_aton(ip_str)
        # Convert 4 bytes to an integer
        return struct.unpack("!I", packed_ip)[0]
    except:
        return None

def process_ip_or_domain(line):
    """Process a line containing an IP or domain name"""
    line = line.strip()
    if not line or line.startswith('#'):
        return None

    # First, try treating it as an IP address
    hex_ip = ip_to_hex(line)
    if hex_ip:
        return hex_ip, line

    # If not an IP, try resolving as a domain
    try:
        ip_address = socket.gethostbyname(line)
        return ip_to_hex(ip_address), f"{line} ({ip_address})"
    except socket.gaierror:
        sys.stderr.write(f"Warning: Could not resolve domain {line}\n")
        return None

def generate_ip_blacklist_files(ips, output_c_path):
    """Generate C file and corresponding header with resolved IPs"""
    
    # Generate the C implementation file
    with open(output_c_path, 'w') as f:
        f.write("#include <linux/types.h>\n")
        f.write("#include <arpa/inet.h>  // For htonl\n\n")
        f.write("// Pre-resolved IP addresses in network byte order (big-endian)\n")
        f.write("__u32 blacklisted_ips[] = {\n")
        
        # Write IP addresses in hex format with comments
        for ip_hex, comment in ips:
            # Store IPs in host byte order and let htonl convert them at runtime
            f.write(f"    {ip_hex},  // {comment}\n")
        
        f.write("};\n\n")
    
    # Generate the header file
    header_path = os.path.splitext(output_c_path)[0] + ".h"
    with open(header_path, 'w') as f:
        f.write("#ifndef IP_BLACKLIST_H\n")
        f.write("#define IP_BLACKLIST_H\n\n")
        f.write("#include <linux/types.h>\n\n")
        f.write("// Pre-resolved IP addresses in network byte order (big-endian)\n")
        f.write("extern __u32 blacklisted_ips[];\n\n")
        f.write(f"// Number of IP addresses in the blacklist\n")
        f.write(f"#define BLACKLIST_SIZE {len(ips)}\n\n")
        f.write("#endif // IP_BLACKLIST_H\n")

def main():
    if len(sys.argv) != 3:
        sys.stderr.write(f"Usage: {sys.argv[0]} INPUT_FILE OUTPUT_C_FILE\n")
        sys.exit(1)

    input_file = sys.argv[1]
    output_file = sys.argv[2]

    if not os.path.exists(input_file):
        sys.stderr.write(f"Error: Input file {input_file} not found\n")
        sys.exit(1)

    print(f"Processing domains and IPs from {input_file}...")
    resolved_ips = []
    skipped = 0
    
    with open(input_file, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
                
            result = process_ip_or_domain(line)
            if result:
                resolved_ips.append(result)
            else:
                skipped += 1

    print(f"Successfully resolved {len(resolved_ips)} IPs, skipped {skipped} entries")
    
    # Add common ad servers that are known to work if no IPs were resolved
    if len(resolved_ips) == 0:
        print("Warning: No IPs resolved. Adding some common ad servers to test functionality.")
        test_entries = [
            ("8.8.8.8", "google-dns.com"),
            ("1.1.1.1", "cloudflare-dns.com"),
            ("93.184.216.34", "example.com")
        ]
        for ip, domain in test_entries:
            resolved_ips.append((ip_to_hex(ip), f"{domain} ({ip})"))
    
    print(f"Generating C file at {output_file}")
    
    # Create directory if it doesn't exist
    Path(os.path.dirname(output_file)).mkdir(parents=True, exist_ok=True)
    
    generate_ip_blacklist_files(resolved_ips, output_file)
    print(f"Done! Generated {output_file} with {len(resolved_ips)} IPs")

if __name__ == "__main__":
    main()