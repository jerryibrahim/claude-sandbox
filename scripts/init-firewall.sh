#!/usr/bin/env bash
set -euo pipefail

ALLOW_FILE="${ALLOW_DOMAINS_FILE:-/etc/claude-sandbox/allowed-domains.txt}"

if [ ! -r "$ALLOW_FILE" ]; then
  echo "init-firewall: cannot read $ALLOW_FILE" >&2
  exit 1
fi

# Reset OUTPUT chain and the ipsets (v4 and v6).
iptables -F OUTPUT
ipset destroy allowed 2>/dev/null || true
ipset create allowed hash:net family inet

ip6tables -F OUTPUT
ipset destroy allowed6 2>/dev/null || true
ipset create allowed6 hash:net family inet6

# Allow essentials BEFORE switching default to DROP (v4).
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# Allow essentials BEFORE switching default to DROP (v6).
ip6tables -A OUTPUT -o lo -j ACCEPT
ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip6tables -A OUTPUT -p udp --dport 53 -j ACCEPT
ip6tables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# Populate the ipsets. A literal IPv4/IPv6 address or CIDR goes straight in
# (use CIDRs for hosts with large rotating IP pools, e.g. GitHub). A hostname is
# resolved (A + AAAA) at startup.
while IFS= read -r entry; do
  [ -z "$entry" ] && continue
  case "$entry" in \#*) continue ;; esac
  if [[ "$entry" == *:* ]]; then
    # IPv6 address or CIDR.
    ipset add allowed6 "$entry" 2>/dev/null || true
  elif [[ "$entry" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
    # IPv4 address or CIDR.
    ipset add allowed "$entry" 2>/dev/null || true
  else
    # Hostname.
    resolved=0
    for ip in $(getent ahostsv4 "$entry" | awk '{print $1}' | sort -u); do
      ipset add allowed "$ip" 2>/dev/null || true
      resolved=1
    done
    for ip6 in $(getent ahostsv6 "$entry" | awk '{print $1}' | sort -u); do
      ipset add allowed6 "$ip6" 2>/dev/null || true
    done
    if [ "$resolved" -eq 0 ]; then
      echo "init-firewall: WARNING could not resolve $entry" >&2
    fi
  fi
done < "$ALLOW_FILE"

# Allow egress to the resolved sets, then default-DROP everything else (v4).
iptables -A OUTPUT -m set --match-set allowed dst -j ACCEPT
iptables -P OUTPUT DROP

# Allow egress to the resolved sets, then default-DROP everything else (v6).
ip6tables -A OUTPUT -m set --match-set allowed6 dst -j ACCEPT
ip6tables -P OUTPUT DROP

echo "init-firewall: egress restricted to $(ipset list allowed | grep -c '^[0-9]') IPv4 and $(ipset list allowed6 | grep -c '^[0-9a-f]') IPv6 allowed IPs"
