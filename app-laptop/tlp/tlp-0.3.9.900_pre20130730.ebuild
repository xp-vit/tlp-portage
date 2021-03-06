# Copyright 1999-2013 Gentoo Foundation
# Distributed under the terms of the GNU General Public License v2
# $Header: $

EAPI=5

inherit base eutils bash-completion-r1 git-2 linux-info systemd

DESCRIPTION="Power-Management made easy, designed for Thinkpads."
HOMEPAGE="http://linrunner.de/en/tlp/tlp.html"

EGIT_REPO_URI='git://github.com/linrunner/TLP.git'
EGIT_BRANCH='devel'
EGIT_COMMIT='ab835217dd7db4e86fd565df420e84e01aaa4b90'

SRC_URI="http://git.erdmann.es/trac/dywi_tlp-gentoo-additions/downloads/tlp-gentoo-additions-0.3.9.tar.bz2"
RESTRICT="mirror"

LICENSE="GPL-2 tpacpi-bundled? ( GPL-3 )"

SLOT="0"

#KEYWORDS="~x86 ~amd64"
KEYWORDS=""

IUSE="tlp_suggests rdw +openrc systemd bash-completion laptop-mode-tools +tpacpi-bundled"
REQUIRED_USE="|| ( openrc systemd )"

_PKG_TPACPI='>app-laptop/tpacpi-bat-1.0'
_PKG_TPSMAPI='app-laptop/tp_smapi'
_PKG_ACPICALL='sys-power/acpi_call'
_OPTIONAL_DEPEND='
	sys-apps/smartmontools
	sys-apps/ethtool
	sys-apps/lsb-release
'

DEPEND=""
RDEPEND="${DEPEND:-}
	sys-apps/hdparm

	sys-power/upower[-systemd(-),deprecated(+)]
	sys-power/pm-utils
	sys-power/acpid
	virtual/udev

	dev-lang/perl
	sys-apps/usbutils
	sys-apps/pciutils

	|| ( net-wireless/iw net-wireless/wireless-tools )
	net-wireless/rfkill

	rdw?                ( net-misc/networkmanager )
	tlp_suggests?       ( ${_OPTIONAL_DEPEND} )
	!laptop-mode-tools? ( !app-laptop/laptop-mode-tools )
"

# pm hooks to disable defined by upstream
#
# hooks that have a different name in gentoo:
#  * <none>
#
CONFLICTING_PM_POWERHOOKS_UPSTREAM="95hdparm-apm disable_wol hal-cd-polling
intel-audio-powersave harddrive laptop-mode journal-commit pci_devices
pcie_aspm readahead sata_alpm sched-powersave usb_bluetooth wireless
xfs_buffer"

CONFLICTING_PM_POWERHOOKS="${CONFLICTING_PM_POWERHOOKS_UPSTREAM}"

CONFIG_CHECK='~DMIID ~ACPI_PROC_EVENT'
ERROR_DMIID='DMIID is required by tlp-stat and tpacpi-bat'
ERROR_ACPI_PROC_EVENT='ACPI_PROC_EVENT is required by thinkpad-radiosw'

src_prepare() {
	base_src_prepare
	chmod u+x "${WORKDIR}/gentoo/tlp_configure.sh" && \
	ln -fs "${WORKDIR}/gentoo/tlp_configure.sh" "${S}/configure" || \
		die "cannot setup configure script!"
}

src_configure() {
	# econf is not supported and TLP is noarch, use ./configure directly
	./configure --quiet --src="${S}" \
		--target=gentoo $(use_with tpacpi-bundled) || die "configure failed ($?)"
}

src_compile() { return 0; }

src_install() {
	_tlp_usex() { use "${1}" && echo "TLP_NO_${2:-${1^^}}=1"; }

	## tlp

	# TLP_NO_TPACPI: do not install the bundled tpacpi-bat file
	#                 TLP expects to find tpacpi-bat at /usr/sbin/tpacpi-bat
	# LIBDIR:        use proper libary dir names instead of relying on a
	#                 lib->lib64 symlink on amd64 systems
	emake -f "${WORKDIR}/gentoo/Makefile.gentoo" \
		$(_tlp_usex !tpacpi-bundled TPACPI) \
		TLP_NO_INITD=1 TLP_NO_BASHCOMP=1 TLP_NO_CONFIG=1 \
		DESTDIR="${ED}" LIBDIR=$(get_libdir) \
		install-tlp $(usex rdw install-rdw "")

	## use config file from the additions tarball
	# * 0.3.9_900_pre20130730: no config changes
	newconfd "${WORKDIR}/gentoo/tlp.conf" "${PN}"

	## init file(s)
	use openrc  && newinitd "${WORKDIR}/gentoo/tlp-init.openrc" "${PN}"
	use systemd && systemd_dounit tlp.service

	## bashcomp
	use bash-completion && newbashcomp "tlp.bash_completion" "${PN}"

	## man, doc
	doman man/?*.?*
	dodoc README*
}

pkg_postrm() {
	## Re-enable conflicting pm-utils hooks
	local \
		TLP_NOP="${EROOT%/}/usr/$(get_libdir)/${PN}-pm/${PN}-nop" \
		POWER_D="${EROOT%/}/etc/pm/power.d" \
		hook hook_name

	einfo "Re-enabling power hooks in ${POWER_D} that link to ${TLP_NOP}"
	for hook_name in ${CONFLICTING_PM_POWERHOOKS?}; do
		hook="${POWER_D}/${hook_name}"

		if \
			[[ ( -L "${hook}" ) && ( `readlink "${hook}"` == "${TLP_NOP}" ) ]]
		then
			rm "${hook}" || die "cannot reenable hook ${hook_name}."
		fi
	done
}

pkg_postinst() {
	case "${PV}" in
		*.9??_pre*)
			einfo "You're using a development version of ${PN}."
		;;
	esac

	## Disable conflicting pm-utils hooks
	local \
		TLP_NOP="${EROOT%/}/usr/$(get_libdir)/${PN}-pm/${PN}-nop" \
		POWER_D="${EROOT%/}/etc/pm/power.d" \
		hook_name

	einfo "Disabling conflicting power hooks in ${POWER_D}"

	[[ -e "${POWER_D}" ]] || mkdir "${POWER_D}" || \
		die "cannot create '${POWER_D}'."

	for hook_name in ${CONFLICTING_PM_POWERHOOKS?}; do
		if [[ ! -e "${POWER_D}/${hook_name}" ]]; then
			ln -s -- "${TLP_NOP}" "${POWER_D}/${hook_name}" || \
				die "cannot disable power.d hook ${hook_name}."
		fi
	done

	## postinst messages

	elog "${PN^^} is disabled by default."
	elog "You have to enable ${PN^^} by setting ${PN^^}_ENABLE=1 in /etc/conf.d/${PN}."

	if use openrc; then
		elog "Don't forget to add /etc/init.d/${PN} to your favorite runlevel."
	fi

	if use systemd; then
		ewarn "USE=systemd is unsupported."
		elog  "A service file has been installed to /etc/systemd/system/${PN}-init.service."
	fi

	elog "You must restart acpid after upgrading ${PN}."

	local a
	_check_installed() { has_version "${1}" && a=" (already installed)" || a=; }

	if ! use tlp_suggests; then
		local p
		elog "In order to get full functionality, the following packages should be installed:"
		for p in ${_OPTIONAL_DEPEND?}; do
			_check_installed "${p}"
			elog "- ${p}${a}"
		done
	fi

	elog "For battery charge threshold control,"
	elog "one or more of the following packages are required:"

	_check_installed "${_PKG_TPSMAPI?}"
	elog "- ${_PKG_TPSMAPI?} - for Thinkpads up to Core 2 (and Sandy Bridge partially)${a}"
	if use tpacpi-bundled; then
		_check_installed "${_PKG_ACPICALL?}"
		elog "- ${_PKG_ACPICALL?} - kernel module for Sandy Bridge Thinkpads (this includes Ivy Bridge ones as well)${a}"
	else
		_check_installed "${_PKG_TPACPI?}"
		elog "- ${_PKG_TPACPI?} - for Sandy Bridge Thinkpads (this includes Ivy Bridge ones as well)${a}"
	fi

	if use laptop-mode-tools; then
		ewarn "Reminder: don't run laptop-mode-tools and ${PN} at the same time."
	fi
}
