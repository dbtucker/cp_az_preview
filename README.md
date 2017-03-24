# Advanced Linux Template : Deploy a Confluent Platform Cluster in Azure

<a href="https://azuredeploy.net/" target="_blank">
    <img src="http://azuredeploy.net/deploybutton.png"/>
</a>


<h1>
PREVIEW RELEASE
</h1>

This advanced template deploys multiple copies of the Confluent VM
Image for use in simple experimentation of a complete Kafka environment.
Users can select the number and type of instances to use.  Storage for each 
node is currently defined in the template itself: 4 1-TB volumes for each broker node.

The Control Center interface to the cluster will be available at  

    http://[worker-1]:9021

The system admin account will have login access, as will the 
Confluent Software Admin account (user "kadmin").   The password for 
the kadmin user is set along with the other deployment parameters,
but password-authentication to that account will be disabled 
unless the system admin account was configured for password authentication
(rather than sshPublicKey). 

Users can log on to the hosts and change the password
of the kadmin user after deployment should they desire.

<h1>
DEPLOYMENT NOTES
</h1>

When using the one-click Deploy-to-Azure option above, be sure to specify ALL 
of the relevant template parameters.   This basic deployment model is very
different from the Marketplace model, so several default values (notably the
target resource group for a newly created virtual network) cannot be set
propery for display in the web interface.
