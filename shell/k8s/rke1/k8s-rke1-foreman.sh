#!/usr/bin/env bash
# A script that
# (1) updates all packages on a RHEL-like Linux,
# (2) reboots conditionally
# (3) if no reboot is required, checks whether essential kubepods*.slice files got created; these files are usually purged after a dnf docker upgrade
#     if the files don't exist, kubelet gets restarted twice which should create them w/o any service impact
#
# for further details see https://github.com/world-direct/technology/issues/138
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

set -o errexit
set -o nounset
set -o pipefail

if [[ "${TRACE-0}" == "1" ]]; then
  set -o xtrace
fi

# these files are created dynamically by `kubelet` upon start and are essential for scheduling on the current node:
# w/o them no pod of the coresponding QoS class will be able to run, showing an error in the events instead
# for unknown reasons though it usually takes two kubelet restarts for these files to be created
FILES_TO_CHECK=(
  "/run/systemd/transient/kubepods.slice"            # Guaranteed QoS
  "/run/systemd/transient/kubepods-burstable.slice"  # Burstable QoS, depends on `kubepods.slice`
  "/run/systemd/transient/kubepods-besteffort.slice" # Best effort QoS, depends on `kubepods.slice`
)

MAX_RETRIES=2

# delay in seconds between successive kubelet restarts
DELAY=60

check_files() {
  for file in "${FILES_TO_CHECK[@]}"; do
    if [[ ! -f "$file" ]]; then
      echo "File $file does not exist"
      return 1
    fi
  done
  return 0
}

restart_kubelet_action() {
  echo "Executing docker restart kubelet"
  docker restart kubelet
}

update_action() {
  echo "Executing dnf update -y"
  dnf update -y
}

reboot_action() {
  echo "Executing shutdown -t 1"
  shutdown -t 1
}

check_reboot() {
  if needs-restarting -r | grep --quiet "Reboot should not be necessary."; then
    echo "No reboot required, return 0"
    return 0
  else
    echo "Reboot required, return 1"
    return 1
  fi
}

kubelet_restart_loop() {
  for ((i=0; i<MAX_RETRIES; i++)); do
    if check_files; then
      echo "All required files exist, not restarting kubelet"
      return 0
    fi

    echo "One or more files do not exist -> restarting kubelet"
    restart_kubelet_action

    echo "Sleeping for $DELAY seconds to give kubelet time to boot up properly and create the required files which usually happens after the 2nd kubelet restart, cf. https://github.com/world-direct/technology/issues/138"
    sleep $DELAY
  done

  if ! check_files; then
    echo "ERROR: Files still do not exist after $MAX_RETRIES kubelet restarts"
    return 1
  else
    return 0
  fi
}

main() {
  update_action
  if ! check_reboot; then
    reboot_action
  else
    # TODO: we could check whether docker/containerd got an update which is usually when the error occurs
    # we could, e.g. use `dnf history info last | grep -i docker` here
    # however, simply checking always does not really hurt
    if ! kubelet_restart_loop; then
      echo "ERROR: kubelet restart did not help restoring files, manual intervention required, exit 1"
      exit 1
    else
      echo "INFO: OK, all required files exist, return 0"
      return 0
    fi
  fi
}

main "$@"
