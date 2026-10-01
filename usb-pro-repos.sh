#!/usr/bin/env bash
# usb-pro-repos.sh — publish filtered Ubuntu Pro repositories (ESM Infra, ESM Apps, FIPS Updates)
# to the same USB drive as usb-repo.sh, signed with the same offline key.
# Run on the internet-connected (low side) mirror host, after `aptly mirror update` and usb-repo.sh.
set -euo pipefail

# ---------------- settings ----------------
REL="jammy"                                     # must match DIST in usb-repo.sh
USB_MOUNT="/media/usb-repo"                     # must match rootDir in ~/.aptly.conf
ENDPOINT="usb"                                  # FileSystemPublishEndpoints key in ~/.aptly.conf
GPG_UID="USB Repo <usb-repo@localhost>"         # same key as usb-repo.sh

# service | USB prefix | upstream suites | apt Origin | pin priority
SERVICES=(
  "esm-infra|esm-infra|${REL}-infra-security ${REL}-infra-updates|UbuntuESM|510"
  "esm-apps|esm-apps|${REL}-apps-security ${REL}-apps-updates|UbuntuESMApps|510"
  "fips-updates|fips-updates|${REL}-updates|UbuntuFIPSUpdates|1001"
)

CLOUD_FLAVORS=(aws azure gcp gke gkeop oracle ibm)
CLOUD_PKGS=(walinuxagent azure-vm-utils google-guest-agent google-osconfig-agent
            google-compute-engine-oslogin gce-compute-image-packages
            ec2-hibinit-agent ec2-instance-connect amazon-ec2-utils
            ubuntu-aws-fips ubuntu-azure-fips ubuntu-gcp-fips)
# ------------------------------------------

STAMP=$(date +%Y%m%d-%H%M)

# Same exclusion query as usb-repo.sh
terms=()
for f in "${CLOUD_FLAVORS[@]}"; do
  terms+=("Name (~ ^linux.*-${f}\$)" "Name (~ ^linux.*-${f}-)")
done
for p in "${CLOUD_PKGS[@]}"; do
  terms+=("Name (= ${p})")
done
EXCLUDE=$(printf ' | %s' "${terms[@]}"); EXCLUDE=${EXCLUDE:3}
KEEP="!(${EXCLUDE})"

KEYID=$(gpg --list-secret-keys --with-colons "$GPG_UID" | awk -F: '/^fpr/{print $10; exit}')
[[ -n "$KEYID" ]] || { echo "ERROR: signing key not found; run usb-repo.sh first" >&2; exit 1; }

mkdir -p "${USB_MOUNT}/pro"

for entry in "${SERVICES[@]}"; do
  IFS='|' read -r svc prefix suites origin prio <<<"$entry"
  target="filesystem:${ENDPOINT}:${prefix}"

  for suite in $suites; do
    mirror="${svc}-${suite}"
    raw="${mirror}-${STAMP}"
    clean="${mirror}-clean-${STAMP}"

    # 1. Snapshot and filter (no merge: each upstream suite is published under its own name)
    aptly snapshot create "$raw" from mirror "$mirror"
    aptly snapshot filter "$raw" "$clean" "$KEEP"
    if [[ -n "$(aptly snapshot search "$clean" "$EXCLUDE" 2>/dev/null || true)" ]]; then
      echo "ERROR: cloud packages still present in ${clean}" >&2; exit 1
    fi

    # 2. Publish or switch, keeping the upstream suite name and Origin
    if aptly publish show "$suite" "$target" >/dev/null 2>&1; then
      aptly publish switch -batch -gpg-key="$KEYID" "$suite" "$target" "$clean"
    else
      aptly publish snapshot -batch -gpg-key="$KEYID" -origin="$origin" \
        -distribution="$suite" -component=main "$clean" "$target"
    fi
  done

  # 3. Client source and pin files
  cat > "${USB_MOUNT}/pro/usb-${svc}.sources" <<EOF
Types: deb
URIs: file:${USB_MOUNT}/${prefix}
Suites: ${suites}
Components: main
Signed-By: /etc/apt/keyrings/usb-repo.gpg
EOF
  cat > "${USB_MOUNT}/pro/usb-${svc}.pref" <<EOF
Package: *
Pin: release o=${origin}
Pin-Priority: ${prio}
EOF
done

# 4. Guard: no Pro credentials may leave the low side
if grep -rqsE "bearer:[^@[:space:]]+@" "${USB_MOUNT}"/*/dists "${USB_MOUNT}/pro"; then
  echo "ERROR: credential string found on the USB; do not transfer it" >&2; exit 1
fi

# 5. Transfer manifest for the media review on the high side
( cd "$USB_MOUNT" && find . -type f ! -name 'SHA256SUMS*' -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS.new && mv SHA256SUMS.new SHA256SUMS )

sync
echo "Done. Published ESM Infra, ESM Apps and FIPS Updates for ${REL} to ${USB_MOUNT}. Safe to unmount."
