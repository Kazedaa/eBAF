// Header file containing shared definitions

#ifndef ADBLOCKER_H  // Include guard to prevent double inclusion
#define ADBLOCKER_H

// Statistics map indices
#define STAT_TOTAL 0    // Index for counting total packets
#define STAT_BLOCKED 1  // Index for counting blocked packets

// Background resolution settings
#define DOMAIN_MAX_SIZE 256
#define MAX_DOMAINS 10000
#define RESOLUTION_INTERVAL_SEC 10 * 60  // Re-resolve every 20 minutes

// Domain resolution status
#define RESOLUTION_SUCCESS 0
#define RESOLUTION_FAILED 1

// Additional statistics counters (not currently used)
#define STAT_DNS_BLOCKED 1
#define STAT_IP_BLOCKED 2
#define STAT_DNS_QUERIES 3
#define STAT_DNS_RESPONSES 4

// Structure to hold statistics (not currently used)
struct stats {
    unsigned long long total_packets;
    unsigned long long dns_blocked;
    unsigned long long ip_blocked;
    unsigned long long dns_queries;
    unsigned long long dns_responses;
};

#endif