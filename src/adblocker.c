// This is the userspace part of our program

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
#include <sys/resource.h>       // For setrlimit
#include <time.h>               // For time tracking

#include <bpf/libbpf.h>         // libbpf functions for loading eBPF programs
#include <bpf/bpf.h>            // Core eBPF userspace functions

#include "adblocker.h"          // Our header with constants
#include "ip_blacklist.h"       // Pre-resolved IP blacklist

// Global variables to maintain program state
static int ifindex;             // Network interface index
static struct bpf_object *obj;  // Our loaded eBPF object
static int blacklist_ip_map_fd; // File descriptor for the IP blacklist map
static int stats_map_fd;        // File descriptor for the statistics map
static time_t start_time;       // When the program started

// Function to print all blocked IP addresses currently in the map
static void print_ips(void) {
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
                count++;
            }
        // Move to next key until we've gone through all entries
        } while (bpf_map_get_next_key(blacklist_ip_map_fd, &key, &next_key) == 0 && 
                (key = next_key));
    }
    
    printf("Total blocked IPs: %d\n", count);
    close(sock);
}

// Function to get current statistics
static void get_stats(__u64 *total, __u64 *blocked) {
    __u32 key;
    
    // Get total packets count
    key = STAT_TOTAL;
    if (bpf_map_lookup_elem(stats_map_fd, &key, total) != 0)
        *total = 0;
    
    // Get blocked packets count
    key = STAT_BLOCKED;
    if (bpf_map_lookup_elem(stats_map_fd, &key, blocked) != 0)
        *blocked = 0;
}

// Function to clean up when the program exits
static void cleanup(int sig) {
    // Get final statistics
    __u64 total, blocked;
    get_stats(&total, &blocked);
    
    // Calculate uptime
    time_t end_time = time(NULL);
    double uptime = difftime(end_time, start_time);
    
    printf("\n--- eBAF Statistics ---\n");
    printf("Uptime: %.1f seconds\n", uptime);
    printf("Total packets processed: %llu\n", total);
    printf("Packets blocked: %llu\n", blocked);
    printf("Blocking rate: %.2f%%\n", (total > 0) ? ((double)blocked / total * 100.0) : 0);
    
    printf("Removing XDP program from interface %d\n", ifindex);
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
    // First, try in current directory
    if (access("./adblocker.bpf.o", F_OK) != -1) {
        snprintf(path, sizeof(path), "./adblocker.bpf.o");
        return path;
    }
    
    // Try in bin directory
    if (access("./bin/adblocker.bpf.o", F_OK) != -1) {
        snprintf(path, sizeof(path), "./bin/adblocker.bpf.o");
        return path;
    }
    
    // Try in obj directory
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
    
    snprintf(path, sizeof(path), "/usr/local/share/ebaf/adblocker.bpf.o");
    if (access(path, F_OK) != -1)
        return path;
    
    // Could not find the object file
    return NULL;
}

// Function to increase RLIMIT_MEMLOCK to allow eBPF maps to be created
static void increase_memlock_limit(void) {
    struct rlimit rlim = {
        .rlim_cur = RLIM_INFINITY,
        .rlim_max = RLIM_INFINITY
    };
    
    if (setrlimit(RLIMIT_MEMLOCK, &rlim)) {
        fprintf(stderr, "Warning: Failed to increase RLIMIT_MEMLOCK limit: %s\n", 
                strerror(errno));
        fprintf(stderr, "You may need to run with sudo or use the wrapper script\n");
    }
}

// Function to load IP blacklist into the map from C directly
static void load_ip_blacklist(void) {
    int count = 0;
    __u8 value = 1;
    
    printf("Loading IP blacklist into filter...\n");
    
    // Update the map directly from userspace
    for (int i = 0; i < BLACKLIST_SIZE; i++) {
        __u32 ip = htonl(blacklisted_ips[i]);  // Convert to network byte order
        if (bpf_map_update_elem(blacklist_ip_map_fd, &ip, &value, BPF_ANY) == 0) {
            count++;
        }
    }
}

// Main program
int main(int argc, char **argv) {
    // Check command line arguments
    if (argc != 2) {
        fprintf(stderr, "Usage: %s <interface>\n", argv[0]);
        fprintf(stderr, "\n");
        list_interfaces();
        return 1;
    }

    // Record start time
    start_time = time(NULL);
    
    const char *ifname = argv[1];        // Network interface name
    
    // Convert interface name to interface index
    ifindex = if_nametoindex(ifname);
    if (ifindex == 0) {
        fprintf(stderr, "Invalid interface: %s\n", ifname);
        fprintf(stderr, "\n");
        list_interfaces();
        return 1;
    }

    // Increase the RLIMIT_MEMLOCK limit
    increase_memlock_limit();
    
    // Load our eBPF program
    char *bpf_obj_path = get_bpf_object_path(argv[0]);
    if (!bpf_obj_path) {
        fprintf(stderr, "Failed to find adblocker.bpf.o file. Make sure to run 'make' first.\n");
        return 1;
    }
    
    printf("Loading BPF program...\n");
    
    // Open the eBPF object file
    obj = bpf_object__open_file(bpf_obj_path, NULL);
    if (libbpf_get_error(obj)) {
        fprintf(stderr, "Failed to open BPF object file\n");
        return 1;
    }
    
    // Load the eBPF program into the kernel
    if (bpf_object__load(obj)) {
        fprintf(stderr, "Failed to load BPF program\n");
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
    
    // Load the IP blacklist directly from userspace
    load_ip_blacklist();
    
    // Display the list of blocked IPs
    print_ips();
    
    // Define different XDP attachment modes to try
    // These modes affect performance and compatibility
    int xdp_flags[] = {
        XDP_FLAGS_DRV_MODE,    // Native mode (fastest)
        XDP_FLAGS_SKB_MODE,    // Generic mode (most compatible)
        0                      // Default mode
    };
    
    const char *mode_names[] = {
        "native (DRV)",
        "generic (SKB)",
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
        }
        
        // Print error only if it's not "Operation not supported"
        if (errno != EOPNOTSUPP) {
            perror("XDP attach");
        }
    }
    
    if (!attached) {
        fprintf(stderr, "Error: Could not attach XDP program to interface\n");
        return 1;
    }
    
    // Set up signal handler for graceful exit
    signal(SIGINT, cleanup);
    signal(SIGTERM, cleanup);
    
    printf("\nAd blocker is running. Press Ctrl+C to stop and view statistics.\n");
    
    // Main loop: just keep the program running
    while (1) {
        sleep(1);
    }
    
    return 0;
}