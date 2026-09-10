# ssh-protect: recover SSH from power-loss corruption on seeed boards.
#
# Power loss during first boot / firstlogin can leave sshd_config or host
# keys zero-filled or truncated; sshd then refuses to start and the board is
# unreachable over the network. This sub-extension installs the repair
# script and an ssh.service ExecStartPre drop-in directly into the image
# rootfs, following the same pattern as
# security-hardening/recomputer-security.sh: the payload is static files
# with no dpkg lifecycle needs, so a plain install beats building and
# dpkg-installing a deb at image time (that variant lives on the
# ssh-protect-deb branch). If these files ever need to reach
# already-deployed boards, a deb can take them over cleanly later - dpkg
# overwrites unowned files.
#
# Verified on recomputer-rk3576-industrial: no-op on a healthy system; each
# corruption class repaired (empty / zero-filled / truncated / deleted key,
# zero-filled config); a 4-way corruption survives reboot with SSH back
# within a minute.

# Install the repair script and the ssh.service drop-in into the image rootfs.
function post_family_tweaks__seeed_ssh_protect() {
	local script_dir
	script_dir="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

	display_alert "ssh-protect" "installing ssh.service ExecStartPre recovery" "info"

	install -D -m 0755 "${script_dir}/rootfs/usr/lib/armbian/ssh-protect" \
		"${SDCARD}/usr/lib/armbian/ssh-protect"
	install -D -m 0644 "${script_dir}/rootfs/etc/systemd/system/ssh.service.d/10-armbian-ssh-protect.conf" \
		"${SDCARD}/etc/systemd/system/ssh.service.d/10-armbian-ssh-protect.conf"
}
