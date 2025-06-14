#ifndef ADBLOCKER_H
#define ADBLOCKER_H

// Stats indices
#define STAT_TOTAL 0
#define STAT_BLOCKED 1

#define STAT_DNS_BLOCKED 1
#define STAT_IP_BLOCKED 2
#define STAT_DNS_QUERIES 3
#define STAT_DNS_RESPONSES 4

struct stats {
    unsigned long long total_packets;
    unsigned long long dns_blocked;
    unsigned long long ip_blocked;
    unsigned long long dns_queries;
    unsigned long long dns_responses;
};
#endif
