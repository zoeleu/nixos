# Typing the disk passphrase without a USB keyboard, then a boot splash.
#
#   initrd:            unl0kr draws an on-screen keyboard when a passphrase is
#                      needed (a USB keyboard still works). With the TPM
#                      enrolled (default.nix) no passphrase is asked at all.
#   after unlocking:   Plymouth shows the splash until Gaming Mode starts.
#
# unl0kr refuses to run while Plymouth is up (its units have
# ConditionPathExists=!/run/plymouth/pid) and Plymouth has no touch keyboard,
# so Plymouth is kept out of the initrd's boot and only starts from the real
# root. tests/touch-unlock.nix boots exactly this module in a VM.
{ lib, ... }:

{
  boot.initrd.unl0kr = {
    enable = true;
    settings.theme.default = "breezy-dark";
  };

  boot.plymouth.enable = true; # themed in modules/branding.nix
  # Installed in the initrd by the Plymouth module, but not started there
  boot.initrd.systemd.services.plymouth-start.wantedBy = lib.mkForce [ ];
  # NixOS expects the splash to be carried over from the initrd, so start it
  # (and link its runtime files, as the initrd would have) from the real root
  systemd.services.plymouth-start = {
    wantedBy = [ "sysinit.target" ];
    preStart = ''
      mkdir -p /run/plymouth
      ln -sfn /etc/plymouth/plymouthd.defaults /etc/plymouth/themes /etc/plymouth/plugins /run/plymouth/
    '';
  };
}
