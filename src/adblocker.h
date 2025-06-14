// Header file containing shared definitions

#ifndef ADBLOCKER_H  // Include guard to prevent double inclusion
#define ADBLOCKER_H

// Stats indices - these must match the indices used in the eBPF code
#define STAT_TOTAL 0    // Index for counting total packets
#define STAT_BLOCKED 1  // Index for counting blocked packets

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