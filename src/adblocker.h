// Header file containing shared definitions.
// These definitions are used by both the userspace program and, indirectly, by the eBPF programs.
// They determine statistics indices, domain resolution parameters, and other configuration constants.

#ifndef ADBLOCKER_H  // Include guard to prevent double inclusion
#define ADBLOCKER_H

// Statistics map indices used in the eBPF stats map.
// The kernel eBPF program updates these counters to track packet stats.
#define STAT_TOTAL 0    // Index for counting total packets processed
#define STAT_BLOCKED 1  // Index for counting packets that were blocked (dropped)

// Background resolution settings.
// These control parameters related to periodic domain resolution.
#define DOMAIN_MAX_SIZE 256  // Maximum length for a domain name string.
#define MAX_DOMAINS 10000    // Maximum number of domains stored in the domain_store.
#define RESOLUTION_INTERVAL_SEC 10 * 60  // Interval (in seconds) for re-resolving domains (i.e. every 10 minutes).

// Domain resolution status constants.
// Used to represent whether a domain resolution was successful or not.
#define RESOLUTION_SUCCESS 0
#define RESOLUTION_FAILED 1

// Additional statistics counters (not currently used in the eBPF program but defined for future extension).
#define STAT_DNS_BLOCKED 1
#define STAT_IP_BLOCKED 2
#define STAT_DNS_QUERIES 3
#define STAT_DNS_RESPONSES 4

// Structure to hold statistics (not currently used, but can be leveraged to expand the program's reporting).
// These statistics could be updated by the userspace program based on data from the eBPF maps.
struct stats {
    unsigned long long total_packets;  // Total number of packets processed.
    unsigned long long dns_blocked;      // Number of DNS queries blocked.
    unsigned long long ip_blocked;       // Number of IP addresses blocked.
    unsigned long long dns_queries;      // Total DNS query count.
    unsigned long long dns_responses;    // Total DNS response count.
};

#endif