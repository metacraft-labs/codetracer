#!/usr/bin/env bash

set -e

eprint_note() {
    echo "[CodeTracer installer] $1"
    sleep 1
}

eprint_error() {
    echo -e "\x1b[31m[CodeTracer installer Error]: $1\x1b[0m"
    exit 1
}

eprint_warning() {
    echo -e "\x1b[33m[CodeTracer installer Warning]: $1\x1b[0m"
    sleep 1
}

eprint_success() {
    echo -e "\x1b[32mSuccessfully installed CodeTracer!\x1b[0m"
    exit 0
}

eprint_install_fail() {
    eprint_error "Couldn't install CodeTracer!"
}

super=""
request_privilleged_access() {
    sudo=$(which sudo || echo "")
    doas=$(which doas || echo "")

    if [ "$sudo" != "" ]; then
        super="sudo"
    elif [ "$doas" != "" ]; then
        super="doas"
    else
        eprint_error "Could not find either sudo or doas. Please install either one so that we can ellevate privilleges!"
    fi
}

install_apt() {
    if [ "$(which apt)" == "" ]; then
        return 0
    fi

    request_privilleged_access || return 1
    getw=$(which wget || echo "")
    if [ "$getw" == "" ]; then
        eprint_note "Installing wget!"
        "$super" apt install -y wget || eprint_error "Couldn't install wget!"
    fi

    "$super" mkdir -p /etc/apt/sources.list.d /etc/apt/trusted.gpg.d &> /dev/null || eprint_error "Couldn't created directories for repository!"

    "$super" sh -c 'echo "deb [arch=amd64] https://deb.codetracer.com stable main" > /etc/apt/sources.list.d/metacraft-debs.list' || eprint_error "Couldn't install repository metadata!"
    eprint_note "Added apt repository as /etc/apt/sources.list.d/metacraft-debs.list"

    (wget "https://deb.codetracer.com/keys/public.asc" && "$super" mv public.asc /etc/apt/trusted.gpg.d/metacraft-debs.asc) || eprint_error "Couldn't install gpg public key!"
    eprint_note "Installed the public key for CodeTracer as /etc/apt/trusted.gpg.d/metacraft-debs.asc"

    eprint_note "Running apt update!"
    "$super" apt update -y || eprint_error "Couldn't update repositories!"

    eprint_note "Installing CodeTracer!"
    "$super" apt install -y codetracer || eprint_install_fail

    eprint_success
}

install_rpm() {
    request_privilleged_access || return 1
    "$super" mkdir -p /etc/yum.repos.d &> /dev/null || return 1

    "$super" sh -c 'echo " \
[metacraft-rpms]
name=MetacraftRPM
baseurl=https://rpm.codetracer.com/
enabled=1
gpgcheck=1
gpgkey=https://rpm.codetracer.com/rpmkey.pub" > /etc/yum.repos.d/metacraft-rpms.repo' || return 1

    eprint_note "Added RPM repository as /etc/yum.repos.d/metacraft-rpms.repo"
}

install_dnf() {
    if [ "$(which dnf)" == "" ]; then
        return 0
    fi

    install_rpm || eprint_error "Couldn't install rpm repository!"

    eprint_note "Updating repositories"
    "$super" dnf -y update || eprint_error "Couldn't update repositories"

    eprint_note "Installing CodeTracer"
    "$super" dnf -y install codetracer || eprint_install_fail

    eprint_success
}

install_yum() {
    if [ "$(which yum)" == "" ]; then
        return 0
    fi

    install_rpm || eprint_error "Couldn't install rpm repository!"

    eprint_note "Updating repositories"
    "$super" yum -y update || eprint_error "Couldn't update repositories"

    eprint_note "Installing CodeTracer"
    "$super" yum -y install codetracer || eprint_install_fail

    eprint_success
}

install_portage() {
    if [ "$(which emerge)" == "" ]; then
        return 0
    fi

    request_privilleged_access || return 1

    emerge app-eselect/eselect-repository || eprint_error "Couldn't install eselect-repository!"

    gitt=$(which git || echo "")
    if [ "$gitt" == "" ]; then
        eprint_note "Installing git"
        emerge dev-vcs/git || eprint_error "Couldn't install git!"
    fi

    eprint_note "Adding ebuild overlay"
    "$super" eselect repository add metacraft-overlay git https://github.com/metacraft-labs/metacraft-overlay.git || eprint_error "Couldn't add gentoo overlay!"

    eprint_note "Synchronizing repositories"
    "$super" emerge --sync metacraft-overlay || eprint_error "Couldn't sync repositories!"

    eprint_note "Installing CodeTracer"
    "$super" emerge codetracer-bin || eprint_install_fail

    eprint_success
}

install_pamac() {
    eprint_note "Installing CodeTracer"
    pamac build codetracer --no-confirm || eprint_install_fail
    eprint_success
}

install_yay() {
    eprint_note "Installing CodeTracer"
    yay -S codetracer --noconfirm || eprint_install_fail
    eprint_success
}

install_paru() {
    eprint_note "Installing CodeTracer"
    paru -S codetracer --noconfirm || eprint_install_fail
    eprint_success
}

download_and_verify() {
    eprint_note "Downloading $1"

    curl -fL --output "CodeTracer.pub.asc" "https://downloads.codetracer.com/CodeTracer.pub.asc" || eprint_error "Couldn't download gpg public key!"
    curl -fL --output "CodeTracer.$1.asc" "https://downloads.codetracer.com/CodeTracer-latest-$2.$1.asc" || eprint_error "Couldn't download gpg signature!"
    curl -fL --output "CodeTracer.$1" "https://downloads.codetracer.com/CodeTracer-latest-$2.$1" || eprint_error "Couldn't download $1"

    if [ "$(which gpg)" != "" ]; then
        while true; do
            if ! gpg --import CodeTracer.pub.asc; then
                eprint_warning "Couldn't import gpg key. Probably caused by an inactive gpg agent"
                break
            fi

            if ! gpg --verify CodeTracer."$1".asc CodeTracer."$1"; then
                eprint_warning "Couldn't verify bundle integrity. Aborting!"
                break
            fi
            eprint_note "Successfully verified $1 signature"
            break
        done
    else
        eprint_warning "Couldn't verify bundle integrity because gpg is not installed."
    fi
    rm CodeTracer.*.asc
}

install_dmg() {
    if [ "$(uname)" != "Darwin" ]; then
        return 0
    fi

    if [ "$(which brew)" != "" ]; then
        brew install ruby
    else
        eprint_warning "Homebrew was not found on your system. It is required for Ruby support to function. Please install it if possible."
    fi

    download_and_verify dmg arm64 || return 1

    eprint_note "Mounting DMG"
    MOUNT_INFO=$(hdiutil attach "CodeTracer.dmg" -nobrowse -readonly)
    MOUNT_POINT=$(echo "$MOUNT_INFO" | awk '/\/Volumes\// {print $3; exit}')

    if [ -z "$MOUNT_POINT" ]; then
        eprint_error "Failed to mount DMG."
    fi

    eprint_note "Mounted at: $MOUNT_POINT"

    # Find .app bundle inside
    APP_PATH=$(find "$MOUNT_POINT" -maxdepth 1 -type d -name "CodeTracer.app" | head -n 1)

    if [ -z "$APP_PATH" ]; then
        hdiutil detach "$MOUNT_POINT" > /dev/null
        eprint_error "No .app bundle found in DMG."
    fi

    eprint_note "Copying to /Applications..."
    ditto "$APP_PATH" /Applications/CodeTracer.app

    eprint_note "App installed to /Applications."

    # Unmount DMG
    eprint_note "Unmounting DMG..."
    hdiutil detach "$MOUNT_POINT" >/dev/null

    eprint_note "Running xattr -c on the bundle"
    xattr -c "/Applications/CodeTracer.app"

    rm -rf CodeTracer.dmg

    eprint_success
}

install_appimage() {
    download_and_verify AppImage amd64 || return 1
    
    eprint_note "Installing AppImage"
    mkdir -p "$HOME/.local/bin" || eprint_error "Couldn't create $HOME/.local/bin!"
    mv CodeTracer.AppImage "$HOME/.local/bin/ct" || eprint_error "Couldn't install ct in $HOME/.local/bin!"

    "$HOME"/.local/bin/ct install

    eprint_success
}

install_apt
install_dnf
install_yum
install_portage

pamac=$(which pamac || echo "")
yay=$(which yay || echo "")
paru=$(which paru || echo "")
pacman=$(which pacman || echo "")

if [ "$pamac" != "" ]; then
    install_pamac
    exit 0
fi

if [ "$yay" != "" ]; then
    install_yay
    exit 0
fi

if [ "$paru" != "" ]; then
    install_paru
    exit 0
fi

if [ "$pacman" != "" ] && [ "$yay" == "" ] && [ "$pamac" == "" ] && [ "$paru" == "" ]; then
    eprint_warning "\
Installing on an Arch Linux system without AUR helper that is one of yay, pamac or paru.
Please install one of them, or request that we add support for your AUR helper, so that you get automatic updates!"
    eprint_warning "Installing as AppImage instead!"
fi

install_dmg
install_appimage
