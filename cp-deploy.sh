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

#
# Wrapper script around our deployment scripts for Confluent Platform on Azure.
#
# Assumptions: all other scripts downloaded to same directory.
#
# WARNING: The file upload process from the Azure templates CLEARS the
#	execute bit on all files.   For that reason, we must to "sh <script>"
#	when chaining them together here.
#
# The template will generate a set of hosts with a well-defined 
# naming conventions (resolved with internal DNS).
#	<base>-broker-<n>
#	<base>-zk-<n>		# if zknodes>0
#	<base>-worker-<n>	# if workders>0
#
# It is simple for any node to use its own hostname and the other
# parameters to figure out what services to deploy.  For now, the 
# service layout is
#
#	broker : kafka service and REST service
#		(if zknodes==0, then 
#			broker-0 or broker-[012] will deploy zookeeper
#			broker-0 will deploy Schema Registry )
#	zk : zookeeper service 
#		zk-0 deploys the SchemaRegistry service as well
#	worker : distributed-connect worker service
# 
#
# USAGE :
#	$0 
#		--basename <basename> 
#		--num-brokers <#brokers> 
#		[ --num-zookeepers <#zk> ]		# must be 1 or 3
#		[ --num-workers <#workers> ]
#		[ --password <passwd for <KafkaAdmin> ]
#
# EXAMPLES :
#	$0 --basename ktest --num-brokers 3
#		A simple 3-node cluster ktest-broker-1, ktest-broker-2, ktest-broker-3
#
#	$0 --basename kcluster --num-brokers 5 --num-zookeepers 3 --num-workers 4
#		A more complex cluster of 12 total nodes
#			kcluster-broker-[1-5]
#			kcluster-zk-[1-3]
#			kcluster-worker-[1-4]
#
# NOTE:
#	We take our queue regarding our role from the hostname.  We use
#	the command line arguments to determine the config values to
#	set in the properties files.
#
# TBD
#	Probably don't need the <basename> property, since we can extract it
#	from our own hostname ... but we'll keep it this way for now.
#	


THIS=`readlink -f $0`
BINDIR=`dirname $THIS`

HOSTNAME=`hostname`
CLUSTER_HOSTNAME_BASE="${HOSTNAME%%-*}"

###############  START HERE ##################

# Parse and validate command line args 
while [ $# -gt 0 ]
do
  case $1 in
  --basename)        shift 1; CLUSTER_BASENAME=$1  ;;
  --num-brokers)     shift 1; nbrokers=$1 ;;
  --num-zookeepers)  shift 1; nzookeepers=$1  ;;
  --num-workers)     shift 1; nworkers=$1  ;;
  --password)        shift 1; KADMIN_PASSWD=$1  ;;
  *)
     echo "**** Unrecognized argument: " $1
  esac
  shift 1
done

# Quick sanity check
#	TBD : make sure there are no '-' characters in CLUSTER_BASENAME
#
CLUSTER_BASENAME=${CLUSTER_BASENAME:-$CLUSTER_HOSTNAME_BASE}
nbrokers=${nbrokers:-1}
nzookeepers=${nzookeepers:-0}
nworkers=${nworkers:-0}

# These should be passed in via metadata
export KADMIN_USER=${KADMIN_USER:-kadmin}
export KADMIN_PASSWD=${KADMIN_PASSWD:-ConfAZ}
export CONFLUENT_VERSION=${CONFLUENT_VERSION:-3.0.0} 

chmod a+x $BINDIR/prepare-node.sh
$BINDIR/prepare-node.sh

# Be sure to "source" the prepare-disks script so as to
# set the DATA_DIRS environment variable for later use
chmod a+x $BINDIR/prepare-disks.sh
. $BINDIR/prepare-disks.sh

# We've seen issues with DNS in Azure ... so we may need to
# generate a hosts file (which has the added advantage of
# delaying the rest of script until DNS settles down)
#
chmod a+x $BINDIR/gen-cluster-hosts.sh
$BINDIR/gen-cluster-hosts.sh ${CLUSTER_BASENAME} $nbrokers $nzookeepers $nworkers

# and now deploy our software
#
chmod a+x $BINDIR/configure-node.sh
$BINDIR/configure-node.sh

exit 0

