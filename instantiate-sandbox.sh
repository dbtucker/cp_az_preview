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
# Deploy the Confluent Platform components as a single-node install.
#
# Assumptions: all scripts included in the same directory.
#
# WARNING: The file upload process from the Azure templates CLEARS the
#	execute bit on all files.   For that reason, we must to "sh <script>"
#	when chaining them together here.
#
# USAGE :
#	$0 
#		--basename <basename> 
#		--num-brokers <#brokers> 
#		[ --num-zookeepers <#zk> ]		# must be 1 or 3
#		[ --num-workers <#workers> ]
#		[ --password <passwd for KafkaAdmin> ] 
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

KADMIN_USER=${KADMIN_USER:-kadmin}
KADMIN_USER_DIR=`eval "echo ~${KADMIN_USER}"`
KADMIN_USER_DIR=${KADMIN_USER_DIR:-/home/kadmin}
AMI_SBIN=${KADMIN_USER_DIR}/sbin

THIS_HOST=`hostname`

patch_ami() {
	if [ -d "$AMI_SBIN"  -a  "$AMI_SBIN"!= "$BINDIR" ] ; then
    	for f in $(cd ${AMI_SBIN}; ls) ; do
        	[ ! -f $BINDIR/$f ] && continue

        	cp -p ${AMI_SBIN}/$f ${AMI_SBIN}/${f}.ami
        	cp ${BINDIR}/$f ${AMI_SBIN}/$f
    	done
	fi
}

patch_ami


###############  START HERE ##################

cat << cpparmEOF > /tmp/cp.parm
zknodes=$THIS_HOST
brokers=$THIS_HOST
workers=$THIS_HOST
cpparmEOF

[ ! -d ${AMI_SBIN} ] && AMI_SBIN=$BINDIR

chmod a+x $AMI_SBIN/prepare-node.sh
$AMI_SBIN/prepare-node.sh

# Be sure to "source" the prepare-disks script so as to
# set the DATA_DIRS environment variable for later use
chmod a+x $AMI_SBIN/prepare-disks.sh
. $AMI_SBIN/prepare-disks.sh

# and now deploy our software
#
chmod a+x $AMI_SBIN/configure-node.sh
$AMI_SBIN/configure-node.sh

exit 0

