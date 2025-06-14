#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <signal.h>
#include <net/if.h>
#include <linux/if_link.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>  // Required for struct addrinfo
#include <libgen.h>

#include <bpf/libbpf.h>
#include <bpf/bpf.h>

#include "adblocker.h"

static int ifindex;
static struct bpf_object *obj;
static int blacklist_ip_map_fd;
static int stats_map_fd;

static void print_ips(void) {
    printf("\nCurrently blocked IPs:\n");
    
    // Create a temporary socket for ioctls
    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) {
        perror("socket");
        return;
    }
    
    // Get all keys and values from IP map
    __u32 key, next_key;
    __u8 value;
    int count = 0;
    
    if (bpf_map_get_next_key(blacklist_ip_map_fd, NULL, &key) == 0) {
        do {
            if (bpf_map_lookup_elem(blacklist_ip_map_fd, &key, &value) == 0) {
                struct in_addr addr;
                addr.s_addr = key;
                printf("  %s\n", inet_ntoa(addr));
                count++;
            }
        } while (bpf_map_get_next_key(blacklist_ip_map_fd, &key, &next_key) == 0 && 
                (key = next_key));
    }
    
    printf("Total blocked IPs: %d\n", count);
    close(sock);
}

static void cleanup(int sig) {
    (void)sig;  // Mark parameter as used to avoid warning
    printf("\nRemoving XDP program from interface %d\n", ifindex);
    bpf_xdp_detach(ifindex, 0, NULL);
    exit(0);
}

static void list_interfaces(void) {
    printf("Available network interfaces:\n");
    
    FILE *fp = popen("ip -o link show | awk -F': ' '{print $2}'", "r");
    if (fp == NULL) {
        printf("  Failed to get interface list\n");
        return;
    }
    
    char iface[64];
    while (fgets(iface, sizeof(iface), fp) != NULL) {
        iface[strcspn(iface, "\n")] = 0;
        if (strcmp(iface, "lo") != 0)
            printf("  %s\n", iface);
    }
    pclose(fp);
}

static char *get_bpf_object_path(const char *progname) {
    static char path[256];
    
    // Try different paths for object file
    if (access("./obj/adblocker.bpf.o", F_OK) != -1) {
        snprintf(path, sizeof(path), "./obj/adblocker.bpf.o");
        return path;
    }
    
    char *dir = dirname(strdup(progname));
    snprintf(path, sizeof(path), "%s/../obj/adblocker.bpf.o", dir);
    if (access(path, F_OK) != -1)
        return path;
    
    snprintf(path, sizeof(path), "%s/adblocker.bpf.o", dir);
    if (access(path, F_OK) != -1)
        return path;
    
    snprintf(path, sizeof(path), "/usr/local/bin/adblocker.bpf.o");
    if (access(path, F_OK) != -1)
        return path;
    
    return NULL;
}

static int resolve_and_add_ip(const char *domain_or_ip) {
    struct in_addr addr;
    
    // Check if it's already an IP
    if (inet_pton(AF_INET, domain_or_ip, &addr) == 1) {
        __u8 value = 1;
        __u32 ip = addr.s_addr;
        
        if (bpf_map_update_elem(blacklist_ip_map_fd, &ip, &value, BPF_ANY) == 0) {
            printf("Added IP to blacklist: %s\n", domain_or_ip);
            return 1;
        } else {
            fprintf(stderr, "Failed to add IP to blacklist: %s\n", domain_or_ip);
            return 0;
        }
    }
    
    // Try to resolve as domain name
    struct addrinfo hints, *result, *rp;
    int count = 0;
    __u8 value = 1;
    
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_INET; // IPv4 only
    hints.ai_socktype = SOCK_STREAM;
    
    int status = getaddrinfo(domain_or_ip, NULL, &hints, &result);
    if (status != 0) {
        fprintf(stderr, "Failed to resolve %s: %s\n", domain_or_ip, gai_strerror(status));
        return 0;
    }
    
    for (rp = result; rp != NULL; rp = rp->ai_next) {
        struct sockaddr_in *addr_in = (struct sockaddr_in *)rp->ai_addr;
        __u32 ip = addr_in->sin_addr.s_addr;
        
        char ip_str[INET_ADDRSTRLEN];
        inet_ntop(AF_INET, &ip, ip_str, INET_ADDRSTRLEN);
        
        if (bpf_map_update_elem(blacklist_ip_map_fd, &ip, &value, BPF_ANY) == 0) {
            printf("  Added IP: %s -> %s\n", domain_or_ip, ip_str);
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
        
        printf("Processing: %s\n", line);
        ip_count += resolve_and_add_ip(line);
    }
    
    fclose(file);
    printf("\nLoaded %d IP addresses into blacklist\n", ip_count);
    return ip_count;
}

static void print_stats(void) {
    __u32 key;
    __u64 total, blocked;
    
    key = STAT_TOTAL;
    if (bpf_map_lookup_elem(stats_map_fd, &key, &total) != 0)
        total = 0;
    
    key = STAT_BLOCKED;
    if (bpf_map_lookup_elem(stats_map_fd, &key, &blocked) != 0)
        blocked = 0;
    
    printf("Total packets: %llu, Blocked packets: %llu\n", total, blocked);
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "Usage: %s <interface> <blacklist_file>\n", argv[0]);
        fprintf(stderr, "\n");
        list_interfaces();
        return 1;
    }
    
    const char *ifname = argv[1];
    const char *blacklist_file = argv[2];
    
    ifindex = if_nametoindex(ifname);
    if (ifindex == 0) {
        fprintf(stderr, "Invalid interface: %s\n", ifname);
        fprintf(stderr, "\n");
        list_interfaces();
        return 1;
    }
    
    // Load eBPF program
    char *bpf_obj_path = get_bpf_object_path(argv[0]);
    if (!bpf_obj_path) {
        fprintf(stderr, "Failed to find adblocker.bpf.o file. Make sure to run 'make' first.\n");
        return 1;
    }
    
    printf("Loading BPF object: %s\n", bpf_obj_path);
    obj = bpf_object__open_file(bpf_obj_path, NULL);
    if (libbpf_get_error(obj)) {
        fprintf(stderr, "Failed to open BPF object file\n");
        return 1;
    }
    
    if (bpf_object__load(obj)) {
        fprintf(stderr, "Failed to load BPF object\n");
        return 1;
    }
    
    struct bpf_program *prog = bpf_object__find_program_by_name(obj, "xdp_blocker");
    if (!prog) {
        fprintf(stderr, "Failed to find XDP program\n");
        return 1;
    }
    
    int prog_fd = bpf_program__fd(prog);
    
    // Get map file descriptors
    struct bpf_map *blacklist_ip_map = bpf_object__find_map_by_name(obj, "blacklist_ip_map");
    struct bpf_map *stats_map = bpf_object__find_map_by_name(obj, "stats_map");
    
    if (!blacklist_ip_map || !stats_map) {
        fprintf(stderr, "Failed to find BPF maps\n");
        return 1;
    }
    
    blacklist_ip_map_fd = bpf_map__fd(blacklist_ip_map);
    stats_map_fd = bpf_map__fd(stats_map);
    
    // Initialize stats
    __u32 key;
    __u64 value = 0;
    
    key = STAT_TOTAL;
    bpf_map_update_elem(stats_map_fd, &key, &value, BPF_ANY);
    
    key = STAT_BLOCKED;
    bpf_map_update_elem(stats_map_fd, &key, &value, BPF_ANY);
    
    // Load blacklist
    if (load_blacklist(blacklist_file) <= 0) {
        fprintf(stderr, "Error: No valid IPs loaded. Check the blacklist file.\n");
        return 1;
    }
    
    // Print loaded IPs
    print_ips();
    
    // Try different XDP modes in order of preference
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
    
    if (!attached) {
        fprintf(stderr, "Failed to attach XDP program in any mode\n");
        fprintf(stderr, "Make sure you have sufficient privileges (run as root)\n");
        return 1;
    }
    
    printf("eBPF traffic blocker attached to %s\n", ifname);
    printf("Press Ctrl+C to stop\n");
    
    signal(SIGINT, cleanup);
    signal(SIGTERM, cleanup);
    
    // Print stats every 1 second
    while (1) {
        sleep(1);
        print_stats();
    }
    
    return 0;
}
