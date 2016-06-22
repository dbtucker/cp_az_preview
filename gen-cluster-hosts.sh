#!/bin/bash
#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


LOG=/tmp/gen-cluster-hosts.log

#
# VERY SIMPLE Script to generate the list of hosts within this cluster.
#	print out errors when node resolution fails
#
# NOTE: the CP_HOSTS_FILE is used by multiple other scripts as
# part of the complete cluster deployment
#

echo "$0 script started at "`date`   | tee -a $LOG
echo "    with args: $@"             | tee -a $LOG
echo "    executed by: "`whoami`     | tee -a $LOG
echo ""                              | tee -a $LOG


CLUSTER_BASENAME=${1:-}
CLUSTER_BROKERS=${2:-1}
CLUSTER_ZOOKEEPERS=${3:-0}
CLUSTER_WORKERS=${4:-0}

# Don't do anything if bogus parameters are passed in 
[ -z "${CLUSTER_BASENAME}"  -o  -z "${CLUSTER_BROKERS}" ] && exit 0

CP_HOSTS_FILE=/tmp/cphosts    # Helper file
truncate --size 0 $CP_HOSTS_FILE

for ((h=1; h<=CLUSTER_BROKERS; h++))
do
	hname=${CLUSTER_BASENAME}-broker-$h
#	hip=$(dig -t a +search +short $hname)
	hip=$(getent hosts $hname | awk '{print $1}')

	if [ -z "$hip" ] ; then
		echo "getent(1M) could not resolve $hname" | tee -a $LOG
	fi

	echo "$hname" >> $CP_HOSTS_FILE
done

for ((h=1; h<=CLUSTER_ZOOKEEPERS; h++))
do
	hname=${CLUSTER_BASENAME}-zk-$h
#	hip=$(dig -t a +search +short $hname)
	hip=$(getent hosts $hname | awk '{print $1}')

	if [ -z "$hip" ] ; then
		echo "getent(1M) could not resolve $hname" | tee -a $LOG
	fi

	echo "$hname" >> $CP_HOSTS_FILE
done

for ((h=1; h<=CLUSTER_WORKERS; h++))
do
	hname=${CLUSTER_BASENAME}-worker-$h
#	hip=$(dig -t a +search +short $hname)
	hip=$(getent hosts $hname | awk '{print $1}')

	if [ -z "$hip" ] ; then
		echo "getent(1M) could not resolve $hname" | tee -a $LOG
	fi

	echo "$hname" >> $CP_HOSTS_FILE
done

# Really last kludge ... put hostname list into /etc/clustershell/groups
# if it exists
if [ -f /etc/clustershell/groups ] ; then
	nodes=`echo $(awk '{print $1}' $CP_HOSTS_FILE)`
	if [ -n "$nodes" ] ; then
		echo "all: ${nodes// /,}" > /etc/clustershell/groups
	fi
fi

echo "$0 script completed at "`date` | tee -a $LOG
