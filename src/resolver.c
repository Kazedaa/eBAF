#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <bpf/bpf.h>
#include <pthread.h>
#include <fnmatch.h>
#include <linux/in6.h>

#include "adblocker.h"
#include "resolver.h"

static struct domain_entry *domains = NULL;
static int domain_count = 0;
static pthread_mutex_t domain_mutex = PTHREAD_MUTEX_INITIALIZER;

static char **whitelist_patterns = NULL;
static int whitelist_pattern_count = 0;
static pthread_mutex_t whitelist_mutex = PTHREAD_MUTEX_INITIALIZER;

static void init_domain_ips(struct domain_entry *entry) {
    entry->resolved_ipv4 = malloc(sizeof(__u32) * 4);
    entry->ipv4_capacity = 4;
    entry->ipv4_count = 0;
    
    entry->resolved_ipv6 = malloc(sizeof(struct in6_addr) * 4);
    entry->ipv6_capacity = 4;
    entry->ipv6_count = 0;
    
    entry->total_drops = 0;
}

static int add_ipv4_to_domain(struct domain_entry *entry, __u32 ip) {
    for (int i = 0; i < entry->ipv4_count; i++) {
        if (entry->resolved_ipv4[i] == ip) return 0;
    }
    if (entry->ipv4_count >= entry->ipv4_capacity) {
        entry->ipv4_capacity *= 2;
        entry->resolved_ipv4 = realloc(entry->resolved_ipv4, sizeof(__u32) * entry->ipv4_capacity);
    }
    entry->resolved_ipv4[entry->ipv4_count++] = ip;
    return 0;
}

static int add_ipv6_to_domain(struct domain_entry *entry, struct in6_addr ip) {
    for (int i = 0; i < entry->ipv6_count; i++) {
        if (memcmp(&entry->resolved_ipv6[i], &ip, sizeof(struct in6_addr)) == 0) return 0;
    }
    if (entry->ipv6_count >= entry->ipv6_capacity) {
        entry->ipv6_capacity *= 2;
        entry->resolved_ipv6 = realloc(entry->resolved_ipv6, sizeof(struct in6_addr) * entry->ipv6_capacity);
    }
    entry->resolved_ipv6[entry->ipv6_count++] = ip;
    return 0;
}

void domain_store_init(void) {
    pthread_mutex_lock(&domain_mutex);
    if (domains == NULL) {
        domains = calloc(MAX_DOMAINS, sizeof(struct domain_entry));
        domain_count = 0;
    }
    pthread_mutex_unlock(&domain_mutex);
}

int domain_store_add(const char *domain) {
    if (!domains) return -1;
    pthread_mutex_lock(&domain_mutex);
    for (int i = 0; i < domain_count; i++) {
        if (strcmp(domains[i].domain, domain) == 0) {
            pthread_mutex_unlock(&domain_mutex);
            return 0;
        }
    }
    if (domain_count >= MAX_DOMAINS) {
        pthread_mutex_unlock(&domain_mutex);
        return -1;
    }
    strncpy(domains[domain_count].domain, domain, DOMAIN_MAX_SIZE - 1);
    domains[domain_count].domain[DOMAIN_MAX_SIZE - 1] = '\0';
    domain_count++;
    init_domain_ips(&domains[domain_count - 1]);
    pthread_mutex_unlock(&domain_mutex);
    return 0;
}

int domain_store_get_count(void) { return domain_count; }

void domain_store_cleanup(void) {
    pthread_mutex_lock(&domain_mutex);
    if (domains) {
        for (int i = 0; i < domain_count; i++) {
            if (domains[i].resolved_ipv4) free(domains[i].resolved_ipv4);
            if (domains[i].resolved_ipv6) free(domains[i].resolved_ipv6);
        }
        free(domains);
        domains = NULL;
        domain_count = 0;
    }
    pthread_mutex_unlock(&domain_mutex);
    
    pthread_mutex_lock(&whitelist_mutex);
    if (whitelist_patterns) {
        for (int i = 0; i < whitelist_pattern_count; i++) free(whitelist_patterns[i]);
        free(whitelist_patterns);
        whitelist_patterns = NULL;
        whitelist_pattern_count = 0;
    }
    pthread_mutex_unlock(&whitelist_mutex);
}

static int resolve_domain_to_ip(const char *domain, int map_fd_v4, int map_fd_v6) {
    struct addrinfo hints, *res, *p;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC; // Allow IPv4 or IPv6
    hints.ai_socktype = SOCK_STREAM;

    if (getaddrinfo(domain, NULL, &hints, &res) != 0) {
        return -1;
    }

    struct domain_entry *entry = NULL;
    for (int i = 0; i < domain_count; i++) {
        if (strcmp(domains[i].domain, domain) == 0) {
            entry = &domains[i];
            break;
        }
    }
    if (!entry) {
        freeaddrinfo(res);
        return -1;
    }
    
    __u64 value = 0;

    for(p = res; p != NULL; p = p->ai_next) {
        if (p->ai_family == AF_INET) {
            struct sockaddr_in *ipv4 = (struct sockaddr_in *)p->ai_addr;
            __u32 ip = ipv4->sin_addr.s_addr; // Already in network byte order
            add_ipv4_to_domain(entry, ip);
            bpf_map_update_elem(map_fd_v4, &ip, &value, BPF_ANY);
        } else if (p->ai_family == AF_INET6) {
            struct sockaddr_in6 *ipv6 = (struct sockaddr_in6 *)p->ai_addr;
            struct in6_addr ip6 = ipv6->sin6_addr; // Already in network byte order
            add_ipv6_to_domain(entry, ip6);
            bpf_map_update_elem(map_fd_v6, &ip6, &value, BPF_ANY);
        }
    }
    
    freeaddrinfo(res);
    return 0;
}

int domain_store_resolve_all(int map_fd_v4, int map_fd_v6) {
    for (int i = 0; i < domain_count; i++) {
        resolve_domain_to_ip(domains[i].domain, map_fd_v4, map_fd_v6);
    }
    return 0;
}

void domain_store_update_drop_counts(int map_fd_v4, int map_fd_v6) {
    pthread_mutex_lock(&domain_mutex);
    for (int i = 0; i < domain_count; i++) {
        struct domain_entry *entry = &domains[i];
        __u64 total_drops = 0;
        
        for (int j = 0; j < entry->ipv4_count; j++) {
            __u32 key = entry->resolved_ipv4[j];
            __u64 drop_count = 0;
            if (bpf_map_lookup_elem(map_fd_v4, &key, &drop_count) == 0) {
                total_drops += drop_count;
            }
        }
        for (int j = 0; j < entry->ipv6_count; j++) {
            struct in6_addr key = entry->resolved_ipv6[j];
            __u64 drop_count = 0;
            if (bpf_map_lookup_elem(map_fd_v6, &key, &drop_count) == 0) {
                total_drops += drop_count;
            }
        }
        entry->total_drops = total_drops;
    }
    pthread_mutex_unlock(&domain_mutex);
}

void domain_store_write_stats_file(void) {
    const char *stats_file = "/tmp/ebaf-domain-stats.dat";    
    pthread_mutex_lock(&domain_mutex);    
    FILE *fp = fopen(stats_file, "w");
    if (!fp) {
        pthread_mutex_unlock(&domain_mutex);
        return;
    }
    for (int i = 0; i < domain_count; i++) {
        if (domains[i].total_drops > 0) {
            fprintf(fp, "%s:%llu\n", domains[i].domain, domains[i].total_drops);
        }
    }
    fclose(fp);
    pthread_mutex_unlock(&domain_mutex);
}

int whitelist_domain_matches(const char *domain) {
    pthread_mutex_lock(&whitelist_mutex);
    for (int i = 0; i < whitelist_pattern_count; i++) {
        if (fnmatch(whitelist_patterns[i], domain, 0) == 0) {
            pthread_mutex_unlock(&whitelist_mutex);
            return 1;
        }
    }
    pthread_mutex_unlock(&whitelist_mutex);
    return 0;
}

static int load_whitelist_patterns(void) {
    const char *whitelist_paths[] = {
        "spotify-whitelist.txt",
        "/usr/local/share/ebaf/spotify-whitelist.txt",
        NULL
    };
    FILE *fp = NULL;
    int i = 0;
    while (whitelist_paths[i] != NULL) {
        fp = fopen(whitelist_paths[i], "r");
        if (fp != NULL) break;
        i++;
    }
    if (!fp) return -1;
    
    char line[512];
    whitelist_patterns = malloc(sizeof(char*) * 1000);
    whitelist_pattern_count = 0;
    
    while (fgets(line, sizeof(line), fp) && whitelist_pattern_count < 1000) {
        char *domain = strtok(line, " \t\n#");
        if (!domain || domain[0] == '#') continue;
        whitelist_patterns[whitelist_pattern_count++] = strdup(domain);
    }
    fclose(fp);
    return 0;
}

void whitelist_resolver_init(int whitelist_map_fd_v4, int whitelist_map_fd_v6) {
    pthread_mutex_lock(&whitelist_mutex);
    if (load_whitelist_patterns() != 0) {
        pthread_mutex_unlock(&whitelist_mutex);
        return;
    }
    pthread_mutex_unlock(&whitelist_mutex);
    whitelist_resolver_update(whitelist_map_fd_v4, whitelist_map_fd_v6);
}

void whitelist_resolver_update(int whitelist_map_fd_v4, int whitelist_map_fd_v6) {    
    if (!whitelist_patterns || whitelist_pattern_count == 0) return;
    
    pthread_mutex_lock(&whitelist_mutex);
    
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
    
    if (fp) {
        char line[512];
        while (fgets(line, sizeof(line), fp)) {
            char *domain = strtok(line, " \t\n#");
            if (!domain || domain[0] == '#') continue;
            
            int matches = 0;
            for (int j = 0; j < whitelist_pattern_count; j++) {
                if (fnmatch(whitelist_patterns[j], domain, 0) == 0) {
                    matches = 1;
                    break;
                }
            }
            
            if (matches) {
                struct addrinfo hints, *res, *p;
                memset(&hints, 0, sizeof hints);
                hints.ai_family = AF_UNSPEC;
                hints.ai_socktype = SOCK_STREAM;
                
                if (getaddrinfo(domain, NULL, &hints, &res) == 0) {
                    for(p = res; p != NULL; p = p->ai_next) {
                        __u64 value = 1;
                        if (p->ai_family == AF_INET) {
                            __u32 ip = ((struct sockaddr_in *)p->ai_addr)->sin_addr.s_addr;
                            bpf_map_update_elem(whitelist_map_fd_v4, &ip, &value, BPF_ANY);
                        } else if (p->ai_family == AF_INET6) {
                            struct in6_addr ip6 = ((struct sockaddr_in6 *)p->ai_addr)->sin6_addr;
                            bpf_map_update_elem(whitelist_map_fd_v6, &ip6, &value, BPF_ANY);
                        }
                    }
                    freeaddrinfo(res);
                }
            }
        }
        fclose(fp);
    }
    
    // Resolve explicit non-wildcard patterns
    for (int i = 0; i < whitelist_pattern_count; i++) {
        if (strchr(whitelist_patterns[i], '*') == NULL) {
            struct addrinfo hints, *res, *p;
            memset(&hints, 0, sizeof hints);
            hints.ai_family = AF_UNSPEC;
            hints.ai_socktype = SOCK_STREAM;
            
            if (getaddrinfo(whitelist_patterns[i], NULL, &hints, &res) == 0) {
                for(p = res; p != NULL; p = p->ai_next) {
                    __u64 value = 1;
                    if (p->ai_family == AF_INET) {
                        __u32 ip = ((struct sockaddr_in *)p->ai_addr)->sin_addr.s_addr;
                        bpf_map_update_elem(whitelist_map_fd_v4, &ip, &value, BPF_ANY);
                    } else if (p->ai_family == AF_INET6) {
                        struct in6_addr ip6 = ((struct sockaddr_in6 *)p->ai_addr)->sin6_addr;
                        bpf_map_update_elem(whitelist_map_fd_v6, &ip6, &value, BPF_ANY);
                    }
                }
                freeaddrinfo(res);
            }
        }
    }
    pthread_mutex_unlock(&whitelist_mutex);
}