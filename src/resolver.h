#ifndef RESOLVER_H
#define RESOLVER_H

#include "adblocker.h"  // Includes shared definitions and constants, e.g., DOMAIN_MAX_SIZE

// Structure to store domain information for periodic resolution.
// Each domain may be re-resolved, and the resolved IPs are updated into the eBPF map.
// The eBPF map uses these IPs to decide if a packet should be blocked.
struct domain_entry {
    char domain[DOMAIN_MAX_SIZE];  // Holds the domain name string.
    __u64 total_drops;  // Total packet drops for this domain
    __u32 *resolved_ips;  // Array of all resolved IPs for this domain
    int ip_count;  // Number of resolved IPs
    int ip_capacity;  // Current capacity of the resolved IPs array
};

/* Interesting Note : Why do we need an ip_capacity when we have an ip_count?*/
/* Can we not create more space as we go? Well although it is memory effecient, it is actually unneccasarily complex
we will have to call realloc every single time we need to add an ip, which would involve finding a contiguous block of memory
moreover this would create more fragmentation which is not memory effecient either */

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

// Get drop count for a specific domain
__u64 domain_store_get_drops(const char *domain);

// Update drop counts for all domains by reading from the BPF map
void domain_store_update_drop_counts(int map_fd);

// Clean up resources allocated for the domain store.
void domain_store_cleanup(void);

// Write domain statistics to a file for the dashboard
void domain_store_write_stats_file(void);

// Whitelist-related functions
// Initialize whitelist resolver - loads patterns and resolves initial IPs
void whitelist_resolver_init(int whitelist_map_fd);

// Resolve whitelisted domains and add their IPs to whitelist map
// Handles both explicit domains and wildcard patterns
void whitelist_resolver_update(int whitelist_map_fd);

// Check if a domain matches any whitelist pattern
int whitelist_domain_matches(const char *domain);

#endif // DOMAIN_STORE_H