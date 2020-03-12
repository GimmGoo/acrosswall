#!/bin/bash
＃字体颜色
blue() {
	echo -e "\033[34m\033[01m$1\033[0m"
}
green() {
	echo -e "\033[32m\033[01m$1\033[0m"
}
red() {
	echo -e "\033[31m\033[01m$1\033[0m"
}

function check_port_status() {
	Port80=$(netstat -tlpn | awk -F '[: ]+' '$1=="tcp"{print $5}' | grep -w 80)
	Port443=$(netstat -tlpn | awk -F '[: ]+' '$1=="tcp"{print $5}' | grep -w 443)
	if [ -n "$Port80" ]; then
		process80=$(netstat -tlpn | awk -F '[: ]+' '$5=="80"{print $9}')
		red "==========================================================="
		red "检测到80端口被占用，占用进程为：$process80，本次安装结束"
		red "==========================================================="
		exit 1
	fi
	if [ -n "$Port443" ]; then
		process443=$(netstat -tlpn | awk -F '[: ]+' '$5=="443"{print $9}')
		red "============================================================="
		red "检测到443端口被占用，占用进程为：$process443，本次安装结束"
		red "============================================================="
		exit 1
	fi
	CHECK=$(grep SELINUX= /etc/selinux/config | grep -v "#")
	if [ "$CHECK" == "SELINUX=enforcing" ]; then
		red "======================================================================="
		red "检测到SELinux为开启状态，为防止申请证书失败，请先重启VPS后，再执行本脚本"
		red "======================================================================="
		read -p "是否现在重启 ?请输入 [Y/n] :" yn
		[ -z "$yn" ] && yn="y"
		if [[ $yn == [Yy] ]]; then
			sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
			setenforce 0
			echo -e "VPS 重启中..."
			reboot
		fi
		exit
	fi
	if [ "$CHECK" == "SELINUX=permissive" ]; then
		red "======================================================================="
		red "检测到SELinux为宽容状态，为防止申请证书失败，请先重启VPS后，再执行本脚本"
		red "======================================================================="
		read -p "是否现在重启 ?请输入 [Y/n] :" yn
		[ -z "$yn" ] && yn="y"
		if [[ $yn == [Yy] ]]; then
			sed -i 's/SELINUX=permissive/SELINUX=disabled/g' /etc/selinux/config
			setenforce 0
			echo -e "VPS 重启中..."
			reboot
		fi
		exit
	fi
	systemctl stop firewalld
	systemctl disable firewalld
}

function centos_install_trojan() {
	release="centos"
	systemctl stop nginx
	yum -y install net-tools socat
	check_port_status
	rpm -Uvh http://nginx.org/packages/centos/7/noarch/RPMS/nginx-release-centos-7-0.el7.ngx.noarch.rpm
	yum -y install nginx wget unzip zip curl tar >/dev/null 2>&1
	systemctl enable nginx
	systemctl stop nginx
	green "======================="
	blue "请输入绑定到本VPS的域名"
	green "======================="
	read your_domain
	real_addr=$(ping $your_domain -c 1 | sed '1{s/[^(]*(//;s/).*//;q}')
	local_addr=$(curl ipv4.icanhazip.com)
	if [ $real_addr == $local_addr ]; then
		green "=========================================="
		green "       域名解析正常，开始安装trojan"
		green "=========================================="
		sleep 1s
		cat >/etc/nginx/nginx.conf <<-EOF
			user  root;
			worker_processes  1;
			error_log  /var/log/nginx/error.log warn;
			pid        /var/run/nginx.pid;
			events {
				worker_connections  1024;
			}
			http {
				include       /etc/nginx/mime.types;
				default_type  application/octet-stream;
				log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
				'\$status \$body_bytes_sent "\$http_referer" '
				'"\$http_user_agent" "\$http_x_forwarded_for"';
				access_log  /var/log/nginx/access.log  main;
				sendfile        on;
				#tcp_nopush     on;
				keepalive_timeout  120;
				client_max_body_size 20m;
				#gzip  on;
				server {
					listen       80;
					server_name  $your_domain;
					root /usr/share/nginx/html;
					index index.php index.html index.htm;
				}
			}
		EOF
		#设置伪装站
		rm -rf /usr/share/nginx/html/*
		cd /usr/share/nginx/html/
		wget https://github.com/GimmGoo/acrosswall/raw/master/web.zip
		unzip web.zip
		systemctl stop nginx
		sleep 5
		#申请https证书
		mkdir /usr/src/trojan-cert /usr/src/trojan-temp
		curl https://get.acme.sh | sh
		~/.acme.sh/acme.sh --issue -d $your_domain --standalone
		~/.acme.sh/acme.sh --installcert -d $your_domain \
		--key-file /usr/src/trojan-cert/private.key \
		--fullchain-file /usr/src/trojan-cert/fullchain.cer
		if test -s /usr/src/trojan-cert/fullchain.cer; then
			systemctl start nginx
			cd /usr/src
			wget https://api.github.com/repos/trojan-gfw/trojan/releases/latest
			latest_version=$(grep tag_name latest | awk -F '[:,"v]' '{print $6}')
			wget https://github.com/trojan-gfw/trojan/releases/download/v$latest_version/trojan-$latest_version-linux-amd64.tar.xz
			tar xf trojan-$latest_version-linux-amd64.tar.xz
			rm -rf trojan-$latest_version-linux-amd64.tar.xz
			green "======================="
			blue "请输入Trojan连接密码,一定要记住哦！"
			green "======================="
			read trojan_password
			rm -rf /usr/src/trojan/server.conf
			# 配置trojan
			cat >/usr/src/trojan/server.conf <<-EOF
				{
					"run_type": "server",
					"local_addr": "0.0.0.0",
					"local_port": 443,
					"remote_addr": "127.0.0.1",
					"remote_port": 80,
					"password": [
					"$trojan_password"
					],
					"log_level": 1,
					"ssl": {
						"cert": "/usr/src/trojan-cert/fullchain.cer",
						"key": "/usr/src/trojan-cert/private.key",
						"key_password": "",
						"cipher_tls13":"TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_256_GCM_SHA384",
						"prefer_server_cipher": true,
						"alpn": [
						"http/1.1"
						],
						"reuse_session": true,
						"session_ticket": false,
						"session_timeout": 600,
						"plain_http_response": "",
						"curves": "",
						"dhparam": ""
					},
					"tcp": {
						"no_delay": true,
						"keep_alive": true,
						"fast_open": true,
						"fast_open_qlen": 20
					},
					"mysql": {
						"enabled": false,
						"server_addr": "127.0.0.1",
						"server_port": 3306,
						"database": "trojan",
						"username": "trojan",
						"password": ""
					}
				}
			EOF
			#增加启动脚本
			cat >/usr/lib/systemd/system/trojan.service <<-EOF
				[Unit]
				Description=trojan
				After=network.target
						
				[Service]
				Type=simple
				PIDFile=/usr/src/trojan/trojan/trojan.pid
				ExecStart=/usr/src/trojan/trojan -c "/usr/src/trojan/server.conf"
				ExecReload=
				ExecStop=/usr/src/trojan/trojan
				PrivateTmp=true
						
				[Install]
				WantedBy=multi-user.target
			EOF

			chmod +x /usr/lib/systemd/system/trojan.service
			systemctl start trojan.service
			systemctl enable trojan.service
			green "恭喜您！Trojan已安装完成!"
		else
			red "==================================="
			red "https证书没有申请成果，自动安装失败"
			green "不要担心，你可以手动修复证书申请"
			green "1. 重启VPS"
			green "2. 重新执行脚本，使用修复证书功能"
			red "==================================="
		fi

	else
		red "================================"
		red "域名解析地址与本VPS IP地址不一致"
		red "本次安装失败，请确保域名解析正常"
		red "================================"
	fi
}

function debian_install_trojan() {
	release="debian"
	apt-get update
	apt-get install wget curl vim git
	check_port_status
	apt -y install build-essential cmake libboost-system-dev libboost-program-options-dev libssl-dev default-libmysqlclient-dev
	git clone https://github.com/trojan-gfw/trojan.git
	cd trojan/
	mkdir build && cd build/
	cmake .. -DENABLE_MYSQL=OFF -DENABLE_SSL_KEYLOG=ON -DFORCE_TCP_FASTOPEN=ON -DSYSTEMD_SERVICE=AUTO
	make && make install
	cd --
	green "======================="
	blue "请输入绑定到本VPS的域名"
	green "======================="
	read your_domain
	real_addr=$(ping $your_domain -c 1 | sed '1{s/[^(]*(//;s/).*//;q}')
	local_addr=$(curl ipv4.icanhazip.com)
	if [ $real_addr == $local_addr ]; then
		green "=========================================="
		green "       域名解析正常，开始安装trojan"
		green "=========================================="
		sleep 1s
		cat >/etc/nginx/nginx.conf <<-EOF
			user  root;
			worker_processes  1;
			error_log  /var/log/nginx/error.log warn;
			pid        /var/run/nginx.pid;
			events {
				worker_connections  1024;
			}
			http {
				include       /etc/nginx/mime.types;
				default_type  application/octet-stream;
				log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
				'\$status \$body_bytes_sent "\$http_referer" '
				'"\$http_user_agent" "\$http_x_forwarded_for"';
				access_log  /var/log/nginx/access.log  main;
				sendfile        on;
				#tcp_nopush     on;
				keepalive_timeout  120;
				client_max_body_size 20m;
				#gzip  on;
				server {
					listen 80;
					server_name  $your_domain;
					root /usr/share/nginx/html;
					index index.php index.html index.htm;
				}
			}
		EOF
		#设置伪装站
		rm -rf /usr/share/nginx/html/*
		cd /usr/share/nginx/html/
		wget https://github.com/GimmGoo/acrosswall/raw/master/web.zip
		unzip web.zip
		systemctl stop nginx
		sleep 5
		#申请https证书
		mkdir /usr/src/trojan-cert /usr/src/trojan-temp
		curl https://get.acme.sh | sh
		~/.acme.sh/acme.sh --issue -d $your_domain --standalone
		~/.acme.sh/acme.sh --installcert -d $your_domain \
		--key-file /usr/src/trojan-cert/private.key \
		--fullchain-file /usr/src/trojan-cert/fullchain.cer
		if test -s /usr/src/trojan-cert/fullchain.cer; then
			systemctl start nginx
			cd /usr/src
			wget https://api.github.com/repos/trojan-gfw/trojan/releases/latest
			latest_version=$(grep tag_name latest | awk -F '[:,"v]' '{print $6}')
			wget https://github.com/trojan-gfw/trojan/releases/download/v$latest_version/trojan-$latest_version-linux-amd64.tar.xz
			tar xf trojan-$latest_version-linux-amd64.tar.xz
			rm -rf trojan-$latest_version-linux-amd64.tar.xz
			green "======================="
			blue "请输入Trojan连接密码,一定要记住哦！"
			green "======================="
			read trojan_password
			rm -rf /usr/local/etc/trojan/config.json
			# 配置trojan
			cat >/usr/local/etc/trojan/config.json <<-EOF
				{
					"run_type": "server",
					"local_addr": "0.0.0.0",
					"local_port": 443,
					"remote_addr": "127.0.0.1",
					"remote_port": 80,
					"password": [
					"$trojan_password"
					],
					"log_level": 1,
					"ssl": {
						"cert": "/usr/src/trojan-cert/fullchain.cer",
						"key": "/usr/src/trojan-cert/private.key",
						"key_password": "",
						"cipher_tls13":"TLS_AES_128_GCM_SHA256:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_256_GCM_SHA384",
						"prefer_server_cipher": true,
						"alpn": [
						"http/1.1"
						],
						"reuse_session": true,
						"session_ticket": false,
						"session_timeout": 600,
						"plain_http_response": "",
						"curves": "",
						"dhparam": ""
					},
					"tcp": {
						"no_delay": true,
						"keep_alive": true,
						"fast_open": true,
						"fast_open_qlen": 20
					},
					"mysql": {
						"enabled": false,
						"server_addr": "127.0.0.1",
						"server_port": 3306,
						"database": "trojan",
						"username": "trojan",
						"password": ""
					}
				}
			EOF
			#增加启动脚本
			cat >/etc/systemd/system/trojan.service <<-EOF
				[Unit]
				After=network.target
									
				[Service]
				ExecStart=/root/trojan/build/trojan -c /usr/local/etc/trojan/config.json
				Restart=always
									
				[Install]
				WantedBy=multi-user.target
			EOF

			chmod +x /etc/systemd/system/trojan.service
			systemctl start trojan.service
			systemctl enable trojan.service
			green "恭喜您！Trojan已安装完成!"
		else
			red "==================================="
			red "https证书没有申请成果，自动安装失败"
			green "不要担心，你可以手动修复证书申请"
			green "1. 重启VPS"
			green "2. 重新执行脚本，使用修复证书功能"
			red "==================================="
		fi

	else
		red "================================"
		red "域名解析地址与本VPS IP地址不一致"
		red "本次安装失败，请确保域名解析正常"
		red "================================"
	fi
}

function repair_cert() {
	systemctl stop nginx
	Port80=$(netstat -tlpn | awk -F '[: ]+' '$1=="tcp"{print $5}' | grep -w 80)
	if [ -n "$Port80" ]; then
		process80=$(netstat -tlpn | awk -F '[: ]+' '$5=="80"{print $9}')
		red "==========================================================="
		red "检测到80端口被占用，占用进程为：$process80，本次安装结束"
		red "==========================================================="
		exit 1
	fi
	green "======================="
	blue "请输入绑定到本VPS的域名"
	blue "务必与之前失败使用的域名一致"
	green "======================="
	read your_domain
	real_addr=$(ping $your_domain -c 1 | sed '1{s/[^(]*(//;s/).*//;q}')
	local_addr=$(curl ipv4.icanhazip.com)
	if [ $real_addr == $local_addr ]; then
		~/.acme.sh/acme.sh --issue -d $your_domain --standalone
		~/.acme.sh/acme.sh --installcert -d $your_domain \
		--key-file /usr/src/trojan-cert/private.key \
		--fullchain-file /usr/src/trojan-cert/fullchain.cer
		if test -s /usr/src/trojan-cert/fullchain.cer; then
			green "证书申请成功"
			systemctl restart trojan
			systemctl start nginx
		else
			red "申请证书失败"
		fi
	else
		red "================================"
		red "域名解析地址与本VPS IP地址不一致"
		red "本次安装失败，请确保域名解析正常"
		red "================================"
	fi
}

function remove_trojan() {
	red "================================"
	red "即将卸载trojan"
	red "同时卸载安装的nginx"
	red "================================"
	systemctl stop trojan
	systemctl disable trojan
	if [ "$release" == "centos" ]; then
		rm -rf /usr/lib/systemd/system/trojan.service
	else
		rm -rf /etc/systemd/system/trojan.service
	fi
	if [ "$release" == "centos" ]; then
		yum remove -y nginx
	else
		apt autoremove -y nginx
	fi
	rm -rf /usr/src/trojan*
	rm -rf /usr/share/nginx/html/*
	green "=============="
	green "trojan删除完毕"
	green "=============="
}

start_menu() {
	clear
	green " ===================================="
	green " Modidified By William "
	green " Trojan 一键安装自动脚本 2020-3-12 更新  "
	green " 系统：centos7"
	green " ===================================="
	blue " 声明："
	red " *请不要在任何生产环境使用此脚本"
	red " *请不要有其他程序占用80和443端口"
	red " *若是第二次使用脚本，请先执行卸载trojan"
	green " ======================================="
	echo
	green " 1. CentOS7 安装Trojan"
	yellow " 2. Debian10 安装Trojan"
	red " 3. 卸载trojan"
	green " 4. 修复证书"
	blue " 0. 退出脚本"
	echo
	read -p "请输入数字:" num
	case "$num" in
	1)
		centos_install_trojan
		;;
	2)
		debian_install_trojan
		;;
	3)
		remove_trojan
		;;
	4)
		repair_cert
		;;
	0)
		exit 1
		;;
	*)
		clear
		red "请输入正确数字"
		sleep 1s
		start_menu
		;;
	esac
}

start_men
