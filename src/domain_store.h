#ifndef DOMAIN_STORE_H
#define DOMAIN_STORE_H

#include <linux/types.h>

// Structure to store domain information for periodic resolution
struct domain_entry {
    char domain[DOMAIN_MAX_SIZE];
    int status;  // 0=success, 1=failed
    __u32 last_ip;
};

// Initialize the domain store
void domain_store_init(void);

// Add a domain to the store
int domain_store_add(const char *domain);

// Get the number of stored domains
int domain_store_size(void);

// Resolve all domains in the store and update the BPF map (handles multiple IPs per domain)
int domain_store_resolve_all(int map_fd);

// Clean up resources
void domain_store_cleanup(void);

#endif // DOMAIN_STORE_H