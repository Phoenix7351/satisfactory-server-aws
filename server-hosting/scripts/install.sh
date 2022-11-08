#!/bin/sh

# Note: Arguments to this script 
#  1: string - S3 bucket for your backup save files (required)
#  2: true|false - whether to use Satisfactory Experimental build (optional, default false)
S3_SAVE_BUCKET=$1
USE_EXPERIMENTAL_BUILD=${2-false}


# install steamcmd: https://developer.valvesoftware.com/wiki/SteamCMD?__cf_chl_jschl_tk__=pmd_WNQPOiK18.h0rf16RCYrARI2s8_84hUMwT.7N1xHYcs-1635248050-0-gqNtZGzNAiWjcnBszQiR#Linux.2FmacOS)
add-apt-repository multiverse
dpkg --add-architecture i386
apt update

#Install ec2metadata
sudo wget http://s3.amazonaws.com/ec2metadata/ec2-metadata
sudo chmod a+x ec2-metadata
sudo mv ec2-metadata /usr/bin/ec2-metadata

# Needed to accept steam license without hangup
echo steam steam/question 'select' "I AGREE" | sudo debconf-set-selections
echo steam steam/license note '' | sudo debconf-set-selections

apt install -y unzip lib32gcc1 steamcmd

# install satisfactory: https://satisfactory.fandom.com/wiki/Dedicated_servers
if [ $USE_EXPERIMENTAL_BUILD = "true" ]; then
    STEAM_INSTALL_SCRIPT="/usr/games/steamcmd +login anonymous +app_update 1690800 -beta experimental validate +quit"
else
    STEAM_INSTALL_SCRIPT="/usr/games/steamcmd +login anonymous +app_update 1690800 validate +quit"
fi
# note, we are switching users because steam doesn't recommend running steamcmd as root
su - ubuntu -c "$STEAM_INSTALL_SCRIPT"

# enable as server so it stays up and start: https://satisfactory.fandom.com/wiki/Dedicated_servers/Running_as_a_Service
cat << EOF > /etc/systemd/system/satisfactory.service
[Unit]
Description=Satisfactory dedicated server
Wants=network-online.target
After=syslog.target network.target nss-lookup.target network-online.target

[Service]
Environment="LD_LIBRARY_PATH=./linux64"
ExecStartPre=$STEAM_INSTALL_SCRIPT
ExecStart=/home/ubuntu/.steam/steamapps/common/SatisfactoryDedicatedServer/FactoryServer.sh
User=ubuntu
Group=ubuntu
StandardOutput=journal
Restart=on-failure
KillSignal=SIGINT
WorkingDirectory=/home/ubuntu/.steam/steamapps/common/SatisfactoryDedicatedServer

[Install]
WantedBy=multi-user.target
EOF
systemctl enable satisfactory
systemctl start satisfactory

# enable auto shutdown: https://github.com/feydan/satisfactory-tools/tree/main/shutdown
cat << 'EOF' > /home/ubuntu/auto-shutdown.sh
#!/bin/sh

shutdownIdleMinutes=30
idleCheckFrequencySeconds=1

isIdle=0
while [ $isIdle -le 0 ]; do
    isIdle=1
    iterations=$((60 / $idleCheckFrequencySeconds * $shutdownIdleMinutes))
    while [ $iterations -gt 0 ]; do
        sleep $idleCheckFrequencySeconds
        connectionBytes=$(ss -lu | grep 777 | awk -F ' ' '{s+=$2} END {print s}')
        if [ ! -z $connectionBytes ] && [ $connectionBytes -gt 0 ]; then
            isIdle=0
        fi
        if [ $isIdle -le 0 ] && [ $(($iterations % 21)) -eq 0 ]; then
           echo "Activity detected, resetting shutdown timer to $shutdownIdleMinutes minutes."
           break
        fi
        iterations=$(($iterations-1))
    done
done

echo "No activity detected for $shutdownIdleMinutes minutes, shutting down."
sudo shutdown -h now
EOF
chmod +x /home/ubuntu/auto-shutdown.sh
chown ubuntu:ubuntu /home/ubuntu/auto-shutdown.sh

cat << 'EOF' > /etc/systemd/system/auto-shutdown.service
[Unit]
Description=Auto shutdown if no one is playing Satisfactory
After=syslog.target network.target nss-lookup.target network-online.target

[Service]
Environment="LD_LIBRARY_PATH=./linux64"
ExecStart=/home/ubuntu/auto-shutdown.sh
User=ubuntu
Group=ubuntu
StandardOutput=journal
Restart=on-failure
KillSignal=SIGINT
WorkingDirectory=/home/ubuntu

[Install]
WantedBy=multi-user.target
EOF
systemctl enable auto-shutdown
systemctl start auto-shutdown

# DuckDNS Setup

mkdir /home/ubuntu/duckdns

cat << 'EOF' > /home/ubuntu/duckdns/duck.sh
#!/bin/bash
current=""
while true; do
    latest=`/usr/bin/ec2-metadata --public-ipv4`
    echo "public-ipv4=$latest"
    if [ "$current" == "$latest" ]
    then
        echo "ip not changed"
    else
        echo "ip has changed - updating"
        current=$latest
        echo url="[redacted]" | curl -k -o /home/ubuntu/duckdns/duck.log -K -
    fi
    sleep 5m
done
EOF

chmod 700 /home/ubuntu/duckdns/duck.sh
sudo chown ubuntu:ubuntu /home/ubuntu/duckdns/duck.sh

#cat << 'EOF' > /home/ubuntu/duckdns/duck_daemon.sh
##!/bin/bash
##su - ubuntu -c "nohup /home/ubuntu/duckdns/duck.sh > /home/ubuntu/duckdns/duck.log 2>&1&"
#nohup /home/ubuntu/duckdns/duck.sh > /home/ubuntu/duckdns/duck.log 2>&1&
#EOF
#
#chmod a+x /home/ubuntu/duckdns/duck_daemon.sh
#sudo chown ubuntu:ubuntu /home/ubuntu/duckdns/duck_daemon.sh
#sudo chmod 744 /home/ubuntu/duckdns/duck_daemon.sh
#
#sudo ln -s /home/ubuntu/duckdns/duck_daemon.sh /etc/rc5.d/S10duckdns
#
#sudo /etc/rc5.d/S10duckdns

cat << 'EOF' > /etc/systemd/system/duck_daemon.service
[Unit]
Description=Automatically updates the DNS server
After=syslog.target network.target nss-lookup.target network-online.target

[Service]
Environment="LD_LIBRARY_PATH=./linux64"
ExecStart=/home/ubuntu/duckdns/duck.sh
User=ubuntu
Group=ubuntu
StandardOutput=journal
Restart=on-failure
KillSignal=SIGINT
WorkingDirectory=/home/ubuntu/duckdns

[Install]
WantedBy=multi-user.target
EOF
systemctl enable duck_daemon
systemctl start duck_daemon

# automated backups to s3 every 5 minutes
su - ubuntu -c "crontab -l -e ubuntu | { cat; echo \"*/5 * * * * /usr/local/bin/aws s3 sync /home/ubuntu/.config/Epic/FactoryGame/Saved/SaveGames/server s3://$S3_SAVE_BUCKET\"; } | crontab -"
