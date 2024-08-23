#!/usr/bin/env bash

# A script that
# (1) updates all packages on a RHEL-like Linux,
# (2) reboots conditionally if `needs-restarting` tells us so
# (3) if no reboot is required, checks whether certain packages [0] have been upgraded; if so, we reboot too
#
# for further details see ~~https://github.com/world-direct/technology/issues/138~~ the more recent https://github.com/world-direct/foreman-helpers/issues/1
#
#
# ------
#
# In Foreman, create a `Job Template` w/ the following content to use it
#
#    ```shell
#    curl --silent https://raw.githubusercontent.com/world-direct/foreman-helpers/main/shell/k8s/rke1/k8s-rke1-foreman.sh | bash
#    ```
#
# Of course, you can compine it arbitrarily, e.g. for running only on Thursday (handy for running every 2nd Thursday, a thing one can't express using solely Cron expressions, but working around it using `00 23 8-14,22-31 * *`) simply use:
#
#    ```shell
#    [ "$(date '+%u')" = "4" ] && curl --silent https://raw.githubusercontent.com/world-direct/foreman-helpers/main/shell/k8s/rke1/k8s-rke1-foreman.sh | bash
#    ```
#
# ------
#
# A typical output of `dnf history info last`, when docker-related packages were upgraded, looks as follows:
#
# $ dnf history info last
# Not root, Subscription Management repositories not updated
# Transaction ID : 24
# Begin time     : Thu 22 Aug 2024 11:30:19 PM CEST
# Begin rpmdb    : 01b08e3ca5704da392c8316abf4978f0b2c0e3ae4166b8fe74f6fb78e5cf3bcf
# End time       : Thu 22 Aug 2024 11:30:34 PM CEST (15 seconds)
# End rpmdb      : a8b6ede1850ad921a37fed578f1021e23f062644bdbb8035c171c862e4f6f682
# User           : Foreman Remote Execution <foremanremexec>
# Return-Code    : Success
# Releasever     : 9
# Command Line   : update -y
# Comment        :
# Packages Altered:
#     Upgrade  containerd.io-1.7.20-3.1.el9.x86_64           @docker-ce-stable
#     Upgraded containerd.io-1.7.19-3.1.el9.x86_64           @@System
#     Upgrade  docker-buildx-plugin-0.16.2-1.el9.x86_64      @docker-ce-stable
#     Upgraded docker-buildx-plugin-0.16.1-1.el9.x86_64      @@System
#     Upgrade  docker-ce-3:27.1.2-1.el9.x86_64               @docker-ce-stable
#     Upgraded docker-ce-3:27.1.1-1.el9.x86_64               @@System
#     Upgrade  docker-ce-cli-1:27.1.2-1.el9.x86_64           @docker-ce-stable
#     Upgraded docker-ce-cli-1:27.1.1-1.el9.x86_64           @@System
#     Upgrade  docker-ce-rootless-extras-27.1.2-1.el9.x86_64 @docker-ce-stable
#     Upgraded docker-ce-rootless-extras-27.1.1-1.el9.x86_64 @@System

# [0]
# the package name needs to <<start with>> any of the following names, e.g. `containerd` matches `containerd.io-1.7.20-3.1.el9.x86_64` etc.
PACKAGE_PREFIXES_TO_CHECK=(
  "containerd.io"
  "docker-ce" # includes `docker-ce-cli` and `docker-ce-rootless-extras`
  "docker-buildx-plugin"
)

set -o errexit
set -o nounset
set -o pipefail

if [[ "${TRACE-0}" == "1" ]]; then
  set -o xtrace
fi

update_action() {
  printf "Executing dnf update -y\n"
  dnf update -y
}

reboot_action() {
  printf "Executing shutdown -t 1\n"
  shutdown -t 1
}

check_kernel_reboot_required() {
  if needs-restarting -r | grep --quiet "Reboot should not be necessary."; then
    printf "No reboot required, return 1\n"
    return 1
  else
    printf "Reboot required, return 0\n"
    return 0
  fi
}

essential_package_updated() {
  LAST_TRANSACTION=$(dnf history info last)
  printf "Checking last dnf transaction which reads:\n\n---\n\n$LAST_TRANSACTION\n\n---\n\n"

  LAST_TRANSACTION_BEGIN_TIME=$(echo "$LAST_TRANSACTION" | grep "Begin time") # Begin time     : Thu 22 Aug 2024 11:30:19 PM CEST
  TODAY=$(date '+%a %d %b %Y') # Fri 23 Aug 2024
  if echo $LAST_TRANSACTION_BEGIN_TIME | grep --quiet "$TODAY"; then
    printf "Latest upgrade transaction took place today (i.e., was instrumented by this script run) -> continuing to check wheter packages requiring a reboot got upgraded\n"
  else
    printf "INFO: Latest upgrade action did NOT happen today (=\"$TODAY\"), but on \"$LAST_TRANSACTION_BEGIN_TIME\" instead -> NOT continuing to check whether any packages got an update since this happened in a previous run of this script already; return 1\n"
    return 1
  fi

  UPGRADED_PACKAGES=$(echo "$LAST_TRANSACTION" | grep -E "Upgrade[[:space:]]+")
  printf "Checking whether essential packages requiring a reboot got upgraded; upgraded packages are:\n\n---\n\n$UPGRADED_PACKAGES\n\n---\n\n"

  for PACKAGE_PREFIX in "${PACKAGE_PREFIXES_TO_CHECK[@]}"; do
    if echo "$UPGRADED_PACKAGES" | grep --quiet "$PACKAGE_PREFIX"; then
      printf "Essential package with prefix \"$PACKAGE_PREFIX\" was updated -> reboot required; return 0\n"
      return 0
    fi
  done

  printf "No essential package requiring a reboot got upgraded; return 1\n"
  return 1
}

main() {
  update_action
  if check_kernel_reboot_required; then
    reboot_action
  else
    if essential_package_updated; then
      printf "Essential package(s) HAVE been updated -> rebooting now\n"
      reboot_action
    else
      printf "No essential package(s) have been updated, nothing to do\n"
    fi
  fi

  exit 0
}

main "$@"
