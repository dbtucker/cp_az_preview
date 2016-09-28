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
# This is leveraged from the Azure template deployment script.
#
# Assumptions: all scripts included in the same directory.
#
# USAGE :
#	$0 
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

