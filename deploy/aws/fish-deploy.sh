#!/usr/bin/env bash

# fish is an operator convenience shell, not required by strimserver. The pinned
# release URL below is x86_64-only; on any other architecture (e.g. aarch64 on
# the g5g.2xlarge arm64 target) we skip the install loudly rather than download
# a wrong-arch binary. This script is `source`d by deploy.sh, so the guard uses
# `return` - an `exit` would kill the parent deploy.
MACHINE="$(uname -m)"
if [[ "$MACHINE" != "x86_64" && "$MACHINE" != "amd64" ]]; then
   printf "\n*** fish shell: skipped on %s ***\n" "$MACHINE"
   printf "The pinned fish 4.3.1 release URL is x86_64-only and strimserver does not\n"
   printf "ship a pinned aarch64 fish build. fish is an operator convenience shell,\n"
   printf "not required by strimserver - install it manually later if you want it:\n"
   printf "  sudo dnf install fish     # or build from https://github.com/fish-shell/fish-shell\n\n"
   return 0
fi

printf "configuring fish shell...\n"
FISH_DIST_URL="https://github.com/fish-shell/fish-shell/releases/download/4.3.1/fish-4.3.1-linux-x86_64.tar.xz"
FISH_DIST_CHECKSUM="dda2233dde1f36918a4ee2055a2bbbb61ddbdc9d81e77004885529b25560ba1f"
FISH_TEMP_DIR="$(mktemp -d)"
FISH_DIST_FILE="$FISH_TEMP_DIR/fish-bin.tar.xz"
FISH_SYSTEM_CONFIG_FILE="/etc/fish/config.fish"
FISH_VENDOR_COMPLETIONS_DIR="/usr/share/fish/vendor_completions.d"
set -x
wget "$FISH_DIST_URL" -O "$FISH_DIST_FILE" 
echo "$FISH_DIST_CHECKSUM  $FISH_DIST_FILE" | sha256sum --check -
sudo tar -xvJf "$FISH_DIST_FILE" -C /usr/local/bin
sudo mkdir -p $(dirname $FISH_SYSTEM_CONFIG_FILE)
{ 
   printf "if status is-interactive\n"
   printf "   fish_vi_key_bindings\n"
   printf "end\n\n"
   printf "set -gx fish_color_host_remote brcyan\n"

} | sudo tee "$FISH_SYSTEM_CONFIG_FILE"

cat "$FISH_SYSTEM_CONFIG_FILE" prompt_login.fish | sudo tee "$FISH_SYSTEM_CONFIG_FILE"
rm -f /mnt/nvme/prompt_login.fish

sudo mkdir -p "$FISH_VENDOR_COMPLETIONS_DIR"

FISH_SHELL=$(which fish)
if [[ ! -s /etc/shells.original ]]; then
   sudo cp /etc/{shells,shells.original}
fi
echo "$FISH_SHELL" | cat /etc/shells.original - | sudo tee /etc/shells
sudo usermod -s "$FISH_SHELL" ec2-user
fish --version
set +x
printf "fish shell configured!\n"

