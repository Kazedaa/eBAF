#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <bpf/bpf.h>
#include <pthread.h>
#include <fnmatch.h>

#include "adblocker.h"
#include "resolver.h"

/*
    This file implements a simple domain store that keeps track of domains that need to be resolved
    into IP addresses. The resolved IPs are then updated into an eBPF map so that the kernel program
    can block traffic based on those IP addresses.

    Thread Safety:
    - A mutex (domain_mutex) is used to protect access to the domain store so that concurrent
      modifications (by adding/resolving domains) are safe.

    eBPF related concept:
    - bpf_map_update_elem(): This is an eBPF helper function that updates an element in a BPF map.
      We use it to add resolved IP addresses into the blacklist map.
*/

// The domain store array
static struct domain_entry *domains = NULL;
static int domain_count = 0;
static pthread_mutex_t domain_mutex = PTHREAD_MUTEX_INITIALIZER;

// Whitelist pattern storage
static char **whitelist_patterns = NULL;
static int whitelist_pattern_count = 0;
static pthread_mutex_t whitelist_mutex = PTHREAD_MUTEX_INITIALIZER;

// Initialize IP array for a domain entry
static void init_domain_ips(struct domain_entry *entry) {
    entry->resolved_ips = malloc(sizeof(__u32) * 4); // Start with capacity for 4 IPs
    entry->ip_capacity = 4;
    entry->ip_count = 0;
    entry->total_drops = 0;
}

// Add an IP to a domain's IP list
static int add_ip_to_domain(struct domain_entry *entry, __u32 ip) {
    // Check if IP already exists
    for (int i = 0; i < entry->ip_count; i++) {
        if (entry->resolved_ips[i] == ip) {
            return 0; // IP already exists
        }
    }
    
    // Expand array if needed
    if (entry->ip_count >= entry->ip_capacity) {
        entry->ip_capacity *= 2;
        entry->resolved_ips = realloc(entry->resolved_ips, sizeof(__u32) * entry->ip_capacity);
        if (!entry->resolved_ips) {
            return -1;
        }
    }
    
    entry->resolved_ips[entry->ip_count++] = ip;
    return 0;
}

// Initialize the domain store if not already created.
void domain_store_init(void) {
    pthread_mutex_lock(&domain_mutex);
    if (domains == NULL) {
        // calloc(): allocates and zero-initializes an array of MAX_DOMAINS domain_entry structures.
        domains = calloc(MAX_DOMAINS, sizeof(struct domain_entry));
        domain_count = 0;
    }
    pthread_mutex_unlock(&domain_mutex);
}

// Add a new domain to the store.
int domain_store_add(const char *domain) {
    if (!domains)
        return -1;
        
    pthread_mutex_lock(&domain_mutex);
    
    // Check if we already have this domain to avoid duplicates.
    for (int i = 0; i < domain_count; i++) {
        if (strcmp(domains[i].domain, domain) == 0) {
            pthread_mutex_unlock(&domain_mutex);
            return 0;  // Already exists
        }
    }
    
    // Check if we have space available.
    if (domain_count >= MAX_DOMAINS) {
        pthread_mutex_unlock(&domain_mutex);
        return -1;  // No space
    }
    
    // Add the new domain into the array.
    // strncpy(): copies up to DOMAIN_MAX_SIZE - 1 characters to ensure null-termination.
    strncpy(domains[domain_count].domain, domain, DOMAIN_MAX_SIZE - 1);
    domains[domain_count].domain[DOMAIN_MAX_SIZE - 1] = '\0';
    domain_count++;

    // Initialize the IP tracking for this new domain
    init_domain_ips(&domains[domain_count - 1]);
    
    pthread_mutex_unlock(&domain_mutex);
    return 0;
}

// Get the current count of domains stored.
int domain_store_get_count(void) {
    return domain_count;
}



// Cleanup the domain store and free allocated memory.
void domain_store_cleanup(void) {
    pthread_mutex_lock(&domain_mutex);
    if (domains) {
        // Cleanup existing domain store
        for (int i = 0; i < domain_count; i++) {
            if (domains[i].resolved_ips) {
                free(domains[i].resolved_ips);
            }
        }
        free(domains);
        domains = NULL;
        domain_count = 0;
    }
    pthread_mutex_unlock(&domain_mutex);
    
    // Cleanup whitelist patterns
    pthread_mutex_lock(&whitelist_mutex);
    if (whitelist_patterns) {
        for (int i = 0; i < whitelist_pattern_count; i++) {
            free(whitelist_patterns[i]);
        }
        free(whitelist_patterns);
        whitelist_patterns = NULL;
        whitelist_pattern_count = 0;
    }
    pthread_mutex_unlock(&whitelist_mutex);
}

/*
    Resolve a domain to IP addresses and update the eBPF map.

    Explanation of techniques used:
    - gethostbyname(): A legacy function to resolve a hostname to an IP address. It returns a hostent struct.
    - ntohl(): converts an IP address from network byte order to host byte order.
    - htonl(): converts an IP address from host byte order to network byte order. 
      The eBPF program requires IP keys in network byte order.
    - bpf_map_update_elem(): eBPF helper used to add/update an element in a BPF map.
*/
static int resolve_domain_to_ip(const char *domain, __u32 *ip, int map_fd) {
    struct hostent *he;
    struct in_addr **addr_list;
    
    he = gethostbyname(domain);
    if (he == NULL) {
        return -1;
    }
    
    addr_list = (struct in_addr **)he->h_addr_list;
    if (addr_list[0] == NULL) {
        return -1;
    }

    // Find the domain entry to update its IP list
    struct domain_entry *entry = NULL;
    for (int i = 0; i < domain_count; i++) {
        if (strcmp(domains[i].domain, domain) == 0) {
            entry = &domains[i];
            break;
        }
    }
    
    if (!entry) {
        return -1; // Domain not found in store
    }
    
    // Loop through all returned IP addresses.
    for (int i = 0; addr_list[i] != NULL; i++) {
        // Get each IP address and convert from network to host byte order.
        __u32 host_ip = ntohl(addr_list[i]->s_addr);
        *ip = host_ip;

        // Add IP to domain's IP list
        add_ip_to_domain(entry, host_ip);
        
        // Prepare the key for the eBPF map: key must be in network byte order.
        __u32 key = htonl(*ip);
        __u64 value = 0;
        
        // bpf_map_update_elem(): update the map with the new IP.
        // BPF_ANY: flag to indicate the entry should be created if it doesn't exist.
        bpf_map_update_elem(map_fd, &key, &value, BPF_ANY);
    }
    return 0;
}

// Resolve all domains stored, update the eBPF blacklist map, and count successful resolutions.
int domain_store_resolve_all(int map_fd) {
    __u32 ip;
    
    for (int i = 0; i < domain_count; i++) {
        resolve_domain_to_ip(domains[i].domain, &ip, map_fd);
    }
    
    return 0;
}

// Get total packet drops for a specific domain
__u64 domain_store_get_drops(const char *domain) {
    pthread_mutex_lock(&domain_mutex);
    
    for (int i = 0; i < domain_count; i++) {
        if (strcmp(domains[i].domain, domain) == 0) {
            __u64 drops = domains[i].total_drops;
            pthread_mutex_unlock(&domain_mutex);
            return drops;
        }
    }
    
    pthread_mutex_unlock(&domain_mutex);
    return 0; // Domain not found
}

// Update drop counts for all domains by reading from the BPF map
void domain_store_update_drop_counts(int map_fd) {
    pthread_mutex_lock(&domain_mutex);
    
    for (int i = 0; i < domain_count; i++) {
        struct domain_entry *entry = &domains[i];
        __u64 total_drops = 0;
        
        // Sum up drops from all IPs belonging to this domain
        for (int j = 0; j < entry->ip_count; j++) {
            __u32 key = htonl(entry->resolved_ips[j]); // Convert to network byte order
            __u64 drop_count = 0;  // Use actual variable, not pointer
            
            // Look up the drop count for this IP in the BPF map
            // bpf_map_lookup_elem expects: (map_fd, &key, &value_to_store_result)
            if (bpf_map_lookup_elem(map_fd, &key, &drop_count) == 0) {
                total_drops += drop_count;
            }
        }
        
        entry->total_drops = total_drops;
    }
    
    pthread_mutex_unlock(&domain_mutex);
}

// Write domain statistics to a file for the dashboard
void domain_store_write_stats_file(void) {
    const char *stats_file = "/tmp/ebaf-domain-stats.dat";    
    pthread_mutex_lock(&domain_mutex);    
    FILE *fp = fopen(stats_file, "w");
    if (!fp) {
        pthread_mutex_unlock(&domain_mutex);
        return;
    }
    
    // Write each domain and its drop count
    for (int i = 0; i < domain_count; i++) {
        if (domains[i].total_drops > 0) {
            fprintf(fp, "%s:%llu\n", domains[i].domain, domains[i].total_drops);
        }
    }
    
    fclose(fp);
    pthread_mutex_unlock(&domain_mutex);
}

// Function: whitelist_domain_matches
// Purpose: Check if a given domain matches any of the whitelist patterns
// Parameters:
//   - domain: The domain name to check (e.g., "api.spotify.com")
// Returns: 1 if match found, 0 if no match
// Note: Uses fnmatch() for wildcard support (*, ?, [])
// Thread-safe: Uses whitelist_mutex for protection
int whitelist_domain_matches(const char *domain) {
    pthread_mutex_lock(&whitelist_mutex);
    
    for (int i = 0; i < whitelist_pattern_count; i++) {
        // fnmatch(): Pattern matching function that supports wildcards
        // Use 0 for basic pattern matching without special flags
        if (fnmatch(whitelist_patterns[i], domain, 0) == 0) {
            pthread_mutex_unlock(&whitelist_mutex);
            return 1; // Match found - domain matches this pattern
        }
    }
    
    pthread_mutex_unlock(&whitelist_mutex);
    return 0; // No match found
}

// Function: load_whitelist_patterns
// Purpose: Load whitelist patterns from configuration file
// Returns: 0 on success, -1 on error
// Note: This is a helper function called by whitelist_resolver_init
static int load_whitelist_patterns(void) {
    // Try multiple locations for the whitelist file
    const char *whitelist_paths[] = {
        "spotify-whitelist.txt",                           // Current directory (development)
        "/usr/local/share/ebaf/spotify-whitelist.txt",     // System installation
    };
    
    FILE *fp = NULL;
    int i = 0;
    
    // Try each path until we find the file
    while (whitelist_paths[i] != NULL) {
        fp = fopen(whitelist_paths[i], "r");
        if (fp != NULL) {
            printf("Loading whitelist from: %s\n", whitelist_paths[i]);
            break;
        }
        i++;
    }
    
    if (!fp) {
        printf("Warning: No whitelist file found in any of the expected locations\n");
        return -1;
    }
    
    // Allocate memory for storing whitelist patterns
    char line[512];
    whitelist_patterns = malloc(sizeof(char*) * 1000); // Max 1000 patterns
    whitelist_pattern_count = 0;
    
    // Load all patterns from whitelist file
    while (fgets(line, sizeof(line), fp) && whitelist_pattern_count < 1000) {
        // Extract domain from line, skip comments and empty lines
        char *domain = strtok(line, " \t\n#");
        if (!domain || domain[0] == '#') continue;  // Skip comments and empty lines
        
        // Store the pattern in our array
        whitelist_patterns[whitelist_pattern_count] = strdup(domain);  // strdup(): allocate and copy string
        whitelist_pattern_count++;
    }
    fclose(fp);
    
    printf("Loaded %d whitelist patterns\n", whitelist_pattern_count);
    return 0;
}

// Function: whitelist_resolver_init
// Purpose: Initialize the whitelist resolver system
// Parameters:
//   - whitelist_map_fd: File descriptor for the eBPF whitelist map
// This function loads whitelist patterns and performs initial resolution
void whitelist_resolver_init(int whitelist_map_fd) {
    pthread_mutex_lock(&whitelist_mutex);
    
    // Load whitelist patterns from file
    if (load_whitelist_patterns() != 0) {
        pthread_mutex_unlock(&whitelist_mutex);
        return;
    }
    
    pthread_mutex_unlock(&whitelist_mutex);
    
    // Perform initial whitelist resolution
    whitelist_resolver_update(whitelist_map_fd);
}

// Function: whitelist_resolver_update
// Purpose: Resolve whitelisted domains and patterns to IP addresses, then add those IPs to the whitelist map
// This ensures that even if a whitelisted domain resolves to an IP that's in the blacklist,
// the resolved IP will be protected from blocking
// Parameters:
//   - whitelist_map_fd: File descriptor for the eBPF whitelist map
// Algorithm:
//   1. Check each blacklisted domain against whitelist patterns
//   2. Resolve matching domains and add their IPs to whitelist
//   3. Also resolve explicit (non-wildcard) domains from whitelist
void whitelist_resolver_update(int whitelist_map_fd) {    
    // Step 1: Check blacklisted domains against whitelist patterns
    // This handles the case where a blacklisted domain actually matches a whitelist pattern
    printf("Resolving whitelisted domains and patterns...\n");
    
    if (!whitelist_patterns || whitelist_pattern_count == 0) {
        printf("Warning: No whitelist patterns loaded\n");
        return;
    }
    
    pthread_mutex_lock(&whitelist_mutex);
    
    // Step 1: Check blacklisted domains against whitelist patterns
    // Try multiple locations for the blacklist file
    const char *blacklist_paths[] = {
        "spotify-blacklist.txt",                           // Current directory (development)
        "/usr/local/share/ebaf/spotify-blacklist.txt",     // System installation
        NULL
    };
    
    FILE *fp = NULL;
    int i = 0;
    
    // Try each path until we find the file
    while (blacklist_paths[i] != NULL) {
        fp = fopen(blacklist_paths[i], "r");
        if (fp != NULL) {
            break;
        }
        i++;
    }
    
    if (!fp) {
        printf("Warning: Could not open blacklist file for pattern matching\n");
        pthread_mutex_unlock(&whitelist_mutex);
        return;
    }
    
    char line[512];
    int whitelisted_count = 0;
    
    while (fgets(line, sizeof(line), fp)) {
        char *domain = strtok(line, " \t\n#");
        if (!domain || domain[0] == '#') continue;  // Skip comments and empty lines
        
        // Check if this blacklisted domain matches any whitelist pattern
        // Note: We need to check without mutex since whitelist_domain_matches uses its own locking
        int matches = 0;
        for (int i = 0; i < whitelist_pattern_count; i++) {
            if (fnmatch(whitelist_patterns[i], domain, 0) == 0) {
                matches = 1;
                break;
            }
        }
        
        if (matches) {
            // This blacklisted domain matches a whitelist pattern - resolve it and protect its IPs
            struct hostent *he = gethostbyname(domain);  // gethostbyname(): resolve domain to IP(s)
            if (he && he->h_addrtype == AF_INET) {       // Check if resolution successful and IPv4
                struct in_addr **addr_list = (struct in_addr **)he->h_addr_list;
                
                // Process all IP addresses for this domain
                for (int i = 0; addr_list[i]; i++) {
                    __u32 ip = addr_list[i]->s_addr;  // IP already in network byte order
                    __u64 value = 1;                   // Simple existence marker
                    
                    // Add IP to whitelist map in kernel
                    if (bpf_map_update_elem(whitelist_map_fd, &ip, &value, BPF_ANY) == 0) {
                        printf("Whitelisted IP %s from domain %s\n", 
                               inet_ntoa(*addr_list[i]), domain);
                        whitelisted_count++;
                    }
                }
            }
        }
    }
    fclose(fp);
    
    // Step 2: Resolve explicit domains from whitelist (non-wildcard patterns)
    // These are exact domain names without wildcards that should be directly resolved
    for (int i = 0; i < whitelist_pattern_count; i++) {
        if (strchr(whitelist_patterns[i], '*') == NULL) {
            // No wildcard found - this is an explicit domain, resolve it directly
            struct hostent *he = gethostbyname(whitelist_patterns[i]);
            if (he && he->h_addrtype == AF_INET) {
                struct in_addr **addr_list = (struct in_addr **)he->h_addr_list;
                
                // Add all resolved IPs to whitelist
                for (int j = 0; addr_list[j]; j++) {
                    __u32 ip = addr_list[j]->s_addr;  // Network byte order
                    __u64 value = 1;
                    
                    if (bpf_map_update_elem(whitelist_map_fd, &ip, &value, BPF_ANY) == 0) {
                        printf("Whitelisted IP %s from explicit domain %s\n", 
                               inet_ntoa(*addr_list[j]), whitelist_patterns[i]);
                        whitelisted_count++;
                    }
                }
            }
        }
    }
    
    pthread_mutex_unlock(&whitelist_mutex);
    printf("Total whitelisted IPs: %d\n", whitelisted_count);
}