#ifndef DOMAIN_STORE_H
#define DOMAIN_STORE_H

#include "adblocker.h"  // Includes shared definitions and constants, e.g., DOMAIN_MAX_SIZE

// Structure to store domain information for periodic resolution.
// Each domain may be re-resolved, and the resolved IPs are updated into the eBPF map.
// The eBPF map uses these IPs to decide if a packet should be blocked.
struct domain_entry {
    char domain[DOMAIN_MAX_SIZE];  // Holds the domain name string.
    int status;  // Resolution status: 0 = success, 1 = failed. Used to track if the domain resolved correctly.
    __u32 last_ip;  // The last successfully resolved IP address (stored as an unsigned 32-bit integer).
};

// Initialize the domain store.
// Typically allocates memory for a fixed-size array of domain_entry structures.
void domain_store_init(void);

// Add a domain to the store.
// Returns 0 if successful or if the domain already exists, otherwise an error code.
int domain_store_add(const char *domain);

// Get the number of stored domains.
// Useful for iterating on the domain store in order to update eBPF maps with resolved IP addresses.
int domain_store_get_count(void);  // Declaration to retrieve the count of domains

// Resolve all domains in the store and update the BPF map (handles multiple IPs per domain).
// The updated IPs are inserted into an eBPF map, which the kernel program uses for filtering.
int domain_store_resolve_all(int map_fd);

// Clean up resources allocated for the domain store.
void domain_store_cleanup(void);

#endif // DOMAIN_STORE_H