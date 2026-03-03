#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <net/if.h>
#include <linux/if_link.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>

#include "adblocker.h"
#include "resolver.h"

// Globals for cleanup
static int ifindex = 0;
static __u32 xdp_flags = XDP_FLAGS_UPDATE_IF_NOEXIST | XDP_FLAGS_SKB_MODE;
static struct bpf_object *obj = NULL;
static int prog_fd = -1;

// Graceful exit handler
static void cleanup(int sig) {
    printf("\n[eBAF] Detaching eBPF program and cleaning up...\n");
    if (ifindex > 0 && prog_fd > 0) {
        bpf_xdp_detach(ifindex, xdp_flags, NULL);    }
    if (obj) {
        bpf_object__close(obj);
    }
    domain_store_cleanup();
    exit(0);
}

// Runtime file reader
static int load_blacklist_domains(void) {
    const char *blacklist_paths[] = {
        "spotify-blacklist.txt",
        "/usr/local/share/ebaf/spotify-blacklist.txt",
        NULL
    };
    
    FILE *fp = NULL;
    int i = 0;
    while (blacklist_paths[i] != NULL) {
        fp = fopen(blacklist_paths[i], "r");
        if (fp != NULL) break;
        i++;
    }
    
    if (!fp) {
        fprintf(stderr, "[eBAF] Error: Could not find spotify-blacklist.txt\n");
        return -1;
    }
    
    char line[512];
    int count = 0;
    while (fgets(line, sizeof(line), fp)) {
        // Strip whitespace, newlines, and ignore comments
        char *domain = strtok(line, " \t\n\r#");
        if (!domain || domain[0] == '#') continue;
        
        if (domain_store_add(domain) == 0) {
            count++;
        }
    }
    fclose(fp);
    printf("[eBAF] Loaded %d domains from blacklist.\n", count);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <interface_name>\n", argv[0]);
        return 1;
    }

    // Get the interface index from the name passed by the shell script
    const char *ifname = argv[1];
    ifindex = if_nametoindex(ifname);
    if (ifindex == 0) {
        fprintf(stderr, "[eBAF] Error: Invalid interface name '%s'\n", ifname);
        return 1;
    }

    // Setup signal traps for Ctrl+C and systemd stop
    signal(SIGINT, cleanup);
    signal(SIGTERM, cleanup);

    // 1. Load the eBPF object file compiled by Clang
    obj = bpf_object__open_file("/usr/local/share/ebaf/adblocker.bpf.o", NULL);
    if (libbpf_get_error(obj)) {
        // Fallback to local directory if not installed system-wide
        obj = bpf_object__open_file("bin/adblocker.bpf.o", NULL);
        if (libbpf_get_error(obj)) {
            fprintf(stderr, "[eBAF] Failed to open BPF object (adblocker.bpf.o)\n");
            return 1;
        }
    }

    if (bpf_object__load(obj)) {
        fprintf(stderr, "[eBAF] Failed to load BPF object into kernel\n");
        return 1;
    }

    struct bpf_program *prog = bpf_object__find_program_by_name(obj, "xdp_blocker");
    prog_fd = bpf_program__fd(prog);

    // 2. Attach the XDP program to the network interface
if (bpf_xdp_attach(ifindex, prog_fd, xdp_flags, NULL) < 0) {        fprintf(stderr, "[eBAF] Failed to attach XDP program to %s. Are you running as root?\n", ifname);
        cleanup(0);
    }
    printf("[eBAF] Successfully attached eBPF firewall to %s\n", ifname);

    // 3. Retrieve the File Descriptors (FDs) for our new IPv4 and IPv6 maps
    int bl_v4_fd = bpf_object__find_map_fd_by_name(obj, "blacklist_ip_map");
    int bl_v6_fd = bpf_object__find_map_fd_by_name(obj, "blacklist_ipv6_map");
    int wl_v4_fd = bpf_object__find_map_fd_by_name(obj, "whitelist_ip_map");
    int wl_v6_fd = bpf_object__find_map_fd_by_name(obj, "whitelist_ipv6_map");
    int stats_fd = bpf_object__find_map_fd_by_name(obj, "stats_map");

    if (bl_v4_fd < 0 || bl_v6_fd < 0 || stats_fd < 0) {
        fprintf(stderr, "[eBAF] Error: Failed to find BPF maps in kernel\n");
        cleanup(0);
    }

    // 4. Initialize Domains and Resolve IP addresses (Both IPv4 and IPv6!)
    domain_store_init();
    load_blacklist_domains();
    whitelist_resolver_init(wl_v4_fd, wl_v6_fd);
    
    printf("[eBAF] Resolving domains and pushing addresses to kernel...\n");
    domain_store_resolve_all(bl_v4_fd, bl_v6_fd);
    
    printf("[eBAF] Firewall is active and monitoring traffic.\n");

    // 5. Main loop: Fetch stats from kernel and write to the dashboard data files
    while (1) {
        sleep(2); // Tick every 2 seconds
        
        __u32 total_key = 0; // STAT_TOTAL
        __u32 blocked_key = 1; // STAT_BLOCKED
        __u64 total_pkts = 0;
        __u64 blocked_pkts = 0;
        
        // Read stats from kernel
        bpf_map_lookup_elem(stats_fd, &total_key, &total_pkts);
        bpf_map_lookup_elem(stats_fd, &blocked_key, &blocked_pkts);

        // Write to /tmp for Python dashboard
        FILE *f = fopen("/tmp/ebaf-stats.dat", "w");
        if (f) {
            fprintf(f, "Total:%llu\nBlocked:%llu\n", total_pkts, blocked_pkts);
            fclose(f);
        }

        // Update specific domain drop counts
        domain_store_update_drop_counts(bl_v4_fd, bl_v6_fd);
        domain_store_write_stats_file();
    }

    return 0;
}