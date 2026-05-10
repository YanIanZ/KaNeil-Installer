#!/bin/bash

set -e

######################################################################################
#                                                                                    #
# Project 'kaneil-installer'                                                        #
#                                                                                    #
# Copyright (C) 2018 - 2025, YanIanZ                    #
#                                                                                    #
#   This program is free software: you can redistribute it and/or modify             #
#   it under the terms of the GNU General Public License as published by             #
#   the Free Software Foundation, either version 3 of the License, or                #
#   (at your option) any later version.                                              #
#                                                                                    #
#   This program is distributed in the hope that it will be useful,                  #
#   but WITHOUT ANY WARRANTY; without even the implied warranty of                   #
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the                    #
#   GNU General Public License for more details.                                     #
#                                                                                    #
#   You should have received a copy of the GNU General Public License                #
#   along with this program.  If not, see <https://www.gnu.org/licenses/>.           #
#                                                                                    #
# https://github.com/YanIanZ/KaNeil-Installer/blob/main/LICENSE                  #
#                                                                                    #
# This script is not associated with the official KaNeil Project.                   #
# https://github.com/YanIanZ/KaNeil-Installer                                    #
#                                                                                    #
######################################################################################

export GITHUB_SOURCE="main"
export SCRIPT_RELEASE="v2.0.0"
export GITHUB_BASE_URL="https://raw.githubusercontent.com/YanIanZ/KaNeil-Installer"

LOG_PATH="/var/log/kaneil-installer.log"

# check for curl
if ! [ -x "$(command -v curl)" ]; then
  echo "* curl is required in order for this script to work."
  echo "* install using apt (Debian and derivatives) or yum/dnf (CentOS)"
  exit 1
fi

# Always remove lib.sh, before downloading it
rm -rf /tmp/lib.sh
curl -sSL -o /tmp/lib.sh "$GITHUB_BASE_URL"/"$GITHUB_SOURCE"/lib/lib.sh?t=$(date +%s)

# Verify lib.sh was downloaded correctly
if ! head -1 /tmp/lib.sh | grep -q '#!/bin/bash'; then
  echo "* ERROR: Failed to download lib.sh. Please check your internet connection and try again."
  rm -rf /tmp/lib.sh
  exit 1
fi

# shellcheck source=lib/lib.sh
source /tmp/lib.sh

execute() {
  echo -e "\n\n* kaneil-installer $(date) \n\n" >>$LOG_PATH

  update_lib_source

  # Update scripts run directly without UI
  if [[ "$1" == "update-panel" ]] || [[ "$1" == "update-ship" ]]; then
    bash <(curl -sSL "$GITHUB_URL/installers/$1.sh") |& tee -a $LOG_PATH
  else
    run_ui "$1" |& tee -a $LOG_PATH
  fi

  if [[ -n $2 ]]; then
    echo -e -n "* Installation of $1 completed. Do you want to proceed to $2 installation? (y/N): "
    read -r CONFIRM
    if [[ "$CONFIRM" =~ [Yy] ]]; then
      execute "$2"
    else
      error "Installation of $2 aborted."
      exit 1
    fi
  fi
}

welcome ""

done=false
while [ "$done" == false ]; do
  options=(
    "Install the panel"
    "Install Ship"
    "Install both [0] and [1] on the same machine (ship script runs after panel)"
    "Update the panel"
    "Update Ship"
    "Update both panel and ship [3] and [4]"

    "Uninstall panel or ship"
  )

  actions=(
    "panel"
    "ship"
    "panel;ship"
    "update-panel"
    "update-ship"
    "update-panel;update-ship"

    "uninstall"
  )

  output "What would you like to do?"

  for i in "${!options[@]}"; do
    output "[$i] ${options[$i]}"
  done

  echo -n "* Input 0-$((${#actions[@]} - 1)): "
  read -r action

  [ -z "$action" ] && error "Input is required" && continue

  valid_input=("$(for ((i = 0; i <= ${#actions[@]} - 1; i += 1)); do echo "${i}"; done)")
  [[ ! " ${valid_input[*]} " =~ ${action} ]] && error "Invalid option"
  [[ " ${valid_input[*]} " =~ ${action} ]] && done=true && IFS=";" read -r i1 i2 <<<"${actions[$action]}" && execute "$i1" "$i2"
done

# Remove lib.sh, so next time the script is run the, newest version is downloaded.
rm -rf /tmp/lib.sh
