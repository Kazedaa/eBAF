import sys               # Provides system-specific parameters and functions.
import socket            # Module for networking operations (e.g., IP address conversion, hostname resolution).
import struct            # Provides functions to convert between Python values and C structs represented as Python bytes.
import os                # Provides functions for interacting with the operating system (file and directory operations).
import fnmatch            # Add this import for wildcard matching
from pathlib import Path # Offers an object-oriented approach to handling filesystem paths.

# Convert an IP string to an integer in host byte order.
def ip_to_int(ip_str):
    try:
        # inet_aton(): converts an IPv4 address from the dotted-quad string format to 32-bit packed binary format.
        packed_ip = socket.inet_aton(ip_str)
        # struct.unpack("!I", ...): unpacks the binary data as an unsigned 32-bit integer in network (big-endian) byte order.
        return struct.unpack("!I", packed_ip)[0]
    except:
        return None

# New function to load whitelist domains
def load_whitelist_domains(whitelist_file):
    whitelist_domains = []
    
    if not os.path.exists(whitelist_file):
        print(f"Warning: Whitelist file {whitelist_file} not found, proceeding without whitelist")
        return whitelist_domains
    
    print(f"Loading whitelist from {whitelist_file}...")
    
    with open(whitelist_file, 'r') as f:
        for line_num, line in enumerate(f, 1):
            line = line.strip()
            # Skip empty lines or comments
            if not line or line.startswith('#'):
                continue
            
            # Remove comment from the line
            if '#' in line:
                domain = line.split('#')[0].strip()
            else:
                domain = line
            
            if domain:
                whitelist_domains.append(domain)
                print(f"Added whitelist pattern: {domain}",file=open("build_logs.log", "a"))
    
    print(f"Loaded {len(whitelist_domains)} whitelist patterns")
    return whitelist_domains

# New function to check if a domain is whitelisted
def is_whitelisted(domain, whitelist_patterns):
    """Check if a domain matches any whitelist pattern (supports wildcards)"""
    for pattern in whitelist_patterns:
        # Handle wildcard patterns
        if fnmatch.fnmatch(domain, pattern):
            return True
        # Also check exact match (case insensitive)
        if domain.lower() == pattern.lower():
            return True
    return False

def process_ip_or_domain(line, whitelist_patterns):
    line = line.strip()
    if not line or line.startswith('#'):
        return None

    # Assume the entry is a direct IP address.
    ip_int = ip_to_int(line)
    if ip_int:
        return [(ip_int, line)]
    
    # If it's not an IP, try resolving it as a domain.
    try:
        # gethostbyname_ex(): returns a tuple with hostname, alias list, and a list of IPv4 addresses.
        _, _, ip_addresses = socket.gethostbyname_ex(line)
        results = []
        for ip in ip_addresses:
            ip_int = ip_to_int(ip)
            if ip_int:
                results.append((ip_int, f"{line} ({ip})"))
        
        if results:
            return results
        else:
            print(f"Warning: Could not resolve domain {line}",file=open("build_logs.log", "a"))
            return None
    except socket.gaierror:
        print(f"Warning: Could not resolve domain {line} : gaierror",file=open("build_logs.log", "a"))
        return None

# Generate two files: one C file with the IP blacklist and one header file defining the count.
# These files are later used by the eBPF program to populate its IP blacklist map.
def generate_ip_blacklist_files(ips, domains, output_c_path):    
    # Generate the C implementation file.
    with open(output_c_path, 'w') as f:
        f.write("#include <linux/types.h>\n\n")
        f.write("// Pre-resolved IP addresses (host byte order)\n")
        # The array 'blacklisted_ips' will be used by the eBPF program (compiled into the kernel)
        # to block packets from/to these IP addresses.
        f.write("__u32 blacklisted_ips[] = {\n")
        
        # Write each IP address in integer format with its corresponding comment.
        for ip_int, comment in ips:
            f.write(f"    {ip_int},  // {comment}\n")
        
        f.write("};\n\n")
        
        # Generate the domain list array
        f.write("// Domain names for dynamic resolution\n")
        f.write("const char* blacklisted_domains[] = {\n")
        for domain in domains:
            f.write(f'    "{domain}",\n')
        f.write("};\n")
    
    # Generate the header file.
    header_path = os.path.splitext(output_c_path)[0] + ".h"
    with open(header_path, 'w') as f:
        f.write("#ifndef IP_BLACKLIST_H\n")
        f.write("#define IP_BLACKLIST_H\n\n")
        f.write("#include <linux/types.h>\n\n")
        f.write("// Pre-resolved IP addresses (host byte order)\n")
        f.write("extern __u32 blacklisted_ips[];\n\n")
        # BLACKLIST_SIZE is later used by the eBPF program to know how many IPs to consider.
        f.write(f"// Number of IP addresses in the blacklist\n")
        f.write(f"#define BLACKLIST_SIZE {len(ips)}\n\n")
        f.write("// Domain names for dynamic resolution\n")
        f.write("extern const char* blacklisted_domains[];\n")
        f.write(f"#define DOMAIN_LIST_SIZE {len(domains)}\n\n")
        f.write("#endif // IP_BLACKLIST_H\n")

# Main entry point of the script.
def main():
    os.system("rm -f build_logs.log")  # Clear the log file at the start of the script.
    
    # Suppress repetitive output by redirecting to log file
    sys.stdout = open('build_logs.log', 'a')
    
    # Updated to accept 3 arguments: input file, output C file, and optional whitelist file
    if len(sys.argv) < 3 or len(sys.argv) > 4:
        sys.stderr.write(f"Usage: {sys.argv[0]} INPUT_FILE OUTPUT_C_FILE [WHITELIST_FILE]\n")
        sys.exit(1)

    input_file = sys.argv[1]
    output_file = sys.argv[2]
    whitelist_file = sys.argv[3] if len(sys.argv) == 4 else None

    # Verify that the input file exists before proceeding.
    if not os.path.exists(input_file):
        sys.stderr.write(f"Error: Input file {input_file} not found\n")
        sys.exit(1)

    # Load whitelist patterns
    whitelist_patterns = []
    if whitelist_file:
        whitelist_patterns = load_whitelist_domains(whitelist_file)

    print(f"Processing domains and IPs from {input_file}...")
    resolved_ips = []  # List to hold the resolved IP addresses (as tuples).
    domain_list = []   # List to hold domain names for dynamic resolution
    skipped = 0  # Counter for skipped entries.
    whitelisted = 0

    # Read the input file line by line.
    with open(input_file, 'r') as f:
        for line in f:
            line = line.strip()
            # Skip empty lines or lines that are comments.
            if not line or line.startswith('#'):
                continue
            
            # Check if this domain is whitelisted before processing
            if is_whitelisted(line, whitelist_patterns):
                print(f"Skipping whitelisted domain: {line}",file=open("build_logs.log", "a"))
                whitelisted += 1
                continue
            

            domain_list.append(line)
                
            results = process_ip_or_domain(line, whitelist_patterns)
            if results:
                if isinstance(results, list):
                    resolved_ips.extend(results)
                else:
                    resolved_ips.append(results)
            else:
                skipped += 1

    print(f"Successfully resolved {len(resolved_ips)} IPs, skipped {skipped} entries, whitelisted {whitelisted} domains")
    
    # Ensure the directory for the output file exists; create it if it doesn't.
    Path(os.path.dirname(output_file)).mkdir(parents=True, exist_ok=True)
    
    # Generate the C file and corresponding header using the resolved IPs.
    generate_ip_blacklist_files(resolved_ips, domain_list, output_file)
    print(f"Done! Generated {output_file} with {len(resolved_ips)} IPs and {len(domain_list)} domains for dynamic resolution")

    # At the end, restore stdout and print final summary
    sys.stdout.close()
    sys.stdout = sys.__stdout__
    print(f"Generated {len(resolved_ips)} IPs and {len(domain_list)} domains")

# Standard Python module check to only execute main() if the script is run directly.
if __name__ == "__main__":
    main()
