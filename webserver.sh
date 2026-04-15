#!/bin/bash

# clear screen
printf "\033c"

HOMEBREW_INSTALL_FROM_API=0

# get working dir (current path)
WORKING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# default variables
DEFAULT_IFS=$IFS
export IFS=" "

# default parameters
UPDATE_PACKAGES=${UPDATE_PACKAGES:0}
PACKAGES_INSTALLED=""
RUN_UPDATE=0
FORCE_UPGRADE=0
LOG_OUTPUT="/dev/null"

# default paths
CONFIG_DIR="$WORKING_DIR/configs"
LOGS_DIR="$WORKING_DIR/logs"
SRC_DIR="$WORKING_DIR/src"
SSL_DIR="$WORKING_DIR/ssl"

# shell colors
NC="\033[0m"
GREEN="\033[32m"
RED="\033[31m"
CYAN="\033[36m"

# parameter handling
while [[ $# -gt 0 ]]; do
	key="$1"

	case $key in
	-u | --update)
		UPDATE_PACKAGES=1
		shift # past value
		;;
	-f | --force)
		FORCE_UPGRADE=1
		shift # past value
		;;
	-d | --debug)
		LOG_OUTPUT="/dev/stdout"
		shift # past value
		;;
	-p | --php-versions)
		PHP_VERSIONS="$2"
		shift # past argument
		shift # past value
		;;
	*) # unknown option
		POSITIONAL+=("$1") # save it in an array for later
		shift              # past argument
		;;
	esac
done

# bind settings
export HOMEBREW_INSTALL_FROM_API=FALSE

# paths x86_64
brew_path="/usr/local"
brew_bin_dir="$brew_path/bin"
brew_bin="$brew_bin_dir/brew"
brew="arch -x86_64 $brew_bin"

# bin dirs
bin_dir="$brew_path/bin"
brew_bin="$bin_dir/brew"

# custom files
NGINX_CONFIG="$brew_path/etc/nginx/nginx.conf"
MYSQL_CONFIG="$brew_path/etc/my.cnf"
BREW_PACKAGES_DIR="$brew_path/Cellar"

# variables
BREW_SERVICES="nginx redis mailpit mariadb"
BREW_PACKAGES="bash-completion pkg-config composer imagemagick pv jpegoptim optipng phpunit nmap $BREW_SERVICES"
PHP_EXTENSIONS="redis apcu xdebug imagick mcrypt"
PHP_VERSIONS=${PHP_VERSIONS:="7.4"}
PHPVERSION=${PHPVERSION:=7.4}

# methods
EO=0
i() {
	if [ $EO -eq 0 ]; then
		EO=1
		echo
	fi
}

# shellcheck disable=SC2120
dne() {
	# shellcheck disable=SC2181
	if [ $? -eq 0 ] && [ "$1" != "1" ]; then
		echo -e "${GREEN}done!${NC}"
	else
		echo -e "${RED}failed!${NC}"

		if [ "$1" != "2" ]; then
			echo
			exit
		fi
	fi
}

is_installed() {
	[ ! -z "$2" ] && IA="$2" || IA="x86_64"

	if [ -f "$WORKING_DIR/.install/packages" ]; then
		source "$WORKING_DIR/.install/packages"
	fi

	if [ $FORCE_UPGRADE -eq 1 ]; then
		PACKAGES_INSTALLED=""
	fi

	IP=$PACKAGES_INSTALLED

	if [[ "$IP" == *" $1"* ]]; then
		return 0
	fi

	# fallback
	return 1
}

update_packages() {
	# check to run update, depending on parameter or last update
	CURRENT_TIMESTAMP=$(date +%s)

	if [[ $UPDATE_PACKAGES -eq 1 ]]; then
		RUN_UPDATE=1
	elif [ -f "$WORKING_DIR/.install/last_update" ]; then
		LAST_UPDATE=$(cat "$WORKING_DIR/.install/last_update")
		DIFF_DAYS=$((($CURRENT_TIMESTAMP - $LAST_UPDATE) / (60 * 60 * 24)))

		# run update after 1 week
		if [ $DIFF_DAYS -gt 6 ]; then
			RUN_UPDATE=1
		fi
	else
		echo "$CURRENT_TIMESTAMP" >"$WORKING_DIR/.install/last_update"
	fi

	# update packages, if requested
	if [ $RUN_UPDATE -eq 1 ]; then
		i
		echo -n -e "upgrade packages... "
		if [ -f "$brew_bin" ]; then
			echo
			$brew update &>$LOG_OUTPUT && $brew upgrade -q
			echo "$CURRENT_TIMESTAMP" >"$WORKING_DIR/.install/last_update"
		else
			dne 1
		fi
	fi
}

switch_php_version() {
	# unlink php 8 version
	$brew services stop php &>$LOG_OUTPUT
	$brew unlink php &>$LOG_OUTPUT

	# unlink all php7.x versions
	for v in $PHP_VERSIONS; do
		$brew services stop "php@$v" &>$LOG_OUTPUT
		$brew unlink "php@$v" &>$LOG_OUTPUT
	done

	# link requested php version
	PHP_INI=/usr/local/etc/php/$1/php.ini
	$brew link --force "php@$1" &>$LOG_OUTPUT

	# override php.ini values
	while read line; do
			if [[ $line =~ "=" ]] && [[ $line != \;* ]]; then
					variable=${line%%=*}
					if grep "$variable" "$PHP_INI" > /dev/null; then
							sed -i '' "s~^${variable}.*=.*$~${line}~" "$PHP_INI"
							sed -i '' "s~^;${variable}.*=.*$~${line}~" "$PHP_INI"
					else
							echo "$line" >> "$PHP_INI"
					fi
			fi
	done <"$WORKING_DIR/configs/php-ini-overrides.ini"
}

install_rosetta() {
      if ! /usr/bin/pgrep oahd >/dev/null 2>&1; then
          /usr/sbin/softwareupdate --install-rosetta --agree-to-license
      fi
}

install_homebrew() {
	if [ -f "$brew_bin" ]; then
		update_packages
	else
		i
		echo -n -e "install ${CYAN}homebrew${NC}... "

		arch -x86_64 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" <$LOG_OUTPUT
		$brew analytics off &>$LOG_OUTPUT
		$brew tap shivammathur/php
		$brew tap shivammathur/extensions
		$brew tap kabel/php-ext
		$brew update &>$LOG_OUTPUT && $brew upgrade &>$LOG_OUTPUT

		dne

		# check packages
	fi
}

install_packages() {
	NEW_PACKAGES_INSTALLED=""

	# append php packages
	for version in $PHP_VERSIONS; do
		BREW_PACKAGES="$BREW_PACKAGES php@$version"
	done

	# default packages
	for package in $BREW_PACKAGES; do
		# install package
		if ! is_installed "$package" && ! $brew ls --versions "$package" >$LOG_OUTPUT; then
			i
			echo -n -e "install ${GREEN}x86_64 $brew ${CYAN}$package${NC}... "
			$brew install "$package" &>$LOG_OUTPUT
			dne
		fi

		# set NEW_PACKAGES_INSTALLED
		NEW_PACKAGES_INSTALLED="$NEW_PACKAGES_INSTALLED $package"
	done

	# remove default mysql my.cnf
	find $BREW_PACKAGES_DIR -type f -name "my.cnf" -exec rm -f {} \;

	# enable bash_completion
	if [ ! -f ~/.bash_profile ]; then
		echo "" > ~/.bash_profile
	fi
	if ! grep -q "bash_completion.sh" ~/.bash_profile; then
		echo '[[ -r "/usr/local/etc/profile.d/bash_completion.sh" ]] && . "/usr/local/etc/profile.d/bash_completion.sh"' >>~/.bash_profile
	fi

	# install php extensions
	RUN_UPDATE=1
	current_php_version=""
	for version in $PHP_VERSIONS; do
		# loop extensions
		for extension in $PHP_EXTENSIONS; do
			if ! is_installed "php$version-$extension"; then
				i

				# uninstall extension, if needed
#				if is_installed "php$version-$extension"; then
#					echo -n -e "uninstall ${CYAN}$extension${NC} for ${CYAN}php@$version${NC}... "
#					pecl uninstall "$extension" &>$LOG_OUTPUT
#					dne 2 # don't exit on failed installation
#				fi

				# install php extension
				echo -n -e "install ${CYAN}$extension${NC} for ${CYAN}php@$version${NC}... "

				# switch php version
				if [ "$current_php_version" != "$version" ]; then
					current_php_version=$version
					switch_php_version "$version" &>$LOG_OUTPUT
				fi

				# install extension
				if ! pecl list | grep "$extension" &>$LOG_OUTPUT; then
					if [ "$extension" == "xmlrpc" ]; then
						install_extension="channel://pecl.php.net/xmlrpc-1.0.0RC3"
					else
						install_extension=$extension
					fi
					printf "\n" | pecl install "$install_extension" &>$LOG_OUTPUT
				fi
				dne 2 # don't exit on failed installation
			fi

			NEW_PACKAGES_INSTALLED="$NEW_PACKAGES_INSTALLED php$version-$extension"
		done
	done

	# custom php extensions
	# shellcheck disable=SC2044
	for folder in $(find "$SRC_DIR" -type d -depth 1); do
		source "$folder/config"

		if [ ! -z "$MODULE" ]; then
			for version in $PHP_VERSIONS; do
				if ! is_installed "php$version-$MODULE" && [ -d "$folder$MODULE_FOLDER/$MODULE_PREFIX$version" ]; then
					i

					# install php extension
					echo -n -e "install ${CYAN}$MODULE${NC} for ${CYAN}php@$version${NC}... "

					# get extension data
					extension_dir=$(php-config --extension-dir)
					php_ini_file=$(php --ini | grep Loaded | rev | cut -d " " -f1 | rev)
					so_file="$folder$MODULE_FOLDER/$MODULE_PREFIX$version/$MODULE_FILE"

					# switch php version
					if [ "$current_php_version" != "$version" ]; then
						current_php_version=$version
						switch_php_version "$version" &>$LOG_OUTPUT
					fi

					# install module
					if [ -f "$so_file" ]; then
						cp "$so_file" "$extension_dir"

						# update php.ini file
						if [ -f "$php_ini_file" ] && ! grep -q "$MODULE_FILE" "$php_ini_file"; then
							echo -e "extension=\"$MODULE_FILE\"\n$(cat $php_ini_file)" >"$php_ini_file"
						fi
					fi

					dne 2 # don't exit on failed installation

					NEW_PACKAGES_INSTALLED="$NEW_PACKAGES_INSTALLED php$version-$MODULE"
				fi
			done
		fi
	done

	# save installed packages
	if [ "$PACKAGES_INSTALLED" != "$NEW_PACKAGES_INSTALLED" ]; then
		PACKAGES_INSTALLED=$NEW_PACKAGES_INSTALLED
		echo "PACKAGES_INSTALLED=\"$NEW_PACKAGES_INSTALLED\"" >"$WORKING_DIR/.install/packages"
	fi
}

# check packages
echo -n "check packages... "
install_rosetta
install_homebrew
install_packages
dne

# abort on updating only
if [[ $UPDATE_PACKAGES -eq 1 ]]; then
	exit
fi

# start webserver
# variables
PROJECTDIR="$(basename "$(dirname "$PWD")")"
WWW_DIR="$(dirname "$WORKING_DIR")/www/$PROJECTDIR"
WWW_CONFIG_DIR="$WWW_DIR/configs"

# check www dir
if [ ! -d "$WWW_DIR" ]; then
	echo -e "${RED}missing project directory ${CYAN}$WWW_DIR${RED}!${NC}"
	exit
fi

# stop all services
echo -n "stop running services... "
#$brew services stop --all &>$LOG_OUTPUT
#$brew_arm services stop --all &>$LOG_OUTPUT
#if ps ax | grep -v grep | grep "redis-server" &>$LOG_OUTPUT; then
#	killall redis-server &>$LOG_OUTPUT
#fi
#dne

# link config files
echo
echo -n "bind nginx config... "

# default nginx  config
cp "$CONFIG_DIR/nginx.default.conf" "$NGINX_CONFIG"
sed -i '' "s#{include_path}#$CONFIG_DIR/nginx.conf#" "$NGINX_CONFIG"

# project nginx config
[ -f "$CONFIG_DIR/nginx.conf" ] && rm "$CONFIG_DIR/nginx.conf"
cp "$WWW_CONFIG_DIR/nginx.conf" "$CONFIG_DIR/nginx.conf"
sed -i '' "s#{root_dir}#$WWW_DIR#" "$CONFIG_DIR/nginx.conf"
sed -i '' "s#{log_dir}#$LOGS_DIR#" "$CONFIG_DIR/nginx.conf"
sed -i '' "s#{ssl_dir}#$SSL_DIR#" "$CONFIG_DIR/nginx.conf"

dne

# update my.cnf
echo -n "bind mysql config... "
cat "$CONFIG_DIR/my.cnf" >"$MYSQL_CONFIG"
dne

# update php version
echo
echo -n -e "switch php version to ${CYAN}${PHPVERSION}${NC}... "
switch_php_version $PHPVERSION
dne

# start services
echo
SERVICES="$BREW_SERVICES php@$PHPVERSION"
for service in $SERVICES; do
	SA="x86_64"
	echo -n -e "start ${GREEN}${SA} ${CYAN}${service}${NC}... "
	$brew services restart "$service" &>$LOG_OUTPUT
	dne
done

# flush redis
$bin_dir/redis-cli flushall &>$LOG_OUTPUT

# bind console
echo
if [ -f "$WWW_CONFIG_DIR/console.sh" ]; then
	echo -n -e "install shell console... "
	echo "$(cat "$WWW_CONFIG_DIR/console.sh" | sed "s#{bin_dir}#$bin_dir#" | sed "s#{root_dir}#$WWW_DIR/htdocs#")" >"$CONFIG_DIR/console.sh"

	if [ ! -f /usr/local/bin/console ]; then
		ln -s "$WORKING_DIR/configs/console.sh" /usr/local/bin/console
	fi
	chmod 777 /usr/local/bin/console
	/usr/local/bin/console init

	dne
elif [ -f /usr/local/bin/console ]; then
	unlink /usr/local/bin/console
fi

# custom views

# reset defaults
export IFS=$DEFAULT_IFS
echo
