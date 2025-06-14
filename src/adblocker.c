// This is the userspace part of our program
// It loads the eBPF program into the kernel and manages its operation

#include <stdio.h>              // Standard I/O functions
#include <stdlib.h>             // Standard library functions
#include <string.h>             // String manipulation functions
#include <errno.h>              // Error codes
#include <unistd.h>             // UNIX standard functions
#include <signal.h>             // Signal handling
#include <net/if.h>             // Network interface functions
#include <linux/if_link.h>      // Network interface constants
#include <sys/socket.h>         // Socket definitions
#include <netinet/in.h>         // Internet address family
#include <arpa/inet.h>          // IP manipulation functions
#include <netdb.h>              // Network database functions
#include <libgen.h>             // Pathname manipulation functions

#include <bpf/libbpf.h>         // libbpf functions for loading eBPF programs
#include <bpf/bpf.h>            // Core eBPF userspace functions

#include "adblocker.h"          // Our header with constants

// Global variables to maintain program state
static int ifindex;             // Network interface index
static struct bpf_object *obj;  // Our loaded eBPF object
static int blacklist_ip_map_fd; // File descriptor for the IP blacklist map
static int stats_map_fd;        // File descriptor for the statistics map

// Function to print all blocked IP addresses currently in the map
static void print_ips(void) {
    // printf("\nCurrently blocked IPs:\n");
    
    // Create a temporary socket for network functions
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        perror("socket");
        return;
    }
    
    // Variables for map iteration
    __u32 key, next_key;
    __u8 value;
    int count = 0;
    
    // Start iterating through the map entries
    if (bpf_map_get_next_key(blacklist_ip_map_fd, NULL, &key) == 0) {
        do {
            // Get the value for the current key
            if (bpf_map_lookup_elem(blacklist_ip_map_fd, &key, &value) == 0) {
                // Convert IP from numeric to human-readable format
                struct in_addr addr;
                addr.s_addr = key;
                // printf("  %s\n", inet_ntoa(addr));
                count++;
            }
        // Move to next key until we've gone through all entries
        } while (bpf_map_get_next_key(blacklist_ip_map_fd, &key, &next_key) == 0 && 
                (key = next_key));
    }
    
    printf("Total blocked IPs: %d\n", count);
    close(sock);
}

// Function to clean up when the program exits
static void cleanup(int sig) {
    (void)sig;  // Mark parameter as used to avoid warning
    printf("\nRemoving XDP program from interface %d\n", ifindex);
    // Detach our eBPF program from the network interface
    bpf_xdp_detach(ifindex, 0, NULL);
    exit(0);
}

// Function to list all available network interfaces
static void list_interfaces(void) {
    printf("Available network interfaces:\n");
    
    // Use the system's 'ip' command to get interface list
    FILE *fp = popen("ip -o link show | awk -F': ' '{print $2}'", "r");
    if (fp == NULL) {
        printf("  Failed to get interface list\n");
        return;
    }
    
    // Read and print each interface name
    char iface[64];
    while (fgets(iface, sizeof(iface), fp) != NULL) {
        // Remove newline character
        iface[strcspn(iface, "\n")] = 0;
        // Skip the loopback interface
        if (strcmp(iface, "lo") != 0)
            printf("  %s\n", iface);
    }
    pclose(fp);
}

// Function to find the path to our eBPF object file
static char *get_bpf_object_path(const char *progname) {
    static char path[256];
    
    // Try different possible locations for the eBPF object file
    if (access("./obj/adblocker.bpf.o", F_OK) != -1) {
        snprintf(path, sizeof(path), "./obj/adblocker.bpf.o");
        return path;
    }
    
    // Try in parent directory
    char *dir = dirname(strdup(progname));
    snprintf(path, sizeof(path), "%s/../obj/adblocker.bpf.o", dir);
    if (access(path, F_OK) != -1)
        return path;
    
    // Try in same directory as program
    snprintf(path, sizeof(path), "%s/adblocker.bpf.o", dir);
    if (access(path, F_OK) != -1)
        return path;
    
    // Try standard installation location
    snprintf(path, sizeof(path), "/usr/local/bin/adblocker.bpf.o");
    if (access(path, F_OK) != -1)
        return path;
    
    // Could not find the object file
    return NULL;
}

// Function to resolve a domain name or IP and add it to the blacklist
static int resolve_and_add_ip(const char *domain_or_ip) {
    struct in_addr addr;
    
    // Check if it's already an IP address
    if (inet_pton(AF_INET, domain_or_ip, &addr) == 1) {
        __u8 value = 1;
        __u32 ip = addr.s_addr;
        
        // Update the map with this IP
        if (bpf_map_update_elem(blacklist_ip_map_fd, &ip, &value, BPF_ANY) == 0) {
            // printf("Added IP to blacklist: %s\n", domain_or_ip);
            return 1;
        } else {
            fprintf(stderr, "Failed to add IP to blacklist: %s\n", domain_or_ip);
            return 0;
        }
    }
    
    // If not an IP, try to resolve as a domain name
    struct addrinfo hints, *result, *rp;
    int count = 0;
    __u8 value = 1;
    
    // Set up hints for address resolution
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET;       // IPv4 only
    hints.ai_socktype = SOCK_STREAM;
    
    // Resolve the domain name to one or more IP addresses
    int status = getaddrinfo(domain_or_ip, NULL, &hints, &result);
    if (status != 0) {
        fprintf(stderr, "Failed to resolve %s: %s\n", domain_or_ip, gai_strerror(status));
        return 0;
    }
    
    // Add each resolved IP address to our blacklist
    for (rp = result; rp != NULL; rp = rp->ai_next) {
        struct sockaddr_in *addr_in = (struct sockaddr_in *)rp->ai_addr;
        __u32 ip = addr_in->sin_addr.s_addr;
        
        // Convert numeric IP to string for display
        char ip_str[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &ip, ip_str, INET_ADDRSTRLEN);
        
        // Add to the map
        if (bpf_map_update_elem(blacklist_ip_map_fd, &ip, &value, BPF_ANY) == 0) {
            // printf("  Added IP: %s -> %s\n", domain_or_ip, ip_str);
            count++;
        }
    }
    
    freeaddrinfo(result);
    
    if (count == 0) {
        fprintf(stderr, "Warning: No IPs found for %s\n", domain_or_ip);
        return 0;
    }
    
    return count;
}

// Function to load a blacklist file
static int load_blacklist(const char *filename) {
    FILE *file = fopen(filename, "r");
    if (!file) {
        fprintf(stderr, "Failed to open blacklist file: %s\n", filename);
        return -1;
    }
    
    char line[256];
    int ip_count = 0;
    
    printf("Loading blacklist and resolving domains...\n");
    
    while (fgets(line, sizeof(line), file)) {
        // Remove newline
        line[strcspn(line, "\n")] = 0;
        
        // Skip empty lines and comments
        if (strlen(line) == 0 || line[0] == '#') {
            continue;
        }
        
        // printf("Processing: %s\n", line);
        ip_count += resolve_and_add_ip(line);
    }
    
    fclose(file);
    printf("\nLoaded %d IP addresses into blacklist\n", ip_count);
    return ip_count;
}

// Function to print statistics about packet processing
static void print_stats(void) {
    __u32 key;
    __u64 total, blocked;
    
    // Get total packets count
    key = STAT_TOTAL;
    if (bpf_map_lookup_elem(stats_map_fd, &key, &total) != 0)
        total = 0;
    
    // Get blocked packets count
    key = STAT_BLOCKED;
    if (bpf_map_lookup_elem(stats_map_fd, &key, &blocked) != 0)
        blocked = 0;
    
    printf("Total packets: %llu, Blocked packets: %llu\n", total, blocked);
}

// Main program
int main(int argc, char **argv) {
    // Check command line arguments
    if (argc != 3) {
        fprintf(stderr, "Usage: %s <interface> <blacklist_file>\n", argv[0]);
        fprintf(stderr, "\n");
        list_interfaces();
        return 1;
    }
    
    const char *ifname = argv[1];        // Network interface name
    const char *blacklist_file = argv[2]; // Path to blacklist file
    
    // Convert interface name to interface index
    ifindex = if_nametoindex(ifname);
    if (ifindex == 0) {
        fprintf(stderr, "Invalid interface: %s\n", ifname);
        fprintf(stderr, "\n");
        list_interfaces();
        return 1;
    }
    
    // Load our eBPF program
    char *bpf_obj_path = get_bpf_object_path(argv[0]);
    if (!bpf_obj_path) {
        fprintf(stderr, "Failed to find adblocker.bpf.o file. Make sure to run 'make' first.\n");
        return 1;
    }
    
    printf("Loading BPF object: %s\n", bpf_obj_path);
    
    // Open the eBPF object file
    obj = bpf_object__open_file(bpf_obj_path, NULL);
    if (libbpf_get_error(obj)) {
        fprintf(stderr, "Failed to open BPF object file\n");
        return 1;
    }
    
    // Load the eBPF program into the kernel
    if (bpf_object__load(obj)) {
        fprintf(stderr, "Failed to load BPF object\n");
        return 1;
    }
    
    // Find our specific XDP program within the object
    struct bpf_program *prog = bpf_object__find_program_by_name(obj, "xdp_blocker");
    if (!prog) {
        fprintf(stderr, "Failed to find XDP program\n");
        return 1;
    }
    
    int prog_fd = bpf_program__fd(prog);
    
    // Get file descriptors for our eBPF maps
    struct bpf_map *blacklist_ip_map = bpf_object__find_map_by_name(obj, "blacklist_ip_map");
    struct bpf_map *stats_map = bpf_object__find_map_by_name(obj, "stats_map");
    
    if (!blacklist_ip_map || !stats_map) {
        fprintf(stderr, "Failed to find BPF maps\n");
        return 1;
    }
    
    blacklist_ip_map_fd = bpf_map__fd(blacklist_ip_map);
    stats_map_fd = bpf_map__fd(stats_map);
    
    // Initialize statistics counters
    __u32 key;
    __u64 value = 0;
    
    key = STAT_TOTAL;
    bpf_map_update_elem(stats_map_fd, &key, &value, BPF_ANY);
    
    key = STAT_BLOCKED;
    bpf_map_update_elem(stats_map_fd, &key, &value, BPF_ANY);
    
    // Load the blacklist of IPs to block
    if (load_blacklist(blacklist_file) <= 0) {
        fprintf(stderr, "Error: No valid IPs loaded. Check the blacklist file.\n");
        return 1;
    }
    
    // Display the list of blocked IPs
    print_ips();
    
    // Define different XDP attachment modes to try
    // These modes affect performance and compatibility
    int xdp_flags[] = {
        XDP_FLAGS_SKB_MODE,    // Generic mode (most compatible)
        XDP_FLAGS_DRV_MODE,    // Native mode (fastest)
        0                      // Default mode
    };
    
    const char *mode_names[] = {
        "generic (SKB)",
        "native (DRV)",
        "default"
    };
    
    // Try to attach our program in different modes
    int attached = 0;
    for (int i = 0; i < 3; i++) {
        printf("Trying XDP %s mode...\n", mode_names[i]);
        
        if (bpf_xdp_attach(ifindex, prog_fd, xdp_flags[i], NULL) == 0) {
            printf("Successfully attached XDP program in %s mode\n", mode_names[i]);
            attached = 1;
            break;
        } else {
            printf("Failed to attach in %s mode: %s\n", mode_names[i], strerror(errno));
        }
    }
    
    // Check if we were able to attach at all
    if (!attached) {
        fprintf(stderr, "Failed to attach XDP program in any mode\n");
        fprintf(stderr, "Make sure you have sufficient privileges (run as root)\n");
        return 1;
    }
    
    printf("eBPF traffic blocker attached to %s\n", ifname);
    printf("Press Ctrl+C to stop\n");
    
    // Set up signal handlers to clean up on program exit
    signal(SIGINT, cleanup);
    signal(SIGTERM, cleanup);
    
    // Main loop - print statistics every second
    while (1) {
        sleep(1);
        print_stats();
    }
    
    return 0;
}