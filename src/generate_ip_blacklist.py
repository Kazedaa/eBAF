import sys               # Provides system-specific parameters and functions.
import socket            # Module for networking operations (e.g., IP address conversion, hostname resolution).
import struct            # Provides functions to convert between Python values and C structs represented as Python bytes.
import os                # Provides functions for interacting with the operating system (file and directory operations).
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

# Process a single line which may contain an IP or a domain.
def process_ip_or_domain(line):
    line = line.strip()  # Remove leading and trailing whitespace.
    if not line or line.startswith('#'):
        return None  # Skip empty lines or comments.

    # Assume the entry is a direct IP address.
    ip_int = ip_to_int(line)
    if ip_int:
        # Return a list with a tuple containing the integer IP and a comment.
        # These IP addresses will later be inserted into an eBPF map for packet filtering.
        return [(ip_int, line)]
    
    # If it's not an IP, try resolving it as a domain.
    try:
        # gethostbyname_ex(): returns a tuple with hostname, alias list, and a list of IPv4 addresses.
        _, _, ip_addresses = socket.gethostbyname_ex(line)
        results = []
        for ip in ip_addresses:
            ip_int = ip_to_int(ip)
            if ip_int:
                # Append each resolved IP and include the original domain with the resolved IP in the comment.
                results.append((ip_int, f"{line} ({ip})"))
        
        if results:
            return results
        else:
            sys.stderr.write(f"Warning: Could not resolve domain {line}\n")
            return None
    except socket.gaierror:
        # socket.gaierror is raised for address-related errors.
        sys.stderr.write(f"Warning: Could not resolve domain {line}\n")
        return None

# Generate two files: one C file with the IP blacklist and one header file defining the count.
# These files are later used by the eBPF program to populate its IP blacklist map.
def generate_ip_blacklist_files(ips, output_c_path):    
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
        f.write("#endif // IP_BLACKLIST_H\n")

# Main entry point of the script.
def main():
    # Check that exactly 2 arguments are provided: the input file and the output C file.
    if len(sys.argv) != 3:
        sys.stderr.write(f"Usage: {sys.argv[0]} INPUT_FILE OUTPUT_C_FILE\n")
        sys.exit(1)

    input_file = sys.argv[1]
    output_file = sys.argv[2]

    # Verify that the input file exists before proceeding.
    if not os.path.exists(input_file):
        sys.stderr.write(f"Error: Input file {input_file} not found\n")
        sys.exit(1)

    print(f"Processing domains and IPs from {input_file}...")
    resolved_ips = []  # List to hold the resolved IP addresses (as tuples).
    skipped = 0  # Counter for skipped entries.

    # Read the input file line by line.
    with open(input_file, 'r') as f:
        for line in f:
            line = line.strip()
            # Skip empty lines or lines that are comments.
            if not line or line.startswith('#'):
                continue
                
            results = process_ip_or_domain(line)
            if results:
                # Extend the resolved_ips list.
                if isinstance(results, list):
                    resolved_ips.extend(results)
                else:
                    resolved_ips.append(results)
            else:
                skipped += 1

    print(f"Successfully resolved {len(resolved_ips)} IPs, skipped {skipped} entries")
    
    # Ensure the directory for the output file exists; create it if it doesn't.
    Path(os.path.dirname(output_file)).mkdir(parents=True, exist_ok=True)
    
    # Generate the C file and corresponding header using the resolved IPs.
    generate_ip_blacklist_files(resolved_ips, output_file)
    print(f"Done! Generated {output_file} with {len(resolved_ips)} IPs")

# Standard Python module check to only execute main() if the script is run directly.
if __name__ == "__main__":
    main()