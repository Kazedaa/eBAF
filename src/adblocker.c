// This is the userspace part of our program. It loads an eBPF (extended Berkeley Packet Filter)
// program into the kernel to block unwanted IPs. It also performs domain resolution, tracks statistics,
// and attaches the XDP (Express Data Path) program to a network interface for high-speed packet processing.

/*
    Header files inclusion:
    - stdio.h: for input/output functions e.g., printf().
    - stdlib.h: for general functions such as memory allocation and process control.
    - string.h: for string manipulation functions.
    - errno.h: for referring to the error codes.
    - unistd.h: for POSIX functions such as sleep() and close().
    - signal.h: for setting up signal handlers to catch signals like SIGINT.
    - net/if.h: for network interface functions.
    - linux/if_link.h: for constants related to network interfaces.
    - sys/socket.h: for socket functions.
    - netinet/in.h: for Internet address family definitions.
    - arpa/inet.h: for IP address manipulation functions.
    - netdb.h: for network database operations.
    - libgen.h: for pathname manipulation functions.
    - sys/resource.h: for setting resource limits (like RLIMIT_MEMLOCK).
    - time.h: for time-related functions.
    - pthread.h: for working with POSIX threads.
    - stdbool.h: for boolean type and values true/false.
    
    The bpf headers come from libbpf, used for loading and managing eBPF programs.
    
    The custom header files "adblocker.h", "ip_blacklist.h", and "domain_store.h" define program-specific constants,
    IP lists, and domain storage/resolution functions.
*/

#include <stdio.h>              // Standard I/O functions (e.g., printf, fprintf)
#include <stdlib.h>             // Standard library functions (e.g., exit)
#include <string.h>             // String manipulation functions (e.g., strcmp, strcpy)
#include <errno.h>              // Provides the errno macro and error codes
#include <unistd.h>             // Provides access to POSIX functions (e.g., sleep, close)
#include <signal.h>             // For creating signal handlers (e.g., SIGINT)
#include <net/if.h>             // Network interface functions (e.g., if_nametoindex)
#include <linux/if_link.h>      // Network interface constants used by XDP
#include <sys/socket.h>         // Socket definitions (e.g., socket)
#include <netinet/in.h>         // Internet address family definitions (e.g., for sockaddr_in)
#include <arpa/inet.h>          // IP manipulation functions (e.g., htonl)
#include <netdb.h>              // Network database functions (e.g., for DNS lookup)
#include <libgen.h>             // To use dirname() for path manipulation
#include <sys/resource.h>       // For setrlimit, which is used to change resource limits (e.g., RLIMIT_MEMLOCK)
#include <time.h>               // For tracking time and formatting timestamps
#include <pthread.h>            // For multithreading (e.g., pthread_create, pthread_join)
#include <stdbool.h>            // For using bool, true, and false

#include <bpf/libbpf.h>         // For loading eBPF programs into the kernel using libbpf
#include <bpf/bpf.h>            // For core eBPF operations (e.g., bpf_map_update_elem)

#include "adblocker.h"          // Custom header for constants used in the ad blocker
#include "ip_blacklist.h"       // Header that holds the list of blacklisted IP addresses
#include "domain_store.h"       // Header for domain store handling and resolution

// Global variables to maintain the state of the program

static int ifindex;             // Index of the network interface (obtained with if_nametoindex)
static struct bpf_object *obj;  // Pointer to the loaded eBPF object which contains our eBPF programs
static int blacklist_ip_map_fd; // File descriptor for the eBPF map holding blacklisted IPs
static int stats_map_fd;        // File descriptor for the eBPF map holding statistics data

static pthread_t resolver_thread;   // Thread for resolving domain names into IPs
static volatile bool running = true;  // Flag that controls the main loop and thread execution

// Function: get_stats
// Purpose: Reads the statistics (total packets and blocked packets) from the eBPF stats map
// __u64: unsigned 64-bit integer used to store large count values
static void get_stats(__u64 *total, __u64 *blocked) {
    __u32 key;
    
    // Retrieve total packets count using STAT_TOTAL constant defined in adblocker.h
    // bpf_map_lookup_elem() is an eBPF helper that retrieves an element from an eBPF map.
    key = STAT_TOTAL;
    if (bpf_map_lookup_elem(stats_map_fd, &key, total) != 0)
        *total = 0;
    
    // Retrieve blocked packets count using STAT_BLOCKED constant defined in adblocker.h
    // This helper allows user space to read statistics maintained by the kernel eBPF program.
    key = STAT_BLOCKED;
    if (bpf_map_lookup_elem(stats_map_fd, &key, blocked) != 0)
        *blocked = 0;
}

// Function: cleanup
// Purpose: Called when the program receives a termination signal (SIGINT/SIGTERM). It cleans up resources,
// prints final statistics, detaches the eBPF program, and exits.
// 'cleanup' parameter: sig - the signal number received.
static void cleanup(int sig) {
    (void)sig;  // Avoids a compiler warning about an unused parameter.
    
    // Stop the resolver thread.
    running = false;
    
    // Wait for resolver thread to finish.
    pthread_join(resolver_thread, NULL);
    
    // Clean up domain store resources.
    domain_store_cleanup();
    
    // Detach the eBPF/XDP program from the network interface.
    // bpf_xdp_detach() is an eBPF helper to remove an XDP program attached to an interface.
    bpf_xdp_detach(ifindex, 0, NULL);
    exit(0); // Terminate the program.
}

// Function: get_default_interface
// Purpose: Tries to determine the default network interface that has a route to 1.1.1.1
// Returns a string containing the interface name or NULL if not found.
static char *get_default_interface(void) {
    static char default_if[IF_NAMESIZE] = {0};
    
    // Try to find the interface by checking the route to a public IP (e.g., 1.1.1.1)
    FILE *fp = popen("ip -o route get 1.1.1.1 2>/dev/null | awk '{print $5}'", "r");
    if (fp != NULL) {
        if (fgets(default_if, sizeof(default_if), fp) != NULL) {
            // Remove newline character.
            default_if[strcspn(default_if, "\n")] = 0;
            
            // Ensure the loopback interface is not chosen.
            if (strcmp(default_if, "lo") == 0) {
                default_if[0] = '\0';
            }
        }
        pclose(fp);
    }
    
    // If no default interface was detected, pick the first non-loopback interface.
    if (default_if[0] == '\0') {
        fp = popen("ip -o link show | grep -v 'lo:' | head -n 1 | cut -d: -f2 | tr -d ' '", "r");
        if (fp != NULL) {
            if (fgets(default_if, sizeof(default_if), fp) != NULL) {
                default_if[strcspn(default_if, "\n")] = 0;
            }
            pclose(fp);
        }
    }
    
    // Return NULL if no interface was found.
    if (default_if[0] == '\0') {
        return NULL;
    }
    
    return default_if;
}

// Function: get_bpf_object_path
// Purpose: Determines the file path to the eBPF object file (adblocker.bpf.o) using various common locations.
// Returns a pointer to a string containing the path if found; otherwise returns NULL.
// access(): checks the existence of the file with the given path.
static char *get_bpf_object_path(const char *progname) {
    static char path[256];
    
    // Check current directory.
    if (access("./adblocker.bpf.o", F_OK) != -1) {
        snprintf(path, sizeof(path), "./adblocker.bpf.o");
        return path;
    }
    
    // Check bin directory.
    if (access("./bin/adblocker.bpf.o", F_OK) != -1) {
        snprintf(path, sizeof(path), "./bin/adblocker.bpf.o");
        return path;
    }
    
    // Check obj directory.
    if (access("./obj/adblocker.bpf.o", F_OK) != -1) {
        snprintf(path, sizeof(path), "./obj/adblocker.bpf.o");
        return path;
    }
    
    // Check parent directory relative to the program's own path.
    char *dir = dirname(strdup(progname));
    snprintf(path, sizeof(path), "%s/../obj/adblocker.bpf.o", dir);
    if (access(path, F_OK) != -1)
        return path;
    
    // Check in the same directory as the program.
    snprintf(path, sizeof(path), "%s/adblocker.bpf.o", dir);
    if (access(path, F_OK) != -1)
        return path;
    
    // Standard installation locations.
    snprintf(path, sizeof(path), "/usr/local/bin/adblocker.bpf.o");
    if (access(path, F_OK) != -1)
        return path;
    
    snprintf(path, sizeof(path), "/usr/local/share/ebaf/adblocker.bpf.o");
    if (access(path, F_OK) != -1)
        return path;
    
    // If the file is not found.
    return NULL;
}

// Function: increase_memlock_limit
// Purpose: Increases the RLIMIT_MEMLOCK limit to allow creation of eBPF maps which require non-swappable memory.
// RLIMIT_MEMLOCK: sets the maximum amount of memory that may be locked into RAM.
static void increase_memlock_limit(void) {
    struct rlimit rlim = {
        .rlim_cur = RLIM_INFINITY,
        .rlim_max = RLIM_INFINITY
    };
    
    // setrlimit(): sets resource limits for the process.
    if (setrlimit(RLIMIT_MEMLOCK, &rlim)) {
        printf("Failed to set memory lock limit");
    }
}

// Function: load_ip_blacklist
// Purpose: Loads a static IP blacklist (provided by ip_blacklist.h) into the eBPF map so that the kernel program
// can inspect it for blocking network traffic.
static void load_ip_blacklist(void) {
    __u64 value = 0;  // This value indicates number of blocks
    
    printf("Loading IP blacklist into filter...\n");
    
    // Loop through the static blacklisted_ips array defined in ip_blacklist.h.
    for (int i = 0; i < BLACKLIST_SIZE; i++) {
        // htonl(): converts an unsigned integer from host to network byte order.
        __u32 ip = htonl(blacklisted_ips[i]);  
        // bpf_map_update_elem() is an eBPF helper that updates an element in an eBPF map.
        if (bpf_map_update_elem(blacklist_ip_map_fd, &ip, &value, BPF_ANY) == 0) {
        }
    }
}

// Function to populate domain store from the generated domain list
static void populate_domain_store(void) {
    printf("Populating domain store with %d domains...\n", DOMAIN_LIST_SIZE);
    
    // Initialize domain store first
    domain_store_init();
    
    // Add all domains from the generated list
    for (int i = 0; i < DOMAIN_LIST_SIZE; i++) {
        if (domain_store_add(blacklisted_domains[i]) == 0) {
            printf("Added domain: %s\n", blacklisted_domains[i]);
        } else {
            printf("Failed to add domain: %s\n", blacklisted_domains[i]);
        }
    }
    
    printf("Domain store populated with %d domains\n", domain_store_get_count());
}

// Function: resolver_thread_func
// Purpose: Runs in a background thread. It is responsible for resolving domain names into IP addresses and updating
// the eBPF map with these IPs. It also prints updates when new IPs are detected.
static void *resolver_thread_func(void *data) {
    int *map_fd = (int *)data;    
    while (running) {
        // Initialize the domain store if it hasn't been already.
        if (domain_store_get_count() == 0) {
            domain_store_init();
        }
        
        // Resolve all domains and update the blacklist map with any new IPs.
        domain_store_resolve_all(*map_fd);

        // Update drop counts for all domains
        domain_store_update_drop_counts(*map_fd);
        
        // Write domain stats to file for dashboard
        domain_store_write_stats_file();
        
        // Sleep in intervals of 1 second for RESOLUTION_INTERVAL_SEC seconds.
        for (int i = 0; i < RESOLUTION_INTERVAL_SEC && running; i++) {
            sleep(1);  // sleep(): suspends execution for the given number of seconds.
        }
    }
    
    return NULL;
}

// Function: write_stats_to_file
// Purpose: Writes current statistics (total packets and blocked packets) to a temporary file. This file can be read by
// a dashboard to display live stats.
static void write_stats_to_file(void *data) {
    __u64 total, blocked;
    int *map_fd = (int *)data;
    get_stats(&total, &blocked);
    
    FILE *fp = fopen("/tmp/ebaf-stats.dat", "w");  // fopen(): opens a file for writing.
    if (fp) {
        fprintf(fp, "total: %llu\nblocked: %llu\n", total, blocked);
        fclose(fp);  // fclose(): closes the file pointer.
    }

    // Update drop counts for all domains
    domain_store_update_drop_counts(*map_fd);

    // Write domain stats to file for dashboard
    domain_store_write_stats_file();
}

// Main program: Entry point for the ad blocker
int main(int argc, char **argv) {
    const char *ifname = NULL;
    
    // Check command line arguments.
    if (argc > 2) {
        // More than one argument provided
        return 1;
    } else if (argc == 2) {
        // If interface is specified as an argument, use that.
        ifname = argv[1];
    } else {
        // Otherwise, try to determine the default interface.
        ifname = get_default_interface();
        
        if (!ifname) {
            // Could not determine a default interface.
            return 1;
        }
        
    }
    
    // Convert the interface name to its index.
    ifindex = if_nametoindex(ifname); // if_nametoindex(): returns the index of a network interface given its name.
    if (ifindex == 0) {
        // Invalid interface name or interface does not exist.
        return 1;
    }

    // Increase memory lock limit to support eBPF map creation.
    increase_memlock_limit();
    
    // Finds eBPF program object file path.
    // get_bpf_object_path() locates the compiled eBPF object file (.bpf.o). This file contains the eBPF bytecode,
    // maps definitions, and sections required by the kernel.
    char *bpf_obj_path = get_bpf_object_path(argv[0]);
    if (!bpf_obj_path) {
        printf("Failed to find the eBPF object file.");
        return 1;
    }
        
    // Open the eBPF object file using libbpf.
    // bpf_object__open_file() loads the BPF object file into memory and prepares it for verification and loading.
    obj = bpf_object__open_file(bpf_obj_path, NULL);
    if (libbpf_get_error(obj)) {
        printf("Failed to open the eBPF object file.");
        return 1;
    }
    
    // Load the eBPF program into the kernel.
    // bpf_object__load() triggers verification and loads the eBPF programs defined in the object file into the kernel.
    if (bpf_object__load(obj)) {
        printf("Failed to load BPF program");
        return 1;
    }
    
    // Find the specific XDP program by name from the eBPF object.
    // bpf_object__find_program_by_name() searches for the eBPF program (xdp_blocker) using its section name.
    struct bpf_program *prog = bpf_object__find_program_by_name(obj, "xdp_blocker");
    if (!prog) {
        printf("Failed to find XDP program");
        return 1;
    }
    
    int prog_fd = bpf_program__fd(prog); // bpf_program__fd() returns a file descriptor referencing the loaded program.
    
    // Retrieve file descriptors for the eBPF maps.
    // bpf_object__find_map_by_name() locates maps within the BPF object by their names.
    struct bpf_map *blacklist_ip_map = bpf_object__find_map_by_name(obj, "blacklist_ip_map");
    struct bpf_map *stats_map = bpf_object__find_map_by_name(obj, "stats_map");
    
    if (!blacklist_ip_map || !stats_map) {
        printf("Failed to find BPF maps");
        return 1;
    }
    
    blacklist_ip_map_fd = bpf_map__fd(blacklist_ip_map);
    stats_map_fd = bpf_map__fd(stats_map);

    // Populate the domain store with domains from the blacklist
    populate_domain_store();
    
    // Initialize statistics counters in the stats map.
    __u32 key;
    __u64 value = 0;
    
    key = STAT_TOTAL;
    // bpf_map_update_elem() updates an entry in an eBPF map. This call initializes the total packets counter.
    bpf_map_update_elem(stats_map_fd, &key, &value, BPF_ANY);
    
    key = STAT_BLOCKED;
    // This initializes the blocked packets counter.
    bpf_map_update_elem(stats_map_fd, &key, &value, BPF_ANY);
    
    // Load the static IP blacklist into the eBPF map.
    load_ip_blacklist();
    
    // Define various XDP attachment modes to try (different performance/compatibility trade-offs).
    int xdp_flags[] = {
        XDP_FLAGS_DRV_MODE,    // Native mode: best performance on supporting hardware.
        XDP_FLAGS_SKB_MODE,    // Generic mode: most compatible.
        0                      // Default mode.
    };
    
    const char *mode_names[] = {
        "native (DRV)",
        "generic (SKB)",
        "default"
    };
    
    // Attempt to attach the XDP program in different modes.
    int attached = 0;
    for (int i = 0; i < 3; i++) {
        printf("Trying XDP %s mode...\n", mode_names[i]);
        
        // bpf_xdp_attach() is an eBPF helper that attaches an XDP program to a network interface.
        if (bpf_xdp_attach(ifindex, prog_fd, xdp_flags[i], NULL) == 0) {
            attached = 1;
            break;
        }
        
        // Print error if the failure is not due to unsupported operation.
        if (errno != EOPNOTSUPP) {
            perror("XDP attach");
        }
    }
    
    if (!attached){
        printf("Could not attach XDP program to interface");
        return 1;
    }
    
    // Start the background thread for resolving domains into IP addresses.
    if (pthread_create(&resolver_thread, NULL, resolver_thread_func, &blacklist_ip_map_fd) != 0) {
        printf("Failed to start resolver thread");
        return 1;
    }
    
    // Set up signal handlers for graceful shutdown on SIGINT and SIGTERM.
    signal(SIGINT, cleanup);
    signal(SIGTERM, cleanup);
        
    time_t last_stats_write = 0;
    while (running) {
        sleep(1);
        time_t now = time(NULL);
        if (now - last_stats_write >= 2) {
            write_stats_to_file(&blacklist_ip_map_fd);
            last_stats_write = now;
        }
    }
    
    // Remove XDP program from the interface if the loop exits.
    bpf_xdp_detach(ifindex, 0, NULL);
    
    // Wait for the background resolver thread to finish.
    pthread_join(resolver_thread, NULL);
    
    // Clean up domain store before exit.
    domain_store_cleanup();
    
    return 0;
}