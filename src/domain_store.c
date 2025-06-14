#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <bpf/bpf.h>
#include <pthread.h>

#include "adblocker.h"
#include "domain_store.h"

// The domain store array
static struct domain_entry *domains = NULL;
static int domain_count = 0;
static pthread_mutex_t domain_mutex = PTHREAD_MUTEX_INITIALIZER;

void domain_store_init(void) {
    pthread_mutex_lock(&domain_mutex);
    if (domains == NULL) {
        domains = calloc(MAX_DOMAINS, sizeof(struct domain_entry));
        domain_count = 0;
    }
    pthread_mutex_unlock(&domain_mutex);
}

int domain_store_add(const char *domain) {
    if (!domains)
        return -1;
        
    pthread_mutex_lock(&domain_mutex);
    
    // Check if we already have this domain
    for (int i = 0; i < domain_count; i++) {
        if (strcmp(domains[i].domain, domain) == 0) {
            pthread_mutex_unlock(&domain_mutex);
            return 0;  // Already exists
        }
    }
    
    // Check if we have space
    if (domain_count >= MAX_DOMAINS) {
        pthread_mutex_unlock(&domain_mutex);
        return -1;  // No space
    }
    
    // Add the new domain
    strncpy(domains[domain_count].domain, domain, DOMAIN_MAX_SIZE - 1);
    domains[domain_count].domain[DOMAIN_MAX_SIZE - 1] = '\0';
    domains[domain_count].status = RESOLUTION_FAILED;
    domains[domain_count].last_ip = 0;
    domain_count++;
    
    pthread_mutex_unlock(&domain_mutex);
    return 0;
}

int domain_store_size(void) {
    return domain_count;
}

// Resolve a domain to IPs and update the map
static int resolve_domain(const char *domain, int map_fd, __u32 *ip) {
    struct hostent *he;
    struct in_addr **addr_list;
    int success = 0;
    
    he = gethostbyname(domain);
    if (he == NULL) {
        return -1;
    }
    
    addr_list = (struct in_addr **)he->h_addr_list;
    if (addr_list[0] == NULL) {
        return -1;
    }
    
    // Loop through all returned IP addresses
    for (int i = 0; addr_list[i] != NULL; i++) {
        // Get each IP address
        *ip = ntohl(addr_list[i]->s_addr);
        
        // Update the map (the key needs to be in network byte order for the eBPF program)
        __u32 key = htonl(*ip);
        __u8 value = 1;
        
        // Add to the blacklist map
        if (bpf_map_update_elem(map_fd, &key, &value, BPF_ANY) == 0) {
            success++;
        }
    }
    
    // Return success if at least one IP was added
    return (success > 0) ? 0 : -1;
}

int domain_store_resolve_all(int map_fd) {
    int total_success = 0;
    int domains_resolved = 0;
    __u32 ip;
    
    pthread_mutex_lock(&domain_mutex);
    
    for (int i = 0; i < domain_count; i++) {
        if (resolve_domain(domains[i].domain, map_fd, &ip) == 0) {
            domains[i].status = RESOLUTION_SUCCESS;
            domains[i].last_ip = ip;  // Store just the last one for status tracking
            domains_resolved++;
        } else {
            domains[i].status = RESOLUTION_FAILED;
        }
    }
    
    pthread_mutex_unlock(&domain_mutex);
    return domains_resolved;
}

void domain_store_cleanup(void) {
    pthread_mutex_lock(&domain_mutex);
    if (domains) {
        free(domains);
        domains = NULL;
    }
    domain_count = 0;
    pthread_mutex_unlock(&domain_mutex);
}