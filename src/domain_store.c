#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <bpf/bpf.h>
#include <pthread.h>

#include "adblocker.h"
#include "domain_store.h"

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
    // Set the initial resolution status and last_ip.
    domains[domain_count].status = RESOLUTION_FAILED;
    domains[domain_count].last_ip = 0;
    domain_count++;
    
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
        free(domains);
        domains = NULL;
        domain_count = 0;
    }
    pthread_mutex_unlock(&domain_mutex);
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
    
    // Loop through all returned IP addresses.
    for (int i = 0; addr_list[i] != NULL; i++) {
        // Get each IP address and convert from network to host byte order.
        *ip = ntohl(addr_list[i]->s_addr);
        
        // Prepare the key for the eBPF map: key must be in network byte order.
        __u32 key = htonl(*ip);
        __u64 value = 0;
        
        // bpf_map_update_elem(): update the map with the new IP.
        // BPF_ANY: flag to indicate the entry should be created if it doesn't exist.
        bpf_map_update_elem(map_fd, &key, &value, BPF_ANY);
    }
    
    // Return success if at least one IP was added to the map.
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