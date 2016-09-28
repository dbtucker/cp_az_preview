# Advanced Linux Template : Deploy a Confluent Platform Cluster in Azure

<a href="https://azuredeploy.net/" target="_blank">
    <img src="http://azuredeploy.net/deploybutton.png"/>
</a>


<h1>
PREVIEW RELEASE
</h1>

This advanced template deploys multiple copies of the Confluent Platform VM
Image for use in simple experimentation of a complete Kafka environment.
Users can select which instance types to use; storage for each node is
currently defined in the template itself: 4 1-TB volumes for each broker node.

The Control Center interface to the cluster will be available at  
    http://[worker-1]:9021

The system admin account will have login access, as well as the 
Confluent Software Admin account (user "kadmin").   The password for 
the kadmin user is set along with the other deployment parameters,
but password-authentication to that account will be disabled 
unless the system admin account was configured for password authentication
(rather than sshPublicKey). 

Users can log on to the hosts and change the password
of the kadmin user after deployment should they desire.

