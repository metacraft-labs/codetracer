# `codetracer-incus-vm` — run ONE command from a codetracer checkout inside a
# NixOS VM that has a real Incus daemon with a managed bridge.
#
# ## Why a VM, and why this is the whole of the CI capability
#
# `ci/test/host-image-serves-in-a-container.sh` needs an Incus daemon: it
# launches `ct host`'s published image as a container, waits for the container's
# own DHCP lease on a managed bridge, and `curl`s the server from OUTSIDE the
# container's network namespace. No runner class hands a job an Incus daemon —
# the ephemeral Linux runners are themselves Incus containers, and they give a
# job Docker and `/dev/kvm`, not Incus (infra `docs/CI-Runner-Fleet-Status.md`,
# "Docker is on EVERY ephemeral Linux runner"; every one carries the `kvm`
# label since infra's 2026-10-11 KVM fold-back).
#
# `/dev/kvm` is enough. This boots the stock NixOS Incus host — the same
# preseed nixpkgs' own `nixos/tests/incus` uses — so the daemon, the bridge, its
# dnsmasq and the nftables NAT are the real ones, configured by the real
# module, and the command runs as root on that host. Nothing about the gate
# changes: it is the same script an operator runs on their own Incus host.
#
# An OCI-runtime variant of the gate was the other route the issue offered, and
# it would grade a different seam: Docker starts `Entrypoint` with a network it
# configured itself, while the substrate starts `/sbin/init` and the container
# leases its own address. The three defects that gate was written around (see
# its header) are all on the Incus side of that difference.
#
# ## The interface
#
#   CT_INCUS_VM_REPO=<abs path of a codetracer checkout> \
#   CT_INCUS_VM_COMMAND='<shell command>' \
#     $(nix build --print-out-paths .#codetracer-incus-vm)/bin/nixos-test-driver
#
# The checkout is shared into the VM at `/repo` and the command runs there. The
# host's `/nix/store` is the VM's store (the test framework mounts it), so a
# store path the caller built — an image archive, a `sessionctl` — is usable
# inside under the same name, which is how the caller hands those in. The driver
# exits non-zero exactly when the command does.
#
# This is the test framework's `.driver`, not a sandboxed check, because the
# command and the checkout are RUN-TIME inputs: a check would have to bake the
# repository into a derivation, and the gate's fixture is a submodule the
# sandbox does not see. `ci/test/host-image-serves-in-incus-vm.sh` is the
# caller.
{ pkgs }:
let
  test = pkgs.testers.runNixOSTest {
    name = "codetracer-incus-vm";

    nodes.machine =
      { pkgs, ... }:
      {
        virtualisation = {
          # Sized for `ci/publish-host-image.sh`: it unpacks a ~1.5 GB rootfs,
          # packs a ~400 MB tarball beside it, and Incus unpacks the import
          # again into its storage pool. The disk image is sparse.
          cores = 4;
          memorySize = 6144;
          diskSize = 24 * 1024;

          # The caller's checkout, at a path chosen at RUN time: qemu's
          # `-virtfs path=` is expanded by the start script's shell, exactly as
          # the framework's own `SHARED_DIR` is.
          sharedDirectories.repo = {
            source = ''"''${CT_INCUS_VM_REPO:?CT_INCUS_VM_REPO names the checkout to share}"'';
            target = "/repo";
          };

          # nixpkgs' `nixos/tests/incus/incus-tests.nix` preseed: one managed
          # bridge, a `dir` pool, and a default profile wiring both. The gate
          # reads the container's address off this bridge and reaches it from
          # this VM, which is "outside the container's namespace".
          incus = {
            enable = true;
            preseed = {
              networks = [
                {
                  name = "incusbr0";
                  type = "bridge";
                  config = {
                    "ipv4.address" = "10.0.10.1/24";
                    "ipv4.nat" = "true";
                    "ipv6.address" = "none";
                  };
                }
              ];
              profiles = [
                {
                  name = "default";
                  devices = {
                    eth0 = {
                      name = "eth0";
                      network = "incusbr0";
                      type = "nic";
                    };
                    root = {
                      path = "/";
                      pool = "default";
                      type = "disk";
                    };
                  };
                }
              ];
              storage_pools = [
                {
                  name = "default";
                  driver = "dir";
                }
              ];
            };
          };
        };

        # The NixOS Incus module requires nftables; the bridge's DHCP and DNS
        # (dnsmasq on incusbr0) are refused by the default firewall unless the
        # interface is trusted — without this the container's init reports
        # `no-lease`, which is a finding about this VM and not about the image.
        networking.nftables.enable = true;
        networking.firewall.trustedInterfaces = [ "incusbr0" ];

        # What `ci/publish-host-image.sh` and the gate call, and nothing else.
        # `git` because the publisher derives a default alias from the revision.
        environment.systemPackages = with pkgs; [
          bashInteractive
          coreutils
          curl
          findutils
          gawk
          git
          gnugrep
          gnused
          gnutar
          gzip
          python3
          zip
          # `sessionctl image build` packs the substrate's own base image from
          # these, resolved off PATH (isonim-platform `defaultImageSpec`).
          iproute2
          dhcpcd
        ];
      };

    # `</dev/null` IS LOAD-BEARING. A command run through the test driver's
    # backdoor inherits the backdoor's stdin, and `incus exec` forwards its
    # stdin into the container: infra's `checks/ephemeral-linux-runners-docker.nix`
    # measured incusd buffering it until the VM's OOM killer fired (7.4 GiB
    # resident) and the exec never returning. The gate's `incus exec` calls
    # take no input, so closing stdin here costs nothing.
    #
    # The output is teed to the serial console so a CI log shows the command's
    # progress as it happens, not one block after it ends. `execute` must still
    # capture it (its default): with `check_output=False` it returns -2 at once,
    # before the command has run, and the exit status is lost.
    testScript = ''
      import os
      import shlex

      command = os.environ.get("CT_INCUS_VM_COMMAND", "")
      if not command:
          raise Exception("CT_INCUS_VM_COMMAND names the command to run in the VM")

      machine.wait_for_unit("incus.service")
      machine.wait_for_unit("incus-preseed.service")
      machine.succeed("incus network info incusbr0 >&2")
      machine.succeed("test -d /repo/.git || test -f /repo/.git")

      wrapped = (
          "set -o pipefail; cd /repo && "
          + "bash -c " + shlex.quote(command)
          + " </dev/null 2>&1 | tee /dev/ttyS0"
      )
      status, _ = machine.execute(wrapped, timeout=None)
      if status != 0:
          raise Exception(f"the command exited {status} inside the Incus VM")
    '';
  };
in
test.driver
