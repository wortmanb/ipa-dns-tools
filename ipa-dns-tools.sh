# ipa-dns-tools
#
# Copyright 2018, Bret Wortman, The Damascus Group LLC
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
# V1.0, 2018-01-17 Initial version
#
export CLASSC="192.168.1"
export NETID="yoyodyne.com"
export NET=".${NETID}"
export CLASSB=$( echo $CLASSC | awk -F. '{print ${1}"."${2}"' )
export IPRE="[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}"

# Make sure we always have a valid Kerberos certificate before doing
# anything that requires interacting with IPA, and limits us to a set number
# of prompts before giving up.
#
ensure_k () {
    tries=3
    while [[ ! klist | grep $ADMIN && $tries -gt 0 ]]; do
        kinit
        tries=$(( $tries - 1 ))
    done
}

# Reverse the Class B network address to produce the zone name
#
reverse_classb () {
    REVB=$( echo $CLASSB | awk -F. '{print ${2}"."${1}".in-addr.arpa"')
}

# Reverse an IP address
#
# @param      $1 { IP to reverse }
# @param      $2 { optional return variable }
#
reverse_ip () {
    $IP=$1
    local __resultvar=$2

    if [[ $IP =~ $IPRE ]]; then
        result=$( echo $IP | awk -F. '{print $4"."$3"."$2"."$1' )
    else
        result=""
    fi

    if [[ "$__resultvar" ]]; then
        eval $__resultvar="'$result'"
    else
        echo "$result"
    fi
}

# Given an IP, return the reverse network Zone name
#
# @param      $1 { IP to reverse }
# @param      $2 { optional return variable }
revnet () {
    $IP=$1
    local __resultvar=$2

    if [[ $IP =~ $IPRE ]]; then
        tmp=$( reverse_ip $IP )
        result=$( echo $tmp | awk -F '{print $2"."$3"."$4".in-addr.arpa"' )
    fi

    if [[ "$__resultvar" ]]; then
        eval $__resultvar="'$result'"
    else
        echo "$result"
    fi
}

# Move a subnet from one Class C to another. We have to do this more often than
# I'd like to admit and this saves boatloads of time.
#
# @param      $1    { Original subnet octet }
# param       $2    { New subnet octet }
#
dnsnetmove () {
    FROM="${CLASSB}.${1}."
    TO="${CLASSC}.${2}."
    NF='not found'
    reverse_classb
    REV="${1}.${REVB}"

    ensure_k
    for (( i = 1; i < 255; i ++ )); do
        # Test to see if this address is in reverse dns
        TST=$( host ${FROM}${i} )
        if [[ $TST =~ $NF ]]; then
            continue
        fi
        # So we have one. What's the hostname?
        HOST=$( echo $HOST) | awk -F. '{print $1}' )
        if [[ $HOST =~ $NET ]]; then
            HOST=$( echo $HOST| awk -F. '{print $1}' )
        fi
        # Remove this address and its reverse
        echo "Removing forward record for $HOST ${FROM}${i}"
        ipa dnsrecord-del $NETID $HOST --del-all
        echo "Removing reverse record for ${i}${REV}"
        ipa dnsrecord-del $REV $i --del-all
        # Now, add the forward on the "to" network
        echo "Adding $HOST ${TO}${i}"
        dnsadd ${TO}${i} $HOST -r
    done
}

# Rename a system, updating its forward and reverse DNS entries
#
# @param      $1    { From name }
# @param      $2    { To name }
#
dnsrename () {
    FROM=$1
    TO=$2
    SEP="has address "
    REVSEP="domain name pointer "

    ensure_k
    if [[ $FROM =~ $NET ]]; then
        FROM=$( echo $FROM | awk -F. '{print $1}' )
    fi
    if [[ $TO =~ $NET ]]; then
        TO=$( echo $TO | awk -F. '{print $1}' )
    fi

    # get IP
    IP=$( host $FROM | awk -F"${SEP}" '{print $2}' )
    ipa dnsrecord-del $NETID $FROM --del-all

    # Remove reverse
    REV=$( host $IP )
    if [[ $REV =~ $REVSEP ]]; then
        reverse_ip $REV $reversed
        REVIP=$( echo $reversed | awk -F. '{print $1}' )
        REVNET=$( echo $reversed | awk -F. '{print $2"."$3"."$4".in-addr.arpa')
        ipa dnsrecord-del $REVNET $REVIP --del-all
    fi

    # Now add the new entry
    dnsadd $IP $TO -r
}

# Add a new DNS entry with optional reverse
#
# @param      $1    { IP address }
# @param      $2    { Hostname (short, not FQDN) }
# @param      $3    { Optional "-r" to indicate a reverse is desired }
#
dnsadd () {
    ensure_k
    if [[ $1 =~ $IPRE ]]; then
        if [[ $3 == -r* ]]; then
            ipa dnsrecord-add $NETID $2 --a-ip-address=$1 --a-create-reverse
            if [[ $? != 0 ]]; then
                echo "Problem creating with reverse, attempting forward only:"
                ipa dnsrecord-add $NETID $2 --a-ip-address=$1
            fi
        else
            ipa dnsrecord-add $NETID $2 --a-ip-address=$1
        fi
    else
        ipa dnsrecord-add $NETID $2 --a-ip-address=$( host $1 | awk '{print $4}' )
    fi
}

# Add a reverse entry from an IP and hostname
#
# @param      $1    { IP Address }
# @param      $2    { Hostname }
#
dnsrev () {
    ensure_k
    if [[ $1 =~ $IPRE ]]; then
        reverse_ip $1 $reversed
        NETID=$( revnet $1 )
        ipa dnsrecord-add $NETID $1 --ptr-hostname=$2
    else
        cat <<EOF
Usage:

    dnsrev <ipaddr> <hostname>

EOF
    fi
}
