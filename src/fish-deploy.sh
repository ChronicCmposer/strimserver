#!/usr/bin/env bash

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

