#ifndef RESOLVER_H
#define RESOLVER_H

#include <linux/in6.h>
#include "adblocker.h"

struct domain_entry {
    char domain[DOMAIN_MAX_SIZE];
    __u64 total_drops;
    
    // IPv4 tracking
    __u32 *resolved_ipv4;
    int ipv4_count;
    int ipv4_capacity;
    
    // IPv6 tracking
    struct in6_addr *resolved_ipv6;
    int ipv6_count;
    int ipv6_capacity;
};

void domain_store_init(void);
int domain_store_add(const char *domain);
int domain_store_get_count(void);

// Now takes both IPv4 and IPv6 map FDs
int domain_store_resolve_all(int map_fd_v4, int map_fd_v6);

__u64 domain_store_get_drops(const char *domain);
void domain_store_update_drop_counts(int map_fd_v4, int map_fd_v6);
void domain_store_cleanup(void);
void domain_store_write_stats_file(void);

void whitelist_resolver_init(int whitelist_map_fd_v4, int whitelist_map_fd_v6);
void whitelist_resolver_update(int whitelist_map_fd_v4, int whitelist_map_fd_v6);
int whitelist_domain_matches(const char *domain);

#endif // RESOLVER_H