# Boots the installer's kiosk (installer/common.nix) in a VM and walks the
# graphical installer through a fake engine speaking the same @@ protocol as
# install-nixos.sh: choose page, a question, a failure. Screenshots land in
# the result.   nix build -L .#checks.x86_64-linux.installer-gui
{ pkgs, ... }:

let
  fakeEngine = pkgs.writeShellScript "fake-install-nixos" ''
    echo "== NixOS installer (fake)"
    echo "@@STEP 1 Fetch the configuration"; sleep 1
    echo "Using latest config"
    echo "@@STEP 3 Sign in and collect secrets"
    echo "@@ASK newsecret Disk encryption passphrase (typed at every boot)"
    IFS= read -r answer
    echo "got ''${#answer} characters"
    echo "@@STEP 6 Install NixOS"; sleep 2
    printf '\033[1;31mError: nixos-install failed; preserve /mnt and resume\033[0m\n'
    exit 1
  '';
in
{
  name = "installer-gui";
  node.pkgsReadOnly = false; # installer/common.nix sets nixpkgs.config itself

  nodes.machine = { lib, ... }: {
    imports = [ ../installer/common.nix ];
    users.users.nixos = {
      isNormalUser = true;
      extraGroups = [ "wheel" "networkmanager" "video" ];
    };
    security.sudo.wheelNeedsPassword = false;
    virtualisation = {
      memorySize = 3072;
      cores = 4;
      resolution = { x = 1280; y = 800; };
      qemu.options = [ "-vga virtio" ];
      emptyDiskImages = [ 2048 ];
    };
    environment.sessionVariables = {
      INSTALLER_FAKE_ENGINE = "${fakeEngine}";
      INSTALLER_TEST = lib.mkDefault "1";
    };
    specialisation.started.configuration.environment.sessionVariables.INSTALLER_TEST = "start";
    systemd.services.installer-extras.enable = false; # no internet in the sandbox
  };

  testScript = ''
    def gui():
        machine.wait_until_succeeds("pgrep -f installer-gui")
        machine.sleep(8)

    machine.wait_for_unit("greetd.service")
    gui()
    machine.screenshot("1-choose")

    machine.succeed("/run/current-system/specialisation/started/bin/switch-to-configuration test")
    machine.succeed("systemctl restart greetd")
    gui()
    machine.screenshot("2-question")
    machine.send_chars("hunter2\nhunter2\n")
    machine.sleep(1)
    machine.screenshot("3-installing")
    machine.wait_until_succeeds("grep -q 'got 7 characters' /tmp/install-nixos.log")
    machine.wait_until_succeeds("grep -q 'Error: nixos-install failed' /tmp/install-nixos.log")
    machine.sleep(2)
    machine.screenshot("4-failed")
  '';
}
